-- WBL_Bank: World Bank Loans gameplay entry (PLAN.md "Production module map and contracts", WBL_Bank row).
-- Owns the turn hook, the synced request dispatcher, persistence and deferred notifications.
-- Data flow per job: WBL_SNAPSHOT.Build -> WBL_REDUCER.Turn/Request -> WBL_EFFECTS.Apply (notifications
-- deferred) -> Game:SetProperty(state.propertyKey, WBL_STATE.Encode(next)) -> WBL_EFFECTS.Notify.
--
-- Multiplayer determinism: every client must run identical code on identical synced inputs. This file
-- only runs from GameEvents: OnGameTurnStarted, and WBL_BankRequest, which the UI raises through
-- UI.RequestPlayerOperation(..., PlayerOperations.EXECUTE_SCRIPT, {OnStart = "WBL_BankRequest", ...}).
-- The shipped BlackDeathScenario uses that path "to call a script on the GameCore side through the ...
-- GameEvent on every client" (GAME/DLC/BlackDeathScenario/UI/BlackDeathScenario_PopupHandler.lua:10,
-- 15-28; handler registration GAME/DLC/BlackDeathScenario/Scripts/BlackDeathScenario.lua:66).
-- Gameplay graph rules: no local player, no pairs, no math.random, no asynchronous Events.
-- Live engine behavior, timing and multiplayer remain unverified (SPIKES S1, S10, S13).
-- Reload Config is dev-only (decision 13 is served by WBL_Dev); production never re-includes config.
include("WBL_Config");
include("WBL_Math");
include("WBL_State");
include("WBL_AIPolicy");
include("WBL_Reducer");
include("WBL_Snapshot");
include("WBL_Effects");

WBL_BANK = {}

-- Request parameters copied from the synced params table; everything else is ignored.
local PARAM_KEYS = { "kind", "nonce", "product", "amount", "termStandardTurns", "quotedV", "quotedAmount",
  "loanID", "depositID", "entitlementID", "targetID", "mode", "freezeID",
  "milestoneKind", "milestoneTarget", "milestoneCityID" }
-- Failed or gated-off rewards recorded in players[i].unpaid (features.recordFailedEffects).
local UNPAID_FIELD = { FAVOR = "favor", ERA_SCORE = "eraScore", MERCHANT_POINTS = "merchantPoints", ENVOY = "envoys" }
-- Request reason recorded when the reducer accepted a request but its effects could not be applied.
local EFFECT_FAILED = "EFFECT_FAILED"

-- Module state for this load. `locked` means the stored property must never be overwritten.
local bank = { state = nil, locked = false, lockReason = "", probeOK = false, fingerprint = "" }

local function Text(value)
  return (string.gsub(tostring(value), "[\r\n]", " "))
end

local function Read(fn)
  local ok, value = pcall(fn)
  if ok then return value, nil end
  return nil, tostring(value)
end

local function FindBy(list, field, value)
  if type(list) ~= "table" then return nil end
  for _, item in ipairs(list) do
    if item[field] == value then return item end
  end
  return nil
end

local function NonceOf(state, playerID)
  local player = type(state) == "table" and FindBy(state.players, "playerID", playerID) or nil
  return player and player.nonce or nil
end

local function ConfigFingerprint(config)
  local value = Read(function() return WBL_STATE.Checksum(config, config) end)
  return value or "unavailable"
end

local function Checksum(state, config)
  local value = Read(function() return WBL_STATE.Checksum(state, config) end)
  return value or "unavailable"
end

local function Suspended()
  return bank.locked or not bank.probeOK
end

local function SuspendReason()
  if bank.locked then return bank.lockReason end
  return "CORE_CAPABILITY_MISSING"
end

-- ------------------------------------------------------------------ startup

local function RunProbe(config)
  local report, err = Read(function() return WBL_EFFECTS.Probe(config) end)
  bank.probeOK = type(report) == "table" and report.core == true
  if not bank.probeOK then
    print("[WBL] FAIL bank suspended: core capability missing (Game property and treasury gold)" ..
      (err and (" error=" .. Text(err)) or "") .. "; turns and requests are skipped until a later probe passes")
  end
  return bank.probeOK
end

