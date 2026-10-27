-- Engine-independent math. Load WBL_Config.lua first; pure transitions never mutate inputs.
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

local function growthResultCopy(result)
  local copy = {}
  for _, key in ipairs({"gameGrowth", "standardGrowth", "rawMedianLog", "emaLog",
      "validPairs", "livingMajors", "requiredPairs", "windowTurns", "reason",
      "resetReason", "duplicate", "measured", "alpha"}) do copy[key] = result[key] end
  return copy
end

local function validGrowthState(state)
  if type(state) ~= "table" or type(state.fingerprint) ~= "string"
      or not finite(state.lastTurn) or state.lastTurn % 1 ~= 0
      or not finite(state.firstTurn) or state.firstTurn > state.lastTurn
      or not finite(state.emaLog) or type(state.history) ~= "table"
      or type(state.lastResult) ~= "table" or not finite(state.lastResult.gameGrowth)
      or not finite(state.lastResult.standardGrowth) or not finite(state.lastResult.emaLog)
      or type(state.lastResult.reason) ~= "string" then return false end
  local priorTurn
  for i = 1, #state.history do
    local row = state.history[i]
    if type(row) ~= "table" or not finite(row.turn) or row.turn % 1 ~= 0
        or row.turn > state.lastTurn or (priorTurn and row.turn <= priorTurn)
        or type(row.valid) ~= "boolean" or type(row.players) ~= "table" then return false end
    priorTurn = row.turn
    local priorID
    for j = 1, #row.players do
      local p = row.players[j]
      if type(p) ~= "table" or not finite(p.id) or p.id < 0 or p.id % 1 ~= 0
          or (priorID and p.id <= priorID) or not finite(p.production) or p.production < 0 then return false end
      priorID = p.id
    end
  end
  return #state.history > 0 and state.history[#state.history].turn == state.lastTurn
end

