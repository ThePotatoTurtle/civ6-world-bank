-- WBL_STATE: pure persisted-state module (schema 1, PLAN.md "State schema 1").
-- Load WBL_Config.lua first. No engine calls, no pairs, no randomness; every
-- traversal uses next + sorted keys so results never depend on insertion order.
--
-- API
--   New(config, turn, opts) -> state     fresh schema-1 state. opts (all optional):
--       speedScale, eraType, U, configFingerprint. The bank is NOT initialised here:
--       bank.cash/cap/refillPerTurn stay 0 and era.U stays 0 unless opts.U is given,
--       because the base-reserve formula (cap = capFloorMultiple * U * living majors)
--       belongs to the reducer, which fills it at its first boundary. players[] starts
--       empty (use NewPlayer). lastProcessedTurn = turn - 1, so `turn` still gets processed.
--   NewPlayer(playerID, config) -> player record with neutral defaults
--   Validate(state, config) -> ok, reason   structural + enum + ordering check, deterministic reason
--   Encode(state, config) -> value, reason  table (default) or string; nil, reason when invalid.
--       String mode only when features.statePersistenceVerified == false AND
--       state.stringCodecWhenUnverified == true. The result is always independent of `state`.
--   Decode(raw, config) -> state, status, reason
--       status "OK" | "NEW" (raw == nil) | "MIGRATED" | "SUSPENDED". A SUSPENDED state is a
--       fresh New(config, 0) with suspended=true and suspendReason == reason
--       (MALFORMED_TYPE, MALFORMED_STRING, MALFORMED_DATA, MALFORMED_SCHEMA, FUTURE_SCHEMA,
--       NO_MIGRATION, MIGRATION_FAILED, INVALID:<detail>). Callers should not overwrite the
--       stored property while suspended for FUTURE_SCHEMA or MALFORMED_* reasons.
--       Both codecs are accepted whatever the current config says.
--   Copy(state) -> independent deep copy (plain data only; errors on functions/cycles/NaN)
--   Prune(state, turn, config, subsidyMinTurn) -> pruned copy: ledger movements older than
--       config.state.ledgerRetentionTurns game turns, and (if given) subsidies before subsidyMinTurn.
--       Closed loans/lots/deposits are kept: lineage and history flags still need them.
--   Checksum(state, config) -> string "<length>:<h1>:<h2>" over CanonicalString
--   CanonicalString(state) -> exact deterministic text (sorted keys, %.17g numbers)
--   MIGRATIONS[n] = function(stateAtSchemaN) -> stateAtSchemaN+1 (none needed yet)
WBL_STATE = {}
local S = WBL_STATE
S.MIGRATIONS = {}

