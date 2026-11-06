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

local function requireInteger(value, label)
  assert(finite(value) and value >= 0 and value % 1 == 0, label .. " must be a nonnegative integer")
end

local function requireID(value, label)
  assert(finite(value) and value >= 1 and value % 1 == 0, label .. " must be a positive integer ID")
end

local function requirePlayerID(value, label)
  assert(finite(value) and value >= 0 and value % 1 == 0, label .. " must be a nonnegative player ID")
end

local function requirePositive(value, label)
  assert(finite(value) and value > 0, label .. " must be finite and positive")
end

-- Whole steps of quantity/step; machine-boundary noise within precision.shareStepTolerance
-- snaps to the integer (dimensionless, never a gameplay benefit).
local function wholeSteps(quantity, step, c)
  requireNonnegative(quantity, "quantity")
  requirePositive(step, "step")
  local quotient = quantity / step
  local nearest = M.RoundNearest(quotient)
  if math.abs(quotient - nearest) <= c.precision.shareStepTolerance then quotient = nearest end
  return math.floor(quotient)
end

local function reaches(quantity, threshold, c)
  return wholeSteps(quantity, threshold, c) >= 1
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

local LOAN_PRODUCTS = {ORDINARY = true, INFRASTRUCTURE = true, RECOVERY = true}

-- Base V for a product: recovery lineages keep decision 15 values; ordinary and
-- infrastructure use the tier value (decision 25). Tier eligibility is the reducer's.
local function productBaseV(product, tier, c)
  assert(type(product) == "string" and LOAN_PRODUCTS[product], "unknown loan product")
  assert(type(tier) == "string" and type(c.tiers[tier]) == "table"
    and finite(c.tiers[tier].valueRatio), "unknown development tier")
  if product == "RECOVERY" then
    local value = c.disasterRecovery.valueRatio[tier]
    assert(finite(value), "unconfigured recovery value ratio")
    return value
  end
  return c.tiers[tier].valueRatio
end

local function ratingAdjustment(rating, c)
  assert(type(rating) == "string" and type(c.credit[rating]) == "table"
    and finite(c.credit[rating].valueAdjustment), "unknown credit rating")
  return c.credit[rating].valueAdjustment
end

local function composeV(base, rating, liquidity, scar, investor, c)
  local raw = base + rating + liquidity + scar + investor
  local floor = c.floors.valueRatio
  return {base = base, rating = rating, liquidity = liquidity, scar = scar, investor = investor,
    raw = raw, floorApplied = raw < floor, quotedV = math.max(floor, raw)}
end

-- Origination V (decision 29 replaces the boolean investor). q = {tier, rating, product
-- (default ORDINARY), liquidityAdjustment (>= 0, already R3/R4-bounded), scarActive,
-- preferredStep (0/1/2, from PreferredTerms; default 0), liquidityExempt (default false)}.
-- Returns the offers-view vComponents {base, rating, liquidity, scar, investor, raw,
-- floorApplied, quotedV, product}.
function M.QuoteV(q, config)
  local c = configOrDefault(config)
  assert(type(q) == "table", "V quote requires a request table")
  local product = q.product
  if product == nil then product = "ORDINARY" end
  local base = productBaseV(product, q.tier, c)
  local rating = ratingAdjustment(q.rating, c)
  assert(q.rating ~= "D", "rating D cannot originate a loan")
  requireNonnegative(q.liquidityAdjustment, "liquidityAdjustment")
  assert(type(q.scarActive) == "boolean", "scarActive must be boolean")
  local step = q.preferredStep
  if step == nil then step = 0 end
  assert(step == 0 or step == 1 or step == 2, "preferredStep must be 0, 1 or 2")
  local exempt = q.liquidityExempt
  if exempt == nil then exempt = false end
  assert(type(exempt) == "boolean", "liquidityExempt must be boolean")
  local e = c.investors.eligibility
  local investor = 0
  if step == 1 then investor = e.preferredHalfValueAdjustment
  elseif step == 2 then investor = e.preferredFullValueAdjustment end
  local liquidity = q.liquidityAdjustment
  if exempt then liquidity = 0 end
  local scar = 0
  if q.scarActive then scar = c.credit.scarValueAdjustment end
  local v = composeV(base, rating, liquidity, scar, investor, c)
  v.product = product
  return v
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
-- request = QuoteV fields plus principal, growth, standardTermTurns, scale. The
-- superseded boolean `investor` field is rejected so stale callers cannot misprice.
function M.ProductLoanQuote(request, config)
  local c = configOrDefault(config)
  assert(type(request) == "table", "loan quote requires a request table")
  assert(request.investor == nil, "boolean investor is superseded; pass preferredStep and liquidityExempt")
  local product = request.product
  if product == nil then product = "ORDINARY" end
  assert(type(request.tier) == "string", "unknown development tier")
  local tier = c.tiers[request.tier]
  assert(type(tier) == "table" and tier.terms, "unknown development tier")
  local allowedTerm = false
  for i = 1, #tier.terms do
    if request.standardTermTurns == tier.terms[i] then allowedTerm = true end
  end
  assert(allowedTerm, "term is not available to this development tier")
  local v = M.QuoteV(request, c)
  local quote = M.LoanQuote(request.principal, v.quotedV, request.growth,
    M.ScaleTurns(request.standardTermTurns, request.scale),
    M.ScaleTurns(tier.graceTurns, request.scale), c)
  quote.product, quote.tier = product, request.tier
  quote.standardTermTurns = request.standardTermTurns
  quote.vComponents = v
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
  assert(finite(source.garnishPercent))
  local strength = c.tiers[tier].penaltyStrength
  return {
    garnishPercent = source.garnishPercent, -- Garnishing is fixed across development tiers.
    amenities = M.ScalePenalty(source.amenities, strength),
    productionPercent = M.ScalePenalty(source.productionPercent, strength),
    sciencePercent = M.ScalePenalty(source.sciencePercent, strength),
    loyalty = M.ScalePenalty(source.loyalty, strength),
    favor = M.ScalePenalty(source.favor, strength),
    tradePercent = M.ScalePenalty(source.tradePercent, strength),
  }
