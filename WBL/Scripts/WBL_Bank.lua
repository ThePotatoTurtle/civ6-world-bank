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
include("WBL_Probes");

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

-- ------------------------------------------------------------------ verbose diagnostics
-- bank.verboseLogging (off in production, on in the MP test build). Read-only: every line describes what a job
-- saw or did and never changes its inputs or outputs. Every helper is pcall'd, so a logging error is reported
-- as "[WBL DIAG]" and the job carries on. Dumps use WBL_STATE.CanonicalString (sorted keys, %.17g numbers), so
-- a later offline replay can rebuild the exact snapshot, effects and state of each job.

local function Verbose(config)
  return type(config.bank) == "table" and config.bank.verboseLogging == true
end

local function Diag(label, fn)
  local ok, err = pcall(fn)
  if not ok then print("[WBL DIAG] " .. Text(label) .. " error=" .. Text(err)) end
end

-- Split long text over numbered lines: "[WBL DUMP] turn=T kind=K part=i/n <text>".
local function Dump(config, turn, kind, text)
  local size = config.bank.dumpChunkSize
  local body = Text(text)
  local total = math.max(1, math.ceil(string.len(body) / size))
  for part = 1, total do
    local first = (part - 1) * size + 1
    print("[WBL DUMP] turn=" .. Text(turn) .. " kind=" .. Text(kind) .. " part=" .. part .. "/" .. total .. " " ..
      string.sub(body, first, first + size - 1))
  end
end

local function DumpValue(config, turn, kind, value)
  if not Verbose(config) then return end
  Diag("dump " .. Text(kind), function() Dump(config, turn, kind, WBL_STATE.CanonicalString(value)) end)
end

local function Sum(...)
  local total = 0
  for _, value in ipairs({ ... }) do
    if type(value) == "number" then total = total + value end
  end
  return total
end

