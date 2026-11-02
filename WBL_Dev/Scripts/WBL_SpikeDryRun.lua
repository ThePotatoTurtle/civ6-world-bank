-- S13 bank dry run (WP9b part 2, decision 33). Dev only.
-- Runs the EXACT production pipeline in memory: WBL_SNAPSHOT.Build(state) -> WBL_REDUCER.Turn(state,
-- snapshot, config) on a dev-only state that lives under its own property keys (STATE_KEY, RUN_KEY), so
-- the production WBL_STATE property is never read or written. Effects are logged (kind, player, amount,
-- expectedBefore) and NEVER applied: this file calls no WBL_EFFECTS function and no engine write; the
-- caller injects store.get/store.set for the two dev keys. A request dry run builds TAKE_LOAN for the
-- local human from the published offers (smallest request) through WBL_REDUCER.Request and logs
-- ok/reason/effects, again without applying anything.
-- Purpose: show a real game's snapshot completeness, phase log, invariants and price/offer plausibility
-- before the bank is allowed to move gold. Fake-engine tests are logic only; live behavior stays PENDING.
--
-- Log format (through the caller's logFor(run) function):
--   [SPIKE S13] run= turn= player= variant=dryrun_* actual= expected= PASS|FAIL|PENDING|RAW
-- PASS needs a complete snapshot, reducer reason OK and invariants ok; an incomplete snapshot or a reducer
-- no-op is PENDING; an invariant violation or reducer error is FAIL (a real bug, not missing evidence).
-- Timeline: Begin on the button turn T (fresh dev state, lastProcessedTurn = T-1), then one Turn call on
-- each OnGameTurnStarted for spikes.dryRunTurns following turns.
--
-- Single player, local human only; the caller (WBL_Spikes.lua) also refuses multiplayer.
WBL_SPIKE_DRYRUN = {}
local M = WBL_SPIKE_DRYRUN

M.STATE_KEY = "WBL_DEV_DRYRUN_STATE"
M.RUN_KEY = "WBL_DEV_DRYRUN_RUN"
M.SPIKE = "S13"

local function Text(value)
  return (string.gsub(tostring(value), "[\r\n]", " "))
end

local function Read(fn)
  local ok, value = pcall(fn)
  if ok then return value, nil end
  return nil, tostring(value)
end

local function Number(value)
  if type(value) ~= "number" then return Text(value) end
  return string.format("%.6g", value)
end

-- "k=v,k=v" over a scalar record, keys sorted (no pairs: gameplay include graph rule).
local function Fields(record, skip)
  local keys = {}
  local key = next(record)
  while key ~= nil do
    if key ~= skip then keys[#keys + 1] = key end
    key = next(record, key)
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, name in ipairs(keys) do
    local value = record[name]
    if type(value) ~= "table" then parts[#parts + 1] = Text(name) .. "=" .. Number(value) end
  end
  return table.concat(parts, ",")
end

local function FindBy(list, field, value)
  if type(list) ~= "table" then return nil end
  for _, item in ipairs(list) do
    if item[field] == value then return item end
  end
  return nil
end

local function Detail(result)
  if result.detail ~= nil and result.detail ~= "" then return Text(result.detail) end
  return nil
end

-- ------------------------------------------------------------------ persistence (dev keys only)

-- The dry-run state must never share the production key.
local function KeysSeparate(config)
  local production = type(config.state) == "table" and config.state.propertyKey or nil
  return production ~= M.STATE_KEY and production ~= M.RUN_KEY
end

local function SaveState(store, state, config)
  local encoded, reason = WBL_STATE.Encode(state, config)
  if encoded == nil then return false, "ENCODE:" .. Text(reason) end
  store.set(M.STATE_KEY, encoded)
  return true, ""
end

local function LoadState(store, config)
  local raw = store.get(M.STATE_KEY)
  if raw == nil then return nil, "STATE_MISSING" end
  local state, status, reason = WBL_STATE.Decode(raw, config)
  if status == "SUSPENDED" then return nil, "STATE_" .. Text(reason) end
  return state, ""
end

function M.Run(store)
  return store.get(M.RUN_KEY)
end

-- A run is active until its last following turn has been processed.
function M.Active(store)
  local run = store.get(M.RUN_KEY)
  return type(run) == "table" and run.finished ~= true
end

-- ------------------------------------------------------------------ logging pieces

local function LogSnapshot(log, snapshot)
  local complete = type(snapshot) == "table" and snapshot.complete == true
  local majors = type(snapshot) == "table" and type(snapshot.majors) == "table" and #snapshot.majors or 0
  log(M.SPIKE, "dryrun_snapshot", "complete:" .. tostring(complete) .. ",majors:" .. majors,
    "complete_snapshot", complete and "PASS" or "PENDING")
  if type(snapshot) == "table" and not complete then
    for _, reason in ipairs(snapshot.incomplete or {}) do
      log(M.SPIKE, "dryrun_incomplete_reason", Text(reason), "no_incomplete_reasons", "PENDING")
    end
  end
  return complete
end

local function LogPhases(log, result)
  for _, entry in ipairs(result.phaseLog or {}) do
    log(M.SPIKE, "dryrun_phase_" .. Text(entry.phase), Fields(entry, "phase"), "reducer_phase_log", "RAW")
  end
end

local function EffectText(index, effect)
  return "index=" .. index .. ",kind=" .. Text(effect.kind) .. ",player=" .. Text(effect.playerID) ..
    ",amount=" .. Number(effect.amount) .. ",expectedBefore=" .. Number(effect.expectedBefore)
end

local function LogEffects(log, effects)
  log(M.SPIKE, "dryrun_effect_count", #effects, "effects_logged_never_applied", "RAW")
  for index, effect in ipairs(effects) do
    log(M.SPIKE, "dryrun_effect", EffectText(index, effect), "never_applied", "RAW")
  end
end

local function LogOffers(log, state, playerID)
  local offer = FindBy(state.offers, "playerID", playerID)
  if offer == nil then
    log(M.SPIKE, "dryrun_offers", "none", "published_offers_for_local_player", "PENDING")
    return nil
  end
  log(M.SPIKE, "dryrun_offers",
    "tier=" .. Text(offer.tier) .. ",rating=" .. Text(offer.rating) .. ",liquidity=" .. Text(offer.liquidityTier) ..
    ",U=" .. Number(offer.U) .. ",pool=" .. Number(offer.pool) .. ",limit=" .. Number(offer.limit) ..
    ",availableDraw=" .. Number(offer.availableDraw) .. ",growth=" .. Number(offer.growth) ..
    ",blocked=" .. Text(offer.blockedReason),
    "published_offers_for_local_player", "RAW")
  for _, product in ipairs(offer.products or {}) do
    log(M.SPIKE, "dryrun_offer_" .. Text(product.product),
      "available=" .. tostring(product.available) .. ",reason=" .. Text(product.reason) ..
      ",maxAmount=" .. Number(product.maxAmount) .. ",quotedV=" .. Number(product.quotedV) ..
      ",terms=" .. #(product.terms or {}),
      "published_offers_for_local_player", "RAW")
  end
  return offer
end

-- The smallest TAKE_LOAN the offers allow: first available product, 1 gold (or the whole limit when
-- smaller), first published term and that product's quotedV. Returns params or nil, reason.
local function BuildRequest(state, offer, playerID)
  local player = FindBy(state.players, "playerID", playerID)
  if player == nil then return nil, "PLAYER_UNKNOWN" end
  for _, product in ipairs(offer.products or {}) do
    local term = product.terms and product.terms[1]
    if product.available == true and term ~= nil and type(product.quotedV) == "number" then
      return {
        kind = "TAKE_LOAN", OnStart = "WBL_BankRequest", nonce = player.nonce, product = product.product,
        amount = math.min(1, product.maxAmount), termStandardTurns = term.termStandardTurns,
        quotedV = product.quotedV, milestoneKind = "NONE", milestoneTarget = "", milestoneCityID = 0,
      }, ""
    end
  end
  return nil, "NO_AVAILABLE_PRODUCT"
end

local function DryRequest(log, state, snapshot, offer, playerID, config)
  local params, why = BuildRequest(state, offer, playerID)
  if params == nil then
    log(M.SPIKE, "dryrun_request", "not_built:" .. why, "TAKE_LOAN_from_published_offers", "PENDING")
    return
  end
  -- The returned state is discarded: nothing from a dry request is kept or applied.
  local _, effects, result = WBL_REDUCER.Request(state, snapshot, playerID, params, config)
  local verdict = "PENDING"
  if result.ok == true then verdict = "PASS"
  elseif result.reason == "REDUCER_ERROR" then verdict = "FAIL" end
  log(M.SPIKE, "dryrun_request",
    "product=" .. params.product .. ",amount=" .. Number(params.amount) .. ",term=" .. Number(params.termStandardTurns) ..
    ",quotedV=" .. Number(params.quotedV) .. ",ok=" .. tostring(result.ok == true) .. ",reason=" .. Text(result.reason) ..
    ",effects=" .. #effects, "ok_true_effects_not_applied", verdict, Detail(result))
  for index, effect in ipairs(effects) do
    log(M.SPIKE, "dryrun_request_effect", EffectText(index, effect), "never_applied", "RAW")
  end
end

-- ------------------------------------------------------------------ one dry-run step

local function Step(store, run, config, log)
  local state, loadReason = LoadState(store, config)
  if state == nil then
    log(M.SPIKE, "dryrun_state", loadReason, "dev_state_readable", "PENDING")
    return
  end
  local snapshot, snapError = Read(function() return WBL_SNAPSHOT.Build(state, config) end)
  if snapshot == nil then
    log(M.SPIKE, "dryrun_snapshot", "error:" .. Text(snapError), "complete_snapshot", "FAIL")
    return
  end
  local complete = LogSnapshot(log, snapshot)
  local reduced, reduceError = Read(function()
    local nextState, effects, result = WBL_REDUCER.Turn(state, snapshot, config)
    return { state = nextState, effects = effects, result = result }
  end)
  if reduced == nil then
    log(M.SPIKE, "dryrun_turn", "error:" .. Text(reduceError), "reducer_ok", "FAIL")
    return
  end
  local nextState, effects, result = reduced.state, reduced.effects, reduced.result
  local reason = Text(result.reason)
  local verdict = "PENDING"
  if reason == "OK" and complete then verdict = "PASS"
  elseif reason == "REDUCER_ERROR" then verdict = "FAIL" end
  log(M.SPIKE, "dryrun_turn", "reason:" .. reason .. ",noop:" .. tostring(result.noop == true) ..
    ",effects:" .. #effects .. ",snapshotTurn:" .. Text(snapshot.turn), "reason_OK_effects_not_applied", verdict,
    Detail(result))
  LogPhases(log, result)
  LogEffects(log, effects)
  if reason ~= "OK" then
    log(M.SPIKE, "dryrun_invariants", "skipped", "reducer_advanced", "PENDING")
    return
  end
  local invariantsOK, invariantsReason = WBL_REDUCER.Invariants(nextState, config)
  local invariantVerdict = "FAIL"
  if invariantsOK then invariantVerdict = complete and "PASS" or "PENDING" end
  log(M.SPIKE, "dryrun_invariants", "ok:" .. tostring(invariantsOK) .. ",reason:" .. Text(invariantsReason),
    "ledger_receivable_liability_lot_checks_ok", invariantVerdict)
  log(M.SPIKE, "dryrun_checksum", WBL_STATE.Checksum(nextState, config) .. ",lastProcessedTurn:" ..
    Text(nextState.lastProcessedTurn), "state_checksum_for_replay_comparison", "RAW")
  local offer = LogOffers(log, nextState, run.playerID)
  if offer ~= nil and complete then
    DryRequest(log, nextState, snapshot, offer, run.playerID, config)
  elseif offer ~= nil then
    log(M.SPIKE, "dryrun_request", "skipped_incomplete_snapshot", "TAKE_LOAN_from_published_offers", "PENDING")
  end
  local saved, saveReason = SaveState(store, nextState, config)
  if not saved then log(M.SPIKE, "dryrun_state", saveReason, "dev_state_saved", "FAIL") end
end

local function Guarded(store, run, turn, config, logFor)
  local log = logFor(run)
  local ok, err = pcall(function() Step(store, run, config, log) end)
  if not ok then log(M.SPIKE, "dryrun_error", Text(err), "step_complete", "FAIL") end
  run.lastTurn = turn
  store.set(M.RUN_KEY, run)
end

-- ------------------------------------------------------------------ public

-- Button turn: fresh dev state, then the first step. Returns the run record, or nil and a reason.
function M.Begin(store, playerID, turn, config, logFor)
  if not KeysSeparate(config) then return nil, "KEY_CONFLICT" end
  local previous = store.get(M.RUN_KEY)
  if type(previous) == "table" and previous.finished ~= true then return nil, "ALREADY_ACTIVE" end
  local run = { runID = type(previous) == "table" and previous.runID + 1 or 1, playerID = playerID,
    startTurn = turn, lastTurn = turn - 1, remaining = config.spikes.dryRunTurns, finished = false,
    pass = 0, fail = 0, pending = 0 }
  local state = WBL_STATE.New(config, turn, { configFingerprint = WBL_STATE.Checksum(config, config) })
  local saved, reason = SaveState(store, state, config)
  if not saved then
    run.finished = true
    store.set(M.RUN_KEY, run)
    logFor(run)(M.SPIKE, "dryrun_begin", reason, "fresh_dev_state_saved", "FAIL")
    store.set(M.RUN_KEY, run)
    return nil, reason
  end
  logFor(run)(M.SPIKE, "dryrun_begin", "stateKey=" .. M.STATE_KEY .. ",steps=" .. (run.remaining + 1),
    "dev_state_separate_from_production_property", "RAW")
  Guarded(store, run, turn, config, logFor)
  return run, ""
end

-- OnGameTurnStarted hook. Returns true when it ran a step.
function M.Turn(store, turn, config, logFor)
  local run = store.get(M.RUN_KEY)
  if type(run) ~= "table" or run.finished == true then return false end
  if turn == run.lastTurn then return false end
  if turn < run.lastTurn then
    logFor(run)(M.SPIKE, "dryrun_rewind", "turn:" .. turn .. ",lastTurn:" .. run.lastTurn, "monotonic_turns", "PENDING")
    run.finished = true
    store.set(M.RUN_KEY, run)
    return false
  end
  run.remaining = run.remaining - 1
  Guarded(store, run, turn, config, logFor)
  if run.remaining <= 0 then
    run.finished = true
    store.set(M.RUN_KEY, run)
    logFor(run)(M.SPIKE, "dryrun_summary", "pass:" .. run.pass .. ",fail:" .. run.fail .. ",pending:" .. run.pending,
      "live_verdict_requires_review", "RAW")
  end
  return true
end

return WBL_SPIKE_DRYRUN