local function LoadState(config)
  local raw, readError = Read(function() return Game:GetProperty(config.state.propertyKey) end)
  if readError ~= nil then
    bank.state = WBL_STATE.New(config, 0, { configFingerprint = bank.fingerprint })
    bank.locked, bank.lockReason = true, "PROPERTY_READ_FAILED"
    print("[WBL] FAIL state read error=" .. Text(readError) .. "; bank suspended, property left untouched")
    return
  end
  local state, status, reason = WBL_STATE.Decode(raw, config)
  bank.state = state
  if status == "SUSPENDED" then
    -- FUTURE_SCHEMA, MALFORMED_* and every other suspension: never overwrite what is stored.
    bank.locked, bank.lockReason = true, reason
    print("[WBL] FAIL state status=SUSPENDED reason=" .. Text(reason) .. "; bank suspended, property left untouched")
    return
  end
  if state.suspended then
    bank.locked, bank.lockReason = true, state.suspendReason
  end
  if status == "NEW" then
    state.configFingerprint = bank.fingerprint
  elseif state.configFingerprint ~= bank.fingerprint then
    print("[WBL] config fingerprint changed stored=" .. Text(state.configFingerprint) .. " current=" ..
      bank.fingerprint .. "; locked contract terms are kept")
    state.configFingerprint = bank.fingerprint
  end
  print("[WBL] state status=" .. status .. " lastProcessedTurn=" .. Text(state.lastProcessedTurn) ..
    " suspended=" .. tostring(bank.locked) .. " checksum=" .. Checksum(state, config))
end

-- ------------------------------------------------------------------ logging

