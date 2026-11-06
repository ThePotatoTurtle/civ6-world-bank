-- WBL_REDUCER: pure deterministic bank reducer (PLAN.md "Production module map and contracts",
-- "Required turn phase contract"). Load WBL_Config, WBL_Math and WBL_State first; WBL_AIPolicy is
-- optional. No engine calls, no pairs, no randomness; never mutates its inputs. Numeric-keyed
-- lookup tables are only indexed, never traversed; every traversal is over ordered arrays.
--
-- API
--   Turn(state, snapshot, config) -> nextState, effects, result
--     result = {ok, reason, noop, turn, eventID, phaseLog[] {phase, ...numbers}, detail}
--     reason OK | DUPLICATE_TURN | SNAPSHOT_INCOMPLETE | BANK_SUSPENDED | REDUCER_ERROR. A no-op
--     returns an unchanged copy, no effects and leaves lastProcessedTurn alone.
--   Request(state, snapshot, playerID, params, config) -> nextState, effects, result
--     result = {ok, reason, kind, detail}. BAD_NONCE, ACTOR_INVALID, BANK_SUSPENDED (and a
--     malformed params table) change nothing. Any other outcome increments the nonce and stores
--     players[i].lastResult; a rejection changes nothing else.
--   PHASES, NOTIFICATIONS, REQUEST_KINDS, MOVEMENTS: ordered contract tables.
--   Invariants(state, config) -> ok, reason   ledger/receivable/liability/lot checks (tests, dev).
--
-- Effects follow WBL_Effects: GOLD/FAVOR carry expectedBefore, the running balance the reducer
-- tracks from the snapshot through the batch; debits never exceed it. effectID is
-- "<turn>:<eventID>:<seq>". Bank-internal cash moves are ledger movements, not effects.
WBL_REDUCER = {}
local R = WBL_REDUCER

R.PHASES = {"growth", "reserve", "tiers", "maturities", "arrears", "scheduled", "garnish", "default",
  "milestones", "shares", "perks", "ai", "notifications"}
R.NOTIFICATIONS = {"LOAN_TAKEN", "PAYMENT_MISSED", "ARREARS_WARNING", "DEFAULT_STAGE1", "DEFAULT_STAGE2",
  "DEFAULT_CLEARED", "RESTRUCTURED", "DEBT_RELIEF", "MILESTONE_COMPLETE", "DEPOSIT_MATURED", "WITHDRAWAL",
  "PRESIDENT_GAINED", "PRESIDENT_LOST", "FREEZE_PLACED", "FREEZE_LIFTED", "RECOVERY_OFFER",
  "RECOVERY_CLAIMED", "RECOVERY_EXPIRED", "GRANT_PAID", "TIER_CHANGED"}
R.REQUEST_KINDS = {"TAKE_LOAN", "CLAIM_RECOVERY", "REPAY_EARLY", "RESTRUCTURE", "DEBT_RELIEF",
  "SELECT_MILESTONE", "REQUEST_GRANT", "DEPOSIT", "WITHDRAW", "FREEZE_PLACE", "FREEZE_LIFT"}
-- Ledger purposes: bank.totals field and cash direction (R2, R6).
R.MOVEMENTS = {
  OPENING = {total = "opening", sign = 1},
  REFILL = {total = "refill", sign = 1},
  DEPOSIT = {total = "depositReceipts", sign = 1},
  REPAY_SCHEDULED = {total = "repayments", sign = 1},
  REPAY_EARLY = {total = "repayments", sign = 1},
  ARREARS = {total = "arrearsPaid", sign = 1},
  ARREARS_PAYOUT = {total = "arrearsPaid", sign = 1},
  GARNISH = {total = "garnished", sign = 1},
  GUARANTEE = {total = "guarantees", sign = 1},
  DISBURSE = {total = "disbursements", sign = -1},
  PAYOUT_PRINCIPAL = {total = "depositPayouts", sign = -1},
  PAYOUT_RETURN = {total = "depositPayouts", sign = -1},
  GRANT = {total = "grantsPaid", sign = -1},
}

local ID_FIELDS = {"loanID", "lotID", "depositID", "grantID", "entitlementID", "freezeID"}
local RATINGS = {"A", "B", "C", "D"}
local LIQUIDITY = {"NORMAL", "TIGHT", "STRAINED", "EMERGENCY"}
-- Emergency-window loans (Developing/Underdeveloped only) use the strained terms (provisional).
local LIQUIDITY_PREFIX = {NORMAL = "normal", TIGHT = "tight", STRAINED = "strained", EMERGENCY = "strained"}
local MILESTONE_KINDS = {POPULATION = true, TECH = true, DISTRICT = true}
-- Split so the manifest localization audit does not read the prefix as an undefined key.
local NOTIFY_PREFIX = "LOC_WBL" .. "_NOTIFY_"

-- ------------------------------------------------------------------ small helpers

local function finite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function isInt(v)
  return finite(v) and v == math.floor(v)
end

local function findBy(list, field, value)
  for i = 1, #list do
    if list[i][field] == value then return list[i], i end
  end
  return nil
end

local function nextID(state, key)
  local id = state.nextIDs[key]
  state.nextIDs[key] = id + 1
  return id
end

local function ratingIndex(rating)
  for i = 1, #RATINGS do
    if RATINGS[i] == rating then return i end
  end
  return #RATINGS
end

local function upgradeRating(rating)
  local i = ratingIndex(rating)
  if rating == "D" or i <= 1 then return rating end
  return RATINGS[i - 1]
end

local function liquidityIndex(name)
  for i = 1, #LIQUIDITY do
    if LIQUIDITY[i] == name then return i end
  end
  return #LIQUIDITY
end