end

-- Share rule on ELIGIBLE share (decision 29); InvestorLadder takes the smaller of this and E.
function M.ShareFavor(share, config)
  local c = configOrDefault(config)
  requireNonnegative(share, "share")
  return math.min(c.investors.favorCap,
    wholeSteps(share, c.investors.favorShareStep, c) * c.investors.favorPerShareStep)
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

-- Decision 34: arrears.simpleRate is per Standard turn; the per-game-turn rate divides by the
-- turn scale (Online 10%, Standard 5%, Marathon ~1.667%). scale nil means Standard.
function M.ArrearsFeeRate(scale, config)
  local c = configOrDefault(config)
  requireNonnegative(c.arrears.simpleRate, "arrears.simpleRate")
  if scale == nil then scale = 1 end
  requirePositive(scale, "scale")
  return c.arrears.simpleRate / scale
end

-- Decision 34: the warning, default-entry and stage-2 clocks are Standard turns converted with
-- ScaleTurns. stage2StartTurn is a default-turn index: stage 1 lasts (index - 1) Standard turns.
-- Returns game-turn counts {warningTurns, defaultTurns, stage2StartTurn}.
function M.ArrearsClocks(scale, config)
  local c = configOrDefault(config)
  local a = c.arrears
  requireInteger(a.warningTurns, "arrears.warningTurns")
  requireInteger(a.defaultTurns, "arrears.defaultTurns")
  requireID(a.stage2StartTurn, "arrears.stage2StartTurn")
  if scale == nil then scale = 1 end
  requirePositive(scale, "scale")
  return {warningTurns = M.ScaleTurns(a.warningTurns, scale), defaultTurns = M.ScaleTurns(a.defaultTurns, scale),
    stage2StartTurn = M.ScaleTurns(a.stage2StartTurn - 1, scale) + 1}
end

-- Simple fees on a fixed unpaid base over elapsed game turns at the speed-adjusted rate.
-- Payment allocation across lots belongs to the reducer.
function M.SimpleArrears(base, elapsedTurns, config, scale)
  requireNonnegative(base, "base")
  requireNonnegative(elapsedTurns, "elapsedTurns")
  return base * M.ArrearsFeeRate(scale, config) * elapsedTurns
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

-- ---------------------------------------------------------------------------
-- Decisions 29-33: eligible capital, investor ladder, deposits, arrears, relief,
-- restructuring, grants and base reserve. All pure; records follow PLAN state
-- schema 1 and are never mutated. Returned rows are ordered by their ID.
-- ---------------------------------------------------------------------------

local RATING_ORDER = {"A", "B", "C", "D"}
local LOWEST_LENDING_RATING = "C" -- Spec 3.5: a restructure drops one grade, to C at worst.
local COMPONENT_FIELD = {FEES = "fees", OVERDUE_INTEREST = "interest", OVERDUE_PRINCIPAL = "principal"}
local SUBSIDY_KINDS = {FORGIVENESS = true, RELIEF = true, GRANT = true}

local function ratingIndex(rating)
  for i = 1, #RATING_ORDER do
    if RATING_ORDER[i] == rating then return i end
  end
  error("unknown credit rating")
end

-- One grade worse, never past floorRating; D (default) stays D.
function M.DowngradeRating(rating, floorRating)
  local index, floorIndex = ratingIndex(rating), ratingIndex(floorRating)
  assert(floorRating ~= "D", "downgrade floor must be a lending rating")
  if rating == "D" or index >= floorIndex then return rating end
  return RATING_ORDER[index + 1]
end

-- U = scaled world-era credit floor. era is the previous state.era record
-- {eraType, U, previousU, previousUntilTurn} or nil. A world-era change keeps the
-- previous era's U for turns [changeTurn, changeTurn + scaled eraChangeGraceTurns).
-- Returns the next era record and the effective U for this turn.
-- Restructuring Favor cost (decision 39): the configured Ancient cost times U over the Ancient U at the same speed,
-- so it follows the era like loan sizes do (50, 100, 150 Favor with the shipped floors) but not game speed.
-- Whole Favor.
function M.RestructureFavorCost(U, scale, config)
  local c = configOrDefault(config)
  requirePositive(U, "U")
  local ancient = M.EraCreditMinimum("ERA_ANCIENT", scale, c)
  return math.floor(c.relief.restructureFavorCost * U / ancient + 0.5)
end

