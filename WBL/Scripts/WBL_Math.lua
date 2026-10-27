-- Engine-independent math. Load WBL_Config.lua first; no game API or state mutation.
WBL_MATH = {}
local M = WBL_MATH

local function configOrDefault(config)
  return config or WBL_CONFIG
end

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function requireNonnegative(value, label)
  assert(finite(value) and value >= 0, label .. " must be finite and nonnegative")
end

function M.Clamp(value, minimum, maximum)
  assert(finite(value) and finite(minimum) and finite(maximum) and minimum <= maximum)
  return math.max(minimum, math.min(maximum, value))
end

function M.RoundNearest(value)
  assert(finite(value))
  if value < 0 then return math.ceil(value - 1 / 2) end
  return math.floor(value + 1 / 2)
end

function M.ScaleTurns(standardTurns, scale)
  requireNonnegative(standardTurns, "standardTurns")
  assert(finite(scale) and scale > 0)
  if standardTurns == 0 then return 0 end
  return math.max(1, M.RoundNearest(standardTurns * scale))
end

function M.SpeedGrowth(standardGrowth, scale)
  assert(finite(standardGrowth) and standardGrowth > -1)
  assert(finite(scale) and scale > 0)
  return (1 + standardGrowth) ^ (1 / scale) - 1
end

function M.Growth(currentIndex, priorIndex, scale, config)
  local c = configOrDefault(config)
  local fallback = M.SpeedGrowth(c.growth.standardDefault, scale)
  if priorIndex == nil then return fallback, "bootstrap" end
  if not finite(currentIndex) or not finite(priorIndex)
      or currentIndex <= 0 or priorIndex <= 0 then
    return nil, "nonpositive_or_invalid_index"
  end
  local window = M.ScaleTurns(c.growth.windowTurns, scale)
  local raw = (currentIndex / priorIndex) ^ (1 / window) - 1
  local low = M.SpeedGrowth(c.growth.standardMin, scale)
  local high = M.SpeedGrowth(c.growth.standardMax, scale)
  return M.Clamp(raw, low, high), "measured", raw
end

