-- WBL_AIPolicy: pure, deterministic AI borrowing policy (spec 6, decisions 2, 15-16, 33).
-- No engine calls, no pairs, no randomness. Load after WBL_Config.lua and WBL_Math.lua.
--
-- Decide(playerFacts, offers, recoveryOffers, config) -> params or nil, reason[, detail]
--   playerFacts: {playerID, isHuman, gold, netGPT, activeLoans, arrears (overdue gold >= 0),
--                 rating ("A".."D"), frozen (bool), inDefault (bool), tier, liquidityTier (optional)}
--   offers: the player's published offers view (PLAN "Offers view"): blockedReason, availableDraw,
--           tier, liquidityTier, products[] {product, available, reason, maxAmount, quotedV, terms[]}
--   recoveryOffers: array of {entitlementID, expiryTurn, maxAmount, quotedV, blockedReason, terms[]};
--           nil falls back to offers.recoveryOffers.
--   params: flat request table without OnStart and nonce (the caller adds them), same keys as
--           WBL_BankView.BuildRequest for TAKE_LOAN / CLAIM_RECOVERY.
-- Reason codes: OK, AI_DISABLED, NOT_AI, BAD_FACTS, IN_DEFAULT, ARREARS, FROZEN, RATING_D,
--   LIQUIDITY_EMERGENCY, MAX_LOANS, NO_TRIGGER, NO_OFFER, OFFER_BLOCKED (detail = reducer reason),
--   PRODUCT_BLOCKED (detail = reducer reason), NO_DRAW, TERM_UNAVAILABLE.
WBL_AIPOLICY = {}
local M = WBL_AIPOLICY

M.REASONS = {"OK", "AI_DISABLED", "NOT_AI", "BAD_FACTS", "IN_DEFAULT", "ARREARS", "FROZEN", "RATING_D",
  "LIQUIDITY_EMERGENCY", "MAX_LOANS", "NO_TRIGGER", "NO_OFFER", "OFFER_BLOCKED", "PRODUCT_BLOCKED",
  "NO_DRAW", "TERM_UNAVAILABLE"}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function blank(reason)
  return reason == nil or reason == ""
end

local function findProduct(offers, product)
  local products = offers.products
  if type(products) ~= "table" then return nil end
  for i = 1, #products do
    if products[i].product == product then return products[i] end
  end
  return nil
end

-- True when terms is absent/empty (cannot check) or lists the standard-turn term.
local function hasTerm(terms, term)
  if type(terms) ~= "table" or #terms == 0 then return true end
  for i = 1, #terms do
    if terms[i].termStandardTurns == term then return true end
  end
  return false
end

local function cap(amount, limit)
  if finite(limit) then return math.min(amount, limit) end
  return amount
end

-- Ascending copy of an ID list; input is never mutated.
function M.OrderPlayers(ids)
  local out = {}
  for i = 1, #ids do out[i] = ids[i] end
  table.sort(out)
  return out
end

-- Cheapest unblocked recovery offer: lowest quotedV, then earliest expiry, then lowest entitlementID.
local function bestRecovery(list)
  local best
  if type(list) ~= "table" then return nil end
  for i = 1, #list do
    local ro = list[i]
    if blank(ro.blockedReason) and finite(ro.quotedV) and finite(ro.maxAmount) and ro.maxAmount > 0
        and finite(ro.entitlementID) then
      local better = best == nil or ro.quotedV < best.quotedV
      if not better and ro.quotedV == best.quotedV then
        local e1, e2 = ro.expiryTurn or math.huge, best.expiryTurn or math.huge
        better = e1 < e2 or (e1 == e2 and ro.entitlementID < best.entitlementID)
      end
      if better then best = ro end
    end
  end
  return best
end

function M.Decide(facts, offers, recoveryOffers, config)
  config = config or WBL_CONFIG
  if not (config.features and config.features.attemptAIBorrowing) then return nil, "AI_DISABLED" end
  if type(facts) ~= "table" then return nil, "BAD_FACTS" end
  if facts.isHuman then return nil, "NOT_AI" end
  if not (finite(facts.gold) and facts.gold >= 0 and finite(facts.netGPT) and finite(facts.activeLoans)
      and facts.activeLoans >= 0 and (facts.arrears == nil or (finite(facts.arrears) and facts.arrears >= 0))) then
    return nil, "BAD_FACTS"
  end
  if facts.inDefault then return nil, "IN_DEFAULT" end
  if (facts.arrears or 0) > 0 then return nil, "ARREARS" end
  if facts.frozen then return nil, "FROZEN" end
  if facts.rating == "D" then return nil, "RATING_D" end
  if type(offers) ~= "table" then return nil, "NO_OFFER" end
  local tier = facts.tier or offers.tier
  local liquidity = facts.liquidityTier or offers.liquidityTier
  -- Spec 2.3 emergency window: only Developing and Underdeveloped may borrow.
  if liquidity == "EMERGENCY" and tier == "DEVELOPED" then return nil, "LIQUIDITY_EMERGENCY" end
  if facts.activeLoans >= config.ai.maxLoans then return nil, "MAX_LOANS" end
  if not WBL_MATH.AIShouldBorrow(facts.gold, facts.netGPT, 0, facts.activeLoans, config) then
    return nil, "NO_TRIGGER"
  end
  if not blank(offers.blockedReason) then return nil, "OFFER_BLOCKED", offers.blockedReason end

  local draw = offers.availableDraw
  if not (finite(draw) and draw > 0) then return nil, "NO_DRAW" end
  local requested = math.min(WBL_MATH.AILoanAmount(facts.netGPT, config), draw)
  local term = config.ai.termStandardTurns

  local ordinary = findProduct(offers, "ORDINARY")
  local ordinaryOpen = ordinary ~= nil and ordinary.available == true and blank(ordinary.reason)
    and finite(ordinary.quotedV)

  -- Recovery preference (decisions 15-16): same requested size, only when cheaper than ordinary.
  local ro = bestRecovery(recoveryOffers or offers.recoveryOffers)
  if ro then
    local recoveryProduct = findProduct(offers, "RECOVERY")
    local terms = ro.terms or (recoveryProduct and recoveryProduct.terms)
    local amount = math.floor(cap(requested, ro.maxAmount))
    if (not ordinaryOpen or ro.quotedV < ordinary.quotedV) and amount > 0 and hasTerm(terms, term) then
      return {kind = "CLAIM_RECOVERY", entitlementID = ro.entitlementID, amount = amount,
        termStandardTurns = term, quotedV = ro.quotedV,
        milestoneKind = "NONE", milestoneTarget = "", milestoneCityID = 0}, "OK"
    end
  end

  if ordinary == nil then return nil, "NO_OFFER" end
  if not ordinaryOpen then return nil, "PRODUCT_BLOCKED", ordinary.reason end
  local amount = math.floor(cap(requested, ordinary.maxAmount))
  if amount <= 0 then return nil, "NO_DRAW" end
  if not hasTerm(ordinary.terms, term) then return nil, "TERM_UNAVAILABLE" end
  return {kind = "TAKE_LOAN", product = "ORDINARY", amount = amount, termStandardTurns = term,
    quotedV = ordinary.quotedV, milestoneKind = "NONE", milestoneTarget = "", milestoneCityID = 0}, "OK"
end

return WBL_AIPOLICY
