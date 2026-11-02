-- S10 state persistence probe (dev only). Pure Lua: no engine calls. The caller injects a store with
-- get(key) / set(key, value) so the same code serves gameplay (Game:SetProperty/GetProperty) and the
-- read-only UI context (get only). It stores a production-shaped table plus a precision vector, a
-- checksum, and can rebuild the expected payload from (turn, runID) to detect lossy storage after a
-- same-session save/reload.
-- TODO: when WBL/Scripts/WBL_State.lua exists, switch Checksum to WBL_STATE.Checksum (and Encode/Decode
-- for the string-codec comparison); this local helper is a stand-in that is not the production codec.
WBL_SPIKE_STATE = {}
local M = WBL_SPIKE_STATE

M.KEY = "WBL_SPIKE_STATE_DEEP"
M.SECTIONS = { "players", "bank", "growth", "nextIDs", "sentOnce", "vector", "ints", "sparse", "empty", "text" }

local MAX_DEPTH = 16
local MOD_A, MULT_A = 2147483647, 31
local MOD_B, MULT_B = 65521, 131

local function Text(value)
  return (string.gsub(tostring(value), "[\r\n]", " "))
end

local function KeyLess(a, b)
  if type(a) == type(b) then return a < b end
  return type(a) < type(b)
end

