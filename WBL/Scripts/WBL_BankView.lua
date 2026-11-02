-- Pure UI view model for the World Bank panel. No engine calls, no state mutation, no ordering by pairs.
-- Input is the decoded published state (PLAN "State schema 1" and "Offers view"); output is plain tables
-- of raw numbers and UI text keys. The panel formats numbers and localizes keys.
-- Privacy (decision 10): only the President receives other civs' tier, rating, debt and default stage;
-- everyone else gets their own row only. Other civs' loans are never copied into the view.
-- Load WBL_Config and WBL_Math first (WBL_MATH global).
WBL_BANKVIEW = {}
local M = WBL_BANKVIEW

M.REQUEST_EVENT = "WBL_BankRequest"
-- Amount shortcut fractions of the maximum draw; the last step is the exact maximum.
M.AMOUNT_STEPS = {0.25, 0.5, 0.75, 1}
-- New-deposit amount shortcuts as multiples of U (scaled world-era credit floor); the UI cannot read the treasury.
M.DEPOSIT_UNIT_STEPS = {0.5, 1, 2, 4}
M.PENALTY_ORDER = {"garnishPercent", "amenities", "productionPercent", "sciencePercent", "loyalty", "favor", "tradePercent"}

-- Every reason code the view can emit (reducer rejection codes plus view-only codes). Each needs
-- one reason text row per code in WBL/Text/WBL_UI_Text.xml; test_bank_ui.py enforces it.
M.REASON_CODES = {
  "BAD_NONCE", "MALFORMED", "UNKNOWN_KIND", "ACTOR_INVALID", "BANK_SUSPENDED", "SNAPSHOT_INCOMPLETE",
  "CAPABILITY_PENDING", "PRICE_CHANGED", "NOT_FOUND", "NOT_OWNER", "TIER_INELIGIBLE", "RATING_D",
  "ARREARS", "IN_DEFAULT", "FROZEN", "TERM_INVALID", "AMOUNT_INVALID", "EXCEEDS_LIMIT",
  "POOL_INSUFFICIENT", "LIQUIDITY_EMERGENCY", "INSUFFICIENT_GOLD", "MILESTONE_INVALID",
  "MILESTONE_COMPLETE", "ALREADY_USED", "PER_ERA_LIMIT", "ENTITLEMENT_EXPIRED",
  "ENTITLEMENT_CLAIMED", "NOT_ELIGIBLE", "NOT_AT_WAR", "PRESIDENT_ONLY",
  "NO_STATE", "NOT_A_PLAYER", "NO_OFFER", "QUOTE_UNAVAILABLE", "NO_LOAN_OFFER", "RELIEF_TIER",
  "RELIEF_PENDING", "RELIEF_NO_ARREARS", "ALREADY_FROZEN", "NO_ACTIVE_LOAN", "MILESTONE_WINDOW",
  "MILESTONE_REQUIRED", "NO_DISASTER_OFFER", "NOT_INVESTOR", "PRODUCT_UNAVAILABLE",
  "REDUCER_ERROR",
}

local KIND_FIELDS = {
  TAKE_LOAN = {"product", "amount", "termStandardTurns", "quotedV"},
  CLAIM_RECOVERY = {"entitlementID", "amount", "termStandardTurns", "quotedV"},
  REPAY_EARLY = {"loanID", "quotedAmount"},
  RESTRUCTURE = {"loanID", "quotedV"},
  DEBT_RELIEF = {},
  SELECT_MILESTONE = {"loanID"},
  REQUEST_GRANT = {"quotedAmount"},
  DEPOSIT = {"amount", "termStandardTurns"},
  WITHDRAW = {"depositID", "quotedAmount"},
  FREEZE_PLACE = {"targetID", "mode"},
  FREEZE_LIFT = {"freezeID"},
}
local MILESTONE_KINDS = {TAKE_LOAN = true, CLAIM_RECOVERY = true, DEBT_RELIEF = true, SELECT_MILESTONE = true, REQUEST_GRANT = true}
M.REQUEST_KINDS = {"TAKE_LOAN", "CLAIM_RECOVERY", "REPAY_EARLY", "RESTRUCTURE", "DEBT_RELIEF", "SELECT_MILESTONE",
  "REQUEST_GRANT", "DEPOSIT", "WITHDRAW", "FREEZE_PLACE", "FREEZE_LIFT"}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function num(value)
  if finite(value) then return value end
  return 0
end

-- Dynamic text keys are built from a split prefix so the key audit (which scans literals) sees only whole keys.
local KEY_PREFIX = "LOC_WBL" .. "_UI_"
function M.Key(group, code)
  return KEY_PREFIX .. group .. "_" .. string.upper(tostring(code))
end

local function reasonKey(code)
  if code == nil or code == "" then return "" end
  return M.Key("REASON", code)