-- One readable line per major in the snapshot.
local function LogSnapshot(config, label, snapshot)
  if not Verbose(config) or type(snapshot) ~= "table" then return end
  Diag("snapshot " .. Text(label), function()
    print("[WBL SNAP] job=" .. Text(label) .. " turn=" .. Text(snapshot.turn) .. " complete=" .. Text(snapshot.complete) ..
      " era=" .. Text(snapshot.eraType) .. " speedScale=" .. Text(snapshot.speedScale) .. " majors=" ..
      Text(type(snapshot.majors) == "table" and #snapshot.majors or "nil") .. " incomplete=" ..
      Text(type(snapshot.incomplete) == "table" and table.concat(snapshot.incomplete, ",") or ""))
    for _, m in ipairs(snapshot.majors or {}) do
      print("[WBL SNAP] job=" .. Text(label) .. " turn=" .. Text(snapshot.turn) .. " player=" .. Text(m.playerID) ..
        " human=" .. Text(m.isHuman) .. " civ=" .. Text(m.civType) .. " difficulty=" .. Text(m.difficultyType) ..
        " treasury=" .. Text(m.treasury) .. " netGPT=" .. Text(m.netGPT) .. " favor=" .. Text(m.favor) ..
        " production=" .. Text(m.production) .. " techs=" .. Text(m.techs) .. " civics=" .. Text(m.civics) ..
        " cities=" .. Text(m.cityCount) .. " wars=" .. Text(type(m.wars) == "table" and table.concat(m.wars, ",") or "") ..
        " allies=" .. Text(type(m.allies) == "table" and table.concat(m.allies, ",") or ""))
    end
  end)
end

-- One readable line per bank player plus one for the bank itself, from a committed state.
local function LogSummary(config, label, state)
  if not Verbose(config) or type(state) ~= "table" then return end
  Diag("summary " .. Text(label), function()
    local turn = state.lastProcessedTurn
    for _, p in ipairs(state.players or {}) do
      local loans, owed, arrears, deposits, principal, accrued = 0, 0, 0, 0, 0, 0
      for _, loan in ipairs(state.loans or {}) do
        if loan.playerID == p.playerID and loan.status == "ACTIVE" then
          loans = loans + 1
          owed = owed + Sum(loan.scheduledPrincipal, loan.futureInterest, loan.overduePrincipal, loan.overdueInterest,
            loan.arrearsFees)
          arrears = arrears + Sum(loan.overduePrincipal, loan.overdueInterest, loan.arrearsFees)
        end
      end
      for _, deposit in ipairs(state.deposits or {}) do
        if deposit.playerID == p.playerID and deposit.status == "ACTIVE" then
          deposits = deposits + 1
          principal = principal + Sum(deposit.principal)
          accrued = accrued + Sum(deposit.accruedReturn)
        end
      end
      local level = type(p.penaltyLevel) == "table" and p.penaltyLevel or {}
      local unpaid = type(p.unpaid) == "table" and p.unpaid or {}
      local last = type(p.lastResult) == "table" and p.lastResult or {}
      print("[WBL SUMMARY] job=" .. Text(label) .. " turn=" .. Text(turn) .. " player=" .. Text(p.playerID) ..
        " tier=" .. Text(p.tier) .. " rating=" .. Text(p.rating) .. " arrearsTurns=" .. Text(p.arrearsTurns) ..
        " inDefault=" .. Text(p.inDefault) .. " defaultTurn=" .. Text(p.defaultTurn) .. " penalty=" ..
        Text(level.tier) .. ":" .. Text(level.stage) .. " scarUntil=" .. Text(p.scarUntilTurn) ..
        " loans=" .. loans .. " owed=" .. Text(owed) .. " arrears=" .. Text(arrears) ..
        " deposits=" .. deposits .. " depositPrincipal=" .. Text(principal) .. " accrued=" .. Text(accrued) ..
        " E=" .. Text(p.eligibleCapital) .. " share=" .. Text(p.eligibleShare) .. " relief=" ..
        Text(type(p.relief) == "table" and p.relief.status or "") .. " unpaid=" .. Text(unpaid.favor) .. "/" ..
        Text(unpaid.eraScore) .. "/" .. Text(unpaid.merchantPoints) .. "/" .. Text(unpaid.envoys) ..
        " nonce=" .. Text(p.nonce) .. " last=" .. Text(last.kind) .. ":" .. Text(last.ok) .. ":" .. Text(last.reason))
    end
    local b = type(state.bank) == "table" and state.bank or {}
    local president = type(state.president) == "table" and state.president or {}
    print("[WBL SUMMARY] job=" .. Text(label) .. " turn=" .. Text(turn) .. " bank cash=" .. Text(b.cash) ..
      " cap=" .. Text(b.cap) .. " refill=" .. Text(b.refillPerTurn) .. " receivables=" .. Text(b.receivables) ..
      " depositLiabilities=" .. Text(b.depositLiabilities) .. " lentThisTurn=" .. Text(b.lentThisTurn) ..
      " era=" .. Text(type(state.era) == "table" and state.era.eraType or "") .. " U=" ..
      Text(type(state.era) == "table" and state.era.U or "") .. " president=" .. Text(president.playerID) ..
      " loans=" .. Text(type(state.loans) == "table" and #state.loans or 0) .. " deposits=" ..
      Text(type(state.deposits) == "table" and #state.deposits or 0) .. " freezes=" ..
      Text(type(state.freezes) == "table" and #state.freezes or 0) .. " grants=" ..
      Text(type(state.grants) == "table" and #state.grants or 0))
  end)
end

-- What one reduction produced: result fields, then the full effects list and result.
local function LogReduction(config, label, turn, effects, result)
  if not Verbose(config) then return end
  Diag("reduction " .. Text(label), function()
    print("[WBL RESULT] job=" .. Text(label) .. " turn=" .. Text(turn) .. " ok=" .. Text(result.ok) .. " reason=" ..
      Text(result.reason) .. " noop=" .. Text(result.noop) .. " effects=" .. Text(type(effects) == "table" and #effects or 0))
  end)
  DumpValue(config, turn, label .. "_effects", effects or {})
  DumpValue(config, turn, label .. "_result", result or {})
end

local function Contains(list, value)
  if type(list) ~= "table" then return false end
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
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
  LogSummary(config, "load", state)
  if Verbose(config) and type(raw) == "string" then
    Diag("dump loaded state", function() Dump(config, state.lastProcessedTurn, "state_load", raw) end)
  else
    DumpValue(config, state.lastProcessedTurn, "state_load", state)
  end
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
  LogSummary(config, label, state)
  if Verbose(config) and type(encoded) == "string" then
    Diag("dump state", function() Dump(config, state.lastProcessedTurn, "state_" .. label, encoded) end)
  elseif Verbose(config) then
    DumpValue(config, state.lastProcessedTurn, "state_" .. label, state)
  end
  return true, ""
end

-- One job: build -> reduce -> apply; on revalidate rebuild and rereduce once from the ORIGINAL state.
-- job = {label, build(), reduce(snapshot) -> next, effects, result, unchanged(next, effects, result)}
-- Returns {status = COMMITTED | UNCHANGED | FAILED | REDUCER_ERROR, result, reason}.
local function Execute(job, config)
  local original = bank.state
  local snapshot = job.build()
  local nextState, effects, result = job.reduce(snapshot)
  local turn = type(snapshot) == "table" and snapshot.turn or nil
  LogSnapshot(config, job.label, snapshot)
  DumpValue(config, turn, job.label .. "_snapshot", snapshot)
  LogReduction(config, job.label, turn, effects, result)
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
    LogSnapshot(config, job.label .. "_retry", snapshot)
    DumpValue(config, turn, job.label .. "_retry_snapshot", snapshot)
    LogReduction(config, job.label .. "_retry", turn, effects, result)
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

-- turnOverride: an earlier game turn still unprocessed (decision 41 fallback); nil = the current turn.
local function ProcessTurn(eventTurn, turnOverride)
  local config = WBL_CONFIG
  local turn = turnOverride or Game.GetCurrentGameTurn()
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
    build = function() return WBL_SNAPSHOT.Build(original, config, { turn = turnOverride }) end,
    reduce = function(snapshot) return WBL_REDUCER.Turn(original, snapshot, config) end,
    unchanged = function(_, _, result) return result.noop == true end,
  }, config)
  if outcome.status == "COMMITTED" then PhaseLog(turn, outcome.result, config) end
  print("[WBL TURN] turn=" .. Text(turn) .. " event=" .. Text(eventTurn) .. " status=" .. outcome.status ..
    " reason=" .. Text(outcome.reason) .. " effects=" .. Text(outcome.effects or 0))
end

-- Decision 41: the turn job waits for every living major's income. One round per game turn: the majors
-- alive at its start, and those whose PlayerTurnStartComplete has fired. Module state only: every client
-- sees the same synced events in the same order, and nothing here is saved.
local round = nil
-- Consecutive rounds that needed the fallback. Two in a row means some major never completes its turn start in
-- this game mode, so requests would be refused all turn: logged loudly for the stage 7 MP check.
local fallbacks = 0

local function AliveMajorIDs()
  local ids = {}
  local ok, list = pcall(function() return PlayerManager.GetAliveMajors() end)
  if not ok or type(list) ~= "table" then return ids end
  for _, player in ipairs(list) do
    local okID, id = pcall(function() return player:GetID() end)
    if okID and type(id) == "number" then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

local function NewRound(turn, fromLoad)
  return { turn = turn, waiting = AliveMajorIDs(), done = {}, fromLoad = fromLoad == true }
end

-- Every major still alive that the round waits for has completed its turn start.
local function RoundComplete(r)
  local alive = AliveMajorIDs()
  if #alive == 0 then return false end
  for _, id in ipairs(alive) do
    if Contains(r.waiting, id) and not Contains(r.done, id) then return false end
  end
  return true
end

-- Runs the job for `turn`; ProcessTurn's lastProcessedTurn guard turns a repeat into a logged no-op.
local function RunJob(turn, trigger, override)
  print("[WBL TURN] job turn=" .. Text(turn) .. " trigger=" .. Text(trigger))
  if Verbose(WBL_CONFIG) then
    -- Read-only timing and deal-gold lines before the job (WBL_Probes; decisions 36, 41 and 52).
    Diag("turn probes", function()
      WBL_PROBES.Timing("BankTurnJob", nil, turn)
      WBL_PROBES.TurnReads(turn)
    end)
  end
  local ok, err = pcall(ProcessTurn, turn, override and turn or nil)
  if not ok then print("[WBL] FAIL turn handler error=" .. Text(err) .. "; nothing committed") end
end

local function OnGameTurnStarted(eventTurn)
  local turn = Game.GetCurrentGameTurn()
  if WBL_CONFIG.features.collectAfterIncome ~= true then
    RunJob(turn, "round_start")
    return
  end
  -- Fallback (decision 41a): the previous round's last turn start never completed (elimination, a dropped
  -- player, a reload mid-round). Process that turn now, under its own number, before the new round.
  if round ~= nil and round.turn < turn and bank.state ~= nil and bank.state.lastProcessedTurn < round.turn then
    local missing = {}
    for _, id in ipairs(round.waiting) do
      if not Contains(round.done, id) then missing[#missing + 1] = id end
    end
    fallbacks = fallbacks + 1
    print("[WBL TURN] fallback turn=" .. Text(round.turn) .. " missing=" .. table.concat(missing, ",") ..
      " streak=" .. fallbacks)
    if fallbacks >= 2 then
      print("[WBL] WARN the turn job needed the fallback " .. fallbacks .. " rounds in a row; a major never completes " ..
        "its turn start (missing=" .. table.concat(missing, ",") .. ")")
    end
    RunJob(round.turn, "fallback", true)
  elseif round ~= nil and round.turn < turn then
    fallbacks = 0
  end
  round = NewRound(turn)
  print("[WBL TURN] round turn=" .. Text(turn) .. " waiting=" .. table.concat(round.waiting, ","))
  -- No majors read: nothing will complete the round, so run at once (the old timing).
  if #round.waiting == 0 then RunJob(turn, "no_majors") end
end

local function OnTurnStartComplete(playerID)
  if WBL_CONFIG.features.collectAfterIncome ~= true or round == nil then return end
  if Game.GetCurrentGameTurn() ~= round.turn then return end
  if not Contains(round.waiting, playerID) or Contains(round.done, playerID) then return end
  round.done[#round.done + 1] = playerID
  if RoundComplete(round) then RunJob(round.turn, "after_income") end
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
  if Verbose(config) then
    Diag("request received", function()
      local turn = Game.GetCurrentGameTurn()
      print("[WBL REQUEST] received player=" .. Text(ePlayer) .. " turn=" .. Text(turn) .. " kind=" .. Text(params.kind) ..
        " nonce=" .. Text(params.nonce) .. " stateNonce=" .. Text(NonceOf(bank.state, ePlayer)))
      DumpValue(config, turn, "request_params", params)
    end)
  end
  if Suspended() then
    LogRequest(ePlayer, params, false, "BANK_SUSPENDED", " detail=" .. Text(SuspendReason()))
    return
  end
  if Contains(config.features.disabledRequests, params.kind) then
    -- Turned off for this build (features.disabledRequests): consume the nonce so the panel unsticks.
    local record = RejectionRecord(bank.state, ePlayer, params, "CAPABILITY_PENDING")
    local committed = record ~= nil and Commit(record, config, "request_disabled")
    LogRequest(ePlayer, params, false, "CAPABILITY_PENDING", " detail=DISABLED_IN_BUILD committed=" ..
      tostring(committed == true))
    return
  end
  local now = Game.GetCurrentGameTurn()
  if config.features.collectAfterIncome == true and bank.state.lastProcessedTurn < now then
    if round ~= nil and round.turn == now and round.fromLoad and not Suspended() then
      -- Loaded mid-round: the turn starts that fired before the save won't fire again, so the first request runs
      -- the job (synced, so every client does the same) rather than refusing for the rest of the turn.
      RunJob(now, "after_load")
    end
    if bank.state.lastProcessedTurn < now then
      -- Decision 47: the bank hasn't run this turn's job yet; refuse, consuming the nonce, and change nothing else.
      local record = RejectionRecord(bank.state, ePlayer, params, "TURN_PENDING")
      local committed = record ~= nil and Commit(record, config, "request_turn_pending")
      LogRequest(ePlayer, params, false, "TURN_PENDING", " committed=" .. tostring(committed == true))
      return
    end
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

-- Verbose builds only: when each player's turn starts and finishes starting, against the bank's turn job.
local function OnPlayerTurnStarted(playerID)
  Diag("PlayerTurnStarted", function() WBL_PROBES.Timing("PlayerTurnStarted", playerID, Game.GetCurrentGameTurn()) end)
end

local function OnPlayerTurnStartComplete(playerID)
  Diag("PlayerTurnStartComplete", function()
    WBL_PROBES.Timing("PlayerTurnStartComplete", playerID, Game.GetCurrentGameTurn())
  end)
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
  print("[WBL] build=" .. Text(config.build) .. " verboseLogging=" .. tostring(Verbose(config)) .. " disabledRequests=" ..
    Text(type(config.features.disabledRequests) == "table" and table.concat(config.features.disabledRequests, ",") or ""))
  DumpValue(config, 0, "config", config)
  RunProbe(config)
  LoadState(config)
  -- Synced round hook: GAME/DLC/PiratesScenario/Scripts/PiratesScenario_StartScript.lua:1614.
  GameEvents.OnGameTurnStarted.Add(OnGameTurnStarted)
  -- Custom EXECUTE_SCRIPT OnStart event: GAME/DLC/BlackDeathScenario/Scripts/BlackDeathScenario.lua:66.
  GameEvents.WBL_BankRequest.Add(OnBankRequest)
  if Verbose(config) then
    -- Log only; the bank's state never depends on these (PolandScenario.lua:545, PiratesScenario_StartScript.lua:1621).
    GameEvents.PlayerTurnStarted.Add(OnPlayerTurnStarted)
    GameEvents.PlayerTurnStartComplete.Add(OnPlayerTurnStartComplete)
  end
  -- Decision 41: the job waits for every major's income (PiratesScenario_StartScript.lua:1621, handler at 1490).
  -- Registered after the log-only handler, so a player's timing line precedes the job it completes.
  GameEvents.PlayerTurnStartComplete.Add(OnTurnStartComplete)
  if config.features.collectAfterIncome == true and bank.state ~= nil then
    local now = Game.GetCurrentGameTurn()
    if type(now) == "number" and bank.state.lastProcessedTurn < now then round = NewRound(now, true) end
  end
end

-- Test and dev visibility only; nothing outside this file mutates the bank through these.
WBL_BANK.OnGameTurnStarted = OnGameTurnStarted
WBL_BANK.OnBankRequest = OnBankRequest
WBL_BANK.Status = function()
  return { state = bank.state, locked = bank.locked, lockReason = bank.lockReason, probeOK = bank.probeOK,
    fingerprint = bank.fingerprint }
end

Initialize()