local function Keys(value)
  local keys = {}
  for key in next, value do keys[#keys + 1] = key end
  table.sort(keys, KeyLess)
  return keys
end

-- Deterministic text form: sorted keys, "%.17g" numbers (round-trip exact for doubles).
local function Canonical(value, depth, out)
  local kind = type(value)
  if kind == "number" then
    out[#out + 1] = string.format("n%.17g", value)
  elseif kind == "string" then
    out[#out + 1] = string.format("s%q", value)
  elseif kind == "boolean" then
    out[#out + 1] = value and "T" or "F"
  elseif kind == "nil" then
    out[#out + 1] = "Z"
  elseif kind == "table" then
    if depth > MAX_DEPTH then
      out[#out + 1] = "<deep>"
      return
    end
    out[#out + 1] = "{"
    for _, key in ipairs(Keys(value)) do
      Canonical(key, depth + 1, out)
      out[#out + 1] = "="
      Canonical(value[key], depth + 1, out)
      out[#out + 1] = ";"
    end
    out[#out + 1] = "}"
  else
    out[#out + 1] = "<" .. kind .. ">"
  end
end

function M.Canonical(value)
  local out = {}
  Canonical(value, 0, out)
  return table.concat(out)
end

-- Two polynomial rolling hashes with small moduli keep every product below 2^53 in Lua 5.1 doubles.
function M.Checksum(value)
  local text = M.Canonical(value)
  local a, b = 0, 0
  for index = 1, #text do
    local byte = string.byte(text, index)
    a = (a * MULT_A + byte) % MOD_A
    b = (b * MULT_B + byte) % MOD_B
  end
  return string.format("%08x%04x:%d", a, b, #text)
end

-- Deep equality with the first differing path; numbers compare exactly (==), never within a tolerance.
function M.Compare(expected, actual, path)
  path = path or "$"
  if type(expected) ~= type(actual) then
    return false, path, "type:" .. type(expected) .. "~=" .. type(actual)
  end
  if type(expected) == "number" then
    if expected == actual then return true end
    return false, path, string.format("%.17g~=%.17g", expected, actual)
  end
  if type(expected) ~= "table" then
    if expected == actual then return true end
    return false, path, Text(expected) .. "~=" .. Text(actual)
  end
  for _, key in ipairs(Keys(expected)) do
    local ok, where, detail = M.Compare(expected[key], actual[key], path .. "." .. tostring(key))
    if not ok then return false, where, detail end
  end
  for _, key in ipairs(Keys(actual)) do
    if expected[key] == nil then return false, path .. "." .. tostring(key), "unexpected_key" end
  end
  return true
end

-- Production-shaped payload: ordered arrays of tables, nested arrays, string-keyed maps, scalars.
function M.Fixture(turn, runID)
  local third = 1 / 3
  local players = {}
  for id = 0, 1 do
    local loans = {}
    for loanID = 1, 2 do
      local schedule = {}
      for step = 1, 3 do
        schedule[#schedule + 1] = { turn = turn + step, principal = 100.1 * step, interest = third * step, paid = false }
      end
      loans[#loans + 1] = { id = id * 2 + loanID, principal = 1000.1 * loanID, rate = 0.1, term = 30, schedule = schedule, tags = { "a", "b" } }
    end
    players[#players + 1] = { id = id, cash = 12.5 + id, rating = "A", scar = 0, loans = loans, flags = { true, false, true } }
  end
  return {
    schema = 1, lastProcessedTurn = turn, runID = runID,
    players = players,
    bank = { cash = 300.1, cap = 900 },
    growth = { ema = 0.1, history = { { turn = turn, value = third }, { turn = turn + 1, value = 0.1 + 0.2 } } },
    nextIDs = { loan = 3, lot = 1 },
    sentOnce = { ["warn:1"] = true, ["milestone:2"] = true },
    vector = { 0.1, third, 2 * third, 1e-9, 0.1 + 0.2, 123456789.12345678, 1e300, 1e-300, -0.5, 0 },
    ints = { 2147483647, 2147483648, 4294967296, 9007199254740991, 9007199254740992 },
    sparse = { [1] = "first", [3] = "third", [10] = "tenth" },
    empty = {},
    text = { "plain", "line\nbreak", "quote\"and\\slash", "caf\195\169" },
  }
end

function M.Wrap(payload)
  return { checksum = M.Checksum(payload), payload = payload }
end

-- Reads the stored wrapper and reports integrity. Safe in any context: it only calls store.get.
function M.Inspect(store, report)
  local wrapper = store.get(M.KEY)
  local result = { present = type(wrapper) == "table" and type(wrapper.payload) == "table" }
  if not result.present then return result end
  result.stored = wrapper.checksum
  result.computed = M.Checksum(wrapper.payload)
  result.checksumOK = result.stored == result.computed
  result.turn = wrapper.payload.lastProcessedTurn
  result.runID = wrapper.payload.runID
  local expected = M.Fixture(result.turn, result.runID)
  result.rebuildOK, result.mismatch, result.detail = M.Compare(expected, wrapper.payload)
  result.sections = {}
  if report then
    for _, name in ipairs(M.SECTIONS) do
      local ok, where, detail = M.Compare(expected[name], wrapper.payload[name], name)
      result.sections[#result.sections + 1] = { name = name, ok = ok, path = where, detail = detail }
    end
  end
  return result
end

function M.Write(store, turn, runID)
  local wrapper = M.Wrap(M.Fixture(turn, runID))
  store.set(M.KEY, wrapper)
  return wrapper
end

local function Verdict(result)
  if not result.present then return "PENDING" end
  return (result.checksumOK and result.rebuildOK) and "PASS" or "FAIL"
end

function M.Describe(result)
  if not result.present then return "present:false" end
  return "checksum:" .. result.computed .. ",stored:" .. Text(result.stored) .. ",turn:" .. Text(result.turn) ..
    ",checksumOK:" .. tostring(result.checksumOK) .. ",rebuildOK:" .. tostring(result.rebuildOK)
end

-- Production codec probe. WBL_STATE comes from the synced dev copy of WBL/Scripts/WBL_State.lua; both of
-- its codecs are exercised in turn because which one production ships depends on this spike.
M.PRODUCTION_KEYS = { table = "WBL_SPIKE_STATE_PROD_TABLE", string = "WBL_SPIKE_STATE_PROD_STRING" }
M.PRODUCTION_MODES = { "table", "string" }

local function ProductionState(turn, config)
  local third = 1 / 3
  local state = WBL_STATE.New(config, turn, { speedScale = third, eraType = "ERA_ANCIENT", U = 0.1, configFingerprint = "spike" })
  for id = 0, 1 do
    local player = WBL_STATE.NewPlayer(id)
    player.rating = "A"
    player.eligibleCapital = 0.1 * (id + 1)
    player.eligibleShare = third
    player.aidCarry = 1e-9
    state.players[#state.players + 1] = player
  end
  state.loans[1] = {
    loanID = 1, playerID = 0, product = "ORDINARY", entitlementID = 0, lineageID = 1, parentLoanID = 0,
    originTurn = turn, originTier = "DEVELOPING", principal = 1000.1, valueRatio = 0.1, nominalRate = third,
    growth = 0.01, earlyRepayInterestFraction = 0.5, paymentTurns = 30, graceTurns = 3, preferredStep = 0,
    liquidityExempt = false, installments = 30, installmentsPaid = 0, nextDueTurn = turn + 4,
    scheduledPrincipal = 1000.1, futureInterest = 333.33333333333337, overduePrincipal = 0, overdueInterest = 0,
    arrearsFees = 0, missedCount = 0, everMissed = false, restructured = false, milestoneUsed = false,
    promotionUsed = false,
    milestone = { kind = "NONE", target = "", cityID = 0, halfwayTurn = 0, status = "NONE", fraction = 0 },
    status = "ACTIVE",
  }
  state.lots[1] = { lotID = 1, loanID = 1, playerID = 0, dueTurn = turn + 4, principal = 33.4, interest = third, fees = 1e-9, firstFeeTurn = turn + 5 }
  state.bank.cash = 300.1
  state.bank.cap = 900
  state.bank.ledger[1] = { movementID = 1, turn = turn, eventID = 1, purpose = "LOAN", playerID = 0, loanID = 1, depositID = 0, grantID = 0, amount = 0.1 + 0.2 }
  state.growth = { ema = 0.1, history = { { turn = turn, value = third } } }
  state.sentOnce = { "milestone:1", "warn:2" }
  return state
end

-- Encodes a fresh production state under each codec and reads each back through the store.
function M.ProductionWrite(store, turn, config)
  local state = ProductionState(turn, config)
  local expected = WBL_STATE.Checksum(state, config)
  local written = {}
  for _, mode in ipairs(M.PRODUCTION_MODES) do
    local copy = WBL_STATE.Copy(config)
    copy.features.statePersistenceVerified = mode == "table"
    copy.state.stringCodecWhenUnverified = mode == "string"
    local encoded, reason = WBL_STATE.Encode(state, copy)
    if encoded == nil then
      written[#written + 1] = { mode = mode, expected = expected, error = Text(reason) }
    else
      store.set(M.PRODUCTION_KEYS[mode], encoded)
      written[#written + 1] = { mode = mode, expected = expected }
    end
  end
  return written
end

-- Reads each codec's stored value back, decodes it and compares against the rebuilt expectation.
function M.ProductionObserve(store, config)
  local results = {}
  for _, mode in ipairs(M.PRODUCTION_MODES) do
    local raw = store.get(M.PRODUCTION_KEYS[mode])
    local result = { mode = mode, present = raw ~= nil, kind = type(raw) }
    if result.present then
      local decoded, status, reason = WBL_STATE.Decode(raw, config)
      result.status, result.reason = status, reason
      if status == "OK" then
        result.checksum = WBL_STATE.Checksum(decoded, config)
        result.expected = WBL_STATE.Checksum(ProductionState(decoded.lastProcessedTurn + 1, config), config)
        result.ok = result.checksum == result.expected
      else
        result.ok = false
      end
    end
    results[#results + 1] = result
  end
  return results
end

local function LogProduction(results, logfn, note)
  for _, result in ipairs(results) do
    local verdict = (not result.present) and "PENDING" or (result.ok and "PASS" or "FAIL")
    logfn("S10", "production_" .. result.mode,
      "kind:" .. result.kind .. ",status:" .. Text(result.status) .. ",checksum:" .. Text(result.checksum) ..
      ",expected:" .. Text(result.expected),
      "decode_checksum_equals_rebuilt_state_checksum", verdict, note or Text(result.reason))
  end
end

function M.ProductionTurn(store, turn, config, logfn, note)
  if type(WBL_STATE) ~= "table" then
    logfn("S10", "production_codec", "WBL_STATE_unavailable", "synced_WBL_State_dev_copy_loaded", "PENDING")
    return
  end
  local ok, err = pcall(function() M.ProductionWrite(store, turn, config) end)
  if not ok then
    logfn("S10", "production_write", Text(err), "encode_and_store_both_codecs", "FAIL")
    return
  end
  LogProduction(M.ProductionObserve(store, config), logfn, note)
end

-- Click-time probe: write, read back, one line per payload section, then the production codec.
function M.Run(store, turn, runID, logfn, config)
  M.Write(store, turn, runID)
  local result = M.Inspect(store, true)
  if not result.present then
    logfn("S10", "deep_roundtrip", "present:false", "production_shaped_table_readable", "FAIL")
  else
    for _, section in ipairs(result.sections) do
      logfn("S10", "deep_" .. section.name, section.ok and "exact" or (section.path .. ":" .. Text(section.detail)),
        "exact_roundtrip_through_Game_property", section.ok and "PASS" or "FAIL")
    end
    logfn("S10", "state_checksum", M.Describe(result), "stored_equals_computed_equals_rebuilt_fixture",
      Verdict(result), "same_session_only_save_reload_still_pending")
  end
  M.ProductionTurn(store, turn, config, logfn, "same_session_only_save_reload_still_pending")
  return result
end

-- Per-turn write-and-verify: compare these lines before a save and after loading it.
function M.Turn(store, turn, runID, logfn, config)
  M.Write(store, turn, runID)
  local result = M.Inspect(store, false)
  logfn("S10", "state_checksum", M.Describe(result), "stored_equals_computed_equals_rebuilt_fixture",
    Verdict(result), result.present and (result.rebuildOK and "same_checksum_expected_after_reload_of_this_turn" or Text(result.mismatch) .. ":" .. Text(result.detail)) or nil)
  M.ProductionTurn(store, turn, config, logfn)
  return result
end

-- Read-only check for load time or another context (UI): never writes.
function M.Observe(store)
  local result = M.Inspect(store, false)
  return result, Verdict(result)
end

M.Verdict = Verdict