end

local function findBy(list, field, value)
  if type(list) ~= "table" then return nil end
  for i = 1, #list do
    if list[i][field] == value then return list[i], i end
  end
  return nil
end

local function blocked(code)
  return {available = false, reason = code, reasonKey = reasonKey(code)}
end

local function allowed()
  return {available = true, reason = "", reasonKey = ""}
end

-- Active-loan money on one loan, all from the locked buckets (never from rates).
local function loanBuckets(loan)
  local principal = num(loan.scheduledPrincipal) + num(loan.overduePrincipal)
  local arrears = num(loan.overduePrincipal) + num(loan.overdueInterest) + num(loan.arrearsFees)
  return {
    principal = principal,
    arrears = arrears,
    debt = principal + num(loan.overdueInterest) + num(loan.arrearsFees),
    totalOwed = principal + num(loan.overdueInterest) + num(loan.arrearsFees) + num(loan.futureInterest),
  }
end

local function playerHasArrears(state, playerID)
  if findBy(state.lots, "playerID", playerID) then return true end
  for i = 1, #(state.loans or {}) do
    local loan = state.loans[i]
    if loan.playerID == playerID and loan.status == "ACTIVE" and loanBuckets(loan).arrears > 0 then return true end
  end
  return false
end

-- Decision 34: arrears clocks are Standard turns scaled by the state's speed scale.
local function arrearsClocks(state, config)
  local scale = num(state.speedScale)
  if scale <= 0 then scale = 1 end
  return WBL_MATH.ArrearsClocks(scale, config)
end

local function penaltyStage(player, config, state)
  local level = player.penaltyLevel
  if type(level) == "table" and finite(level.stage) then return level.stage end
  if player.inDefault and finite(player.defaultTurn) and player.defaultTurn > 0 then
    if player.defaultTurn >= arrearsClocks(state, config).stage2StartTurn then return 2 end
    return 1
  end
  return 0
end

local function penaltyRows(player, config, stage)
  local rows = {}
  if stage < 1 then return rows end
  local tier = player.tier
  if type(player.penaltyLevel) == "table" and config.tiers[player.penaltyLevel.tier] then tier = player.penaltyLevel.tier end
  if not config.tiers[tier] then return rows end
  local ok, values = pcall(WBL_MATH.Penalties, tier, "stage" .. tostring(stage), config)
  if not ok then return rows end
  local relief = type(player.relief) == "table" and player.relief.status == "PENDING"
  for i = 1, #M.PENALTY_ORDER do
    local key = M.PENALTY_ORDER[i]
    local value = values[key]
    if finite(value) and value ~= 0 then
      -- Debt relief pending suspends everything except garnishing (spec 3.6).
      rows[#rows + 1] = {key = key, textKey = M.Key("PENALTY", key), value = value,
        suspended = relief and key ~= "garnishPercent"}
    end
  end
  return rows
end

local function milestoneView(milestone)
  if type(milestone) ~= "table" then return {kind = "NONE", status = "NONE", statusKey = "LOC_WBL_UI_MS_NONE"} end
  local status = milestone.status or "NONE"
  return {kind = milestone.kind or "NONE", target = milestone.target, cityID = milestone.cityID,
    halfwayTurn = milestone.halfwayTurn, fraction = milestone.fraction, status = status,
    statusKey = M.Key("MS", status)}
end

local function productView(product, config, tier, growth)
  local entry = {
    product = product.product, productKey = M.Key("PRODUCT", product.product),
    available = product.available == true, reason = product.reason or "", maxAmount = num(product.maxAmount),
    quotedV = product.quotedV, vComponents = product.vComponents, terms = {},
    milestoneRequired = product.product == "INFRASTRUCTURE",
    forgivenessFraction = config.tiers[tier] and config.tiers[tier].milestoneForgiveness or 0,
  }
  entry.reasonKey = reasonKey(entry.reason)
  if entry.available and (entry.maxAmount <= 0 or not finite(entry.quotedV)) then
    entry.available = false
    entry.reason = finite(entry.quotedV) and "AMOUNT_INVALID" or "QUOTE_UNAVAILABLE"
    entry.reasonKey = reasonKey(entry.reason)
  end
  for i = 1, #(product.terms or {}) do
    local term = product.terms[i]
    entry.terms[#entry.terms + 1] = {termStandardTurns = term.termStandardTurns, paymentTurns = term.paymentTurns,
      graceTurns = term.graceTurns, nominalRate = term.nominalRate}
  end
  entry.growth = growth
  if entry.available and #entry.terms == 0 then
    entry.available, entry.reason = false, "QUOTE_UNAVAILABLE"
    entry.reasonKey = reasonKey(entry.reason)
  end
  return entry
end