local STRING_PREFIX = "WBLS:"

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function keyLess(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta == "number" end
  return a < b
end

local function sortedKeys(value)
  local keys = {}
  for key in next, value do
    local kind = type(key)
    if kind == "number" then
      if not finite(key) then error("non-finite table key", 0) end
    elseif kind ~= "string" then
      error("unsupported table key type " .. kind, 0)
    end
    keys[#keys + 1] = key
  end
  table.sort(keys, keyLess)
  return keys
end

local function copyValue(value, seen)
  local kind = type(value)
  if kind == "table" then
    if seen[value] then error("cyclic table", 0) end
    seen[value] = true
    local out = {}
    for _, key in ipairs(sortedKeys(value)) do out[key] = copyValue(value[key], seen) end
    seen[value] = nil
    return out
  elseif kind == "number" then
    if not finite(value) then error("non-finite number", 0) end
    return value
  elseif kind == "string" or kind == "boolean" then
    return value
  end
  error("unsupported value type " .. kind, 0)
end

function S.Copy(state)
  return copyValue(state, {})
end

-- ---------------------------------------------------------------- schema

local INT, NUM, BOOL, STR = { k = "int" }, { k = "num" }, { k = "bool" }, { k = "str" }
local SCALAR, DATA = { k = "scalar" }, { k = "data" }

local function enum(...)
  local set = {}
  for _, name in ipairs({ ... }) do set[name] = true end
  return { k = "enum", set = set }
end

local function rec(fields)
  local names = {}
  for name in next, fields do names[#names + 1] = name end
  table.sort(names)
  return { k = "rec", fields = fields, names = names }
end

local function arr(item, idKey, ascending)
  return { k = "arr", item = item, idKey = idKey, ascending = ascending }
end

local MILESTONE_KIND = enum("NONE", "POPULATION", "TECH", "DISTRICT")
local MILESTONE_REQUEST = rec({ kind = MILESTONE_KIND, target = SCALAR, cityID = INT })
local LOAN_MILESTONE = rec({
  kind = MILESTONE_KIND, target = SCALAR, cityID = INT, halfwayTurn = INT,
  status = enum("NONE", "PENDING", "DONE", "CANCELLED", "EXPIRED"), fraction = NUM,
})

local PLAYER = rec({
  playerID = INT, nonce = INT,
  lastResult = rec({ nonce = INT, kind = STR, ok = BOOL, reason = STR }),
  tier = STR, pendingTier = STR, pendingCount = INT, rating = STR, arrearsTurns = INT,
  inDefault = BOOL, defaultTurn = INT, scarUntilTurn = INT,
  penaltyLevel = rec({ tier = SCALAR, stage = INT }),
  debtReliefUsed = BOOL,
  relief = rec({ status = enum("NONE", "PENDING", "DONE", "FAILED"), milestone = MILESTONE_REQUEST, deadlineTurn = INT }),
  lastGrantEra = STR, eligibleCapital = NUM, eligibleShare = NUM, shareReachedTurn = INT,
  presidentConfirmCount = INT, presidentTurnsThisEra = INT, presidentEraType = STR,
  eraScorePaidEra = STR, envoyProgressTurns = INT, aidCarry = NUM,
  unpaid = rec({ favor = NUM, eraScore = NUM, merchantPoints = NUM, envoys = NUM }),
})

local LOAN = rec({
  loanID = INT, playerID = INT, product = enum("ORDINARY", "INFRASTRUCTURE", "RECOVERY"),
  entitlementID = INT, lineageID = INT, parentLoanID = INT,
  originTurn = INT, originTier = STR, principal = NUM, valueRatio = NUM, nominalRate = NUM,
  growth = NUM, earlyRepayInterestFraction = NUM, paymentTurns = INT, graceTurns = INT,
  preferredStep = INT, liquidityExempt = BOOL,
  installments = INT, installmentsPaid = INT, nextDueTurn = INT,
  scheduledPrincipal = NUM, futureInterest = NUM,
  overduePrincipal = NUM, overdueInterest = NUM, arrearsFees = NUM,
  missedCount = INT, everMissed = BOOL,
  restructured = BOOL, milestoneUsed = BOOL, promotionUsed = BOOL,
  milestone = LOAN_MILESTONE,
  status = enum("ACTIVE", "MATURED", "REPAID_EARLY", "RESTRUCTURED", "WRITTEN_OFF"),
})

local TOTALS = rec({
  refill = NUM, depositReceipts = NUM, repayments = NUM, garnished = NUM, disbursements = NUM,
  depositPayouts = NUM, guarantees = NUM, grantsPaid = NUM, writtenOff = NUM,
  -- WP3 reducer: opening cash, arrears receipts (collection and payout credits), early-withdrawal
  -- principal kept by the bank and forfeited deposits of eliminated players (memo, not cash).
  opening = NUM, arrearsPaid = NUM, forfeited = NUM,
})

local ROOT = rec({
  schema = INT, configFingerprint = STR, speedScale = NUM, lastProcessedTurn = INT,
  suspended = BOOL, suspendReason = STR,
  era = rec({ eraType = STR, U = NUM, previousU = NUM, previousUntilTurn = INT }),
  nextIDs = rec({
    loan = INT, lot = INT, deposit = INT, freeze = INT, entitlement = INT,
    grant = INT, subsidy = INT, movement = INT, event = INT,
  }),
  sentOnce = arr(STR, nil, true),
  players = arr(PLAYER, "playerID"),
  loans = arr(LOAN, "loanID"),
  lots = arr(rec({
    lotID = INT, loanID = INT, playerID = INT, dueTurn = INT,
    principal = NUM, interest = NUM, fees = NUM, firstFeeTurn = INT,
  }), "lotID"),
  deposits = arr(rec({
    depositID = INT, playerID = INT, principal = NUM, returnFraction = NUM, termTurns = INT,
    openTurn = INT, maturityTurn = INT, accruedReturn = NUM,
    status = enum("ACTIVE", "MATURED", "WITHDRAWN", "FORFEITED"),
  }), "depositID"),
  freezes = arr(rec({
    freezeID = INT, targetID = INT, mode = enum("COALITION", "PRESIDENT"), requesterID = INT,
    members = arr(INT, nil, true), placedTurn = INT,
  }), "freezeID"),
  recovery = arr(rec({
    entitlementID = INT, victimID = INT, eventKey = STR, qualifyingTurn = INT, expiryTurn = INT,
    claimedLoanID = INT, status = enum("OPEN", "CLAIMED", "EXPIRED"),
  }), "entitlementID"),
  grants = arr(rec({
    grantID = INT, playerID = INT, eraType = STR, requestTurn = INT, amount = NUM,
    milestone = MILESTONE_REQUEST,
    status = enum("PENDING_MILESTONE", "AWAITING_CASH", "PAID", "EXPIRED"),
  }), "grantID"),
  subsidies = arr(rec({
    subsidyID = INT, playerID = INT, turn = INT,
    kind = enum("FORGIVENESS", "RELIEF", "GRANT"), amount = NUM,
  }), "subsidyID"),
  president = rec({ playerID = INT, sinceTurn = INT }),
  bank = rec({
    cash = NUM, cap = NUM, refillPerTurn = NUM, receivables = NUM, depositLiabilities = NUM,
    lentThisTurn = NUM,
    lentPreviousTurn = arr(rec({ playerID = INT, amount = NUM })),
    lentCurrent = arr(rec({ playerID = INT, amount = NUM })), -- disbursed since the last boundary
    totals = TOTALS,
    ledger = arr(rec({
      movementID = INT, turn = INT, eventID = INT, purpose = STR, playerID = INT,
      loanID = INT, depositID = INT, grantID = INT, amount = NUM,
    }), "movementID"),
  }),
  growth = DATA,
  offers = arr(DATA),
})

local function check(spec, value, path)
  local kind = spec.k
  if kind == "int" then
    if not finite(value) or value ~= math.floor(value) then return path .. " must be an integer" end
  elseif kind == "num" then
    if not finite(value) then return path .. " must be a finite number" end
  elseif kind == "bool" then
    if type(value) ~= "boolean" then return path .. " must be a boolean" end
  elseif kind == "str" then
    if type(value) ~= "string" then return path .. " must be a string" end
  elseif kind == "scalar" then
    if type(value) ~= "string" and not finite(value) then return path .. " must be a string or finite number" end
  elseif kind == "enum" then
    if type(value) ~= "string" or not spec.set[value] then return path .. " has an unknown value" end
  elseif kind == "data" then
    if type(value) ~= "table" then return path .. " must be a table" end
    local ok, err = pcall(copyValue, value, {})
    if not ok then return path .. ": " .. tostring(err) end
  elseif kind == "rec" then
    if type(value) ~= "table" then return path .. " must be a table" end
    for _, name in ipairs(spec.names) do
      if value[name] == nil then return path .. "." .. name .. " is missing" end
      local reason = check(spec.fields[name], value[name], path .. "." .. name)
      if reason then return reason end
    end
    for _, key in ipairs(sortedKeys(value)) do
      if spec.fields[key] == nil then return path .. "." .. tostring(key) .. " is not a schema field" end
    end
  elseif kind == "arr" then
    if type(value) ~= "table" then return path .. " must be an array" end
    local n, count = #value, 0
    for _ in next, value do count = count + 1 end
    if count ~= n then return path .. " must be a dense array" end
    for i = 1, n do
      local reason = check(spec.item, value[i], path .. "[" .. i .. "]")
      if reason then return reason end
    end
    for i = 2, n do
      local a, b = value[i - 1], value[i]
      if spec.idKey then a, b = a[spec.idKey], b[spec.idKey] end
      if spec.idKey or spec.ascending then
        if not (a < b) then return path .. " must be strictly ascending" end
      end
    end
    if spec.idKey then
      -- Entity IDs are positive; player IDs are engine slots and start at 0.
      local floor = spec.idKey == "playerID" and 0 or 1
      for i = 1, n do
        if value[i][spec.idKey] < floor then return path .. "[" .. i .. "]." .. spec.idKey .. " is below its minimum" end
      end
    end
  end
  return nil
end

function S.Validate(state, config)
  config = config or WBL_CONFIG
  if type(state) ~= "table" then return false, "state must be a table" end
  local ok, reason = pcall(check, ROOT, state, "state")
  if not ok then return false, "validation error: " .. tostring(reason) end
  if reason then return false, reason end
  if state.schema ~= config.state.schema then
    return false, "state.schema " .. state.schema .. " does not match " .. config.state.schema
  end
  return true, ""
end

-- ---------------------------------------------------------------- constructors

function S.NewPlayer(playerID)
  return {
    playerID = playerID, nonce = 0,
    lastResult = { nonce = 0, kind = "", ok = false, reason = "" },
    tier = "", pendingTier = "", pendingCount = 0, rating = "",
    arrearsTurns = 0, inDefault = false, defaultTurn = 0, scarUntilTurn = 0,
    penaltyLevel = { tier = "", stage = 0 },
    debtReliefUsed = false,
    relief = { status = "NONE", milestone = { kind = "NONE", target = "", cityID = 0 }, deadlineTurn = 0 },
    lastGrantEra = "", eligibleCapital = 0, eligibleShare = 0, shareReachedTurn = 0,
    presidentConfirmCount = 0, presidentTurnsThisEra = 0, presidentEraType = "",
    eraScorePaidEra = "", envoyProgressTurns = 0, aidCarry = 0,
    unpaid = { favor = 0, eraScore = 0, merchantPoints = 0, envoys = 0 },
  }
end

function S.New(config, turn, opts)
  config = config or WBL_CONFIG
  opts = opts or {}
  assert(finite(turn) and turn == math.floor(turn), "turn must be an integer")
  local U = opts.U or 0
  return {
    schema = config.state.schema,
    configFingerprint = opts.configFingerprint or "",
    speedScale = opts.speedScale or 1,
    lastProcessedTurn = turn - 1,
    suspended = false, suspendReason = "",
    era = { eraType = opts.eraType or "", U = U, previousU = U, previousUntilTurn = 0 },
    nextIDs = { loan = 1, lot = 1, deposit = 1, freeze = 1, entitlement = 1, grant = 1, subsidy = 1, movement = 1, event = 1 },
    sentOnce = {},
    players = {}, loans = {}, lots = {}, deposits = {}, freezes = {}, recovery = {}, grants = {}, subsidies = {},
    president = { playerID = -1, sinceTurn = 0 },
    bank = {
      cash = 0, cap = 0, refillPerTurn = 0, receivables = 0, depositLiabilities = 0, lentThisTurn = 0,
      lentPreviousTurn = {}, lentCurrent = {},
      totals = {
        refill = 0, depositReceipts = 0, repayments = 0, garnished = 0, disbursements = 0,
        depositPayouts = 0, guarantees = 0, grantsPaid = 0, writtenOff = 0,
        opening = 0, arrearsPaid = 0, forfeited = 0,
      },
      ledger = {},
    },
    growth = {},
    offers = {},
  }
end

-- ---------------------------------------------------------------- string codec

local function quote(text)
  local escaped = string.gsub(text, '[%c"\\]', function(char)
    return string.format("\\%03d", string.byte(char))
  end)
  return '"' .. escaped .. '"'
end

local function write(value, out, seen)
  local kind = type(value)
  if kind == "number" then
    if not finite(value) then error("non-finite number", 0) end
    out[#out + 1] = string.format("%.17g", value)
  elseif kind == "boolean" then
    out[#out + 1] = value and "T" or "F"
  elseif kind == "string" then
    out[#out + 1] = quote(value)
  elseif kind == "table" then
    if seen[value] then error("cyclic table", 0) end
    seen[value] = true
    local keys = sortedKeys(value)
    local isArray = true
    for index, key in ipairs(keys) do
      if key ~= index then isArray = false break end
    end
    if isArray then
      out[#out + 1] = "["
      for index = 1, #keys do
        if index > 1 then out[#out + 1] = "," end
        write(value[index], out, seen)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      for index, key in ipairs(keys) do
        if type(key) ~= "string" then error("non-sequence numeric table key", 0) end
        if index > 1 then out[#out + 1] = "," end
        out[#out + 1] = quote(key)
        out[#out + 1] = ":"
        write(value[key], out, seen)
      end
      out[#out + 1] = "}"
    end
    seen[value] = nil
  else
    error("unsupported value type " .. kind, 0)
  end
end

function S.CanonicalString(state)
  local out = {}
  write(state, out, {})
  return table.concat(out)
end

local function parse(text)
  local pos = 1
  local function fail(message) error("parse error at " .. pos .. ": " .. message, 0) end
  local function peek() return string.sub(text, pos, pos) end
  local function readString()
    local pieces = {}
    while true do
      local stop = string.find(text, '[\\"]', pos)
      if not stop then fail("unterminated string") end
      pieces[#pieces + 1] = string.sub(text, pos, stop - 1)
      pos = stop
      if peek() == '"' then
        pos = pos + 1
        return table.concat(pieces)
      end
      local digits = string.match(text, "^\\(%d%d%d)", pos)
      if not digits then fail("bad escape") end
      pieces[#pieces + 1] = string.char(tonumber(digits))
      pos = pos + 1 + #digits
    end
  end
  local value
  function value()
    local char = peek()
    if char == '"' then
      pos = pos + 1
      return readString()
    elseif char == "T" then
      pos = pos + 1
      return true
    elseif char == "F" then
      pos = pos + 1
      return false
    elseif char == "[" then
      pos = pos + 1
      local list, count = {}, 0
      if peek() == "]" then
        pos = pos + 1
        return list
      end
      while true do
        count = count + 1
        list[count] = value()
        local sep = peek()
        pos = pos + 1
        if sep == "]" then return list end
        if sep ~= "," then fail("expected , or ]") end
      end
    elseif char == "{" then
      pos = pos + 1
      local map = {}
      if peek() == "}" then
        pos = pos + 1
        return map
      end
      while true do
        if peek() ~= '"' then fail("expected key") end
        pos = pos + 1
        local key = readString()
        if map[key] ~= nil then fail("duplicate key") end
        if peek() ~= ":" then fail("expected :") end
        pos = pos + 1
        map[key] = value()
        local sep = peek()
        pos = pos + 1
        if sep == "}" then return map end
        if sep ~= "," then fail("expected , or }") end
      end
    end
    local token = string.match(text, "^[%+%-]?%d[%d%.eE%+%-]*", pos)
    if not token then fail("unexpected character") end
    local number = tonumber(token)
    if not finite(number) then fail("bad number") end
    pos = pos + #token
    return number
  end
  local result = value()
  if pos <= #text then fail("trailing characters") end
  return result
end

-- ---------------------------------------------------------------- codec

local function useString(config)
  return config.features.statePersistenceVerified == false
    and config.state.stringCodecWhenUnverified == true
end

function S.Encode(state, config)
  config = config or WBL_CONFIG
  local ok, reason = S.Validate(state, config)
  if not ok then return nil, reason end
  if useString(config) then return STRING_PREFIX .. S.CanonicalString(state) end
  return S.Copy(state)
end

local function suspended(config, reason)
  local state = S.New(config, 0)
  state.suspended = true
  state.suspendReason = reason
  return state, "SUSPENDED", reason
end

function S.Decode(raw, config)
  config = config or WBL_CONFIG
  if raw == nil then return S.New(config, 0), "NEW", "" end
  local data = raw
  if type(raw) == "string" then
    if string.sub(raw, 1, #STRING_PREFIX) ~= STRING_PREFIX then return suspended(config, "MALFORMED_STRING") end
    local ok, parsed = pcall(parse, string.sub(raw, #STRING_PREFIX + 1))
    if not ok or type(parsed) ~= "table" then return suspended(config, "MALFORMED_STRING") end
    data = parsed
  elseif type(raw) ~= "table" then
    return suspended(config, "MALFORMED_TYPE")
  end
  local ok, copy = pcall(copyValue, data, {})
  if not ok then return suspended(config, "MALFORMED_DATA") end
  local schema = copy.schema
  if not finite(schema) or schema ~= math.floor(schema) then return suspended(config, "MALFORMED_SCHEMA") end
  local target = config.state.schema
  if schema > target then return suspended(config, "FUTURE_SCHEMA") end
  local migrated = false
  while schema < target do
    local migrate = S.MIGRATIONS[schema]
    if type(migrate) ~= "function" then return suspended(config, "NO_MIGRATION") end
    local done, result = pcall(migrate, copy)
    if not done or type(result) ~= "table" or result.schema ~= schema + 1 then
      return suspended(config, "MIGRATION_FAILED")
    end
    copy, schema, migrated = result, schema + 1, true
  end
  local valid, reason = S.Validate(copy, config)
  if not valid then return suspended(config, "INVALID:" .. reason) end
  return copy, migrated and "MIGRATED" or "OK", ""
end

-- ---------------------------------------------------------------- maintenance

function S.Prune(state, turn, config, subsidyMinTurn)
  config = config or WBL_CONFIG
  local out = S.Copy(state)
  local oldest = turn - config.state.ledgerRetentionTurns + 1
  local ledger = {}
  for _, movement in ipairs(out.bank.ledger) do
    if movement.turn >= oldest then ledger[#ledger + 1] = movement end
  end
  out.bank.ledger = ledger
  if subsidyMinTurn ~= nil then
    local subsidies = {}
    for _, subsidy in ipairs(out.subsidies) do
      if subsidy.turn >= subsidyMinTurn then subsidies[#subsidies + 1] = subsidy end
    end
    out.subsidies = subsidies
  end
  return out
end

function S.Checksum(state, config)
  config = config or WBL_CONFIG
  local text = S.CanonicalString(state)
  local modulus = config.state.checksumModulus
  local multipliers = config.state.checksumMultipliers
  local h1, h2 = 0, 0
  for index = 1, #text do
    local byte = string.byte(text, index)
    h1 = (h1 * multipliers[1] + byte) % modulus
    h2 = (h2 * multipliers[2] + byte) % modulus
  end
  return string.format("%d:%.0f:%.0f", #text, h1, h2)
end