function M.Median(values)
  if #values == 0 then return nil end
  local ordered = {}
  for i = 1, #values do
    assert(finite(values[i]), "median values must be finite")
    ordered[i] = values[i]
  end
  table.sort(ordered)
  local middle = math.floor(#ordered / 2) + 1
  if #ordered % 2 == 1 then return ordered[middle] end
  return (ordered[middle - 1] + ordered[middle]) / 2
end

function M.NetGPT(goldYield, maintenance)
  assert(finite(goldYield) and finite(maintenance))
  return goldYield - maintenance
end

function M.WorldIncome(players)
  local total, count = 0, 0
  for i = 1, #players do
    local p = players[i]
    if p.alive and p.isMajor then
      assert(finite(p.netGPT))
      total, count = total + p.netGPT, count + 1
    end
  end
  if count == 0 then return nil, 0 end
  return total / count, count
end

function M.ClampedDebit(gold, requested)
  requireNonnegative(gold, "gold")
  requireNonnegative(requested, "requested")
  local paid = math.min(gold, requested)
  return paid, gold - paid
end

-- Facts: ordered array {id, alive, isMajor, human, score, netGPT, difficulty}.
-- AI reference scores are normalized; an AI borrower's numerator remains raw.
function M.ReferenceGroup(players, borrowerIsHuman, config)
  local c = configOrDefault(config)
  local humanCount = 0
  for i = 1, #players do
    local p = players[i]
    if p.alive and p.isMajor and p.human then humanCount = humanCount + 1 end
  end
  local humansOnly = borrowerIsHuman and humanCount >= 2
  local group = {}
  for i = 1, #players do
    local p = players[i]
    if p.alive and p.isMajor and (not humansOnly or p.human) then
      local divisor = 1
      if not p.human then
        divisor = c.tiers.difficultyFactor[p.difficulty]
        assert(divisor and divisor > 0, "unconfigured AI difficulty factor")
      end
      group[#group + 1] = {id = p.id, score = p.score / divisor, netGPT = p.netGPT}
    end
  end
  table.sort(group, function(a, b) return a.id < b.id end)
  return group
end

function M.ReferenceMedians(players, borrowerIsHuman, config)
  local group = M.ReferenceGroup(players, borrowerIsHuman, config)
  local scores, incomes = {}, {}
  for i = 1, #group do scores[i], incomes[i] = group[i].score, group[i].netGPT end
  return M.Median(scores), M.Median(incomes), #group
end

function M.DevelopmentRatio(rawScore, referenceMedian, config)
  local c = configOrDefault(config)
  requireNonnegative(rawScore, "rawScore")
  requireNonnegative(referenceMedian, "referenceMedian")
  return (rawScore + c.tiers.smoothingK) / (referenceMedian + c.tiers.smoothingK)
end

function M.ClassifyTier(ratio, netGPT, referenceGPT, groupCount, config)
  local c = configOrDefault(config)
  assert(finite(ratio))
  if groupCount == 1 or ratio >= c.tiers.developedBoundary then return "DEVELOPED" end
  if ratio >= c.tiers.underdevelopedBoundary then return "DEVELOPING" end
  if c.tiers.blendCapEnabled and netGPT >= referenceGPT then return "DEVELOPING" end
  return "UNDERDEVELOPED"
end

-- Ratio-only hysteresis; apply the separate blend cap in reducer eligibility.
-- Returns current/new tier, pending target (nil when cleared), pending count.
function M.Hysteresis(currentTier, pendingTier, pendingCount, ratio, config)
  local c = configOrDefault(config)
  local developed = c.tiers.developedBoundary
  local underdeveloped = c.tiers.underdevelopedBoundary
  local margin = c.tiers.hysteresisMargin
  local target = currentTier
  if currentTier == "DEVELOPED" then
    if ratio < underdeveloped - margin then target = "UNDERDEVELOPED"
    elseif ratio < developed - margin then target = "DEVELOPING" end
  elseif currentTier == "DEVELOPING" then
    if ratio >= developed + margin then target = "DEVELOPED"
    elseif ratio < underdeveloped - margin then target = "UNDERDEVELOPED" end
  elseif currentTier == "UNDERDEVELOPED" then
    if ratio >= developed + margin then target = "DEVELOPED"
    elseif ratio >= underdeveloped + margin then target = "DEVELOPING" end
  else error("unknown tier") end
  if target == currentTier then return currentTier, nil, 0 end
  local count = 1
  if pendingTier == target then count = pendingCount + 1 end
  if count >= c.tiers.hysteresisTurns then return target, nil, 0 end
  return currentTier, target, count
end

-- Product is optional after config so existing ordinary-quote callers keep their arguments.
function M.AdjustedV(tier, rating, investor, liquidityAdjustment, scarActive, config, product)
  local c = configOrDefault(config)
  if product == nil then product = "ORDINARY" end
  assert(product == "ORDINARY" or product == "RECOVERY", "unknown loan product")
  assert(c.tiers[tier] and c.credit[rating])
  assert(rating ~= "D", "rating D cannot originate a loan")
  local base = c.tiers[tier].valueRatio
  if product == "RECOVERY" then base = c.disasterRecovery.valueRatio[tier] end
  local value = base + c.credit[rating].valueAdjustment
  if investor then value = value + c.investors.preferredValueAdjustment
  else value = value + liquidityAdjustment end
  if scarActive then value = value + c.credit.scarValueAdjustment end
  return math.max(c.floors.valueRatio, value)
end

function M.LoanQuote(principal, valueRatio, growth, paymentTurns, graceTurns, config)
  local c = configOrDefault(config)
  assert(finite(principal) and principal > 0)
  assert(finite(valueRatio) and valueRatio > 0)
  assert(finite(growth) and growth > -1)
  assert(finite(paymentTurns) and paymentTurns >= 1 and paymentTurns % 1 == 0)
  requireNonnegative(graceTurns, "graceTurns")
  assert(graceTurns % 1 == 0, "graceTurns must be an integer")
  local annuity = paymentTurns
  if growth ~= 0 then annuity = (1 - (1 + growth) ^ (-paymentTurns)) / growth end
  local pvPerGold = annuity * (1 + growth) ^ (-graceTurns)
  local nominal = math.max(c.floors.nominalRate, valueRatio * paymentTurns / pvPerGold - 1)
  local total = principal * (1 + nominal)
  return {principal = principal, valueRatio = valueRatio, growth = growth,
    paymentTurns = paymentTurns, graceTurns = graceTurns, annuity = annuity,
    pvPerGold = pvPerGold, nominalRate = nominal, totalRepayment = total,
    payment = total / paymentTurns}
end

-- Pure preview only: the reducer must separately establish eligibility and reserve cash.
-- growth is already expressed per game turn; term and grace are scaled from Standard.
function M.ProductLoanQuote(request, config)
  local c = configOrDefault(config)
  local product = request.product
  if product == nil then product = "ORDINARY" end
  local tier = c.tiers[request.tier]
  assert(tier and tier.terms, "unknown development tier")
  local allowedTerm = false
  for i = 1, #tier.terms do
    if request.standardTermTurns == tier.terms[i] then allowedTerm = true end
  end
  assert(allowedTerm, "term is not available to this development tier")
  local value = M.AdjustedV(request.tier, request.rating, request.investor,
    request.liquidityAdjustment, request.scarActive, c, product)
  local quote = M.LoanQuote(request.principal, value, request.growth,
    M.ScaleTurns(request.standardTermTurns, request.scale),
    M.ScaleTurns(tier.graceTurns, request.scale), c)
  quote.product, quote.tier = product, request.tier
  quote.standardTermTurns = request.standardTermTurns
  return quote
end

function M.RecoveryClaimWindow(scale, config)
  local c = configOrDefault(config)
  return M.ScaleTurns(c.disasterRecovery.claimWindowTurns, scale)
end

-- No extra credit line or earmarked recovery pool: inputs are the normal remaining limits.
function M.RecoveryPrincipalCap(normalRemainingCredit, pool)
  requireNonnegative(normalRemainingCredit, "normalRemainingCredit")
  requireNonnegative(pool, "pool")
  return math.min(normalRemainingCredit, pool)
end

function M.BaseCreditLimit(rating, netGPT, eraMinimum, config)
  local c = configOrDefault(config)
  requireNonnegative(eraMinimum, "eraMinimum")
  assert(c.credit[rating] and finite(netGPT))
  if rating == "D" then return 0 end
  return math.max(eraMinimum, math.max(0, netGPT) * c.credit[rating].limitMultiple)
end

function M.AvailableCredit(limit, outstandingPrincipal)
  requireNonnegative(limit, "limit")
  requireNonnegative(outstandingPrincipal, "outstandingPrincipal")
  return math.max(0, limit - outstandingPrincipal)
end

function M.LiquidityTier(pool, baseCap, config)
  local c = configOrDefault(config)
  assert(finite(pool) and finite(baseCap) and baseCap > 0)
  local liquidity = pool / baseCap
  if liquidity >= c.liquidity.normalThreshold then return "NORMAL", liquidity end
  if liquidity >= c.liquidity.tightThreshold then return "TIGHT", liquidity end
  if liquidity >= c.liquidity.strainedThreshold then return "STRAINED", liquidity end
  return "EMERGENCY", liquidity
end

-- Inputs are nonnegative V improvements measured against the same no-deposit baseline.
-- Caller supplies the one-tier maximum; emergency-window admission is a separate policy.
function M.BoundRivalVBenefit(rawBenefit, oneTierBenefit, investorActualBenefit, config)
  local c = configOrDefault(config)
  requireNonnegative(rawBenefit, "rawBenefit")
  requireNonnegative(oneTierBenefit, "oneTierBenefit")
  requireNonnegative(investorActualBenefit, "investorActualBenefit")
  return math.min(rawBenefit, oneTierBenefit,
    investorActualBenefit * c.liquidity.maximumRivalBenefitFraction)
end

function M.ScalePenalty(base, strength)
  assert(finite(base) and finite(strength) and strength >= 0)
  if base == 0 or strength == 0 then return 0 end
  local magnitude = math.floor(math.abs(base) * strength)
  if math.abs(base) >= 1 then magnitude = math.max(1, magnitude) end
  if base < 0 then return -magnitude end
  return magnitude
end

function M.Penalties(tier, stage, config)
  local c = configOrDefault(config)
  local source = c.penalties[stage]
  assert(source and c.tiers[tier])
  local strength = c.tiers[tier].penaltyStrength
  return {
    garnishPercent = M.ScalePenalty(source.garnishPercent, strength),
    amenities = M.ScalePenalty(source.amenities, strength),
    productionPercent = M.ScalePenalty(source.productionPercent, strength),
    sciencePercent = M.ScalePenalty(source.sciencePercent, strength),
    loyalty = M.ScalePenalty(source.loyalty, strength),
    favor = M.ScalePenalty(source.favor, strength),
    tradePercent = M.ScalePenalty(source.tradePercent, strength),
  }
end

-- Each row is {id, amount}; aggregates multiple deposits and orders output by player ID.
function M.Shares(deposits)
  local rows, total = {}, 0
  for i = 1, #deposits do
    local deposit = deposits[i]
    requireNonnegative(deposit.amount, "deposit.amount")
    local row = nil
    for j = 1, #rows do if rows[j].id == deposit.id then row = rows[j] end end
    if not row then row = {id = deposit.id, amount = 0}; rows[#rows + 1] = row end
    row.amount = row.amount + deposit.amount
    total = total + deposit.amount
  end
  table.sort(rows, function(a, b) return a.id < b.id end)
  for i = 1, #rows do
    rows[i].share = 0
    if total > 0 then rows[i].share = rows[i].amount / total end
  end
  return rows, total
end

function M.ShareFavor(share, config)
  local c = configOrDefault(config)
  requireNonnegative(share, "share")
  local quotient = share / c.investors.favorShareStep
  local nearest = M.RoundNearest(quotient)
  if math.abs(quotient - nearest) <= c.precision.shareStepTolerance then quotient = nearest end
  local steps = math.floor(quotient)
  return math.min(c.investors.favorCap, steps * c.investors.favorPerShareStep)
end

-- Returns exact fractional entitlement; engine Favor rounding/carry is intentionally separate.
function M.AidCredit(share, lentToOthers, config)
  local c = configOrDefault(config)
  requireNonnegative(share, "share")
  requireNonnegative(lentToOthers, "lentToOthers")
  return math.min(c.investors.aidFavorCap, share * lentToOthers / c.investors.aidGoldStep)
end

function M.AIShouldBorrow(gold, netGPT, arrears, activeLoans, config)
  local c = configOrDefault(config)
  requireNonnegative(gold, "gold")
  requireNonnegative(arrears, "arrears")
  requireNonnegative(activeLoans, "activeLoans")
  assert(finite(netGPT))
  return netGPT > 0 and gold < c.ai.lowTreasuryGptMultiple * netGPT
    and arrears == 0 and activeLoans < c.ai.maxLoans
end

function M.AILoanAmount(netGPT, config)
  local c = configOrDefault(config)
  requireNonnegative(netGPT, "netGPT")
  return netGPT * c.ai.loanGptMultiple
end

-- Simple fees on a fixed unpaid base. Payment allocation across lots belongs to the reducer.
function M.SimpleArrears(base, elapsedTurns, config)
  local c = configOrDefault(config)
  requireNonnegative(base, "base")
  requireNonnegative(elapsedTurns, "elapsedTurns")
  return base * c.arrears.simpleRate * elapsedTurns
end

-- Pure cash ledger: loan face balances are never used to derive cash.
-- Supported credit kinds: refill, deposit, repayment, guarantee.
-- Supported debit kinds: loan, grant, deposit_return. Underfunded debits reject atomically.
function M.CashLedger(openingCash, movements)
  requireNonnegative(openingCash, "openingCash")
  local cash = openingCash
  for i = 1, #movements do
    local movement = movements[i]
    requireNonnegative(movement.amount, "movement.amount")
    if movement.kind == "refill" or movement.kind == "deposit"
        or movement.kind == "repayment" or movement.kind == "guarantee" then
      cash = cash + movement.amount
    elseif movement.kind == "loan" or movement.kind == "grant" or movement.kind == "deposit_return" then
      if movement.amount > cash then return nil, "insufficient_cash", i end
      cash = cash - movement.amount
    else return nil, "unknown_movement", i end
  end
  return cash, "ok"
end

return WBL_MATH