local function buildBorrow(state, player, offer, config, view)
  local borrow = {
    tier = player.tier, tierKey = M.Key("TIER", player.tier),
    rating = player.rating, ratingKey = M.Key("RATING", player.rating),
    scarActive = num(player.scarUntilTurn) > view.turn,
    products = {}, recoveryOffers = {}, grant = blocked("NO_OFFER"), terms = {},
    available = false, reason = "NO_OFFER", reasonKey = reasonKey("NO_OFFER"),
    -- Published quotes are the worst case at the maximum amount; smaller loans can price better.
    priceNoteKey = "LOC_WBL_UI_BORROW_PRICE_NOTE",
  }
  if view.suspended then
    borrow.reason, borrow.reasonKey = "BANK_SUSPENDED", reasonKey("BANK_SUSPENDED")
  end
  if not offer then return borrow end
  borrow.growth = offer.growth
  borrow.liquidityTier = offer.liquidityTier
  borrow.liquidityKey = M.Key("LIQUIDITY", offer.liquidityTier)
  borrow.pool, borrow.cap = offer.pool, offer.cap
  borrow.normalLimit, borrow.extension, borrow.limit = offer.normalLimit, offer.extension, offer.limit
  borrow.outstandingPrincipal, borrow.availableDraw = offer.outstandingPrincipal, offer.availableDraw
  borrow.eligibleCapital = offer.eligibleCapital
  borrow.reason = offer.blockedReason or ""
  if view.suspended then borrow.reason = "BANK_SUSPENDED" end
  borrow.reasonKey = reasonKey(borrow.reason)
  borrow.available = borrow.reason == ""
  local recoveryProduct = nil
  for i = 1, #(offer.products or {}) do
    local entry = productView(offer.products[i], config, player.tier, offer.growth)
    if entry.product == "RECOVERY" then
      recoveryProduct = entry
    else
      if view.suspended then entry.available, entry.reason, entry.reasonKey = false, "BANK_SUSPENDED", reasonKey("BANK_SUSPENDED") end
      borrow.products[#borrow.products + 1] = entry
    end
  end
  for i = 1, #(offer.recoveryOffers or {}) do
    local ro = offer.recoveryOffers[i]
    local entry = {entitlementID = ro.entitlementID, eventKey = ro.eventKey, expiryTurn = ro.expiryTurn,
      turnsLeft = num(ro.expiryTurn) - view.turn, maxAmount = num(ro.maxAmount),
      quotedV = ro.quotedV, terms = {}, growth = offer.growth,
      disasterKey = M.DisasterKey(ro.eventKey)}
    local sourceTerms = ro.terms
    if type(sourceTerms) ~= "table" then
      sourceTerms = recoveryProduct and recoveryProduct.terms or {}
      if entry.quotedV == nil and recoveryProduct then entry.quotedV = recoveryProduct.quotedV end
    end
    for j = 1, #sourceTerms do
      local term = sourceTerms[j]
      entry.terms[#entry.terms + 1] = {termStandardTurns = term.termStandardTurns, paymentTurns = term.paymentTurns,
        graceTurns = term.graceTurns, nominalRate = term.nominalRate}
    end
    entry.reason = ro.blockedReason or ""
    if view.suspended then entry.reason = "BANK_SUSPENDED" end
    -- Never guess a price: no published quote, no claim.
    if entry.reason == "" and (not finite(entry.quotedV) or #entry.terms == 0) then entry.reason = "QUOTE_UNAVAILABLE" end
    if entry.reason == "" and entry.maxAmount <= 0 then entry.reason = "AMOUNT_INVALID" end
    entry.reasonKey = reasonKey(entry.reason)
    entry.available = entry.reason == ""
    borrow.recoveryOffers[#borrow.recoveryOffers + 1] = entry
  end
  local grant = offer.grantOffer
  if type(grant) == "table" then
    borrow.grant = {available = grant.available == true and not view.suspended, amount = num(grant.amount),
      reason = grant.reason or "", milestoneRequired = true}
    if view.suspended then borrow.grant.reason = "BANK_SUSPENDED" end
    borrow.grant.reasonKey = reasonKey(borrow.grant.reason)
  end
  return borrow
end

local function disasterEventKeyFor(state, loan)
  if loan.product ~= "RECOVERY" then return "" end
  local entitlement = findBy(state.recovery, "entitlementID", loan.entitlementID)
  if entitlement then return entitlement.eventKey or "" end
  return ""
end

local function loanOfferFor(offer, loanID)
  if not offer then return nil end
  return findBy(offer.loanOffers, "loanID", loanID)
end

local function buildLoans(state, player, offer, config, view)
  local loans = {rows = {}, relief = nil, penalties = {}}
  local stage = penaltyStage(player, config, state)
  local clocks = arrearsClocks(state, config)
  loans.penaltyStage = stage
  loans.penalties = penaltyRows(player, config, stage)
  loans.inDefault = player.inDefault == true
  loans.defaultTurn = num(player.defaultTurn)
  loans.arrearsTurns = num(player.arrearsTurns)
  -- Game-turn clock limits for the warning line (decision 34).
  loans.warningTurns, loans.defaultTurns = clocks.warningTurns, clocks.defaultTurns
  loans.warning = loans.arrearsTurns >= clocks.warningTurns and not loans.inDefault
  loans.arrearsActive = playerHasArrears(state, player.playerID)
  loans.rating = player.rating
  local totalOwed, forgivable = 0, 0
  for i = 1, #(state.loans or {}) do
    local loan = state.loans[i]
    if loan.playerID == player.playerID and loan.status == "ACTIVE" then
      local buckets = loanBuckets(loan)
      local remaining = num(loan.installments) - num(loan.installmentsPaid)
      local row = {
        loanID = loan.loanID, product = loan.product, productKey = M.Key("PRODUCT", loan.product),
        isRecovery = loan.product == "RECOVERY", disasterEventKey = disasterEventKeyFor(state, loan),
        principal = buckets.principal, arrears = buckets.arrears, debt = buckets.debt, totalOwed = buckets.totalOwed,
        overduePrincipal = num(loan.overduePrincipal), overdueInterest = num(loan.overdueInterest),
        arrearsFees = num(loan.arrearsFees), futureInterest = num(loan.futureInterest),
        installmentsLeft = math.max(0, remaining), nextDueTurn = loan.nextDueTurn,
        nextPayment = 0, missedCount = num(loan.missedCount), inArrears = buckets.arrears > 0,
        nominalRate = loan.nominalRate, valueRatio = loan.valueRatio,
        milestone = milestoneView(loan.milestone),
      }
      row.disasterKey = M.DisasterKey(row.disasterEventKey)
      if remaining > 0 then
        row.nextPayment = (num(loan.scheduledPrincipal) + num(loan.futureInterest)) / remaining
      end
      totalOwed = totalOwed + buckets.totalOwed
      if config.relief.debtReliefIncludesFutureInterest then forgivable = forgivable + buckets.totalOwed
      else forgivable = forgivable + buckets.debt end
      -- Early settlement quote from the locked buckets (decision 17).
      local ok, quote = pcall(WBL_MATH.EarlySettlementQuote, {
        scheduledPrincipal = num(loan.scheduledPrincipal), overduePrincipal = num(loan.overduePrincipal),
        futureInterest = num(loan.futureInterest), overdueInterest = num(loan.overdueInterest),
        arrearsFees = num(loan.arrearsFees), earlyRepayInterestFraction = num(loan.earlyRepayInterestFraction)})
      if ok then
        row.repay = allowed()
        row.repay.totalDue, row.repay.waived = quote.totalDue, quote.waivedFutureInterest
        row.repay.principalDue, row.repay.interestDue = quote.principalDue, quote.futureInterestDue
        row.repay.overdueInterestDue, row.repay.feesDue = quote.overdueInterestDue, quote.arrearsFeesDue
        if view.suspended then row.repay = blocked("BANK_SUSPENDED") end
      else
        row.repay = blocked("QUOTE_UNAVAILABLE")
      end
      -- Restructure: lineage flag gates it; the price must be published by the reducer (decision 33C).
      if view.suspended then
        row.restructure = blocked("BANK_SUSPENDED")
      elseif loan.restructured then
        row.restructure = blocked("ALREADY_USED")
      else
        local lo = loanOfferFor(offer, loan.loanID)
        if not lo then
          row.restructure = blocked("NO_LOAN_OFFER")
        elseif lo.restructureReason and lo.restructureReason ~= "" then
          row.restructure = blocked(lo.restructureReason)
        elseif not finite(lo.restructureQuotedV) then
          row.restructure = blocked("QUOTE_UNAVAILABLE")
        else
          row.restructure = allowed()
          row.restructure.quotedV = lo.restructureQuotedV
        end
      end
      row.restructure.favorCost = config.relief.restructureFavorCost
      row.restructure.termStandardTurns = config.relief.restructureTermTurns
      -- A milestone may only be chosen in the origination turn for a loan without one.
      if type(loan.milestone) == "table" and loan.milestone.status ~= "NONE" and loan.milestone.status ~= nil then
        row.selectMilestone = blocked("ALREADY_USED")
      elseif loan.originTurn ~= view.turn then
        row.selectMilestone = blocked("MILESTONE_WINDOW")
      elseif view.suspended then
        row.selectMilestone = blocked("BANK_SUSPENDED")
      else
        row.selectMilestone = allowed()
      end
      loans.rows[#loans.rows + 1] = row
    end
  end
  loans.totalOwed = totalOwed
  -- Debt relief (Underdeveloped, once per game, spec 3.6).
  local relief = type(player.relief) == "table" and player.relief or {status = "NONE"}
  local entry
  if view.suspended then entry = blocked("BANK_SUSPENDED")
  elseif relief.status == "PENDING" then entry = blocked("RELIEF_PENDING")
  elseif player.debtReliefUsed then entry = blocked("ALREADY_USED")
  elseif player.tier ~= "UNDERDEVELOPED" then entry = blocked("RELIEF_TIER")
  elseif not (loans.arrearsActive or loans.inDefault) then entry = blocked("RELIEF_NO_ARREARS")
  else entry = allowed() end
  entry.milestoneRequired = true
  entry.status = relief.status or "NONE"
  entry.statusKey = M.Key("RELIEF", entry.status)
  entry.deadlineTurn = relief.deadlineTurn
  entry.turnsLeft = num(relief.deadlineTurn) - view.turn
  entry.milestone = relief.milestone
  entry.forgiveAmount = forgivable * config.relief.debtReliefFraction
  entry.fraction = config.relief.debtReliefFraction
  loans.debtRelief = entry
  return loans
end

local function exposure(state, playerID, view, config)
  local total = 0
  for i = 1, #(state.loans or {}) do
    local loan = state.loans[i]
    if loan.playerID == playerID and loan.status == "ACTIVE" then total = total + loanBuckets(loan).debt end
  end
  local memory = WBL_MATH.ScaleTurns(config.investors.eligibility.subsidyMemoryTurns, num(state.speedScale))
  for i = 1, #(state.subsidies or {}) do
    local s = state.subsidies[i]
    if s.playerID == playerID and view.turn - num(s.turn) <= memory then total = total + num(s.amount) end
  end
  return total
end

local function buildInvest(state, player, offer, config, view)
  local elig = config.investors.eligibility
  local unit = num(state.era and state.era.U)
  local E = num(player.eligibleCapital)
  local invest = {
    unit = unit, eligibleCapital = E, eligibleShare = num(player.eligibleShare),
    deposits = {}, thresholds = {}, perks = {}, unpaid = {},
    exposure = exposure(state, player.playerID, view, config),
  }
  local active = 0
  for i = 1, #(state.deposits or {}) do
    local d = state.deposits[i]
    if d.playerID == player.playerID and d.status == "ACTIVE" then
      active = active + num(d.principal)
      local early = num(d.principal) * config.investors.earlyWithdrawalFraction
      local w = view.suspended and blocked("BANK_SUSPENDED") or allowed()
      w.quotedAmount = early
      invest.deposits[#invest.deposits + 1] = {depositID = d.depositID, principal = num(d.principal),
        returnFraction = num(d.returnFraction), termTurns = d.termTurns, openTurn = d.openTurn,
        maturityTurn = d.maturityTurn, accruedReturn = num(d.accruedReturn),
        turnsLeft = num(d.maturityTurn) - view.turn, earlyPayout = early, withdraw = w}
    end
  end
  invest.activePrincipal = active
  local ladder = offer and offer.ladder or {}
  invest.ladder = ladder
  -- Next capital thresholds, in U. "post-loan" ones apply to E left after a loan.
  local steps = {
    {key = "ENTRY", multiple = elig.entryFloorMultiple},
    {key = "PREFERRED_HALF", multiple = elig.preferredHalfFloorMultiple},
    {key = "PREFERRED_FULL", multiple = elig.preferredFullFloorMultiple},
    {key = "LIQUIDITY_EXEMPT", multiple = elig.liquidityExemptionFloorMultiple},
    {key = "PRESIDENT", multiple = elig.presidentFloorMultiple},
    {key = "FREEZE_MEMBER", multiple = elig.coalitionMemberFloorMultiple},
    {key = "FREEZE_COALITION", multiple = elig.coalitionFloorMultiple},
  }
  for i = 1, #steps do
    local needed = steps[i].multiple * unit
    invest.thresholds[#invest.thresholds + 1] = {key = steps[i].key, textKey = M.Key("THRESHOLD", steps[i].key),
      multiple = steps[i].multiple, needed = needed, reached = unit > 0 and E >= needed,
      remaining = math.max(0, needed - E)}
  end
  -- Favor: smaller of share rule and capital ladder (decision 29); prefer the reducer's published number.
  local shareFavor, capitalFavor = 0, 0
  if unit > 0 and E >= elig.entryFloorMultiple * unit then
    local okShare, value = pcall(WBL_MATH.ShareFavor, invest.eligibleShare, config)
    if okShare then shareFavor = value end
    capitalFavor = math.min(config.investors.favorCap, math.floor(E / (elig.favorStepFloorMultiple * unit)))
  end
  local favor = math.min(shareFavor, capitalFavor)
  if type(ladder) == "table" and finite(ladder.favor) then favor = ladder.favor end
  local nextFavorAt = nil
  if unit > 0 and capitalFavor < config.investors.favorCap then
    nextFavorAt = (math.floor(E / (elig.favorStepFloorMultiple * unit)) + 1) * elig.favorStepFloorMultiple * unit
  end
  invest.perks = {favor = favor, shareFavor = shareFavor, capitalFavor = capitalFavor, nextFavorAt = nextFavorAt,
    favorCap = config.investors.favorCap,
    aidCap = type(ladder) == "table" and ladder.aidCap or nil,
    preferredStep = type(ladder) == "table" and ladder.preferredStep or 0,
    liquidityExempt = type(ladder) == "table" and ladder.liquidityExempt == true,
    isInvestor = unit > 0 and E >= elig.entryFloorMultiple * unit}
  -- President.
  local presidentID = state.president and state.president.playerID or -1
  local confirmNeeded = WBL_MATH.ScaleTurns(elig.presidentConfirmTurns, num(state.speedScale))
  invest.president = {
    presidentID = presidentID, sinceTurn = state.president and state.president.sinceTurn or 0,
    isPresident = presidentID == player.playerID,
    eligible = type(ladder) == "table" and ladder.presidentEligible == true,
    confirmCount = num(player.presidentConfirmCount), confirmNeeded = confirmNeeded,
    shareNeeded = config.investors.presidentShareThreshold,
    eraTurns = num(player.presidentTurnsThisEra),
    eraTurnsNeeded = WBL_MATH.ScaleTurns(config.investors.presidentEraTurns, num(state.speedScale)),
    perks = {favor = config.investors.presidentFavor, merchantPoints = config.investors.presidentMerchantPoints,
      envoyTurns = config.investors.presidentEnvoyTurns, eraScore = config.investors.presidentEraScore},
  }
  -- Failed attempted rewards that were recorded instead of paid (decision 33D).
  local unpaid = type(player.unpaid) == "table" and player.unpaid or {}
  local names = {"favor", "eraScore", "merchantPoints", "envoys"}
  for i = 1, #names do
    if num(unpaid[names[i]]) > 0 then
      invest.unpaid[#invest.unpaid + 1] = {key = names[i], textKey = M.Key("UNPAID", names[i]), amount = unpaid[names[i]]}
    end
  end
  -- New-deposit rules.
  local dep = type(offer) == "table" and offer.depositOffer or nil
  local depositBlock = ""
  if view.suspended then depositBlock = "BANK_SUSPENDED"
  elseif player.inDefault then depositBlock = "IN_DEFAULT"
  elseif playerHasArrears(state, player.playerID) then depositBlock = "ARREARS"
  elseif dep and dep.available ~= true then depositBlock = dep.reason or "NOT_ELIGIBLE"
  elseif not dep then depositBlock = "NO_OFFER" end
  invest.deposit = {available = depositBlock == "", reason = depositBlock, reasonKey = reasonKey(depositBlock), terms = {}}
  for i = 1, #(dep and dep.terms or {}) do
    invest.deposit.terms[#invest.deposit.terms + 1] = {termStandardTurns = dep.terms[i].termStandardTurns,
      returnFraction = dep.terms[i].returnFraction}
  end
  if invest.deposit.available and #invest.deposit.terms == 0 then
    invest.deposit.available, invest.deposit.reason = false, "NO_OFFER"
    invest.deposit.reasonKey = reasonKey("NO_OFFER")
  end
  invest.deposit.refusedInArrears = true
  invest.deposit.earlyFraction = config.investors.earlyWithdrawalFraction
  -- Freeze controls.
  local freezes = {rows = {}, targets = {}}
  local solo = invest.president.isPresident
  local coalition = unit > 0 and E >= elig.coalitionMemberFloorMultiple * unit
  freezes.canPlace = (solo or coalition) and not view.suspended
  freezes.reason = ""
  if view.suspended then freezes.reason = "BANK_SUSPENDED"
  elseif not (solo or coalition) then freezes.reason = "NOT_INVESTOR" end
  freezes.reasonKey = reasonKey(freezes.reason)
  for i = 1, #(state.freezes or {}) do
    local f = state.freezes[i]
        freezes.rows[#freezes.rows + 1] = {freezeID = f.freezeID, targetID = f.targetID, mode = f.mode,
      modeKey = M.Key("FREEZE", f.mode), requesterID = f.requesterID, members = f.members,
      placedTurn = f.placedTurn, canLift = f.requesterID == player.playerID and not view.suspended,
      isTarget = f.targetID == player.playerID}
  end
  for i = 1, #(state.players or {}) do
    local other = state.players[i]
    if other.playerID ~= player.playerID then
      local t = {playerID = other.playerID, modes = {}, frozen = findBy(state.freezes, "targetID", other.playerID) ~= nil}
      if freezes.canPlace and not t.frozen then
        if solo then t.modes[#t.modes + 1] = "PRESIDENT" end
        if coalition then t.modes[#t.modes + 1] = "COALITION" end
      end
      freezes.targets[#freezes.targets + 1] = t
    end
  end
  invest.freezes = freezes
  return invest
end

local function buildBank(state, player, offer, config, view, invest)
  local bank = state.bank or {}
  local out = {
    pool = offer and offer.pool or num(bank.cash), cap = offer and offer.cap or num(bank.cap),
    liquidityTier = offer and offer.liquidityTier or "", receivables = num(bank.receivables),
    depositLiabilities = num(bank.depositLiabilities), disbursed = num(bank.totals and bank.totals.disbursements),
    repaid = num(bank.totals and bank.totals.repayments), lentThisTurn = num(bank.lentThisTurn),
    freezes = invest.freezes.rows, civs = {}, canSeeAll = invest.president.isPresident,
  }
  out.liquidityKey = M.Key("LIQUIDITY", out.liquidityTier)
  out.fillFraction = out.cap > 0 and out.pool / out.cap or 0
  local lt = out.liquidityTier
  local prefix = ({NORMAL = "normal", TIGHT = "tight", STRAINED = "strained"})[lt]
  if prefix then
    out.valueAdjustment = config.liquidity[prefix .. "ValueAdjustment"]
    out.limitMultiplier = config.liquidity[prefix .. "LimitMultiplier"]
  end
  out.emergency = lt == "EMERGENCY"
  -- Privacy: other civs' tier/rating/debt/stage exist in the view only for the President.
  for i = 1, #(state.players or {}) do
    local p = state.players[i]
    if p.playerID == player.playerID or out.canSeeAll then
      local debt = 0
      for j = 1, #(state.loans or {}) do
        local loan = state.loans[j]
        if loan.playerID == p.playerID and loan.status == "ACTIVE" then debt = debt + loanBuckets(loan).debt end
      end
      out.civs[#out.civs + 1] = {playerID = p.playerID, isSelf = p.playerID == player.playerID,
        tier = p.tier, tierKey = M.Key("TIER", p.tier),
        rating = p.rating, ratingKey = M.Key("RATING", p.rating),
        debt = debt, inDefault = p.inDefault == true, defaultStage = penaltyStage(p, config, state)}
    end
  end
  table.sort(out.civs, function(a, b) return a.playerID < b.playerID end)
  return out
end

-- Public: DisasterKey("LOC_X") -> "LOC_X"; anything else is shown raw by the panel (empty -> "").
function M.DisasterKey(eventKey)
  if type(eventKey) ~= "string" then return "" end
  return eventKey
end

-- state: decoded published state. offers: optional array (defaults to state.offers).
-- facts: optional engine-side facts gathered by the panel: milestoneOptions = array of {kind, target, cityID, name}.
function M.BuildView(state, localPlayerID, config, offers, facts)
  config = config or WBL_CONFIG
  if type(state) ~= "table" then
    return {ok = false, reason = "NO_STATE", reasonKey = reasonKey("NO_STATE")}
  end
  local player = findBy(state.players, "playerID", localPlayerID)
  if not player then
    return {ok = false, reason = "NOT_A_PLAYER", reasonKey = reasonKey("NOT_A_PLAYER")}
  end
  local offer = findBy(offers or state.offers, "playerID", localPlayerID)
  local view = {
    ok = true, playerID = localPlayerID, nonce = player.nonce,
    turn = (offer and finite(offer.turn)) and offer.turn or num(state.lastProcessedTurn),
    suspended = state.suspended == true, suspendReason = state.suspendReason or "",
    lastResult = player.lastResult,
  }
  view.suspendedKey = view.suspended and "LOC_WBL_UI_SUSPENDED" or ""
  view.borrow = buildBorrow(state, player, offer, config, view)
  view.loans = buildLoans(state, player, offer, config, view)
  view.invest = buildInvest(state, player, offer, config, view)
  view.bank = buildBank(state, player, offer, config, view, view.invest)
  view.rating, view.tier = player.rating, player.tier
  -- Milestone picker options: NONE first, DISTRICT only when the S6 gate is verified.
  local options = {{kind = "NONE", target = "", cityID = 0}}
  local supplied = facts and facts.milestoneOptions or {}
  for i = 1, #supplied do
    local option = supplied[i]
    if option.kind == "POPULATION" or option.kind == "TECH"
      or (option.kind == "DISTRICT" and config.features.districtMilestoneVerified) then
      options[#options + 1] = {kind = option.kind, target = option.target, cityID = option.cityID or 0, name = option.name}
    end
  end
  view.milestoneOptions = options
  -- Result of the last accepted/rejected request, so the panel can show why something failed.
  if type(player.lastResult) == "table" and player.lastResult.kind and player.lastResult.kind ~= "" then
    view.lastResult = {kind = player.lastResult.kind, ok = player.lastResult.ok == true,
      reason = player.lastResult.reason or "", reasonKey = reasonKey(player.lastResult.reason),
      nonce = player.lastResult.nonce}
  end
  return view
end

-- Amount for shortcut step index `step` (1..#AMOUNT_STEPS) of `maxAmount`; whole gold except the exact maximum.
function M.AmountForStep(maxAmount, step)
  local fraction = M.AMOUNT_STEPS[step] or 1
  if fraction >= 1 then return maxAmount end
  return math.max(1, math.floor(maxAmount * fraction))
end

-- Live loan preview. entry is a borrow.products[i] or borrow.recoveryOffers[i]; returns table or nil, message.
function M.Preview(entry, amount, termStandardTurns, config)
  config = config or WBL_CONFIG
  if type(entry) ~= "table" or not finite(entry.quotedV) then return nil, "QUOTE_UNAVAILABLE" end
  if not finite(amount) or amount <= 0 then return nil, "AMOUNT_INVALID" end
  local term = findBy(entry.terms, "termStandardTurns", termStandardTurns)
  if not term then return nil, "TERM_INVALID" end
  local ok, quote = pcall(WBL_MATH.LoanQuote, amount, entry.quotedV, entry.growth, term.paymentTurns, term.graceTurns, config)
  if not ok then return nil, tostring(quote) end
  return {amount = amount, quotedV = entry.quotedV, nominalRate = quote.nominalRate, payment = quote.payment,
    totalRepayment = quote.totalRepayment, totalCost = quote.totalRepayment - amount,
    paymentTurns = term.paymentTurns, graceTurns = term.graceTurns, termStandardTurns = termStandardTurns}
end

function M.DepositAmount(invest, step)
  local multiple = M.DEPOSIT_UNIT_STEPS[step] or 1
  return math.max(1, math.floor(invest.unit * multiple))
end

-- Share of a new deposit that would count as eligible capital (decision 29), with the return it earns.
-- Pure: E' = max(0, deposits + amount - exposure); the eligible part is E' - E. Refused deposits give nil.
function M.DepositPreview(invest, amount, termStandardTurns)
  if not invest.deposit.available then return nil, invest.deposit.reason end
  if not finite(amount) or amount <= 0 then return nil, "AMOUNT_INVALID" end
  local term = findBy(invest.deposit.terms, "termStandardTurns", termStandardTurns)
  if not term then return nil, "TERM_INVALID" end
  local after = math.max(0, invest.activePrincipal + amount - invest.exposure)
  local eligiblePart = math.max(0, after - invest.eligibleCapital)
  if eligiblePart > amount then eligiblePart = amount end
  return {amount = amount, eligiblePart = eligiblePart, ineligiblePart = amount - eligiblePart,
    eligibleCapitalAfter = after, expectedReturn = eligiblePart * term.returnFraction,
    returnFraction = term.returnFraction, termStandardTurns = termStandardTurns,
    payoutAtMaturity = amount + eligiblePart * term.returnFraction,
    earlyPayout = amount * invest.deposit.earlyFraction}
end

-- Build the flat request params for GameEvents.WBL_BankRequest. args holds the kind's fields; args.milestone is
-- {kind, target, cityID} or nil (= NONE). Returns params or nil, message. Flat scalars only (PLAN "Requests").
function M.BuildRequest(view, kind, args)
  if type(view) ~= "table" or view.ok ~= true then return nil, "NO_STATE" end
  local fields = KIND_FIELDS[kind]
  if not fields then return nil, "UNKNOWN_KIND" end
  args = args or {}
  local params = {OnStart = M.REQUEST_EVENT, kind = kind, nonce = view.nonce}
  if not finite(view.nonce) then return nil, "MALFORMED" end
  for i = 1, #fields do
    local value = args[fields[i]]
    local t = type(value)
    if not (t == "string" or finite(value)) or (t == "string" and value == "") then return nil, "MALFORMED:" .. fields[i] end
    params[fields[i]] = value
  end
  if MILESTONE_KINDS[kind] then
    local m = args.milestone or {}
    params.milestoneKind = m.kind or "NONE"
    params.milestoneTarget = m.target == nil and "" or m.target
    params.milestoneCityID = m.cityID or 0
    if type(params.milestoneTarget) == "table" then return nil, "MALFORMED:milestoneTarget" end
  end
  return params
end

return WBL_BANKVIEW