function M.CapitalUnit(era, eraType, turn, scale, config)
  local c = configOrDefault(config)
  requireInteger(turn, "turn")
  local U = M.EraCreditMinimum(eraType, scale, c)
  local grace = M.ScaleTurns(c.investors.eligibility.eraChangeGraceTurns, scale)
  local nextEra
  if era == nil then
    nextEra = {eraType = eraType, U = U, previousU = 0, previousUntilTurn = 0}
  else
    assert(type(era) == "table" and type(era.eraType) == "string", "invalid era record")
    requirePositive(era.U, "era.U")
    requireNonnegative(era.previousU, "era.previousU")
    requireInteger(era.previousUntilTurn, "era.previousUntilTurn")
    if era.eraType == eraType then
      nextEra = {eraType = eraType, U = U, previousU = era.previousU, previousUntilTurn = era.previousUntilTurn}
    else
      nextEra = {eraType = eraType, U = U, previousU = era.U, previousUntilTurn = turn + grace}
    end
  end
  local effective = U
  if turn < nextEra.previousUntilTurn and nextEra.previousU > 0 then effective = nextEra.previousU end
  return nextEra, effective
end

local function loanExposureOf(loan)
  assert(type(loan) == "table" and type(loan.status) == "string", "invalid loan record")
  requirePlayerID(loan.playerID, "loan.playerID")
  requireNonnegative(loan.scheduledPrincipal, "loan.scheduledPrincipal")
  requireNonnegative(loan.overduePrincipal, "loan.overduePrincipal")
  requireNonnegative(loan.overdueInterest, "loan.overdueInterest")
  requireNonnegative(loan.arrearsFees, "loan.arrearsFees")
  return loan.scheduledPrincipal + loan.overduePrincipal + loan.overdueInterest + loan.arrearsFees
end

-- X: the player's ACTIVE loans (every product) scheduled + overdue principal, overdue
-- contractual interest and arrears fees; not-yet-due interest is excluded. Plus
-- subsidies {playerID, turn, kind, amount} received in the last scaled
-- subsidyMemoryTurns (received turn T counts for turns T .. T + memory - 1).
-- Returns total, loanExposure, subsidyExposure.
function M.BankExposure(loans, subsidies, playerID, turn, scale, config)
  local c = configOrDefault(config)
  assert(type(loans) == "table" and type(subsidies) == "table", "exposure requires loan and subsidy arrays")
  requirePlayerID(playerID, "playerID")
  requireInteger(turn, "turn")
  local memory = M.ScaleTurns(c.investors.eligibility.subsidyMemoryTurns, scale)
  local loanExposure, subsidyExposure = 0, 0
  for i = 1, #loans do
    local amount = loanExposureOf(loans[i])
    if loans[i].playerID == playerID and loans[i].status == "ACTIVE" then
      loanExposure = loanExposure + amount
    end
  end
  for i = 1, #subsidies do
    local s = subsidies[i]
    assert(type(s) == "table" and type(s.kind) == "string" and SUBSIDY_KINDS[s.kind], "invalid subsidy record")
    requirePlayerID(s.playerID, "subsidy.playerID")
    requireInteger(s.turn, "subsidy.turn")
    requireNonnegative(s.amount, "subsidy.amount")
    if s.playerID == playerID and s.turn <= turn and turn - s.turn < memory then
      subsidyExposure = subsidyExposure + s.amount
    end
  end
  return loanExposure + subsidyExposure, loanExposure, subsidyExposure
end

-- D: the player's ACTIVE deposit principal (accrued return excluded).
function M.ActiveDepositPrincipal(deposits, playerID)
  assert(type(deposits) == "table", "deposit array required")
  requirePlayerID(playerID, "playerID")
  local total = 0
  for i = 1, #deposits do
    local d = deposits[i]
    assert(type(d) == "table" and type(d.status) == "string", "invalid deposit record")
    requirePlayerID(d.playerID, "deposit.playerID")
    requireNonnegative(d.principal, "deposit.principal")
    if d.playerID == playerID and d.status == "ACTIVE" then total = total + d.principal end
  end
  return total
end

-- E = max(0, D - X); 0 with a reason while in default, in arrears or relief is pending.
-- blocks = {inDefault, hasArrears, reliefPending} booleans.
function M.EligibleCapital(depositPrincipal, exposure, blocks)
  requireNonnegative(depositPrincipal, "depositPrincipal")
  requireNonnegative(exposure, "exposure")
  assert(type(blocks) == "table" and type(blocks.inDefault) == "boolean"
    and type(blocks.hasArrears) == "boolean" and type(blocks.reliefPending) == "boolean",
    "eligibility blocks must be booleans")
  if blocks.inDefault then return 0, "IN_DEFAULT" end
  if blocks.hasArrears then return 0, "ARREARS" end
  if blocks.reliefPending then return 0, "RELIEF_PENDING" end
  return math.max(0, depositPrincipal - exposure), ""
end