-- The adapter supplies the complete authoritative cohort, including failed reads.
-- State/history/results contain only ordered tables and serializable scalar facts.
function M.ProductionGrowth(previous, observation, config)
  local g = configOrDefault(config).growth
  assert(g.model == "production_median_log_ema_v1", "unsupported growth model")
  assert(finite(g.standardMin) and g.standardMin >= 0 and finite(g.standardMax)
    and finite(g.standardDefault) and g.standardMin <= g.standardDefault
    and g.standardDefault <= g.standardMax, "invalid growth bounds")
  assert(finite(g.windowTurns) and g.windowTurns > 0
    and finite(g.emaHalfLifeTurns) and g.emaHalfLifeTurns > 0, "invalid growth durations")
  assert(finite(g.minimumPairs) and g.minimumPairs >= 1 and g.minimumPairs % 1 == 0
    and finite(g.smallWorldPlayers) and g.smallWorldPlayers >= 1 and g.smallWorldPlayers % 1 == 0
    and g.smallWorldPlayers < g.minimumPairs and finite(g.coverageFraction)
    and g.coverageFraction > 0 and g.coverageFraction <= 1, "invalid growth coverage")
  assert(type(observation) == "table" and finite(observation.turn)
    and observation.turn >= 0 and observation.turn % 1 == 0
    and finite(observation.scale) and observation.scale > 0, "invalid growth observation clock")
  local token = observation.resetToken
  if token == nil then token = "" end
  assert(type(token) == "string" or finite(token), "invalid growth reset token")
  local turn, scale = observation.turn, observation.scale
  local window = M.ScaleTurns(g.windowTurns, scale)
  local fallbackLog = math.log(1 + g.standardDefault)
  local fallbackGame = M.SpeedGrowth(g.standardDefault, scale)
  assert(finite(fallbackGame), "growth scale overflows per-game fallback")
  local parts = {g.model, type(token), tostring(token)}
  for _, value in ipairs({g.standardDefault, g.standardMin, g.standardMax, g.windowTurns,
      g.emaHalfLifeTurns, g.minimumPairs, g.coverageFraction, g.smallWorldPlayers, scale}) do
    parts[#parts + 1] = string.format("%.17g", value)
  end
  local fingerprint = table.concat(parts, "|")
  local resetReason = ""
  if previous == nil then resetReason = "initial"
  elseif not validGrowthState(previous) then resetReason = "invalid_saved_state"
  elseif previous.fingerprint ~= fingerprint then resetReason = "fingerprint_changed"
  elseif turn < previous.lastTurn then resetReason = "turn_rewind" end
  if resetReason ~= "" then previous = nil end
  local current, complete = {}, observation.complete == true
  if type(observation.players) ~= "table" then complete = false
  else
    local ids = {}
    for i = 1, #observation.players do
      local p = observation.players[i]
      assert(type(p) == "table" and finite(p.id) and p.id >= 0 and p.id % 1 == 0, "invalid growth player ID")
      for j = 1, #ids do assert(ids[j] ~= p.id, "duplicate growth player ID") end
      ids[#ids + 1] = p.id
      if type(p.alive) ~= "boolean" or type(p.isMajor) ~= "boolean" then complete = false
      elseif p.alive and p.isMajor then
        local production = p.production
        if not finite(production) or production < 0 then complete = false; production = 0 end
        current[#current + 1] = {id = p.id, production = production}
      end
    end
  end
  table.sort(current, function(a, b) return a.id < b.id end)
  if previous and turn == previous.lastTurn then
    local result = growthResultCopy(previous.lastResult)
    result.duplicate = true
    return previous, result
  end
  local living, required = #current, g.minimumPairs
  if living == g.smallWorldPlayers then required = living
  elseif living >= g.minimumPairs then required = math.max(g.minimumPairs, math.ceil(living * g.coverageFraction)) end
  local state = {fingerprint = fingerprint, firstTurn = previous and previous.firstTurn or turn,
    lastTurn = turn, emaLog = fallbackLog, history = {}}
  local reference
  if previous then
    for i = 1, #previous.history do
      local row = previous.history[i]
      if row.turn >= turn - window then
        local copy = {turn = row.turn, valid = row.valid, players = {}}
        for j = 1, #row.players do copy.players[j] = {id = row.players[j].id, production = row.players[j].production} end
        state.history[#state.history + 1] = copy
        if row.turn == turn - window then reference = copy end
      end
    end
  end
  local result = {gameGrowth = fallbackGame, standardGrowth = g.standardDefault, emaLog = fallbackLog,
    validPairs = 0, livingMajors = living, requiredPairs = required, windowTurns = window,
    reason = "bootstrap", resetReason = resetReason, duplicate = false, measured = false, alpha = 0}
  if not complete then result.reason = "invalid_current_observation"
  elseif living < g.smallWorldPlayers then result.reason = "too_few_living_majors"
  elseif reference == nil then
    if turn - state.firstTurn >= window then result.reason = "missing_reference_observation" end
  elseif not reference.valid then result.reason = "invalid_reference_observation"
  else
    local logs = {}
    for i = 1, #current do
      local p = current[i]
      for j = 1, #reference.players do
        local prior = reference.players[j]
        if p.id == prior.id and p.production > 0 and prior.production > 0 then
          logs[#logs + 1] = (math.log(p.production) - math.log(prior.production)) * scale / window
        end
      end
    end
    result.validPairs = #logs
    if #logs < required then result.reason = "insufficient_coverage"
    else
      result.rawMedianLog = M.Median(logs)
      local elapsedStandard = (turn - previous.lastTurn) / scale
      result.alpha = 1 - 2 ^ (-elapsedStandard / g.emaHalfLifeTurns)
      state.emaLog = (1 - result.alpha) * previous.emaLog + result.alpha * result.rawMedianLog
      result.emaLog = state.emaLog
      -- Clipping in log space is equivalent to clipping the published rate and
      -- prevents exp overflow. Raw state and negative rates remain unmodified.
      result.standardGrowth = M.Clamp(math.exp(M.Clamp(state.emaLog,
        math.log(1 + g.standardMin), math.log(1 + g.standardMax))) - 1,
        g.standardMin, g.standardMax)
      result.gameGrowth = M.SpeedGrowth(result.standardGrowth, scale)
      assert(finite(result.gameGrowth), "growth scale overflows per-game measured rate")
      result.reason, result.measured = "measured", true
    end
  end
  local stored = {turn = turn, valid = complete, players = {}}
  if complete then stored.players = current end
  state.history[#state.history + 1] = stored
  state.lastResult = growthResultCopy(result)
  return state, result
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

-- Gold diagnostic only; this aggregate never supplies production growth.
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

-- Pure settlement preview from locked, non-overlapping balances. Maturing debt
-- moves OUT of scheduledPrincipal/futureInterest into overdue buckets exactly once.
-- The caller must reject an underfunded settlement atomically; no cash moves here.
function M.EarlySettlementQuote(snapshot)
  assert(type(snapshot) == "table", "settlement requires a locked balance snapshot")
  requireNonnegative(snapshot.scheduledPrincipal, "scheduledPrincipal")
  requireNonnegative(snapshot.overduePrincipal, "overduePrincipal")
  requireNonnegative(snapshot.futureInterest, "futureInterest")
  requireNonnegative(snapshot.overdueInterest, "overdueInterest")
  requireNonnegative(snapshot.arrearsFees, "arrearsFees")
  requireNonnegative(snapshot.earlyRepayInterestFraction, "earlyRepayInterestFraction")
  assert(snapshot.earlyRepayInterestFraction <= 1, "earlyRepayInterestFraction must be at most one")
  local principalDue = snapshot.scheduledPrincipal + snapshot.overduePrincipal
  local futureInterestDue = snapshot.earlyRepayInterestFraction * snapshot.futureInterest
  local totalDue = principalDue + snapshot.overdueInterest + snapshot.arrearsFees + futureInterestDue
  requireNonnegative(totalDue, "totalDue")
  return {
    principalDue = principalDue,
    overdueInterestDue = snapshot.overdueInterest,
    arrearsFeesDue = snapshot.arrearsFees,
    futureInterestDue = futureInterestDue,
    waivedFutureInterest = (1 - snapshot.earlyRepayInterestFraction) * snapshot.futureInterest,
    totalDue = totalDue,
  }
end

-- Pure policy only, called after verified full closure. Balance validation,
-- atomic closure and retained lineage history belong to the reducer.
-- An early closure never earns a promotion.
function M.RatingPromotionEligible(closureKind, everMissedPayment)
  assert(closureKind == "MATURITY" or closureKind == "EARLY", "unknown loan closure kind")
  assert(type(everMissedPayment) == "boolean", "missed-payment history must be boolean")
  return closureKind == "MATURITY" and not everMissedPayment
end

-- Pure policy for an authoritative D rating, using aggregates across ALL loans.
-- Arrears-only clearance can end default penalties while D still blocks credit.
-- A D-to-C recovery consumes this closure event; do not also award a promotion.
function M.RatingRecoveryEligible(snapshot)
  assert(type(snapshot) == "table", "rating recovery requires an all-loans balance snapshot")
  requireNonnegative(snapshot.scheduledPrincipal, "scheduledPrincipal")
  requireNonnegative(snapshot.overduePrincipal, "overduePrincipal")
  requireNonnegative(snapshot.futureInterest, "futureInterest")
  requireNonnegative(snapshot.overdueInterest, "overdueInterest")
  requireNonnegative(snapshot.arrearsFees, "arrearsFees")
  return snapshot.scheduledPrincipal == 0 and snapshot.overduePrincipal == 0
    and snapshot.futureInterest == 0 and snapshot.overdueInterest == 0 and snapshot.arrearsFees == 0
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

-- Caller resolves the world era and supplies CostMultiplier / 100. Gold floors
-- scale continuously; this is deliberate policy, not duration rounding.
function M.EraCreditMinimum(eraType, scale, config)
  local c = configOrDefault(config)
  assert(type(eraType) == "string" and type(c.credit.eraMinimums) == "table", "unknown or unconfigured credit era")
  local minimum = c.credit.eraMinimums[eraType]
  assert(finite(minimum) and minimum > 0, "credit era floor must be configured, finite and positive")
  assert(finite(scale) and scale > 0, "credit era scale must be finite and positive")
  local scaled = minimum * scale
  assert(finite(scaled), "scaled credit era floor must be finite")
  return scaled
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