local function insertSortedString(list, value)
  for i = 1, #list do
    if list[i] == value then return false end
    if value < list[i] then
      table.insert(list, i, value)
      return true
    end
  end
  list[#list + 1] = value
  return true
end

local function contains(list, value)
  for i = 1, #list do
    if list[i] == value then return true end
  end
  return false
end

local function lotTotal(lot)
  return lot.principal + lot.interest + lot.fees
end

local function playerLots(state, playerID)
  local out = {}
  for i = 1, #state.lots do
    if state.lots[i].playerID == playerID then out[#out + 1] = state.lots[i] end
  end
  return out
end

local function sumLots(lots)
  local total = 0
  for i = 1, #lots do total = total + lotTotal(lots[i]) end
  return total
end

local function hasLots(state, playerID)
  return findBy(state.lots, "playerID", playerID) ~= nil
end

local function activeLoans(state, playerID)
  local out = {}
  for i = 1, #state.loans do
    local loan = state.loans[i]
    if loan.status == "ACTIVE" and (playerID == nil or loan.playerID == playerID) then out[#out + 1] = loan end
  end
  return out
end

local function loanOutstanding(loan)
  return loan.scheduledPrincipal + loan.futureInterest + loan.overduePrincipal + loan.overdueInterest + loan.arrearsFees
end

-- Overdue buckets are always the exact sums of the loan's lots.
local function syncLoan(state, loan)
  local p, i, f = 0, 0, 0
  for j = 1, #state.lots do
    local lot = state.lots[j]
    if lot.loanID == loan.loanID then
      p, i, f = p + lot.principal, i + lot.interest, f + lot.fees
    end
  end
  loan.overduePrincipal, loan.overdueInterest, loan.arrearsFees = p, i, f
end

local function syncLoans(state, playerID)
  local loans = activeLoans(state, playerID)
  for i = 1, #loans do syncLoan(state, loans[i]) end
end

local function purgeLots(state)
  local kept = {}
  for i = 1, #state.lots do
    if lotTotal(state.lots[i]) > 0 then kept[#kept + 1] = state.lots[i] end
  end
  state.lots = kept
end

local function isFrozen(state, playerID)
  return findBy(state.freezes, "targetID", playerID) ~= nil
end

local function milestoneKey(kind, target, cityID)
  -- Same text as WBL_SNAPSHOT.MilestoneKey.
  return tostring(kind) .. ":" .. tostring(target) .. ":" .. tostring(cityID or 0)
end

local function noneLoanMilestone()
  return {kind = "NONE", target = "", cityID = 0, halfwayTurn = 0, status = "NONE", fraction = 0}
end

-- ------------------------------------------------------------------ context, effects, ledger

local function newContext(state, snapshot, config)
  local ctx = {state = state, snapshot = snapshot, config = config, turn = snapshot.turn,
    scale = snapshot.speedScale, effects = {}, seq = 0, gold = {}, favor = {}, majors = {},
    living = {}, notes = {}, phaseLog = {}}
  for i = 1, #snapshot.majors do
    local m = snapshot.majors[i]
    ctx.majors[m.playerID] = m
    ctx.living[#ctx.living + 1] = m.playerID
    ctx.gold[m.playerID] = m.treasury
    ctx.favor[m.playerID] = m.favor
  end
  table.sort(ctx.living)
  ctx.eventID = nextID(state, "event")
  ctx.U = state.era.U
  local growth = state.growth
  if type(growth) == "table" and type(growth.lastResult) == "table" and finite(growth.lastResult.gameGrowth) then
    ctx.growth = growth.lastResult.gameGrowth
  else
    ctx.growth = WBL_MATH.SpeedGrowth(config.growth.standardDefault, ctx.scale)
  end
  return ctx
end

local function playerOf(ctx, playerID)
  return findBy(ctx.state.players, "playerID", playerID)
end

local function available(ctx, balances, playerID)
  local value = balances[playerID]
  if not finite(value) then return 0 end
  return math.max(0, value)
end

local function pushEffect(ctx, effect, ids)
  ctx.seq = ctx.seq + 1
  effect.effectID = string.format("%d:%d:%d", ctx.turn, ctx.eventID, ctx.seq)
  for i = 1, #ID_FIELDS do
    local field = ID_FIELDS[i]
    effect[field] = (ids and ids[field]) or 0
  end
  if effect.reason == nil then effect.reason = "" end
  if effect.required == nil then effect.required = false end
  ctx.effects[#ctx.effects + 1] = effect
  return effect
end

local function balanceEffect(ctx, kind, balances, playerID, amount, reason, ids, required)
  if amount == 0 then return nil end
  local before = balances[playerID] or 0
  balances[playerID] = before + amount
  return pushEffect(ctx, {kind = kind, playerID = playerID, amount = amount, expectedBefore = before,
    reason = reason, required = required}, ids)
end

local function goldEffect(ctx, playerID, amount, reason, ids)
  return balanceEffect(ctx, "GOLD", ctx.gold, playerID, amount, reason, ids, true)
end

local function favorEffect(ctx, playerID, amount, reason, ids, required)
  return balanceEffect(ctx, "FAVOR", ctx.favor, playerID, amount, reason, ids, required == true)
end

local function counterEffect(ctx, kind, playerID, amount, reason)
  if amount == 0 then return nil end
  return pushEffect(ctx, {kind = kind, playerID = playerID, amount = amount, reason = reason})
end

local function move(ctx, purpose, playerID, amount, ids)
  if amount == 0 then return end
  local spec = R.MOVEMENTS[purpose]
  local bank = ctx.state.bank
  ids = ids or {}
  bank.cash = bank.cash + spec.sign * amount
  bank.totals[spec.total] = bank.totals[spec.total] + amount
  bank.ledger[#bank.ledger + 1] = {movementID = nextID(ctx.state, "movement"), turn = ctx.turn,
    eventID = ctx.eventID, purpose = purpose, playerID = playerID, loanID = ids.loanID or 0,
    depositID = ids.depositID or 0, grantID = ids.grantID or 0, amount = spec.sign * amount}
end

-- Notifications are queued and emitted last (Turn) or at the end of the request.
local function notify(ctx, name, playerID, onceKey, p1, p2, p3, p4)
  ctx.notes[#ctx.notes + 1] = {name = name, playerID = playerID, onceKey = onceKey or "",
    p1 = p1 or "", p2 = p2 or "", p3 = p3 or "", p4 = p4 or ""}
end

local function flushNotes(ctx)
  local sent = 0
  for i = 1, #ctx.notes do
    local n = ctx.notes[i]
    local fresh = true
    if n.onceKey ~= "" then fresh = insertSortedString(ctx.state.sentOnce, n.onceKey) end
    if fresh then
      sent = sent + 1
      pushEffect(ctx, {kind = "NOTIFY", playerID = n.playerID, reason = n.name,
        messageKey = NOTIFY_PREFIX .. n.name .. "_MESSAGE", p1 = n.p1, p2 = n.p2, p3 = n.p3, p4 = n.p4,
        onceKey = n.onceKey})
    end
  end
  ctx.notes = {}
  return sent
end

local function logPhase(ctx, entry)
  ctx.phaseLog[#ctx.phaseLog + 1] = entry
end

local function addLent(ctx, playerID, amount)
  local bank = ctx.state.bank
  bank.lentThisTurn = bank.lentThisTurn + amount
  local row = findBy(bank.lentCurrent, "playerID", playerID)
  if row then row.amount = row.amount + amount
  else
    bank.lentCurrent[#bank.lentCurrent + 1] = {playerID = playerID, amount = amount}
    table.sort(bank.lentCurrent, function(a, b) return a.playerID < b.playerID end)
  end
end

local function addSubsidy(ctx, playerID, kind, amount)
  if amount <= 0 then return end
  local s = ctx.state
  s.subsidies[#s.subsidies + 1] = {subsidyID = nextID(s, "subsidy"), playerID = playerID, turn = ctx.turn,
    kind = kind, amount = amount}
end

-- Write AllocateArrearsPayment lot copies back, drop paid lots, resync loan buckets and book
-- one ledger movement per paid lot row. Returns the gold paid.
local function applyAllocation(ctx, playerID, allocation, purpose)
  local s = ctx.state
  local paid = 0
  for i = 1, #allocation.payments do
    local row = allocation.payments[i]
    local amount = row.fees + row.interest + row.principal
    paid = paid + amount
    move(ctx, purpose, playerID, amount, {loanID = row.loanID})
  end
  for i = 1, #allocation.lots do
    local copy = allocation.lots[i]
    local lot = findBy(s.lots, "lotID", copy.lotID)
    lot.principal, lot.interest, lot.fees = copy.principal, copy.interest, copy.fees
  end
  purgeLots(s)
  syncLoans(s, playerID)
  return paid
end

-- Spend up to `budget` of the player's gold on its arrears (oldest lot first). Passing the full
-- budget rather than the debt lets full settlement clear every lot exactly.
local function payArrears(ctx, playerID, budget, purpose, reason)
  local lots = playerLots(ctx.state, playerID)
  if #lots == 0 or budget <= 0 then return 0 end
  local allocation = WBL_MATH.AllocateArrearsPayment(lots, budget, ctx.config)
  local paid = applyAllocation(ctx, playerID, allocation, purpose)
  paid = math.min(paid, available(ctx, ctx.gold, playerID))
  goldEffect(ctx, playerID, -paid, reason)
  return paid
end

-- ------------------------------------------------------------------ measurements

local function measureE(ctx, playerID)
  local s = ctx.state
  local p = playerOf(ctx, playerID)
  local D = WBL_MATH.ActiveDepositPrincipal(s.deposits, playerID)
  local X = WBL_MATH.BankExposure(s.loans, s.subsidies, playerID, ctx.turn, ctx.scale, ctx.config)
  return (WBL_MATH.EligibleCapital(D, X, {inDefault = p.inDefault == true, hasArrears = hasLots(s, playerID),
    reliefPending = p.relief.status == "PENDING"}))
end

local function totalActiveDeposits(state)
  local total = 0
  for i = 1, #state.deposits do
    if state.deposits[i].status == "ACTIVE" then total = total + state.deposits[i].principal end
  end
  return total
end

-- R3: baseline liquidity excludes all active deposit principal; deposits improve the tier by at
-- most maximumDepositTierImprovement. Returns nil while the reserve is unconfigured.
local function liquidityInfo(ctx)
  local c, bank = ctx.config, ctx.state.bank
  if not (finite(bank.cap) and bank.cap > 0) then return nil end
  local actual = liquidityIndex((WBL_MATH.LiquidityTier(bank.cash, bank.cap, c)))
  local base = liquidityIndex((WBL_MATH.LiquidityTier(math.max(0, bank.cash - totalActiveDeposits(ctx.state)), bank.cap, c)))
  local eff = math.max(actual, base - c.liquidity.maximumDepositTierImprovement)
  local function adj(index) return c.liquidity[LIQUIDITY_PREFIX[LIQUIDITY[index]] .. "ValueAdjustment"] end
  return {name = LIQUIDITY[eff], index = eff, baseIndex = base, actualIndex = actual,
    adjBase = adj(base), adjEff = adj(eff), pool = bank.cash, cap = bank.cap,
    limitMultiplier = c.liquidity[LIQUIDITY_PREFIX[LIQUIDITY[eff]] .. "LimitMultiplier"]}
end

local function largestInvestor(ctx)
  local best
  for i = 1, #ctx.living do
    local p = playerOf(ctx, ctx.living[i])
    if p and p.eligibleCapital > 0 and (best == nil or p.eligibleCapital > best.eligibleCapital) then best = p end
  end
  return best
end

-- R3/R4: a non-exempt borrower's liquidity V adjustment. The deposit-driven improvement over
-- the baseline is capped at half the actual post-floor benefit the largest eligible investor
-- would get with the same tier, rating, product and scar.
local function liquidityAdjustment(ctx, liq, tier, rating, product, scarActive)
  local raw = liq.adjBase - liq.adjEff
  if raw <= 0 then return liq.adjEff end
  local benefit = 0
  local investor = largestInvestor(ctx)
  if investor and ctx.U > 0 then
    local pt = WBL_MATH.PreferredTerms(investor.eligibleCapital, ctx.U, ctx.config)
    local without = WBL_MATH.QuoteV({tier = tier, rating = rating, product = product,
      liquidityAdjustment = liq.adjBase, scarActive = scarActive}, ctx.config)
    local with = WBL_MATH.QuoteV({tier = tier, rating = rating, product = product,
      liquidityAdjustment = liq.adjEff, scarActive = scarActive, preferredStep = pt.preferredStep,
      liquidityExempt = pt.liquidityExempt}, ctx.config)
    benefit = math.max(0, without.quotedV - with.quotedV)
  end
  return liq.adjBase - WBL_MATH.BoundRivalVBenefit(raw, raw, benefit, ctx.config)
end

local function outstandingPrincipal(state, playerID)
  local total = 0
  local loans = activeLoans(state, playerID)
  for i = 1, #loans do total = total + loans[i].scheduledPrincipal + loans[i].overduePrincipal end
  return total
end

-- Borrowing context shared by offers and requests. E for pricing is the smaller of the boundary
-- measurement and a fresh one (same-turn loans count; same-turn deposits do not help).
local function borrowContext(ctx, playerID)
  local c, s = ctx.config, ctx.state
  local p = playerOf(ctx, playerID)
  local major = ctx.majors[playerID]
  local bc = {playerID = playerID, player = p, major = major, tier = p.tier, rating = p.rating,
    scarActive = p.scarUntilTurn > ctx.turn, liq = liquidityInfo(ctx), block = ""}
  bc.E = math.min(p.eligibleCapital, measureE(ctx, playerID))
  bc.outstanding = outstandingPrincipal(s, playerID)
  bc.normalLimit, bc.extension = 0, 0
  if bc.liq and ctx.U > 0 and c.tiers[bc.tier] then
    bc.normalLimit = WBL_MATH.BaseCreditLimit(bc.rating, major.netGPT, ctx.U, c) * bc.liq.limitMultiplier
    bc.extension = WBL_MATH.InvestorCreditExtension(bc.normalLimit, bc.E, ctx.U, c)
  end
  if s.suspended or not bc.liq or not (ctx.U > 0) or not c.tiers[bc.tier] then bc.block = "BANK_SUSPENDED"
  elseif isFrozen(s, playerID) then bc.block = "FROZEN"
  elseif p.inDefault then bc.block = "IN_DEFAULT"
  elseif p.rating == "D" then bc.block = "RATING_D"
  elseif hasLots(s, playerID) then bc.block = "ARREARS"
  elseif bc.liq.name == "EMERGENCY" and bc.tier == "DEVELOPED" then bc.block = "LIQUIDITY_EMERGENCY" end
  return bc
end

-- Remaining credit for a product (before the pool) and the drawable maximum.
local function productLimits(ctx, bc, product)
  local multiple = 1
  if product == "INFRASTRUCTURE" then multiple = ctx.config.grants.infrastructureLimitMultiplier end
  local credit = WBL_MATH.AvailableCredit(bc.normalLimit * multiple + bc.extension, bc.outstanding)
  local pool = 0
  if bc.liq then pool = math.max(0, bc.liq.pool) end
  if product == "RECOVERY" then return WBL_MATH.RecoveryPrincipalCap(credit, pool), credit end
  return math.min(credit, pool), credit
end

local function quoteV(ctx, bc, product, amount)
  local ePost = WBL_MATH.PostLoanCapital(bc.E, math.max(0, amount))
  local pt = WBL_MATH.PreferredTerms(ePost, ctx.U, ctx.config)
  local adjustment = 0
  if not pt.liquidityExempt then
    adjustment = liquidityAdjustment(ctx, bc.liq, bc.tier, bc.rating, product, bc.scarActive)
  end
  local v = WBL_MATH.QuoteV({tier = bc.tier, rating = bc.rating, product = product,
    liquidityAdjustment = adjustment, scarActive = bc.scarActive, preferredStep = pt.preferredStep,
    liquidityExempt = pt.liquidityExempt}, ctx.config)
  return v, pt
end

local function termRows(ctx, tier, valueRatio, standardTerms, standardGrace)
  local rows = {}
  for i = 1, #standardTerms do
    local n = WBL_MATH.ScaleTurns(standardTerms[i], ctx.scale)
    local grace = WBL_MATH.ScaleTurns(standardGrace, ctx.scale)
    local q = WBL_MATH.LoanQuote(1, valueRatio, ctx.growth, n, grace, ctx.config)
    rows[#rows + 1] = {termStandardTurns = standardTerms[i], paymentTurns = n, graceTurns = grace,
      nominalRate = q.nominalRate}
  end
  return rows
end

local function vView(v)
  return {base = v.base, rating = v.rating, liquidity = v.liquidity, scar = v.scar, investor = v.investor,
    raw = v.raw, floorApplied = v.floorApplied, quotedV = v.quotedV, product = v.product}
end

local function restructurePriceRating(ctx, rating)
  if rating == "D" then return ctx.config.reducer.restructureMinimumPriceRating end
  return rating
end

-- Spec 3.5: the credit scar applies to a restructure; a player still in default (or rated D with
-- arrears outstanding) is priced as scarred, never cheaper than after curing.
local function restructureScarActive(ctx, p)
  return p.scarUntilTurn > ctx.turn or p.inDefault == true
    or (p.rating == "D" and hasLots(ctx.state, p.playerID))
end

local function restructureQuote(ctx, p, loan)
  return WBL_MATH.RestructureQuote({product = loan.product, tier = p.tier,
    rating = restructurePriceRating(ctx, p.rating), scarActive = restructureScarActive(ctx, p), inDefault = p.inDefault,
    growth = ctx.growth, scale = ctx.scale, scheduledPrincipal = loan.scheduledPrincipal,
    overduePrincipal = loan.overduePrincipal, futureInterest = loan.futureInterest,
    overdueInterest = loan.overdueInterest, arrearsFees = loan.arrearsFees}, ctx.config)
end

local function restructureBlock(ctx, p, loan)
  if ctx.state.suspended then return "BANK_SUSPENDED" end
  if loan.restructured then return "ALREADY_USED" end
  if not ctx.config.features.attemptFavorWrite and ctx.config.relief.restructureFavorCost > 0 then
    return "CAPABILITY_PENDING"
  end
  if not ctx.config.tiers[p.tier] then return "BANK_SUSPENDED" end
  if loan.scheduledPrincipal + loan.overduePrincipal + loan.overdueInterest + loan.arrearsFees <= 0 then
    return "AMOUNT_INVALID"
  end
  return ""
end

-- ------------------------------------------------------------------ offers view

local function grantBlock(ctx, p)
  local s = ctx.state
  if s.suspended or not (ctx.U > 0) then return "BANK_SUSPENDED" end
  if p.tier ~= "UNDERDEVELOPED" then return "TIER_INELIGIBLE" end
  if isFrozen(s, p.playerID) then return "FROZEN" end
  if p.lastGrantEra == ctx.snapshot.eraType then return "PER_ERA_LIMIT" end
  for i = 1, #s.grants do
    local g = s.grants[i]
    if g.playerID == p.playerID and (g.status == "PENDING_MILESTONE" or g.status == "AWAITING_CASH") then
      return "ALREADY_USED"
    end
  end
  return ""
end

local function depositBlock(ctx, p)
  if ctx.state.suspended or not (ctx.state.bank.cap > 0) then return "BANK_SUSPENDED" end
  if p.inDefault then return "IN_DEFAULT" end
  if hasLots(ctx.state, p.playerID) then return "ARREARS" end
  return ""
end

local function buildOffer(ctx, playerID)
  local c, s = ctx.config, ctx.state
  local p = playerOf(ctx, playerID)
  local bc = borrowContext(ctx, playerID)
  local liq = bc.liq
  local offer = {playerID = playerID, turn = ctx.turn, nonce = p.nonce, tier = p.tier, rating = p.rating,
    growth = ctx.growth, U = ctx.U, liquidityTier = liq and liq.name or "", pool = s.bank.cash, cap = s.bank.cap,
    normalLimit = bc.normalLimit, extension = bc.extension, limit = bc.normalLimit + bc.extension,
    outstandingPrincipal = bc.outstanding, availableDraw = 0, blockedReason = bc.block,
    products = {}, eligibleCapital = p.eligibleCapital, eligibleShare = p.eligibleShare,
    recoveryOffers = {}, loanOffers = {}, atWarWith = {}}
  local wars = (ctx.majors[playerID] and ctx.majors[playerID].wars) or {}
  for i = 1, #wars do offer.atWarWith[i] = wars[i] end
  table.sort(offer.atWarWith)
  local canQuote = bc.rating ~= "D" and liq ~= nil and ctx.U > 0 and c.tiers[bc.tier] ~= nil
  local products = {"ORDINARY", "INFRASTRUCTURE"}
  for i = 1, #products do
    local product = products[i]
    local maxAmount, credit = 0, 0
    if liq then maxAmount, credit = productLimits(ctx, bc, product) end
    local reason = bc.block
    if reason == "" and product == "INFRASTRUCTURE" and bc.tier ~= "DEVELOPING" then reason = "TIER_INELIGIBLE" end
    if reason == "" and maxAmount <= 0 then
      if credit <= 0 then reason = "EXCEEDS_LIMIT" else reason = "POOL_INSUFFICIENT" end
    end
    local entry = {product = product, available = reason == "", reason = reason, maxAmount = maxAmount, terms = {}}
    if canQuote then
      -- Worst-case price over the drawable range (V rises as E_post falls), so a quote taken
      -- from the panel never fails the price guard for a smaller amount.
      local v = quoteV(ctx, bc, product, maxAmount)
      entry.quotedV = v.quotedV
      entry.vComponents = vView(v)
      entry.terms = termRows(ctx, bc.tier, v.quotedV, c.tiers[bc.tier].terms, c.tiers[bc.tier].graceTurns)
    end
    if product == "ORDINARY" then
      offer.availableDraw = maxAmount
      if entry.vComponents then offer.vComponents = entry.vComponents end
    end
    offer.products[#offer.products + 1] = entry
  end
  -- Ladder at E (no new loan).
  if ctx.U > 0 then
    local ladder = WBL_MATH.InvestorLadder(p.eligibleCapital, math.min(1, p.eligibleShare), ctx.U, c)
    local pt = WBL_MATH.PreferredTerms(p.eligibleCapital, ctx.U, c)
    offer.ladder = {favor = ladder.favor, aidCap = ladder.aidCap, preferredStep = pt.preferredStep,
      liquidityExempt = pt.liquidityExempt,
      presidentEligible = ladder.presidentCapital and p.eligibleShare + c.precision.shareStepTolerance
        >= c.investors.presidentShareThreshold,
      presidentConfirmCount = p.presidentConfirmCount}
  else
    offer.ladder = {favor = 0, aidCap = 0, preferredStep = 0, liquidityExempt = false,
      presidentEligible = false, presidentConfirmCount = p.presidentConfirmCount}
  end
  -- Recovery offers (decisions 15-16): OPEN entitlements of this victim inside the window.
  for i = 1, #s.recovery do
    local en = s.recovery[i]
    if en.victimID == playerID and en.status == "OPEN" and ctx.turn >= en.qualifyingTurn and ctx.turn < en.expiryTurn then
      local maxAmount, credit = 0, 0
      if liq then maxAmount, credit = productLimits(ctx, bc, "RECOVERY") end
      local reason = bc.block
      if reason == "" and not c.features.recoveryPredicateVerified then reason = "CAPABILITY_PENDING" end
      if reason == "" and maxAmount <= 0 then
        if credit <= 0 then reason = "EXCEEDS_LIMIT" else reason = "POOL_INSUFFICIENT" end
      end
      local row = {entitlementID = en.entitlementID, eventKey = en.eventKey, expiryTurn = en.expiryTurn,
        maxAmount = maxAmount, blockedReason = reason, terms = {}}
      if canQuote then
        local v = quoteV(ctx, bc, "RECOVERY", maxAmount)
        row.quotedV = v.quotedV
        row.vComponents = vView(v)
        row.terms = termRows(ctx, bc.tier, v.quotedV, c.tiers[bc.tier].terms, c.tiers[bc.tier].graceTurns)
      end
      offer.recoveryOffers[#offer.recoveryOffers + 1] = row
    end
  end
  -- Grant.
  local gReason = grantBlock(ctx, p)
  local amount = 0
  if ctx.U > 0 and ctx.majors[playerID] then amount = WBL_MATH.GrantAmount(ctx.majors[playerID].netGPT, ctx.U, c) end
  offer.grantOffer = {available = gReason == "", amount = amount, reason = gReason}
  -- Deposits.
  local dReason = depositBlock(ctx, p)
  local terms = {}
  for i = 1, #c.investors.depositTerms do
    terms[i] = {termStandardTurns = c.investors.depositTerms[i], returnFraction = c.investors.depositReturns[i],
      termTurns = WBL_MATH.ScaleTurns(c.investors.depositTerms[i], ctx.scale)}
  end
  offer.depositOffer = {available = dReason == "", reason = dReason, terms = terms}
  -- Per active loan: restructure price (decisions 31, 33C) and early settlement.
  local loans = activeLoans(s, playerID)
  for i = 1, #loans do
    local loan = loans[i]
    local row = {loanID = loan.loanID, restructureReason = restructureBlock(ctx, p, loan),
      restructureFavorCost = WBL_MATH.RestructureFavorCost(ctx.U, ctx.scale, c)}
    if row.restructureReason == "" then
      local q = restructureQuote(ctx, p, loan)
      row.restructureQuotedV = q.valueRatio
      row.restructurePrincipal = q.principal
      row.restructureNominalRate = q.nominalRate
      row.restructurePaymentTurns = q.paymentTurns
    end
    row.settlementDue = WBL_MATH.EarlySettlementQuote(loan).totalDue
    offer.loanOffers[#offer.loanOffers + 1] = row
  end
  return offer
end

local function publishOffers(ctx)
  local offers = {}
  for i = 1, #ctx.living do
    if playerOf(ctx, ctx.living[i]) then offers[#offers + 1] = buildOffer(ctx, ctx.living[i]) end
  end
  ctx.state.offers = offers
end

local function refreshAggregates(state)
  local receivables = 0
  local loans = activeLoans(state, nil)
  for i = 1, #loans do receivables = receivables + loanOutstanding(loans[i]) end
  state.bank.receivables = receivables
  state.bank.depositLiabilities = totalActiveDeposits(state)
end

-- ------------------------------------------------------------------ request validation helpers

local function paramNumber(params, key)
  local value = params[key]
  if finite(value) then return value end
  return nil
end

local function paramMilestone(params)
  local kind = params.milestoneKind
  if kind == nil or kind == "" then kind = "NONE" end
  if kind == "NONE" then return {kind = "NONE", target = "", cityID = 0} end
  local target = params.milestoneTarget
  if target == nil then target = "" end
  local cityID = params.milestoneCityID
  if cityID == nil then cityID = 0 end
  return {kind = kind, target = target, cityID = cityID}
end

local function milestoneFact(ctx, playerID, m)
  local major = ctx.majors[playerID]
  if not major or type(major.milestoneFacts) ~= "table" then return nil end
  return findBy(major.milestoneFacts, "key", milestoneKey(m.kind, m.target, m.cityID))
end

-- "" when acceptable. A target already complete is rejected (decision 17); a target the
-- snapshot did not read cannot be validated.
local function milestoneBlock(ctx, playerID, m, required)
  if m.kind == "NONE" then
    if required then return "MILESTONE_REQUIRED" end
    return ""
  end
  if type(m.kind) ~= "string" or not MILESTONE_KINDS[m.kind] or not isInt(m.cityID) then return "MILESTONE_INVALID" end
  if m.kind == "DISTRICT" and not ctx.config.features.districtMilestoneVerified then return "MILESTONE_INVALID" end
  if m.kind == "POPULATION" and not (finite(m.target) and m.target > 0) then return "MILESTONE_INVALID" end
  if m.kind ~= "POPULATION" and not (type(m.target) == "string" and m.target ~= "") then return "MILESTONE_INVALID" end
  local fact = milestoneFact(ctx, playerID, m)
  if not fact or fact.valid == false then return "MILESTONE_INVALID" end
  if fact.done then return "MILESTONE_COMPLETE" end
  return ""
end

local function loanMilestone(m, halfwayTurn)
  if m.kind == "NONE" then return noneLoanMilestone() end
  return {kind = m.kind, target = m.target, cityID = m.cityID, halfwayTurn = halfwayTurn, status = "PENDING", fraction = 0}
end

local function termIn(list, term)
  for i = 1, #list do
    if list[i] == term then return i end
  end
  return nil
end

-- Request numbers cross from the UI as 32-bit floats (Session P, 2026-11-04: 58.3333 arrived as 58.333332061768),
-- so a quote may differ from the exact value by that rounding as well as by the balance tolerance.
local function within(actual, quoted, ctx)
  local precision = ctx.config.precision
  local slack = math.max(precision.balanceTolerance, math.abs(quoted) * (precision.requestFloatEpsilon or 0))
  return actual <= quoted + slack
end

-- ------------------------------------------------------------------ loan creation

local function newLoan(ctx, p, spec)
  local s = ctx.state
  local loanID = nextID(s, "loan")
  local quote = spec.quote
  local loan = {loanID = loanID, playerID = p.playerID, product = spec.product,
    entitlementID = spec.entitlementID or 0, lineageID = spec.lineageID or loanID,
    parentLoanID = spec.parentLoanID or 0, originTurn = ctx.turn, originTier = p.tier,
    principal = quote.principal, valueRatio = quote.valueRatio, nominalRate = quote.nominalRate,
    growth = quote.growth, earlyRepayInterestFraction = ctx.config.credit.earlyRepayInterestFraction,
    paymentTurns = quote.paymentTurns, graceTurns = quote.graceTurns,
    preferredStep = spec.preferredStep or 0, liquidityExempt = spec.liquidityExempt == true,
    installments = quote.paymentTurns, installmentsPaid = 0,
    nextDueTurn = ctx.turn + quote.graceTurns + 1,
    scheduledPrincipal = quote.principal, futureInterest = math.max(0, quote.totalRepayment - quote.principal),
    overduePrincipal = 0, overdueInterest = 0, arrearsFees = 0,
    missedCount = spec.missedCount or 0, everMissed = spec.everMissed == true,
    restructured = spec.restructured == true, milestoneUsed = spec.milestoneUsed == true,
    promotionUsed = spec.promotionUsed == true,
    milestone = spec.milestone or noneLoanMilestone(), status = "ACTIVE"}
  s.loans[#s.loans + 1] = loan
  return loan
end

-- Shared gate for TAKE_LOAN and CLAIM_RECOVERY; returns reason, bc, v, pt, quote.
local function priceLoan(ctx, p, params, product, m)
  local c = ctx.config
  local amount = paramNumber(params, "amount")
  local term = paramNumber(params, "termStandardTurns")
  local quotedV = paramNumber(params, "quotedV")
  if not term or not quotedV then return "MALFORMED" end
  if not amount or amount <= 0 then return "AMOUNT_INVALID" end
  local bc = borrowContext(ctx, p.playerID)
  if bc.block ~= "" then return bc.block end
  if not termIn(c.tiers[bc.tier].terms, term) then return "TERM_INVALID" end
  if product == "INFRASTRUCTURE" and bc.tier ~= "DEVELOPING" then return "TIER_INELIGIBLE" end
  local mReason = milestoneBlock(ctx, p.playerID, m, product == "INFRASTRUCTURE")
  if mReason ~= "" then return mReason end
  local maxAmount, credit = productLimits(ctx, bc, product)
  if amount > credit + c.precision.balanceTolerance then return "EXCEEDS_LIMIT" end
  if amount > maxAmount and amount > bc.liq.pool then return "POOL_INSUFFICIENT" end
  if amount > maxAmount then return "EXCEEDS_LIMIT" end
  local v, pt = quoteV(ctx, bc, product, amount)
  if not within(v.quotedV, quotedV, ctx) then return "PRICE_CHANGED" end
  local n = WBL_MATH.ScaleTurns(term, ctx.scale)
  local grace = WBL_MATH.ScaleTurns(c.tiers[bc.tier].graceTurns, ctx.scale)
  local quote = WBL_MATH.LoanQuote(amount, v.quotedV, ctx.growth, n, grace, c)
  return "", bc, v, pt, quote
end

local function disburse(ctx, p, product, quote, pt, m, entitlementID)
  local halfway = WBL_MATH.MilestoneHalfwayTurn(ctx.turn, quote.graceTurns, quote.paymentTurns)
  local loan = newLoan(ctx, p, {product = product, quote = quote, preferredStep = pt.preferredStep,
    liquidityExempt = pt.liquidityExempt, milestone = loanMilestone(m, halfway), entitlementID = entitlementID})
  move(ctx, "DISBURSE", p.playerID, quote.principal, {loanID = loan.loanID})
  addLent(ctx, p.playerID, quote.principal)
  goldEffect(ctx, p.playerID, quote.principal, "LOAN_DISBURSED", {loanID = loan.loanID, entitlementID = entitlementID})
  notify(ctx, "LOAN_TAKEN", p.playerID, "", loan.loanID, quote.principal, product)
  return loan
end

-- ------------------------------------------------------------------ deposits

local function payDeposit(ctx, deposit, kind)
  local pid = deposit.playerID
  local lots = playerLots(ctx.state, pid)
  local r = WBL_MATH.DepositPayout({kind = kind, deposit = deposit, bankCash = ctx.state.bank.cash, lots = lots}, ctx.config)
  local ids = {depositID = deposit.depositID}
  move(ctx, "GUARANTEE", pid, r.guarantee, ids)
  move(ctx, "PAYOUT_PRINCIPAL", pid, r.principalPaid, ids)
  move(ctx, "PAYOUT_RETURN", pid, r.returnPaid, ids)
  if #r.allocation.payments > 0 then applyAllocation(ctx, pid, r.allocation, "ARREARS_PAYOUT") end
  goldEffect(ctx, pid, r.toTreasury, kind == "MATURITY" and "DEPOSIT_MATURED" or "DEPOSIT_WITHDRAWN", ids)
  if kind == "MATURITY" then deposit.status = "MATURED"
  else
    deposit.status = "WITHDRAWN"
    ctx.state.bank.totals.forfeited = ctx.state.bank.totals.forfeited + r.principalForfeited
  end
  return r
end

-- ------------------------------------------------------------------ request handlers

local H = {}

local function freezeCoalition(ctx, requesterID, targetID)
  local c = ctx.config
  local major = ctx.majors[requesterID]
  local candidates = {requesterID}
  for i = 1, #(major.allies or {}) do candidates[#candidates + 1] = major.allies[i] end
  table.sort(candidates)
  local members, share, capital = {}, 0, 0
  local floor = c.investors.eligibility.coalitionMemberFloorMultiple * ctx.U
  for i = 1, #candidates do
    local id = candidates[i]
    local m = ctx.majors[id]
    local p = playerOf(ctx, id)
    if m and p and contains(m.wars or {}, targetID) and p.eligibleCapital > 0 and p.eligibleCapital >= floor then
      members[#members + 1] = id
      share, capital = share + p.eligibleShare, capital + p.eligibleCapital
    end
  end
  local qualifies = contains(members, requesterID)
    and share + c.precision.shareStepTolerance >= c.investors.freezeShareThreshold
    and capital >= c.investors.eligibility.coalitionFloorMultiple * ctx.U
  return members, qualifies
end

function H.TAKE_LOAN(ctx, p, params)
  local product = params.product
  if product ~= "ORDINARY" and product ~= "INFRASTRUCTURE" then return "MALFORMED" end
  local m = paramMilestone(params)
  local reason, _, _, pt, quote = priceLoan(ctx, p, params, product, m)
  if reason ~= "" then return reason end
  local loan = disburse(ctx, p, product, quote, pt, m, 0)
  return "", {loanID = loan.loanID}
end

function H.CLAIM_RECOVERY(ctx, p, params)
  local id = paramNumber(params, "entitlementID")
  if not id then return "MALFORMED" end
  local en = findBy(ctx.state.recovery, "entitlementID", id)
  if not en then return "NOT_FOUND" end
  if en.victimID ~= p.playerID then return "NOT_OWNER" end
  if en.status == "CLAIMED" then return "ENTITLEMENT_CLAIMED" end
  if en.status ~= "OPEN" or ctx.turn >= en.expiryTurn or ctx.turn < en.qualifyingTurn then return "ENTITLEMENT_EXPIRED" end
  if not ctx.config.features.recoveryPredicateVerified then return "CAPABILITY_PENDING" end
  local m = paramMilestone(params)
  local reason, _, _, pt, quote = priceLoan(ctx, p, params, "RECOVERY", m)
  if reason ~= "" then return reason end
  local loan = disburse(ctx, p, "RECOVERY", quote, pt, m, en.entitlementID)
  en.status, en.claimedLoanID = "CLAIMED", loan.loanID
  notify(ctx, "RECOVERY_CLAIMED", p.playerID, "", en.entitlementID, loan.loanID)
  return "", {loanID = loan.loanID}
end

local function ownLoan(ctx, p, params)
  local id = paramNumber(params, "loanID")
  if not id then return nil, "MALFORMED" end
  local loan = findBy(ctx.state.loans, "loanID", id)
  if not loan then return nil, "NOT_FOUND" end
  if loan.playerID ~= p.playerID then return nil, "NOT_OWNER" end
  if loan.status ~= "ACTIVE" then return nil, "NOT_FOUND" end
  return loan, ""
end

local function removeLoanLots(state, loanID)
  local kept = {}
  for i = 1, #state.lots do
    if state.lots[i].loanID ~= loanID then kept[#kept + 1] = state.lots[i] end
  end
  state.lots = kept
end

function H.REPAY_EARLY(ctx, p, params)
  local loan, reason = ownLoan(ctx, p, params)
  if not loan then return reason end
  local quoted = paramNumber(params, "quotedAmount")
  if not quoted then return "MALFORMED" end
  if ctx.state.suspended then return "BANK_SUSPENDED" end
  local q = WBL_MATH.EarlySettlementQuote(loan)
  if not within(q.totalDue, quoted, ctx) then return "PRICE_CHANGED" end
  if q.totalDue > available(ctx, ctx.gold, p.playerID) then return "INSUFFICIENT_GOLD" end
  local overdue = loan.overduePrincipal + loan.overdueInterest + loan.arrearsFees
  local ids = {loanID = loan.loanID}
  move(ctx, "ARREARS", p.playerID, overdue, ids)
  move(ctx, "REPAY_EARLY", p.playerID, loan.scheduledPrincipal + q.futureInterestDue, ids)
  goldEffect(ctx, p.playerID, -q.totalDue, "REPAY_EARLY", ids)
  removeLoanLots(ctx.state, loan.loanID)
  loan.scheduledPrincipal, loan.futureInterest = 0, 0
  loan.overduePrincipal, loan.overdueInterest, loan.arrearsFees = 0, 0, 0
  loan.status = "REPAID_EARLY"
  if loan.milestone.status == "PENDING" then loan.milestone.status = "CANCELLED" end
  return "", {loanID = loan.loanID, amount = q.totalDue}
end

function H.RESTRUCTURE(ctx, p, params)
  local c = ctx.config
  local loan, reason = ownLoan(ctx, p, params)
  if not loan then return reason end
  local quotedV = paramNumber(params, "quotedV")
  if not quotedV then return "MALFORMED" end
  local block = restructureBlock(ctx, p, loan)
  if block ~= "" then return block end
  local q = restructureQuote(ctx, p, loan)
  if not within(q.valueRatio, quotedV, ctx) then return "PRICE_CHANGED" end
  local cost = math.min(WBL_MATH.RestructureFavorCost(ctx.U, ctx.scale, c), available(ctx, ctx.favor, p.playerID))
  favorEffect(ctx, p.playerID, -cost, "RESTRUCTURE_FAVOR", {loanID = loan.loanID}, true)
  removeLoanLots(ctx.state, loan.loanID)
  local child = newLoan(ctx, p, {product = loan.product, quote = q, entitlementID = loan.entitlementID,
    lineageID = loan.lineageID, parentLoanID = loan.loanID, missedCount = loan.missedCount,
    everMissed = loan.everMissed, restructured = true, milestoneUsed = loan.milestoneUsed,
    promotionUsed = loan.promotionUsed, milestone = loan.milestone})
  loan.milestone = noneLoanMilestone()
  loan.scheduledPrincipal, loan.futureInterest = 0, 0
  loan.overduePrincipal, loan.overdueInterest, loan.arrearsFees = 0, 0, 0
  loan.status = "RESTRUCTURED"
  if p.rating ~= "D" then p.rating = q.rating end
  notify(ctx, "RESTRUCTURED", p.playerID, "", child.loanID, loan.loanID, cost)
  return "", {loanID = child.loanID}
end

function H.DEBT_RELIEF(ctx, p, params)
  local c = ctx.config
  if ctx.state.suspended then return "BANK_SUSPENDED" end
  if p.tier ~= "UNDERDEVELOPED" then return "TIER_INELIGIBLE" end
  if p.relief.status == "PENDING" or p.debtReliefUsed then return "ALREADY_USED" end
  if not (p.inDefault or hasLots(ctx.state, p.playerID)) then return "NOT_ELIGIBLE" end
  local m = paramMilestone(params)
  local reason = milestoneBlock(ctx, p.playerID, m, true)
  if reason ~= "" then return reason end
  p.debtReliefUsed = true
  p.relief = {status = "PENDING", milestone = {kind = m.kind, target = m.target, cityID = m.cityID},
    deadlineTurn = ctx.turn + WBL_MATH.ScaleTurns(c.relief.debtReliefTurns, ctx.scale)}
  return ""
end

function H.SELECT_MILESTONE(ctx, p, params)
  local loan, reason = ownLoan(ctx, p, params)
  if not loan then return reason end
  if loan.milestone.status ~= "NONE" or loan.milestoneUsed then return "ALREADY_USED" end
  if loan.originTurn ~= ctx.turn then return "MILESTONE_WINDOW" end
  -- Milestone is chosen at origination and preserved through restructuring; a restructured
  -- lineage that never had one must not gain one (spec 2.5, decision 17).
  if loan.parentLoanID ~= 0 then return "MILESTONE_WINDOW" end
  local m = paramMilestone(params)
  local mReason = milestoneBlock(ctx, p.playerID, m, true)
  if mReason ~= "" then return mReason end
  loan.milestone = loanMilestone(m, WBL_MATH.MilestoneHalfwayTurn(loan.originTurn, loan.graceTurns, loan.paymentTurns))
  return "", {loanID = loan.loanID}
end

function H.REQUEST_GRANT(ctx, p, params)
  local quoted = paramNumber(params, "quotedAmount")
  if not quoted then return "MALFORMED" end
  local block = grantBlock(ctx, p)
  if block ~= "" then return block end
  local m = paramMilestone(params)
  local reason = milestoneBlock(ctx, p.playerID, m, true)
  if reason ~= "" then return reason end
  local amount = WBL_MATH.GrantAmount(ctx.majors[p.playerID].netGPT, ctx.U, ctx.config)
  -- Worse for the player means less gold than quoted.
  if not within(quoted, amount, ctx) then return "PRICE_CHANGED" end
  local s = ctx.state
  local grantID = nextID(s, "grant")
  s.grants[#s.grants + 1] = {grantID = grantID, playerID = p.playerID, eraType = ctx.snapshot.eraType,
    requestTurn = ctx.turn, amount = amount, milestone = {kind = m.kind, target = m.target, cityID = m.cityID},
    status = "PENDING_MILESTONE"}
  p.lastGrantEra = ctx.snapshot.eraType
  return "", {grantID = grantID, amount = amount}
end

function H.DEPOSIT(ctx, p, params)
  local c = ctx.config
  local amount = paramNumber(params, "amount")
  local term = paramNumber(params, "termStandardTurns")
  if not term then return "MALFORMED" end
  local block = depositBlock(ctx, p)
  if block ~= "" then return block end
  local index = termIn(c.investors.depositTerms, term)
  if not index then return "TERM_INVALID" end
  if not amount or amount <= 0 then return "AMOUNT_INVALID" end
  if amount > available(ctx, ctx.gold, p.playerID) then return "INSUFFICIENT_GOLD" end
  local s = ctx.state
  local depositID = nextID(s, "deposit")
  local turns = WBL_MATH.ScaleTurns(term, ctx.scale)
  s.deposits[#s.deposits + 1] = {depositID = depositID, playerID = p.playerID, principal = amount,
    returnFraction = c.investors.depositReturns[index], termTurns = turns, openTurn = ctx.turn,
    maturityTurn = ctx.turn + turns, accruedReturn = 0, status = "ACTIVE"}
  goldEffect(ctx, p.playerID, -amount, "DEPOSIT", {depositID = depositID})
  move(ctx, "DEPOSIT", p.playerID, amount, {depositID = depositID})
  return "", {depositID = depositID}
end

function H.WITHDRAW(ctx, p, params)
  local id = paramNumber(params, "depositID")
  local quoted = paramNumber(params, "quotedAmount")
  if not id or not quoted then return "MALFORMED" end
  local d = findBy(ctx.state.deposits, "depositID", id)
  if not d then return "NOT_FOUND" end
  if d.playerID ~= p.playerID then return "NOT_OWNER" end
  if d.status ~= "ACTIVE" then return "NOT_FOUND" end
  if ctx.state.suspended then return "BANK_SUSPENDED" end
  local due = ctx.config.investors.earlyWithdrawalFraction * d.principal
  if not within(quoted, due, ctx) then return "PRICE_CHANGED" end
  local r = payDeposit(ctx, d, "EARLY")
  notify(ctx, "WITHDRAWAL", p.playerID, "", d.depositID, r.due, r.toArrears)
  return "", {depositID = d.depositID, amount = r.due}
end

function H.FREEZE_PLACE(ctx, p, params)
  local c, s = ctx.config, ctx.state
  local target = paramNumber(params, "targetID")
  local mode = params.mode
  if not target or (mode ~= "COALITION" and mode ~= "PRESIDENT") then return "MALFORMED" end
  if s.suspended then return "BANK_SUSPENDED" end
  if target == p.playerID or not ctx.majors[target] or not playerOf(ctx, target) then return "NOT_FOUND" end
  if not contains(ctx.majors[p.playerID].wars or {}, target) then return "NOT_AT_WAR" end
  if isFrozen(s, target) then return "ALREADY_FROZEN" end
  local members = {p.playerID}
  if mode == "PRESIDENT" then
    if s.president.playerID ~= p.playerID then return "PRESIDENT_ONLY" end
    local count = 0
    for i = 1, #s.freezes do
      if s.freezes[i].mode == "PRESIDENT" and s.freezes[i].requesterID == p.playerID then count = count + 1 end
    end
    if count >= c.investors.presidentFreezeTargets then return "ALREADY_USED" end
  else
    if not (ctx.U > 0) or p.eligibleCapital < c.investors.eligibility.coalitionMemberFloorMultiple * ctx.U
        or p.eligibleCapital <= 0 then
      return "NOT_INVESTOR"
    end
    local qualifies
    members, qualifies = freezeCoalition(ctx, p.playerID, target)
    if not qualifies then return "NOT_ELIGIBLE" end
  end
  local freezeID = nextID(s, "freeze")
  s.freezes[#s.freezes + 1] = {freezeID = freezeID, targetID = target, mode = mode, requesterID = p.playerID,
    members = members, placedTurn = ctx.turn}
  notify(ctx, "FREEZE_PLACED", target, "", freezeID, p.playerID, mode)
  for i = 1, #members do notify(ctx, "FREEZE_PLACED", members[i], "", freezeID, target, mode) end
  return "", {freezeID = freezeID}
end

local function liftFreeze(ctx, f, why)
  local kept = {}
  for i = 1, #ctx.state.freezes do
    if ctx.state.freezes[i].freezeID ~= f.freezeID then kept[#kept + 1] = ctx.state.freezes[i] end
  end
  ctx.state.freezes = kept
  notify(ctx, "FREEZE_LIFTED", f.targetID, "", f.freezeID, why)
  for i = 1, #f.members do notify(ctx, "FREEZE_LIFTED", f.members[i], "", f.freezeID, why) end
end

function H.FREEZE_LIFT(ctx, p, params)
  local id = paramNumber(params, "freezeID")
  if not id then return "MALFORMED" end
  local f = findBy(ctx.state.freezes, "freezeID", id)
  if not f then return "NOT_FOUND" end
  if f.requesterID ~= p.playerID then return "NOT_OWNER" end
  liftFreeze(ctx, f, "REQUESTED")
  return "", {freezeID = id}
end

-- Dispatch one request against ctx (serialized authority order). Handlers validate fully before
-- mutating, so a rejection leaves ctx untouched except for the nonce and lastResult.
local function handle(ctx, playerID, params)
  local p = playerOf(ctx, playerID)
  local kind = params.kind
  p.nonce = p.nonce + 1
  local reason, info = "", nil
  local handler = type(kind) == "string" and H[kind] or nil
  if not handler then reason = "UNKNOWN_KIND"
  elseif not ctx.majors[playerID] then reason = "ACTOR_INVALID"
  elseif ctx.state.suspended then reason = "BANK_SUSPENDED"
  else reason, info = handler(ctx, p, params) end
  if type(kind) ~= "string" then kind = "" end
  p.lastResult = {nonce = params.nonce, kind = kind, ok = reason == "", reason = reason}
  return reason, info, kind
end

-- ------------------------------------------------------------------ turn phases

local function phaseGrowth(ctx)
  local s = ctx.state
  local players = {}
  for i = 1, #ctx.snapshot.majors do
    local m = ctx.snapshot.majors[i]
    players[#players + 1] = {id = m.playerID, alive = true, isMajor = true, production = m.production}
  end
  local previous = s.growth
  if type(previous) ~= "table" or previous.fingerprint == nil then previous = nil end
  local nextGrowth, result = WBL_MATH.ProductionGrowth(previous,
    {turn = ctx.turn, scale = ctx.scale, complete = true, players = players}, ctx.config)
  s.growth = WBL_STATE.Copy(nextGrowth)
  ctx.growth = result.gameGrowth
  logPhase(ctx, {phase = "growth", gameGrowth = result.gameGrowth, standardGrowth = result.standardGrowth,
    validPairs = result.validPairs, reason = result.reason})
end

local function phaseReserve(ctx)
  local c, s = ctx.config, ctx.state
  local bank = s.bank
  local era = nil
  if s.era.U > 0 and s.era.eraType ~= "" then era = s.era end
  local nextEra, U = WBL_MATH.CapitalUnit(era, ctx.snapshot.eraType, ctx.turn, ctx.scale, c)
  -- era.U holds the effective U (previous era's U during the change grace).
  s.era = {eraType = nextEra.eraType, U = U, previousU = nextEra.previousU, previousUntilTurn = nextEra.previousUntilTurn}
  ctx.U = U
  bank.lentPreviousTurn = bank.lentCurrent
  bank.lentCurrent = {}
  bank.lentThisTurn = 0
  local living = #ctx.living
  local cap = WBL_MATH.ReserveCap(U, living, c)
  local opened, refill = 0, 0
  if cap == nil then
    bank.cap, bank.refillPerTurn = 0, 0
  else
    if bank.cap <= 0 and bank.totals.opening == 0 and bank.cash == 0 then
      opened = WBL_MATH.ReserveOpeningCash(cap, c)
      move(ctx, "OPENING", -1, opened)
    end
    bank.cap = cap
    refill = WBL_MATH.ReserveRefill(U, living, ctx.scale, bank.cash, cap, c)
    bank.refillPerTurn = refill
    move(ctx, "REFILL", -1, refill)
  end
  logPhase(ctx, {phase = "reserve", U = U, cap = bank.cap, opening = opened, refill = refill, cash = bank.cash})
end

local function eliminate(ctx, p)
  local s = ctx.state
  local loans = activeLoans(s, p.playerID)
  for i = 1, #loans do
    local loan = loans[i]
    s.bank.totals.writtenOff = s.bank.totals.writtenOff + loan.scheduledPrincipal + loan.overduePrincipal
      + loan.overdueInterest + loan.arrearsFees
    loan.scheduledPrincipal, loan.futureInterest = 0, 0
    loan.overduePrincipal, loan.overdueInterest, loan.arrearsFees = 0, 0, 0
    if loan.milestone.status == "PENDING" then loan.milestone.status = "CANCELLED" end
    loan.status = "WRITTEN_OFF"
  end
  local kept = {}
  for i = 1, #s.lots do
    if s.lots[i].playerID ~= p.playerID then kept[#kept + 1] = s.lots[i] end
  end
  s.lots = kept
  for i = 1, #s.deposits do
    local d = s.deposits[i]
    if d.playerID == p.playerID and d.status == "ACTIVE" then
      d.status = "FORFEITED"
      s.bank.totals.forfeited = s.bank.totals.forfeited + d.principal
    end
  end
  for i = 1, #s.grants do
    local g = s.grants[i]
    if g.playerID == p.playerID and (g.status == "PENDING_MILESTONE" or g.status == "AWAITING_CASH") then g.status = "EXPIRED" end
  end
  if p.relief.status == "PENDING" then p.relief.status = "FAILED" end
  p.eligibleCapital, p.eligibleShare = 0, 0
  return #loans
end

local function phaseTiers(ctx)
  local c, s = ctx.config, ctx.state
  local eliminated = 0
  for i = 1, #s.players do
    local p = s.players[i]
    if not ctx.majors[p.playerID] then eliminated = eliminated + eliminate(ctx, p) end
  end
  local facts = {}
  for i = 1, #ctx.living do
    local m = ctx.majors[ctx.living[i]]
    local difficulty = m.difficultyType
    if c.tiers.difficultyFactor[difficulty] == nil then difficulty = c.reducer.unknownDifficultyFallback end
    facts[#facts + 1] = {id = m.playerID, alive = true, isMajor = true, human = m.isHuman == true,
      score = m.techs + m.civics, netGPT = m.netGPT, difficulty = difficulty}
  end
  local medians = {}
  local changes = 0
  for i = 1, #ctx.living do
    local m = ctx.majors[ctx.living[i]]
    local p = playerOf(ctx, m.playerID)
    local key = m.isHuman == true and "human" or "ai"
    if not medians[key] then
      local score, gpt, count = WBL_MATH.ReferenceMedians(facts, m.isHuman == true, c)
      medians[key] = {score = score, gpt = gpt, count = count}
    end
    local med = medians[key]
    local ratio = WBL_MATH.DevelopmentRatio(m.techs + m.civics, med.score, c)
    local old = p.tier
    local tier, pending, count
    if old == "" or med.count == 1 then
      tier, pending, count = WBL_MATH.ClassifyTier(ratio, m.netGPT, med.gpt, med.count, c), nil, 0
    else
      local prior = p.pendingTier
      if prior == "" then prior = nil end
      tier, pending, count = WBL_MATH.Hysteresis(old, prior, p.pendingCount, ratio, c)
      if tier == "UNDERDEVELOPED" and c.tiers.blendCapEnabled and m.netGPT >= med.gpt then tier = "DEVELOPING" end
    end
    p.tier, p.pendingTier, p.pendingCount = tier, pending or "", count
    if old ~= "" and old ~= tier then
      changes = changes + 1
      notify(ctx, "TIER_CHANGED", p.playerID, "", tier, old)
    end
  end
  -- Freezes: lift when the war ends, a party is gone, the President freeze loses its President,
  -- or a coalition fails re-measurement on the last measured eligible capital.
  local lifted = 0
  local freezes = {}
  for i = 1, #s.freezes do freezes[i] = s.freezes[i] end
  for i = 1, #freezes do
    local f = freezes[i]
    local why = ""
    local requester = ctx.majors[f.requesterID]
    if not ctx.majors[f.targetID] or not requester then why = "NOT_LIVING"
    elseif not contains(requester.wars or {}, f.targetID) then why = "WAR_ENDED"
    elseif f.mode == "PRESIDENT" then
      if s.president.playerID ~= f.requesterID then why = "PRESIDENT_LOST" end
    else
      local members, qualifies = freezeCoalition(ctx, f.requesterID, f.targetID)
      if qualifies then f.members = members else why = "REMEASURE_FAILED" end
    end
    if why ~= "" then
      lifted = lifted + 1
      liftFreeze(ctx, f, why)
    end
  end
  -- Recovery entitlements: only verified qualifying-disaster facts register (decisions 15-16).
  local registered, expired = 0, 0
  if c.features.recoveryPredicateVerified then
    local facts2 = {}
    for i = 1, #(ctx.snapshot.disasterFacts or {}) do facts2[i] = ctx.snapshot.disasterFacts[i] end
    table.sort(facts2, function(a, b)
      if a.qualifyingTurn ~= b.qualifyingTurn then return a.qualifyingTurn < b.qualifyingTurn end
      if a.victimID ~= b.victimID then return a.victimID < b.victimID end
      return a.eventKey < b.eventKey
    end)
    local window = WBL_MATH.RecoveryClaimWindow(ctx.scale, c)
    for i = 1, #facts2 do
      local fact = facts2[i]
      local duplicate = false
      for j = 1, #s.recovery do
        if s.recovery[j].eventKey == fact.eventKey and s.recovery[j].victimID == fact.victimID then duplicate = true end
      end
      local expiry = fact.qualifyingTurn + window
      if not duplicate and fact.qualifyingTurn <= ctx.turn and ctx.turn < expiry then
        local id = nextID(s, "entitlement")
        s.recovery[#s.recovery + 1] = {entitlementID = id, victimID = fact.victimID, eventKey = fact.eventKey,
          qualifyingTurn = fact.qualifyingTurn, expiryTurn = expiry, claimedLoanID = 0, status = "OPEN"}
        registered = registered + 1
        notify(ctx, "RECOVERY_OFFER", fact.victimID, "RECOVERY_OFFER:" .. id, id, fact.eventKey, expiry)
      end
    end
  end
  for i = 1, #s.recovery do
    local en = s.recovery[i]
    if en.status == "OPEN" and ctx.turn >= en.expiryTurn then
      en.status = "EXPIRED"
      expired = expired + 1
      notify(ctx, "RECOVERY_EXPIRED", en.victimID, "RECOVERY_EXPIRED:" .. en.entitlementID, en.entitlementID, en.eventKey)
    end
  end
  logPhase(ctx, {phase = "tiers", tierChanges = changes, eliminatedLoans = eliminated, freezesLifted = lifted,
    entitlementsRegistered = registered, entitlementsExpired = expired})
end

local function phaseMaturities(ctx)
  local s = ctx.state
  local count, paid, guarantee, toArrears = 0, 0, 0, 0
  -- Measure E once per player before any payout so same-turn maturities accrue identically.
  local accrualRows = {}
  for i = 1, #s.deposits do
    local d = s.deposits[i]
    if d.status == "ACTIVE" and d.maturityTurn <= ctx.turn and ctx.majors[d.playerID]
        and accrualRows[d.playerID] == nil then
      accrualRows[d.playerID] = WBL_MATH.DepositAccrual(s.deposits, d.playerID, measureE(ctx, d.playerID))
    end
  end
  for i = 1, #s.deposits do
    local d = s.deposits[i]
    if d.status == "ACTIVE" and d.maturityTurn <= ctx.turn and ctx.majors[d.playerID] then
      -- Accrue the maturity turn first with this turn's E, then pay arrears first (decisions 30, 32).
      local row = findBy(accrualRows[d.playerID], "depositID", d.depositID)
      if row then d.accruedReturn = row.accruedReturn end
      local r = payDeposit(ctx, d, "MATURITY")
      count, paid = count + 1, paid + r.due
      guarantee, toArrears = guarantee + r.guarantee, toArrears + r.toArrears
      notify(ctx, "DEPOSIT_MATURED", d.playerID, "", d.depositID, r.due, r.toArrears)
    end
  end
  logPhase(ctx, {phase = "maturities", count = count, paid = paid, guarantee = guarantee, toArrears = toArrears})
end

local function closeFinished(ctx)
  local s = ctx.state
  local loans = activeLoans(s, nil)
  local closed = 0
  for i = 1, #loans do
    local loan = loans[i]
    local scheduleDone = loan.installmentsPaid >= loan.installments
      or (loan.scheduledPrincipal == 0 and loan.futureInterest == 0)
    if scheduleDone and loan.scheduledPrincipal == 0 and not findBy(s.lots, "loanID", loan.loanID) then
      loan.status, loan.futureInterest = "MATURED", 0
      loan.overduePrincipal, loan.overdueInterest, loan.arrearsFees = 0, 0, 0
      if loan.milestone.status == "PENDING" then loan.milestone.status = "EXPIRED" end
      local p = playerOf(ctx, loan.playerID)
      if p and not loan.promotionUsed and p.rating ~= "D"
          and WBL_MATH.RatingPromotionEligible("MATURITY", loan.everMissed) then
        p.rating = upgradeRating(p.rating)
        loan.promotionUsed = true
      end
      closed = closed + 1
    end
  end
  return closed
end

-- Decision 34: a player in default is never swept from its treasury; garnishing is its only
-- collection (phaseGarnish).
local function sweepsTreasury(ctx, playerID)
  return playerOf(ctx, playerID).inDefault ~= true
end

local function phaseArrears(ctx)
  local s = ctx.state
  local lots, fees = WBL_MATH.AccrueLotFees(s.lots, ctx.turn, ctx.config, ctx.scale)
  s.lots = lots
  syncLoans(s, nil)
  local collected = 0
  for i = 1, #ctx.living do
    local pid = ctx.living[i]
    if sweepsTreasury(ctx, pid) then
      collected = collected + payArrears(ctx, pid, available(ctx, ctx.gold, pid), "ARREARS", "ARREARS")
    end
  end
  logPhase(ctx, {phase = "arrears", fees = fees, collected = collected})
end

-- Collect one due installment from at most `cap` gold (nil = all available gold). Contractual
-- interest is paid first, then principal; the unpaid parts become a new arrears lot.
local function collectInstallment(ctx, loan, p, cap, purpose, reason)
  local c = ctx.config
  local k = loan.installments - loan.installmentsPaid
  local principal, interest = loan.scheduledPrincipal, loan.futureInterest
  if k > 1 then principal, interest = principal / k, interest / k end
  local dueTurn = loan.nextDueTurn
  local due = principal + interest
  local gold = available(ctx, ctx.gold, loan.playerID)
  if cap ~= nil then gold = math.max(0, math.min(gold, cap)) end
  local paidI, paidP = interest, principal
  local pay = due
  if gold < due then
    pay = gold
    paidI = math.min(gold, interest)
    paidP = math.min(gold - paidI, principal)
  end
  if k > 1 then
    loan.scheduledPrincipal = loan.scheduledPrincipal - principal
    loan.futureInterest = loan.futureInterest - interest
  else
    loan.scheduledPrincipal, loan.futureInterest = 0, 0
  end
  loan.installmentsPaid = loan.installmentsPaid + 1
  loan.nextDueTurn = loan.nextDueTurn + 1
  local ids = {loanID = loan.loanID}
  goldEffect(ctx, loan.playerID, -pay, reason or "INSTALLMENT", ids)
  move(ctx, purpose or "REPAY_SCHEDULED", loan.playerID, pay, ids)
  local unpaidP, unpaidI = principal - paidP, interest - paidI
  if gold >= due then unpaidP, unpaidI = 0, 0 end
  if unpaidP + unpaidI > 0 then
    local s = ctx.state
    s.lots[#s.lots + 1] = {lotID = nextID(s, "lot"), loanID = loan.loanID, playerID = loan.playerID,
      dueTurn = dueTurn, principal = unpaidP, interest = unpaidI, fees = 0,
      firstFeeTurn = WBL_MATH.LotFirstFeeTurn(dueTurn, c)}
    syncLoan(s, loan)
    loan.missedCount = loan.missedCount + c.arrears.missPerPartlyUnpaidInstallment
    loan.everMissed = true
    if loan.missedCount % c.credit.missedPaymentsToDowngrade == 0 then
      p.rating = WBL_MATH.DowngradeRating(p.rating, c.arrears.missDowngradeFloor)
    end
    notify(ctx, "PAYMENT_MISSED", loan.playerID, "", loan.loanID, unpaidP + unpaidI)
    return pay, true
  end
  return pay, false
end

local function phaseScheduled(ctx)
  local s = ctx.state
  local collected, missed = 0, 0
  for i = 1, #ctx.living do
    local pid = ctx.living[i]
    local p = playerOf(ctx, pid)
    -- In default the due installments are collected by garnishing instead (decision 34).
    if sweepsTreasury(ctx, pid) then
      local loans = activeLoans(s, pid)
      for j = 1, #loans do
        local loan = loans[j]
        while loan.installmentsPaid < loan.installments and loan.nextDueTurn <= ctx.turn do
          local pay, miss = collectInstallment(ctx, loan, p)
          collected = collected + pay
          if miss then missed = missed + 1 end
        end
      end
    end
  end
  local closed = closeFinished(ctx)
  logPhase(ctx, {phase = "scheduled", collected = collected, missed = missed, matured = closed})
end

-- stage2Start is the game-turn default index from WBL_MATH.ArrearsClocks (decision 34).
local function stageFor(defaultTurn, stage2Start)
  if defaultTurn <= 0 then return 0 end
  if defaultTurn >= stage2Start then return 2 end
  return 1
end

-- Decision 34: a player in default keeps its treasury. Each turn the bank takes at most
-- budget = min(stage garnish % x max(0, net GPT), available gold), using the stage in force at
-- the boundary, and applies it to arrears lots first (AllocateArrearsPayment order), then to the
-- installments due this turn (oldest loan first). Nothing prepays future principal or interest;
-- any installment part the budget does not cover becomes an arrears lot as usual.
local function phaseGarnish(ctx)
  local c = ctx.config
  local stage2Start = WBL_MATH.ArrearsClocks(ctx.scale, c).stage2StartTurn
  local total, missed = 0, 0
  for i = 1, #ctx.living do
    local pid = ctx.living[i]
    local p = playerOf(ctx, pid)
    if p.inDefault then
      local stage = stageFor(p.defaultTurn, stage2Start)
      local budget = 0
      if stage > 0 and c.tiers[p.tier] then
        local pct = WBL_MATH.Penalties(p.tier, "stage" .. stage, c).garnishPercent
        budget = math.min(pct / c.reducer.percentUnit * math.max(0, ctx.majors[pid].netGPT),
          available(ctx, ctx.gold, pid))
      end
      local paid = payArrears(ctx, pid, budget, "GARNISH", "GARNISH")
      local left = math.max(0, budget - paid)
      local loans = activeLoans(ctx.state, pid)
      for j = 1, #loans do
        local loan = loans[j]
        while loan.installmentsPaid < loan.installments and loan.nextDueTurn <= ctx.turn do
          local pay, miss = collectInstallment(ctx, loan, p, left, "GARNISH", "GARNISH")
          left = math.max(0, left - pay)
          paid = paid + pay
          if miss then missed = missed + 1 end
        end
      end
      total = total + paid
    end
  end
  closeFinished(ctx)
  logPhase(ctx, {phase = "garnish", garnished = total, missed = missed})
end

local function allDebtSettled(state, playerID)
  local loans = activeLoans(state, playerID)
  for i = 1, #loans do
    if loanOutstanding(loans[i]) > 0 then return false end
  end
  return not hasLots(state, playerID)
end

local function phaseDefault(ctx)
  local c, s = ctx.config, ctx.state
  local clocks = WBL_MATH.ArrearsClocks(ctx.scale, c)
  local entered, cleared, restored = 0, 0, 0
  for i = 1, #ctx.living do
    local pid = ctx.living[i]
    local p = playerOf(ctx, pid)
    local arrears = hasLots(s, pid)
    if arrears then p.arrearsTurns = p.arrearsTurns + 1 else p.arrearsTurns = 0 end
    if p.inDefault then
      if not arrears then
        -- Penalties end and the scar starts when arrears clear; D persists while debt remains.
        p.inDefault, p.defaultTurn = false, 0
        p.scarUntilTurn = ctx.turn + WBL_MATH.ScaleTurns(c.credit.scarTurns, ctx.scale)
        cleared = cleared + 1
        notify(ctx, "DEFAULT_CLEARED", pid, "")
      else
        p.defaultTurn = p.defaultTurn + 1
        if p.defaultTurn == clocks.stage2StartTurn then
          notify(ctx, "DEFAULT_STAGE2", pid, "DEFAULT_STAGE2:" .. pid .. ":" .. (ctx.turn - p.defaultTurn + 1))
        end
      end
    elseif arrears and p.arrearsTurns >= clocks.defaultTurns then
      p.inDefault, p.defaultTurn, p.rating = true, 1, "D"
      entered = entered + 1
      local loans = activeLoans(s, pid)
      for j = 1, #loans do
        if loans[j].milestone.status == "PENDING" then
          loans[j].milestone.status = "CANCELLED"
          loans[j].milestoneUsed = true
        end
      end
      notify(ctx, "DEFAULT_STAGE1", pid, "DEFAULT_STAGE1:" .. pid .. ":" .. ctx.turn)
    elseif arrears and p.arrearsTurns == clocks.warningTurns then
      notify(ctx, "ARREARS_WARNING", pid, "ARREARS_WARNING:" .. pid .. ":" .. (ctx.turn - p.arrearsTurns + 1), p.arrearsTurns)
    end
    -- Decision 19: D returns to C only once every loan's arrears and all bank debt are settled.
    if p.rating == "D" and not p.inDefault and allDebtSettled(s, pid) then
      p.rating = c.reducer.recoveredRating
      restored = restored + 1
    end
    local stage = 0
    if p.inDefault then stage = stageFor(p.defaultTurn, clocks.stage2StartTurn) end
    if p.relief.status == "PENDING" then stage = 0 end
    local tier = ""
    if stage > 0 then tier = p.tier end
    if stage ~= p.penaltyLevel.stage or tier ~= p.penaltyLevel.tier then
      p.penaltyLevel = {tier = tier, stage = stage}
      pushEffect(ctx, {kind = "PENALTY_LEVEL", playerID = pid, tier = tier, stage = stage, reason = "DEFAULT_STAGE"})
    end
  end
  logPhase(ctx, {phase = "default", entered = entered, cleared = cleared, restoredC = restored})
end

local function phaseMilestones(ctx)
  local c, s = ctx.config, ctx.state
  local forgiven, completed, reliefDone, grantsPaid = 0, 0, 0, 0
  local loans = activeLoans(s, nil)
  for i = 1, #loans do
    local loan = loans[i]
    local m = loan.milestone
    if m.status == "PENDING" and ctx.majors[loan.playerID] then
      local fact = milestoneFact(ctx, loan.playerID, m)
      if ctx.turn >= m.halfwayTurn then
        m.status = "EXPIRED"
      elseif fact and fact.done then
        local r = WBL_MATH.MilestoneForgive(loan, loan.originTier, c)
        loan.scheduledPrincipal, loan.futureInterest = r.scheduledPrincipal, r.futureInterest
        m.status, m.fraction = "DONE", r.fraction
        loan.milestoneUsed = true
        addSubsidy(ctx, loan.playerID, "FORGIVENESS", r.forgivenPrincipal)
        s.bank.totals.writtenOff = s.bank.totals.writtenOff + r.forgivenPrincipal
        forgiven, completed = forgiven + r.forgivenPrincipal, completed + 1
        notify(ctx, "MILESTONE_COMPLETE", loan.playerID, "", loan.loanID, r.forgivenPrincipal)
      end
    end
  end
  for i = 1, #ctx.living do
    local p = playerOf(ctx, ctx.living[i])
    if p.relief.status == "PENDING" then
      local fact = milestoneFact(ctx, p.playerID, p.relief.milestone)
      if ctx.turn >= p.relief.deadlineTurn then
        p.relief.status = "FAILED"
      elseif fact and fact.done then
        local r = WBL_MATH.ApplyDebtRelief(s.loans, s.lots, p.playerID, c)
        for j = 1, #r.loans do
          local loan = findBy(s.loans, "loanID", r.loans[j].loanID)
          loan.scheduledPrincipal, loan.futureInterest = r.loans[j].scheduledPrincipal, r.loans[j].futureInterest
        end
        for j = 1, #r.lots do
          local lot = findBy(s.lots, "lotID", r.lots[j].lotID)
          lot.principal, lot.interest, lot.fees = r.lots[j].principal, r.lots[j].interest, r.lots[j].fees
        end
        purgeLots(s)
        syncLoans(s, p.playerID)
        p.relief.status = "DONE"
        addSubsidy(ctx, p.playerID, "RELIEF", r.forgivenExposure)
        s.bank.totals.writtenOff = s.bank.totals.writtenOff + r.forgivenExposure
        reliefDone = reliefDone + 1
        notify(ctx, "DEBT_RELIEF", p.playerID, "", r.forgivenExposure)
      end
    end
  end
  for i = 1, #s.grants do
    local g = s.grants[i]
    local open = g.status == "PENDING_MILESTONE" or g.status == "AWAITING_CASH"
    if open and (g.eraType ~= ctx.snapshot.eraType or not ctx.majors[g.playerID]) then
      g.status = "EXPIRED"
    elseif g.status == "PENDING_MILESTONE" then
      local fact = milestoneFact(ctx, g.playerID, g.milestone)
      if fact and fact.done then g.status = "AWAITING_CASH" end
    end
    if g.status == "AWAITING_CASH" and s.bank.cash >= g.amount then
      move(ctx, "GRANT", g.playerID, g.amount, {grantID = g.grantID})
      goldEffect(ctx, g.playerID, g.amount, "GRANT", {grantID = g.grantID})
      g.status = "PAID"
      addSubsidy(ctx, g.playerID, "GRANT", g.amount)
      grantsPaid = grantsPaid + g.amount
      notify(ctx, "GRANT_PAID", g.playerID, "", g.grantID, g.amount)
    end
  end
  logPhase(ctx, {phase = "milestones", completed = completed, forgiven = forgiven, reliefDone = reliefDone,
    grantsPaid = grantsPaid})
end

local function phaseShares(ctx)
  local c, s = ctx.config, ctx.state
  local rows = {}
  for i = 1, #ctx.living do
    local pid = ctx.living[i]
    local E = measureE(ctx, pid)
    playerOf(ctx, pid).eligibleCapital = E
    rows[#rows + 1] = {playerID = pid, eligibleCapital = E}
  end
  local shares, total = WBL_MATH.EligibleShares(rows)
  local accrued = 0
  local presidentRows = {}
  for i = 1, #shares do
    local p = playerOf(ctx, shares[i].playerID)
    p.eligibleShare = shares[i].share
    local deposits = WBL_MATH.DepositAccrual(s.deposits, p.playerID, p.eligibleCapital)
    for j = 1, #deposits do
      findBy(s.deposits, "depositID", deposits[j].depositID).accruedReturn = deposits[j].accruedReturn
      accrued = accrued + deposits[j].accrual
    end
    presidentRows[#presidentRows + 1] = {playerID = p.playerID, eligibleCapital = p.eligibleCapital,
      eligibleShare = p.eligibleShare, shareReachedTurn = p.shareReachedTurn,
      presidentConfirmCount = p.presidentConfirmCount}
  end
  local step = WBL_MATH.PresidentStep({turn = ctx.turn, scale = ctx.scale, U = ctx.U,
    president = s.president, players = presidentRows}, c)
  for i = 1, #step.players do
    local p = playerOf(ctx, step.players[i].playerID)
    p.shareReachedTurn = step.players[i].shareReachedTurn
    p.presidentConfirmCount = step.players[i].presidentConfirmCount
  end
  s.president = {playerID = step.president.playerID, sinceTurn = step.president.sinceTurn}
  if step.changed then
    if step.previousPlayerID ~= -1 then
      if ctx.majors[step.previousPlayerID] then notify(ctx, "PRESIDENT_LOST", step.previousPlayerID, "") end
      local freezes = {}
      for i = 1, #s.freezes do freezes[i] = s.freezes[i] end
      for i = 1, #freezes do
        if freezes[i].mode == "PRESIDENT" and freezes[i].requesterID == step.previousPlayerID then
          liftFreeze(ctx, freezes[i], "PRESIDENT_LOST")
        end
      end
    end
    if step.president.playerID ~= -1 then
      notify(ctx, "PRESIDENT_GAINED", step.president.playerID,
        "PRESIDENT_GAINED:" .. step.president.playerID .. ":" .. step.president.sinceTurn)
    end
  end
  logPhase(ctx, {phase = "shares", totalEligible = total, accrued = accrued, president = s.president.playerID,
    presidentReason = step.reason})
end

local function phasePerks(ctx)
  local c, s = ctx.config, ctx.state
  local inv = c.investors
  local totalLent = 0
  for i = 1, #s.bank.lentPreviousTurn do totalLent = totalLent + s.bank.lentPreviousTurn[i].amount end
  local favorPaid, aidPaid = 0, 0
  local eraType = ctx.snapshot.eraType
  for i = 1, #ctx.living do
    local pid = ctx.living[i]
    local p = playerOf(ctx, pid)
    local ladder = WBL_MATH.InvestorLadder(p.eligibleCapital, math.min(1, p.eligibleShare), ctx.U, c)
    favorEffect(ctx, pid, ladder.favor, "INVESTOR_FAVOR")
    favorPaid = favorPaid + ladder.favor
    local own = findBy(s.bank.lentPreviousTurn, "playerID", pid)
    local others = totalLent - ((own and own.amount) or 0)
    local aid = 0
    if ladder.eligible then aid = WBL_MATH.InvestorAidCredit(p.eligibleShare, math.max(0, others), ladder.aidCap, c) end
    local whole, carry = WBL_MATH.SplitWhole(p.aidCarry, aid, c)
    p.aidCarry = carry
    favorEffect(ctx, pid, whole, "AID_CREDIT")
    aidPaid = aidPaid + whole
    if s.president.playerID == pid then
      favorEffect(ctx, pid, inv.presidentFavor, "PRESIDENT_FAVOR")
      favorPaid = favorPaid + inv.presidentFavor
      counterEffect(ctx, "MERCHANT_POINTS", pid, inv.presidentMerchantPoints, "PRESIDENT_MERCHANT")
      p.envoyProgressTurns = p.envoyProgressTurns + 1
      if p.envoyProgressTurns >= WBL_MATH.ScaleTurns(inv.presidentEnvoyTurns, ctx.scale) then
        counterEffect(ctx, "ENVOY", pid, 1, "PRESIDENT_ENVOY")
        p.envoyProgressTurns = 0
      end
      if p.presidentEraType ~= eraType then p.presidentEraType, p.presidentTurnsThisEra = eraType, 0 end
      p.presidentTurnsThisEra = p.presidentTurnsThisEra + 1
      if p.presidentTurnsThisEra >= WBL_MATH.ScaleTurns(inv.presidentEraTurns, ctx.scale)
          and p.eraScorePaidEra ~= eraType then
        counterEffect(ctx, "ERA_SCORE", pid, inv.presidentEraScore, "PRESIDENT_ERA_SCORE")
        p.eraScorePaidEra = eraType
      end
    else
      p.envoyProgressTurns = 0
    end
  end
  logPhase(ctx, {phase = "perks", favor = favorPaid, aid = aidPaid, lentPreviousTurn = totalLent})
end

local function aiFacts(ctx, pid, offer)
  local s = ctx.state
  local p = playerOf(ctx, pid)
  return {playerID = pid, isHuman = false, gold = available(ctx, ctx.gold, pid), netGPT = ctx.majors[pid].netGPT,
    activeLoans = #activeLoans(s, pid), arrears = sumLots(playerLots(s, pid)), rating = p.rating,
    frozen = isFrozen(s, pid), inDefault = p.inDefault, tier = p.tier, liquidityTier = offer.liquidityTier}
end

local function phaseAI(ctx)
  local attempted, accepted, errors = 0, 0, 0
  local policy = WBL_AIPOLICY
  if ctx.config.features.attemptAIBorrowing and type(policy) == "table" and type(policy.Decide) == "function" then
    for i = 1, #ctx.living do
      local pid = ctx.living[i]
      if ctx.majors[pid].isHuman ~= true then
        local offer = buildOffer(ctx, pid)
        local ok, params = pcall(policy.Decide, aiFacts(ctx, pid, offer), offer, offer.recoveryOffers, ctx.config)
        if ok and type(params) == "table" then
          local request = {}
          local keys = {"kind", "product", "entitlementID", "amount", "termStandardTurns", "quotedV",
            "milestoneKind", "milestoneTarget", "milestoneCityID"}
          for j = 1, #keys do request[keys[j]] = params[keys[j]] end
          request.nonce = playerOf(ctx, pid).nonce
          attempted = attempted + 1
          if request.kind == "TAKE_LOAN" or request.kind == "CLAIM_RECOVERY" then
            -- A failing AI request must not block the boundary: roll back to the saved state.
            local saved = {state = WBL_STATE.Copy(ctx.state), effects = #ctx.effects, notes = #ctx.notes,
              seq = ctx.seq, gold = ctx.gold[pid], favor = ctx.favor[pid]}
            local done, reason = pcall(handle, ctx, pid, request)
            if done and reason == "" then accepted = accepted + 1 end
            if not done then
              ctx.state, ctx.seq, ctx.gold[pid], ctx.favor[pid] = saved.state, saved.seq, saved.gold, saved.favor
              for j = #ctx.effects, saved.effects + 1, -1 do table.remove(ctx.effects, j) end
              for j = #ctx.notes, saved.notes + 1, -1 do table.remove(ctx.notes, j) end
              errors = errors + 1
            end
          end
        end
      end
    end
  end
  logPhase(ctx, {phase = "ai", attempted = attempted, accepted = accepted, errors = errors})
end

local function finalize(ctx, prune)
  local s = ctx.state
  syncLoans(s, nil)
  refreshAggregates(s)
  publishOffers(ctx)
  if prune then
    local memory = WBL_MATH.ScaleTurns(ctx.config.investors.eligibility.subsidyMemoryTurns, ctx.scale)
    s = WBL_STATE.Prune(s, ctx.turn, ctx.config, ctx.turn - memory + 1)
  end
  local ok, reason = WBL_STATE.Validate(s, ctx.config)
  if not ok then error("invalid reducer state: " .. tostring(reason), 0) end
  return s
end

local function turnGuard(state, snapshot)
  if type(state) ~= "table" then return "BANK_SUSPENDED" end
  if state.suspended then return "BANK_SUSPENDED" end
  if type(snapshot) ~= "table" or snapshot.complete ~= true or type(snapshot.majors) ~= "table"
      or #snapshot.majors == 0 or not isInt(snapshot.turn) or snapshot.turn < 1
      or not (finite(snapshot.speedScale) and snapshot.speedScale > 0)
      or type(snapshot.eraType) ~= "string" or snapshot.eraType == "" then
    return "SNAPSHOT_INCOMPLETE"
  end
  if snapshot.turn <= state.lastProcessedTurn then return "DUPLICATE_TURN" end
  return nil
end

local function ensurePlayers(ctx)
  local s = ctx.state
  local added = false
  for i = 1, #ctx.living do
    if not playerOf(ctx, ctx.living[i]) then
      local p = WBL_STATE.NewPlayer(ctx.living[i])
      p.rating = ctx.config.reducer.startingRating
      s.players[#s.players + 1] = p
      added = true
    end
  end
  if added then table.sort(s.players, function(a, b) return a.playerID < b.playerID end) end
end

local function turnBody(state, snapshot, config)
  local s = WBL_STATE.Copy(state)
  local ctx = newContext(s, snapshot, config)
  s.speedScale = ctx.scale
  ensurePlayers(ctx)
  phaseGrowth(ctx)
  phaseReserve(ctx)
  phaseTiers(ctx)
  phaseMaturities(ctx)
  phaseArrears(ctx)
  phaseScheduled(ctx)
  phaseGarnish(ctx)
  phaseDefault(ctx)
  phaseMilestones(ctx)
  phaseShares(ctx)
  phasePerks(ctx)
  phaseAI(ctx)
  local sent = flushNotes(ctx)
  logPhase(ctx, {phase = "notifications", sent = sent})
  ctx.state.lastProcessedTurn = ctx.turn
  local out = finalize(ctx, true)
  return out, ctx.effects, {ok = true, reason = "OK", noop = false, turn = ctx.turn, eventID = ctx.eventID,
    phaseLog = ctx.phaseLog, detail = ""}
end

function R.Turn(state, snapshot, config)
  config = config or WBL_CONFIG
  local guard = turnGuard(state, snapshot)
  local turn = type(snapshot) == "table" and snapshot.turn or -1
  if guard then
    local copy = state
    if type(state) == "table" then copy = WBL_STATE.Copy(state) end
    return copy, {}, {ok = guard == "DUPLICATE_TURN", reason = guard, noop = true, turn = turn, eventID = 0,
      phaseLog = {}, detail = ""}
  end
  local ok, nextState, effects, result = pcall(turnBody, state, snapshot, config)
  if not ok then
    return WBL_STATE.Copy(state), {}, {ok = false, reason = "REDUCER_ERROR", noop = true, turn = turn,
      eventID = 0, phaseLog = {}, detail = tostring(nextState)}
  end
  return nextState, effects, result
end

local function requestBody(state, snapshot, playerID, params, config)
  local kind = ""
  if type(params) == "table" and type(params.kind) == "string" then kind = params.kind end
  if type(state) ~= "table" or state.suspended then
    return state, {}, {ok = false, reason = "BANK_SUSPENDED", kind = kind, detail = ""}
  end
  if type(params) ~= "table" then
    return WBL_STATE.Copy(state), {}, {ok = false, reason = "MALFORMED", kind = kind, detail = ""}
  end
  local player = findBy(state.players, "playerID", playerID)
  if not player then
    return WBL_STATE.Copy(state), {}, {ok = false, reason = "ACTOR_INVALID", kind = kind, detail = ""}
  end
  if params.nonce ~= player.nonce then
    return WBL_STATE.Copy(state), {}, {ok = false, reason = "BAD_NONCE", kind = kind, detail = ""}
  end
  if type(snapshot) == "table" and type(snapshot.majors) == "table"
      and not findBy(snapshot.majors, "playerID", playerID) then
    return WBL_STATE.Copy(state), {}, {ok = false, reason = "ACTOR_INVALID", kind = kind, detail = ""}
  end
  local complete = type(snapshot) == "table" and snapshot.complete == true and type(snapshot.majors) == "table"
    and isInt(snapshot.turn) and finite(snapshot.speedScale) and snapshot.speedScale > 0
  local function rejected(reason)
    local s = WBL_STATE.Copy(state)
    local p = findBy(s.players, "playerID", playerID)
    p.nonce = p.nonce + 1
    p.lastResult = {nonce = params.nonce, kind = kind, ok = false, reason = reason}
    local offer = findBy(s.offers, "playerID", playerID)
    if offer then offer.nonce = p.nonce end
    return s, {}, {ok = false, reason = reason, kind = kind, detail = ""}
  end
  if not complete then return rejected("SNAPSHOT_INCOMPLETE") end
  local s = WBL_STATE.Copy(state)
  local ctx = newContext(s, snapshot, config)
  local reason, info = handle(ctx, playerID, params)
  if reason ~= "" then return rejected(reason) end
  flushNotes(ctx)
  local out = finalize(ctx, false)
  local result = {ok = true, reason = "OK", kind = kind, detail = ""}
  if info then
    for i = 1, #ID_FIELDS do
      if info[ID_FIELDS[i]] then result[ID_FIELDS[i]] = info[ID_FIELDS[i]] end
    end
    if info.amount then result.amount = info.amount end
  end
  return out, ctx.effects, result
end

function R.Request(state, snapshot, playerID, params, config)
  config = config or WBL_CONFIG
  local ok, nextState, effects, result = pcall(requestBody, state, snapshot, playerID, params, config)
  if not ok then
    local kind = (type(params) == "table" and type(params.kind) == "string") and params.kind or ""
    local copy = state
    if type(state) == "table" then copy = WBL_STATE.Copy(state) end
    return copy, {}, {ok = false, reason = "REDUCER_ERROR", kind = kind, detail = tostring(nextState)}
  end
  return nextState, effects, result
end

-- Ledger and balance invariants (R2, R6). tolerance defaults to precision.balanceTolerance.
function R.Invariants(state, config, tolerance)
  config = config or WBL_CONFIG
  tolerance = tolerance or config.precision.balanceTolerance
  local bank, t = state.bank, state.bank.totals
  local expected = t.opening + t.refill + t.depositReceipts + t.repayments + t.arrearsPaid + t.garnished
    + t.guarantees - t.disbursements - t.depositPayouts - t.grantsPaid
  if math.abs(bank.cash - expected) > tolerance then return false, "CASH_LEDGER" end
  if bank.cash < -tolerance then return false, "NEGATIVE_CASH" end
  local receivables = 0
  local loans = activeLoans(state, nil)
  for i = 1, #loans do
    local loan = loans[i]
    receivables = receivables + loanOutstanding(loan)
    local p, int, f = 0, 0, 0
    for j = 1, #state.lots do
      local lot = state.lots[j]
      if lot.loanID == loan.loanID then p, int, f = p + lot.principal, int + lot.interest, f + lot.fees end
    end
    if math.abs(p - loan.overduePrincipal) > tolerance or math.abs(int - loan.overdueInterest) > tolerance
        or math.abs(f - loan.arrearsFees) > tolerance then
      return false, "LOT_BUCKETS:" .. loan.loanID
    end
    if loan.scheduledPrincipal < -tolerance or loan.futureInterest < -tolerance then return false, "NEGATIVE_LOAN" end
  end
  for j = 1, #state.lots do
    local lot = state.lots[j]
    local loan = findBy(state.loans, "loanID", lot.loanID)
    if not loan or loan.status ~= "ACTIVE" then return false, "ORPHAN_LOT:" .. lot.lotID end
    if lot.principal < 0 or lot.interest < 0 or lot.fees < 0 then return false, "NEGATIVE_LOT" end
  end
  if math.abs(receivables - bank.receivables) > tolerance then return false, "RECEIVABLES" end
  if math.abs(totalActiveDeposits(state) - bank.depositLiabilities) > tolerance then return false, "LIABILITIES" end
  return true, ""
end

return WBL_REDUCER