local function PhaseLog(turn, result, config)
  if type(config.bank) ~= "table" or config.bank.phaseLogging ~= true then return end
  for _, entry in ipairs(result.phaseLog or {}) do
    local keys = {}
    local key = next(entry)
    while key ~= nil do
      if key ~= "phase" then keys[#keys + 1] = key end
      key = next(entry, key)
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = { "[WBL PHASE] turn=" .. Text(turn) .. " phase=" .. Text(entry.phase) }
    for _, name in ipairs(keys) do parts[#parts + 1] = Text(name) .. "=" .. Text(entry[name]) end
    print(table.concat(parts, " "))
  end
end

-- ------------------------------------------------------------------ apply and commit

-- Adjust the state to commit for effects that did not apply (non-required failures and gated kinds).
local function AdjustForFailures(nextState, original, effects, entries, config)
  for index, entry in ipairs(entries) do
    local effect = effects[index]
    if type(effect) == "table" and not entry.applied and entry.status ~= "DEFERRED" then
      local player = FindBy(nextState.players, "playerID", effect.playerID)
      if player ~= nil and effect.kind == "PENALTY_LEVEL" then
        -- Restore the previous level so the reducer emits this target again next boundary.
        local before = FindBy(original.players, "playerID", effect.playerID)
        local level = before and before.penaltyLevel or { tier = "", stage = 0 }
        player.penaltyLevel = { tier = level.tier, stage = level.stage }
        print("[WBL] penalty_level_retry player=" .. Text(effect.playerID) .. " target=" .. Text(effect.tier) ..
          ":" .. Text(effect.stage) .. " status=" .. Text(entry.status) .. " kept=" .. Text(level.tier) .. ":" .. Text(level.stage))
      elseif player ~= nil and config.features.recordFailedEffects and UNPAID_FIELD[effect.kind] ~= nil
          and type(effect.amount) == "number" and effect.amount > 0 then
        local field = UNPAID_FIELD[effect.kind]
        player.unpaid[field] = player.unpaid[field] + effect.amount
        print("[WBL] unpaid_recorded player=" .. Text(effect.playerID) .. " kind=" .. effect.kind ..
          " amount=" .. Text(effect.amount) .. " status=" .. Text(entry.status))
      end
    end
  end
  return nextState
end

-- Validate, apply effects (notifications deferred). Returns {ok, revalidate, reason, entries}.
local function ApplyEffects(nextState, effects, snapshot, config)
  local valid, reason = WBL_STATE.Validate(nextState, config)
  if not valid then return { ok = false, revalidate = false, reason = "INVALID_STATE:" .. Text(reason), entries = {} } end
  if #effects > 0 and (type(snapshot) ~= "table" or snapshot.complete ~= true) then
    -- expectedBefore is only trustworthy from a complete snapshot (failed reads default to 0).
    return { ok = false, revalidate = false, reason = "INCOMPLETE_SNAPSHOT_EFFECTS", entries = {} }
  end
  local result = WBL_EFFECTS.Apply(effects, snapshot, config, { deferNotify = true })
  return { ok = result.ok == true, revalidate = result.revalidate == true, reason = result.reason,
    entries = result.entries or {} }
end

local function Commit(state, config, label)
  local encoded, reason = WBL_STATE.Encode(state, config)
  if encoded == nil then return false, "ENCODE:" .. Text(reason) end
  local ok, err = pcall(function() Game:SetProperty(config.state.propertyKey, encoded) end)
  if not ok then return false, "SET_PROPERTY:" .. Text(err) end
  bank.state = state
  print("[WBL COMMIT] job=" .. label .. " lastProcessedTurn=" .. Text(state.lastProcessedTurn) ..
    " checksum=" .. Checksum(state, config))
  return true, ""
end

-- One job: build -> reduce -> apply; on revalidate rebuild and rereduce once from the ORIGINAL state.
-- job = {label, build(), reduce(snapshot) -> next, effects, result, unchanged(next, effects, result)}
-- Returns {status = COMMITTED | UNCHANGED | FAILED | REDUCER_ERROR, result, reason}.
local function Execute(job, config)
  local original = bank.state
  local snapshot = job.build()
  local nextState, effects, result = job.reduce(snapshot)
  local attempt = nil
  for round = 1, 2 do
    if result.reason == "REDUCER_ERROR" then
      print("[WBL] FAIL job=" .. job.label .. " REDUCER_ERROR detail=" .. Text(result.detail) .. "; nothing committed")
      return { status = "REDUCER_ERROR", result = result, reason = "REDUCER_ERROR" }
    end
    if job.unchanged(nextState, effects, result) then
      return { status = "UNCHANGED", result = result, reason = result.reason, snapshot = snapshot }
    end
    attempt = ApplyEffects(nextState, effects, snapshot, config)
    if attempt.ok or not attempt.revalidate or round == 2 then break end
    print("[WBL] revalidate job=" .. job.label .. " reason=" .. Text(attempt.reason) .. "; rebuilding snapshot")
    snapshot = job.build()
    nextState, effects, result = job.reduce(snapshot)
  end
  if not attempt.ok then
    print("[WBL] FAIL job=" .. job.label .. " reason=" .. Text(attempt.reason) .. "; nothing committed")
    return { status = "FAILED", result = result, reason = attempt.reason, snapshot = snapshot }
  end
  local state = AdjustForFailures(nextState, original, effects, attempt.entries, config)
  local committed, commitError = Commit(state, config, job.label)
  if not committed then
    local report = WBL_EFFECTS.Compensate(attempt.entries, config)
    print("[WBL] FAIL job=" .. job.label .. " commit=" .. commitError .. " compensated=" .. tostring(report.ok) ..
      "; nothing committed")
    return { status = "FAILED", result = result, reason = commitError, snapshot = snapshot }
  end
  WBL_EFFECTS.Notify(effects, config)
  return { status = "COMMITTED", result = result, reason = result.reason, snapshot = snapshot,
    effects = #effects }
end

-- ------------------------------------------------------------------ turn hook

local function ProcessTurn(eventTurn)
  local config = WBL_CONFIG
  local turn = Game.GetCurrentGameTurn()
  if not bank.locked and not bank.probeOK then RunProbe(config) end
  if Suspended() then
    print("[WBL TURN] turn=" .. Text(turn) .. " skipped reason=BANK_SUSPENDED detail=" .. Text(SuspendReason()))
    return
  end
  local last = bank.state.lastProcessedTurn
  if turn <= last then
    print("[WBL TURN] turn=" .. Text(turn) .. " ignored reason=" .. (turn == last and "DUPLICATE_TURN" or "REWIND") ..
      " lastProcessedTurn=" .. Text(last))
    return
  end
  local original = bank.state
  local outcome = Execute({
    label = "turn",
    build = function() return WBL_SNAPSHOT.Build(original, config) end,
    reduce = function(snapshot) return WBL_REDUCER.Turn(original, snapshot, config) end,
    unchanged = function(_, _, result) return result.noop == true end,
  }, config)
  if outcome.status == "COMMITTED" then PhaseLog(turn, outcome.result, config) end
  print("[WBL TURN] turn=" .. Text(turn) .. " event=" .. Text(eventTurn) .. " status=" .. outcome.status ..
    " reason=" .. Text(outcome.reason) .. " effects=" .. Text(outcome.effects or 0))
end

local function OnGameTurnStarted(eventTurn)
  local ok, err = pcall(ProcessTurn, eventTurn)
  if not ok then print("[WBL] FAIL turn handler error=" .. Text(err) .. "; nothing committed") end
end

-- ------------------------------------------------------------------ request handler

local function CopyParams(params)
  local copy = {}
  if type(params) ~= "table" then return copy end
  for _, key in ipairs(PARAM_KEYS) do
    local value = params[key]
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then copy[key] = value end
  end
  return copy
end

-- The reducer accepted a request whose effects failed (or errored): consume the nonce and record the outcome only.
local function RejectionRecord(original, playerID, params, reason)
  local state = WBL_STATE.Copy(original)
  local player = FindBy(state.players, "playerID", playerID)
  if player == nil or params.nonce ~= player.nonce then return nil end
  player.nonce = player.nonce + 1
  player.lastResult = { nonce = params.nonce, kind = type(params.kind) == "string" and params.kind or "",
    ok = false, reason = reason or EFFECT_FAILED }
  local offer = FindBy(state.offers, "playerID", playerID)
  if offer ~= nil then offer.nonce = player.nonce end
  return state
end

local function LogRequest(playerID, params, ok, reason, extra)
  print("[WBL REQUEST] player=" .. Text(playerID) .. " kind=" .. Text(params.kind) .. " ok=" .. tostring(ok) ..
    " reason=" .. Text(reason) .. " nonce=" .. Text(params.nonce) .. (extra or ""))
end

local function ProcessRequest(ePlayer, rawParams)
  local config = WBL_CONFIG
  local params = CopyParams(rawParams)
  if Suspended() then
    LogRequest(ePlayer, params, false, "BANK_SUSPENDED", " detail=" .. Text(SuspendReason()))
    return
  end
  local extra = {}
  if type(params.milestoneKind) == "string" and params.milestoneKind ~= "" and params.milestoneKind ~= "NONE" then
    extra[#extra + 1] = { playerID = ePlayer, kind = params.milestoneKind,
      target = params.milestoneTarget == nil and "" or params.milestoneTarget,
      cityID = params.milestoneCityID == nil and 0 or params.milestoneCityID }
  end
  local original = bank.state
  local outcome = Execute({
    label = "request",
    build = function() return WBL_SNAPSHOT.Build(original, config, { extraMilestones = extra }) end,
    reduce = function(snapshot) return WBL_REDUCER.Request(original, snapshot, ePlayer, params, config) end,
    unchanged = function(nextState, effects, _)
      return #effects == 0 and NonceOf(nextState, ePlayer) == NonceOf(original, ePlayer)
    end,
  }, config)
  local result = outcome.result or {}
  if outcome.status == "FAILED" then
    local record = RejectionRecord(original, ePlayer, params)
    local committed = record ~= nil and Commit(record, config, "request_rejection")
    LogRequest(ePlayer, params, false, EFFECT_FAILED, " detail=" .. Text(outcome.reason) ..
      " committed=" .. tostring(committed == true))
    return
  end
  local detail = ""
  if outcome.status == "REDUCER_ERROR" then
    -- Unstick the panel: consume the nonce from the ORIGINAL state and record the rejection.
    local record = RejectionRecord(original, ePlayer, params, "REDUCER_ERROR")
    local committed = record ~= nil and Commit(record, config, "request_rejection")
    detail = " detail=" .. Text(result.detail) .. " committed=" .. tostring(committed == true)
  end
  LogRequest(ePlayer, params, result.ok == true, result.reason, " status=" .. outcome.status .. detail)
end

local function OnBankRequest(ePlayer, params)
  local ok, err = pcall(ProcessRequest, ePlayer, params)
  if not ok then print("[WBL] FAIL request handler player=" .. Text(ePlayer) .. " error=" .. Text(err) .. "; nothing committed") end
end

-- ------------------------------------------------------------------ load

local function Initialize()
  local config = WBL_CONFIG
  bank.fingerprint = ConfigFingerprint(config)
  print("[WBL] World Bank Loans " .. Text(config.version) .. " config " .. bank.fingerprint)
  RunProbe(config)
  LoadState(config)
  -- Synced round hook: GAME/DLC/PiratesScenario/Scripts/PiratesScenario_StartScript.lua:1614.
  GameEvents.OnGameTurnStarted.Add(OnGameTurnStarted)
  -- Custom EXECUTE_SCRIPT OnStart event: GAME/DLC/BlackDeathScenario/Scripts/BlackDeathScenario.lua:66.
  GameEvents.WBL_BankRequest.Add(OnBankRequest)
end

-- Test and dev visibility only; nothing outside this file mutates the bank through these.
WBL_BANK.OnGameTurnStarted = OnGameTurnStarted
WBL_BANK.OnBankRequest = OnBankRequest
WBL_BANK.Status = function()
  return { state = bank.state, locked = bank.locked, lockReason = bank.lockReason, probeOK = bank.probeOK,
    fingerprint = bank.fingerprint }
end

Initialize()