-- rows {playerID, eligibleCapital}, one per player. Returns rows sorted by playerID with
-- share = E / sum(E) (all zero when the sum is zero) and the total.
function M.EligibleShares(rows)
  assert(type(rows) == "table", "eligible share rows required")
  local out, total = {}, 0
  for i = 1, #rows do
    local r = rows[i]
    assert(type(r) == "table", "invalid eligible share row")
    requirePlayerID(r.playerID, "playerID")
    requireNonnegative(r.eligibleCapital, "eligibleCapital")
    for j = 1, #out do assert(out[j].playerID ~= r.playerID, "duplicate eligible share player") end
    out[#out + 1] = {playerID = r.playerID, eligibleCapital = r.eligibleCapital, share = 0}
    total = total + r.eligibleCapital
  end
  table.sort(out, function(a, b) return a.playerID < b.playerID end)
  if total > 0 then
    for i = 1, #out do out[i].share = out[i].eligibleCapital / total end
  end
  return out, total
end

-- Each reward is the smaller of its share rule and the capital ladder (decision 29, 3A).
-- Below the entry floor only return accrual remains.
function M.InvestorLadder(eligibleCapital, share, U, config)
  local c = configOrDefault(config)
  local e = c.investors.eligibility
  requireNonnegative(eligibleCapital, "eligibleCapital")
  requireNonnegative(share, "share")
  assert(share <= 1 + c.precision.shareStepTolerance, "share must be at most one")
  requirePositive(U, "U")
  local result = {eligible = reaches(eligibleCapital, e.entryFloorMultiple * U, c),
    ladderFavor = 0, shareFavor = M.ShareFavor(share, c), favor = 0, aidCap = 0,
    coalitionMember = reaches(eligibleCapital, e.coalitionMemberFloorMultiple * U, c),
    presidentCapital = reaches(eligibleCapital, e.presidentFloorMultiple * U, c)}
  if result.eligible then
    result.ladderFavor = math.min(c.investors.favorCap,
      wholeSteps(eligibleCapital, e.favorStepFloorMultiple * U, c))
    result.favor = math.min(result.shareFavor, result.ladderFavor)
    result.aidCap = math.min(c.investors.aidFavorCap, e.aidCapPerFloor * eligibleCapital / U)
  end
  return result
end

-- Exact aid entitlement: the share rule (AidCredit) capped by the ladder's aidCap.
function M.InvestorAidCredit(share, lentToOthers, aidCap, config)
  requireNonnegative(aidCap, "aidCap")
  return math.min(aidCap, M.AidCredit(share, lentToOthers, config))
end

-- Whole units to pay now and the fractional carry kept for the next turn.
function M.SplitWhole(carry, amount, config)
  local c = configOrDefault(config)
  requireNonnegative(carry, "carry")
  requireNonnegative(amount, "amount")
  local total = carry + amount
  local whole = wholeSteps(total, 1, c)
  return whole, math.max(0, total - whole)
end

-- E_post = max(0, E - requested principal); decision 29 judges pricing on it.
function M.PostLoanCapital(eligibleCapital, principal)
  requireNonnegative(eligibleCapital, "eligibleCapital")
  requireNonnegative(principal, "principal")
  return math.max(0, eligibleCapital - principal)
end

-- Locked at origination: preferredStep 0/1/2 with its V adjustment, and the liquidity
-- V exemption. Never beyond the pool or the emergency window (reducer).
function M.PreferredTerms(ePost, U, config)
  local c = configOrDefault(config)
  local e = c.investors.eligibility
  requireNonnegative(ePost, "ePost")
  requirePositive(U, "U")
  local step, adjustment = 0, 0
  if reaches(ePost, e.preferredFullFloorMultiple * U, c) then
    step, adjustment = 2, e.preferredFullValueAdjustment
  elseif reaches(ePost, e.preferredHalfFloorMultiple * U, c) then
    step, adjustment = 1, e.preferredHalfValueAdjustment
  end
  return {preferredStep = step, valueAdjustment = adjustment,
    liquidityExempt = reaches(ePost, e.liquidityExemptionFloorMultiple * U, c)}
end

-- Extension above the normal limit = min(fraction x normal limit, E); 0 below entry.
function M.InvestorCreditExtension(normalLimit, eligibleCapital, U, config)
  local c = configOrDefault(config)
  local e = c.investors.eligibility
  requireNonnegative(normalLimit, "normalLimit")
  requireNonnegative(eligibleCapital, "eligibleCapital")
  requirePositive(U, "U")
  if not reaches(eligibleCapital, e.entryFloorMultiple * U, c) then return 0 end
  return math.min(e.creditExtensionLimitFraction * normalLimit, eligibleCapital)
end

-- input = {turn (>= 1), scale, U, president = {playerID (-1 none), sinceTurn},
--   players = [{playerID, eligibleCapital, eligibleShare, shareReachedTurn, presidentConfirmCount}]}.
-- The President is the largest eligible holder (ties: earliest shareReachedTurn, then
-- lower playerID) and only if that holder has eligible share >= threshold, E >= the
-- President floor and that floor held for scaled presidentConfirmTurns consecutive
-- measurements. Loss is immediate. Returns {president, players (sorted), changed,
-- previousPlayerID, reason (NONE, KEPT, NEW, LOST, REPLACED)}.
function M.PresidentStep(input, config)
  local c = configOrDefault(config)
  local e = c.investors.eligibility
  assert(type(input) == "table" and type(input.players) == "table"
    and type(input.president) == "table", "invalid President input")
  requireID(input.turn, "turn")
  requirePositive(input.U, "U")
  local required = M.ScaleTurns(e.presidentConfirmTurns, input.scale)
  local previousID = input.president.playerID
  assert(previousID == -1 or (finite(previousID) and previousID >= 0 and previousID % 1 == 0),
    "invalid President playerID")
  requireInteger(input.president.sinceTurn, "president.sinceTurn")
  local rows = {}
  for i = 1, #input.players do
    local p = input.players[i]
    assert(type(p) == "table", "invalid President player row")
    requirePlayerID(p.playerID, "playerID")
    requireNonnegative(p.eligibleCapital, "eligibleCapital")
    requireNonnegative(p.eligibleShare, "eligibleShare")
    requireInteger(p.shareReachedTurn, "shareReachedTurn")
    requireInteger(p.presidentConfirmCount, "presidentConfirmCount")
    for j = 1, #rows do assert(rows[j].playerID ~= p.playerID, "duplicate President player") end
    local shareOK = reaches(p.eligibleShare, c.investors.presidentShareThreshold, c)
    local capitalOK = reaches(p.eligibleCapital, e.presidentFloorMultiple * input.U, c)
    local reached, count = 0, 0
    if shareOK then
      reached = p.shareReachedTurn
      if reached == 0 then reached = input.turn end
    end
    if capitalOK then count = math.min(required, p.presidentConfirmCount + 1) end
    rows[#rows + 1] = {playerID = p.playerID, eligibleCapital = p.eligibleCapital,
      shareReachedTurn = reached, presidentConfirmCount = count,
      qualified = shareOK and capitalOK and count >= required}
  end
  table.sort(rows, function(a, b) return a.playerID < b.playerID end)
  local largest
  for i = 1, #rows do
    local r = rows[i]
    if r.eligibleCapital > 0 then
      if largest == nil or r.eligibleCapital > largest.eligibleCapital then largest = r
      elseif r.eligibleCapital == largest.eligibleCapital and r.shareReachedTurn > 0
          and (largest.shareReachedTurn == 0 or r.shareReachedTurn < largest.shareReachedTurn) then
        largest = r
      end
    end
  end
  local president = {playerID = -1, sinceTurn = 0}
  if largest and largest.qualified then
    president.playerID = largest.playerID
    if largest.playerID == previousID then president.sinceTurn = input.president.sinceTurn
    else president.sinceTurn = input.turn end
  end
  local reason = "NONE"
  if president.playerID ~= -1 and president.playerID == previousID then reason = "KEPT"
  elseif president.playerID ~= -1 and previousID == -1 then reason = "NEW"
  elseif president.playerID ~= -1 then reason = "REPLACED"
  elseif previousID ~= -1 then reason = "LOST" end
  for i = 1, #rows do rows[i].eligibleCapital = nil end
  return {president = president, players = rows, changed = president.playerID ~= previousID,
    previousPlayerID = previousID, reason = reason}
end

-- One turn of eligible-return accrual for the player's ACTIVE deposits: each accrues
-- returnFraction / termTurns x principal x min(1, E / D), the same eligible fraction pro
-- rata on every deposit, never past principal x returnFraction in total.
-- Returns rows {depositID, accrual, accruedReturn} by depositID, total, eligible fraction.
function M.DepositAccrual(deposits, playerID, eligibleCapital)
  requireNonnegative(eligibleCapital, "eligibleCapital")
  local D = M.ActiveDepositPrincipal(deposits, playerID)
  local fraction = 0
  if D > 0 then fraction = math.min(1, eligibleCapital / D) end
  local rows, total = {}, 0
  for i = 1, #deposits do
    local d = deposits[i]
    if d.playerID == playerID and d.status == "ACTIVE" then
      requireID(d.depositID, "depositID")
      requireNonnegative(d.returnFraction, "returnFraction")
      requireID(d.termTurns, "termTurns")
      requireNonnegative(d.accruedReturn, "accruedReturn")
      local full = d.principal * d.returnFraction
      local accrual = math.min(full / d.termTurns * fraction, math.max(0, full - d.accruedReturn))
      rows[#rows + 1] = {depositID = d.depositID, accrual = accrual, accruedReturn = d.accruedReturn + accrual}
      total = total + accrual
    end
  end
  table.sort(rows, function(a, b) return a.depositID < b.depositID end)
  for i = 2, #rows do assert(rows[i - 1].depositID ~= rows[i].depositID, "duplicate depositID") end
  return rows, total, fraction
end

local function copyLot(lot)
  assert(type(lot) == "table", "invalid arrears lot")
  requireID(lot.lotID, "lotID")
  requireID(lot.loanID, "lot.loanID")
  requirePlayerID(lot.playerID, "lot.playerID")
  requireInteger(lot.dueTurn, "lot.dueTurn")
  requireInteger(lot.firstFeeTurn, "lot.firstFeeTurn")
  requireNonnegative(lot.principal, "lot.principal")
  requireNonnegative(lot.interest, "lot.interest")
  requireNonnegative(lot.fees, "lot.fees")
  return {lotID = lot.lotID, loanID = lot.loanID, playerID = lot.playerID, dueTurn = lot.dueTurn,
    firstFeeTurn = lot.firstFeeTurn, principal = lot.principal, interest = lot.interest, fees = lot.fees}
end

local function copyLots(lots)
  assert(type(lots) == "table", "arrears lot array required")
  local out = {}
  for i = 1, #lots do out[i] = copyLot(lots[i]) end
  table.sort(out, function(a, b) return a.lotID < b.lotID end)
  for i = 2, #out do assert(out[i - 1].lotID ~= out[i].lotID, "duplicate lotID") end
  return out
end

-- A new lot's first fee turn (game turns; arrears.firstFeeDelayTurns). Not speed-scaled: it only
-- means "the next turn"; the per-turn fee rate itself is speed-adjusted (decision 34).
function M.LotFirstFeeTurn(dueTurn, config)
  local c = configOrDefault(config)
  requireInteger(dueTurn, "dueTurn")
  requireInteger(c.arrears.firstFeeDelayTurns, "arrears.firstFeeDelayTurns")
  return dueTurn + c.arrears.firstFeeDelayTurns
end

-- One simple fee per call (one game turn) on each lot whose firstFeeTurn has arrived:
-- ArrearsFeeRate(scale) x unpaid base (principal + contractual interest), never on fees.
-- scale nil means Standard. Returns lots (copies by lotID), total fee and rows
-- {lotID, loanID, fee} for lots charged.
function M.AccrueLotFees(lots, turn, config, scale)
  requireInteger(turn, "turn")
  local rate = M.ArrearsFeeRate(scale, config)
  local out, total, rows = copyLots(lots), 0, {}
  for i = 1, #out do
    local lot = out[i]
    if turn >= lot.firstFeeTurn then
      local fee = rate * (lot.principal + lot.interest)
      if fee > 0 then
        lot.fees = lot.fees + fee
        total = total + fee
        rows[#rows + 1] = {lotID = lot.lotID, loanID = lot.loanID, fee = fee}
      end
    end
  end
  return out, total, rows
end

local function allocationOrder(c)
  assert(c.arrears.lotOrder == "OLDEST_DUE_TURN_THEN_LOAN_ID", "unsupported arrears lot order")
  local order = c.arrears.componentOrder
  assert(type(order) == "table" and order[1] ~= nil, "arrears componentOrder must be an array")
  local count = 0
  for i = 1, #order do
    assert(type(order[i]) == "string" and COMPONENT_FIELD[order[i]], "unknown arrears component")
    for j = 1, i - 1 do assert(order[j] ~= order[i], "duplicate arrears component") end
    count = count + 1
  end
  local expected = 0
  for _, name in ipairs({"FEES", "OVERDUE_INTEREST", "OVERDUE_PRINCIPAL"}) do
    if COMPONENT_FIELD[name] then expected = expected + 1 end
  end
  assert(count == expected, "arrears componentOrder must name every component once")
  return order
end

-- Spend amount on lots: oldest due turn first, then loan ID, then lot ID; within a lot in
-- arrears.componentOrder. Returns {paid, unused, paidFees, paidInterest, paidPrincipal,
-- payments (allocation order, rows {lotID, loanID, fees, interest, principal}),
-- lots (remaining balances, copies by lotID; zero lots kept for the caller to close)}.
function M.AllocateArrearsPayment(lots, amount, config)
  local c = configOrDefault(config)
  requireNonnegative(amount, "amount")
  local components = allocationOrder(c)
  local out = copyLots(lots)
  local ordered = {}
  for i = 1, #out do ordered[i] = out[i] end
  table.sort(ordered, function(a, b)
    if a.dueTurn ~= b.dueTurn then return a.dueTurn < b.dueTurn end
    if a.loanID ~= b.loanID then return a.loanID < b.loanID end
    return a.lotID < b.lotID
  end)
  local remaining = amount
  local result = {paidFees = 0, paidInterest = 0, paidPrincipal = 0, payments = {}, lots = out}
  for i = 1, #ordered do
    local lot = ordered[i]
    local row = {lotID = lot.lotID, loanID = lot.loanID, fees = 0, interest = 0, principal = 0}
    for j = 1, #components do
      local field = COMPONENT_FIELD[components[j]]
      local pay = math.min(remaining, lot[field])
      lot[field] = lot[field] - pay
      row[field] = pay
      remaining = remaining - pay
    end
    if row.fees + row.interest + row.principal > 0 then
      result.payments[#result.payments + 1] = row
      result.paidFees = result.paidFees + row.fees
      result.paidInterest = result.paidInterest + row.interest
      result.paidPrincipal = result.paidPrincipal + row.principal
    end
  end
  result.paid, result.unused = amount - remaining, remaining
  return result
end

-- payout = {kind (MATURITY, EARLY), deposit (record), bankCash, lots (that player's)}.
-- Full due: MATURITY principal + accruedReturn; EARLY earlyWithdrawalFraction x principal,
-- forfeiting accrued return (decision 32). R6 guarantee = max(0, due - bankCash), measured
-- before the arrears credit. Then arrears first via AllocateArrearsPayment, remainder to
-- the treasury. bankCashAfter = bankCash + guarantee - due + toArrears.
function M.DepositPayout(payout, config)
  local c = configOrDefault(config)
  assert(type(payout) == "table" and type(payout.deposit) == "table", "invalid deposit payout")
  local d = payout.deposit
  requireID(d.depositID, "depositID")
  requirePlayerID(d.playerID, "deposit.playerID")
  assert(d.status == "ACTIVE", "only an active deposit can pay out")
  requireNonnegative(d.principal, "deposit.principal")
  requireNonnegative(d.accruedReturn, "deposit.accruedReturn")
  requireNonnegative(payout.bankCash, "bankCash")
  assert(type(payout.lots) == "table", "arrears lot array required")
  for i = 1, #payout.lots do
    assert(type(payout.lots[i]) == "table" and payout.lots[i].playerID == d.playerID,
      "payout lots must belong to the depositor")
  end
  local result = {kind = payout.kind, depositID = d.depositID, playerID = d.playerID}
  if payout.kind == "MATURITY" then
    result.principalPaid, result.returnPaid = d.principal, d.accruedReturn
    result.forfeitedReturn, result.principalForfeited = 0, 0
  elseif payout.kind == "EARLY" then
    local fraction = c.investors.earlyWithdrawalFraction
    assert(finite(fraction) and fraction >= 0 and fraction <= 1, "invalid earlyWithdrawalFraction")
    result.principalPaid, result.returnPaid = fraction * d.principal, 0
    result.forfeitedReturn = d.accruedReturn
    result.principalForfeited = d.principal - result.principalPaid
  else error("unknown deposit payout kind") end
  result.due = result.principalPaid + result.returnPaid
  result.guarantee = math.max(0, result.due - payout.bankCash)
  result.allocation = M.AllocateArrearsPayment(payout.lots, result.due, c)
  result.toArrears = result.allocation.paid
  result.toTreasury = result.allocation.unused
  result.bankCashAfter = payout.bankCash + result.guarantee - result.due + result.toArrears
  return result
end

local function loanBuckets(loan)
  requireID(loan.loanID, "loanID")
  loanExposureOf(loan)
  requireNonnegative(loan.futureInterest, "loan.futureInterest")
end

-- Completed debt relief: every remaining bucket of the player's ACTIVE loans and lots
-- scales by 1 - debtReliefFraction (not-yet-due interest too when configured).
-- Returns {loans = rows {loanID, scheduledPrincipal, overduePrincipal, overdueInterest,
-- arrearsFees, futureInterest}, lots = the player's lot copies by lotID, forgivenExposure
-- (the subsidy amount for exposure memory), forgivenFutureInterest}.
function M.ApplyDebtRelief(loans, lots, playerID, config)
  local c = configOrDefault(config)
  assert(type(loans) == "table", "loan array required")
  requirePlayerID(playerID, "playerID")
  local fraction = c.relief.debtReliefFraction
  assert(finite(fraction) and fraction >= 0 and fraction <= 1, "invalid debtReliefFraction")
  assert(type(c.relief.debtReliefIncludesFutureInterest) == "boolean", "invalid debtReliefIncludesFutureInterest")
  local keep = 1 - fraction
  local result = {loans = {}, lots = {}, forgivenExposure = 0, forgivenFutureInterest = 0}
  for i = 1, #loans do
    local loan = loans[i]
    assert(type(loan) == "table", "invalid loan record")
    loanBuckets(loan)
    if loan.playerID == playerID and loan.status == "ACTIVE" then
      local row = {loanID = loan.loanID, scheduledPrincipal = keep * loan.scheduledPrincipal,
        overduePrincipal = keep * loan.overduePrincipal, overdueInterest = keep * loan.overdueInterest,
        arrearsFees = keep * loan.arrearsFees, futureInterest = loan.futureInterest}
      if c.relief.debtReliefIncludesFutureInterest then row.futureInterest = keep * loan.futureInterest end
      result.forgivenExposure = result.forgivenExposure
        + (loan.scheduledPrincipal - row.scheduledPrincipal) + (loan.overduePrincipal - row.overduePrincipal)
        + (loan.overdueInterest - row.overdueInterest) + (loan.arrearsFees - row.arrearsFees)
      result.forgivenFutureInterest = result.forgivenFutureInterest + loan.futureInterest - row.futureInterest
      result.loans[#result.loans + 1] = row
    end
  end
  table.sort(result.loans, function(a, b) return a.loanID < b.loanID end)
  local copies = copyLots(lots)
  for i = 1, #copies do
    local lot = copies[i]
    if lot.playerID == playerID then
      lot.principal, lot.interest, lot.fees = keep * lot.principal, keep * lot.interest, keep * lot.fees
      result.lots[#result.lots + 1] = lot
    end
  end
  return result
end

-- Milestone completion before the halfway turn: forgive the tier fraction of the
-- not-yet-due principal and recalculate remaining installments proportionally (future
-- interest scales by the same fraction). Overdue lots are untouched. tier is the loan's
-- originTier. Returns {fraction, forgivenPrincipal, cancelledFutureInterest,
-- scheduledPrincipal, futureInterest}.
function M.MilestoneForgive(loan, tier, config)
  local c = configOrDefault(config)
  assert(type(loan) == "table", "invalid loan record")
  loanBuckets(loan)
  assert(type(tier) == "string" and type(c.tiers[tier]) == "table", "unknown development tier")
  local fraction = c.tiers[tier].milestoneForgiveness
  assert(finite(fraction) and fraction >= 0 and fraction <= 1, "invalid milestone forgiveness")
  local forgiven = fraction * loan.scheduledPrincipal
  local cancelled = fraction * loan.futureInterest
  return {fraction = fraction, forgivenPrincipal = forgiven, cancelledFutureInterest = cancelled,
    scheduledPrincipal = loan.scheduledPrincipal - forgiven, futureInterest = loan.futureInterest - cancelled}
end

-- Exclusive halfway turn: completion must happen at a turn strictly before it.
function M.MilestoneHalfwayTurn(originTurn, graceTurns, paymentTurns)
  requireInteger(originTurn, "originTurn")
  requireInteger(graceTurns, "graceTurns")
  requireID(paymentTurns, "paymentTurns")
  return originTurn + math.ceil((graceTurns + paymentTurns) / 2)
end

-- Decision 31 + 33 replacement quote. r = {product (lineage), tier (current), rating
-- (current), scarActive, growth (published, per game turn), scale, scheduledPrincipal,
-- overduePrincipal, futureInterest, overdueInterest, arrearsFees}. Base V of the product
-- for the current tier; with relief.restructureAppliesRatingAndScar the one-grade-dropped
-- rating and any scar adjust it (D stays D at credit.D.valueAdjustment); never investor or
-- liquidity adjustments; normal floor. Not-yet-due interest is cancelled; overdue interest
-- and fees are capitalized as principal. Term/grace from relief.* scaled; a borrower in default
-- (r.inDefault) gets relief.restructureDefaultGraceTurns so default can clear first (decision 40).
function M.RestructureQuote(r, config)
  local c = configOrDefault(config)
  assert(type(r) == "table", "restructure requires a request table")
  local product = r.product
  if product == nil then product = "ORDINARY" end
  local base = productBaseV(product, r.tier, c)
  ratingAdjustment(r.rating, c)
  assert(type(r.scarActive) == "boolean", "scarActive must be boolean")
  assert(type(c.relief.restructureAppliesRatingAndScar) == "boolean", "invalid restructureAppliesRatingAndScar")
  for _, field in ipairs({"scheduledPrincipal", "overduePrincipal", "futureInterest",
      "overdueInterest", "arrearsFees"}) do requireNonnegative(r[field], field) end
  local newRating = M.DowngradeRating(r.rating, LOWEST_LENDING_RATING)
  local rating, scar = 0, 0
  if c.relief.restructureAppliesRatingAndScar then
    rating = ratingAdjustment(newRating, c)
    if r.scarActive then scar = c.credit.scarValueAdjustment end
  end
  local v = composeV(base, rating, 0, scar, 0, c)
  v.product = product
  local carried = r.scheduledPrincipal + r.overduePrincipal
  local principal = carried + r.overdueInterest + r.arrearsFees
  local quote = M.LoanQuote(principal, v.quotedV, r.growth,
    M.ScaleTurns(c.relief.restructureTermTurns, r.scale),
    M.ScaleTurns(r.inDefault == true and c.relief.restructureDefaultGraceTurns or c.relief.restructureGraceTurns, r.scale), c)
  quote.product, quote.tier, quote.rating = product, r.tier, newRating
  quote.standardTermTurns = c.relief.restructureTermTurns
  quote.vComponents = v
  quote.carriedPrincipal = carried
  quote.capitalizedInterest, quote.capitalizedFees = r.overdueInterest, r.arrearsFees
  quote.cancelledFutureInterest = r.futureInterest
  return quote
end

-- Development grant: max(gptMultiple x net GPT, eraMinimumFloorMultiple x U) (decision 33).
function M.GrantAmount(netGPT, U, config)
  local c = configOrDefault(config)
  assert(finite(netGPT), "netGPT must be finite")
  requirePositive(U, "U")
  assert(c.grants.eraMinimums == false, "per-era grant minimum tables are unsupported")
  return math.max(c.grants.gptMultiple * netGPT, c.grants.eraMinimumFloorMultiple * U)
end

local function reserveConfig(c)
  local r = c.liquidity.baseReserve
  assert(type(r) == "table" and type(r.enabled) == "boolean", "invalid base reserve config")
  return r
end

-- Cap = capFloorMultiple x U x living majors (or fixedCap). nil, "RESERVE_DISABLED" when off.
function M.ReserveCap(U, livingMajors, config)
  local r = reserveConfig(configOrDefault(config))
  if not r.enabled then return nil, "RESERVE_DISABLED" end
  requirePositive(U, "U")
  requireInteger(livingMajors, "livingMajors")
  if r.fixedCap ~= false then
    requireNonnegative(r.fixedCap, "fixedCap")
    return r.fixedCap, "ok"
  end
  return r.capFloorMultiple * U * livingMajors, "ok"
end

-- Per game turn: min(refillFloorMultiple x U x living / turn scale (or fixedRefill, exact),
-- max(0, cap - cash)). The configured amount is per Standard turn (PLAN base reserve note).
function M.ReserveRefill(U, livingMajors, scale, cash, cap, config)
  local r = reserveConfig(configOrDefault(config))
  if not r.enabled then return nil, "RESERVE_DISABLED" end
  requirePositive(U, "U")
  requireInteger(livingMajors, "livingMajors")
  requirePositive(scale, "scale")
  requireNonnegative(cash, "cash")
  requireNonnegative(cap, "cap")
  local amount
  if r.fixedRefill ~= false then
    requireNonnegative(r.fixedRefill, "fixedRefill")
    amount = r.fixedRefill
  else amount = r.refillFloorMultiple * U * livingMajors / scale end
  return math.min(amount, math.max(0, cap - cash)), "ok"
end

function M.ReserveOpeningCash(cap, config)
  local r = reserveConfig(configOrDefault(config))
  requireNonnegative(cap, "cap")
  return r.openingCashFraction * cap
end

return WBL_MATH
