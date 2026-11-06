-- Effect adapter spikes S4/S9 (WP9b part 1, decision 33). Dev only.
-- Every engine write here goes through the EXACT production adapters (WBL_EFFECTS.Apply / Compensate /
-- Probe and WBL_SNAPSHOT.Build, synced from WBL/Scripts); the only engine calls in this file are
-- read-only diagnostics (city yield readings, plot flag readback) and the once-per-game guard.
-- Log format is the existing "[SPIKE Sx] run= turn= player= variant= actual= expected= RESULT"
-- through the caller's log function; variants are prefixed "adapter_" (S4E = S4 variants, S9E = S9
-- variants). Gold round trip is tagged S1 so it sits beside the existing S1 probe.
--
-- Single player, local human only; the caller (WBL_Spikes.lua) also refuses multiplayer.
-- Irreversible writes (Era Score, envoy, Merchant points if its reversal fails) are guarded once
-- per game and persisted BEFORE the call, like the existing direct grants: a one-time dev cost.
--
-- Sequencing with the existing S4 spike (WBL_SpikePlayerEffects.lua): that spike switches
-- Developed stage-2 modifiers on the human's capital at the button press, observes them at +1 and
-- removes them at +observationTurns. The adapter penalty (Developing stage 1) must not stack in the
-- same capital, so it starts at startTurn + observationTurns + 1, after S4 removal, and is also
-- deferred while any S4 flag reads 1. Timeline (T = button turn, N = observationTurns):
--   T      : probe, snapshot, gold, favor, compensation, era score, merchant, envoy, notify
--   T+N+1  : baseline readings, PENALTY_LEVEL DEVELOPING stage 1, immediate readings
--   T+N+2  : boundary readings, PENALTY_LEVEL stage 0 (clear), immediate readings
--   T+N+3  : cleared-boundary readings, summary
WBL_SPIKE_EFFECTS = {}
local M = WBL_SPIKE_EFFECTS
local GRANTS = "WBL_SPIKE_ADAPTER_GRANTS"
local PENALTY_TIER = "DEVELOPING"
local PENALTY_STAGE = 1
local MESSAGE_KEY = "LOC_WBL_NOTIFY_LOAN_TAKEN_MESSAGE"
local FORCED_KIND = "SPIKE_FORCED_UNKNOWN_KIND"
-- Turn stamped on adapter result logs for the immediate steps of the current run.
local snapshotTurn = 0

local function Read(fn)
  local ok, value = pcall(fn)
  if ok then return value, nil end
  return nil, tostring(value)
end

local function Finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function Text(value)
  return (string.gsub(tostring(value), "[\r\n]", " "))
end

local function Near(a, b, config)
  return Finite(a) and Finite(b) and math.abs(a - b) <= config.spikes.epsilon
end

-- Session A, 2026-11-03: GameConfiguration's multiplayer queries (cited only from UI scripts) did not
-- answer in gameplay, so a GameConfiguration-only guard rejected a single-player game. Fallback: exactly one
-- living human major means no other machine can run this turn. Mirrors WBL_Spikes.lua.
local function IsSinglePlayer()
  local ok, multiplayer, hotseat = pcall(function()
    return GameConfiguration.IsAnyMultiplayer(), GameConfiguration.IsHotseat()
  end)
  if ok and type(multiplayer) == "boolean" and type(hotseat) == "boolean" then
    multiplayer = multiplayer or hotseat
    return not multiplayer
  end
  local counted, humans = pcall(function()
    local count = 0
    for _, player in ipairs(PlayerManager.GetAliveMajors()) do
      if player:IsHuman() then count = count + 1 end
    end
    return count
  end)
  return counted and humans == 1
end

-- Counts results per adapter run (stored on the run record, scalars only) and forwards to the caller.
local function Tally(fx, log)
  return function(spike, variant, actual, expected, result, detail)
    if result == "PASS" then fx.pass = fx.pass + 1
    elseif result == "FAIL" then fx.fail = fx.fail + 1
    elseif result == "PENDING" then fx.pending = fx.pending + 1 end
    log(spike, variant, actual, expected, result, detail)
  end
end

local function EntryText(entry)
  if entry == nil then return "no_entry" end
  return "status:" .. Text(entry.status) .. ",reason:" .. Text(entry.reason) .. ",before:" .. Text(entry.before) ..
    ",after:" .. Text(entry.after) .. ",amount:" .. Text(entry.amount) .. ",clamped:" .. Text(entry.clamped) ..
    (entry.detail and (",detail:" .. Text(entry.detail)) or "")
end

-- Result for one adapter entry whose readback should equal expectedAfter (nil: no numeric claim).
-- Unavailable API in this context is PENDING (as the existing direct grants); a wrong readback is FAIL.
local function Judge(entry, expectedAfter, config)
  if entry == nil then return "FAIL" end
  local status = entry.status
  if status == "PENDING" or status == "SKIPPED" or status == "DEFERRED" then return "PENDING" end
  if status == "APPLIED" or status == "NOOP" then
    if expectedAfter == nil or entry.after == nil then return "PENDING" end
    return Near(entry.after, expectedAfter, config) and "PASS" or "FAIL"
  end
  local reason = entry.reason
  if reason == "CALL_FAILED" or reason == "ADAPTER_ERROR" or reason == "READ_FAILED" or reason == "READBACK_FAILED" then
    return "PENDING"
  end
  return "FAIL"
end

local function Step(say, name, fn)
  local ok, err = pcall(fn)
  if not ok then say("S4", "adapter_" .. name .. "_error", err, "no_error", "FAIL") end
  return ok
end

-- Persist-before-call guard, shared shape with WBL_SpikePlayerEffects.GrantGuard (own key).
local function Guard(playerID, label, spike, say)
  local completed = Game:GetProperty(GRANTS) or {}
  if type(completed) ~= "table" then
    say(spike, label .. "_guard", "invalid_saved_guard", "no_repeated_irreversible_writes", "PENDING")
    return false
  end
  local actorKey = tostring(playerID)
  local actor = completed[actorKey] or {}
  if type(actor) ~= "table" then
    say(spike, label .. "_guard", "invalid_actor_guard", "no_repeated_irreversible_writes", "PENDING")
    return false
  end
  if actor[label] then
    say(spike, label .. "_guard", "already_attempted", "no_repeated_irreversible_writes", "RAW")
    return false
  end
  actor[label] = true
  completed[actorKey] = actor
  Game:SetProperty(GRANTS, completed)
  return true
end

local function Apply(effects, snapshot, config)
  return WBL_EFFECTS.Apply(effects, snapshot, config)
end

-- strict: an incomplete snapshot yields no row, because failed reads default to zero in a partial row
-- and the money steps must never trust such a baseline.
local function MajorFacts(state, config, playerID, strict)
  local snapshot = WBL_SNAPSHOT.Build(state, config)
  if strict and not snapshot.complete then return nil, snapshot end
  for _, major in ipairs(snapshot.majors) do
    if major.playerID == playerID then return major, snapshot end
  end
  return nil, snapshot
end

local function Delta(config, name)
  local value = config.spikes[name]
  if not Finite(value) then error("invalid_spike_delta:" .. name) end
  return value
end

-- ------------------------------------------------------------------ readings

local function Capital(playerID)
  local player = Players[playerID]
  local cities = player:GetCities()
  return cities:GetCapitalCity()
end

-- Capital-city yield readings, same reads as the S4 Capture. Numbers go to fx; tooltips only to the log.
local function Readings(playerID, phase, say, expected)
  local city, err = Read(function() return Capital(playerID) end)
  if city == nil then
    say("S4", "adapter_penalty_" .. phase, err or "no_capital", "capital_city_readable", "PENDING")
    return nil
  end
  local reading = {}
  reading.amenities = Read(function() local growth = city:GetGrowth(); return growth:GetAmenities() end)
  reading.loyalty = Read(function() local identity = city:GetCulturalIdentity(); return identity:GetLoyaltyPerTurn() end)
  reading.production = Read(function() return city:GetYield(YieldTypes.PRODUCTION) end)
  reading.science = Read(function() return city:GetYield(YieldTypes.SCIENCE) end)
  say("S4", "adapter_penalty_" .. phase,
    "amenities:" .. Text(reading.amenities) .. ",production:" .. Text(reading.production) ..
    ",science:" .. Text(reading.science) .. ",loyalty:" .. Text(reading.loyalty), expected, "RAW")
  local productionTip = Read(function() return city:GetYieldToolTip(YieldTypes.PRODUCTION) end)
  local scienceTip = Read(function() return city:GetYieldToolTip(YieldTypes.SCIENCE) end)
  say("S4", "adapter_penalty_" .. phase .. "_production", productionTip, "raw_breakdown", "RAW")
  say("S4", "adapter_penalty_" .. phase .. "_science", scienceTip, "raw_breakdown", "RAW")
  return reading
end

local function Remember(fx, prefix, reading)
  fx[prefix .. "Amenities"] = reading and reading.amenities or nil
  fx[prefix .. "Production"] = reading and reading.production or nil
  fx[prefix .. "Science"] = reading and reading.science or nil
  fx[prefix .. "Loyalty"] = reading and reading.loyalty or nil
end

local function PenaltyFlag(plotIndex, key)
  return Read(function()
    local plot = Map.GetPlotByIndex(plotIndex)
    return plot:GetProperty(key)
  end)
end

-- True while any flag of the existing S4 fixture still reads 1 (its modifiers could be active).
local function S4Active(run)
  local effects = run.effects
  if type(effects) ~= "table" or type(effects.cases) ~= "table" then return false end
  for _, case in ipairs(effects.cases) do
    if case.flagKey and case.plotIndex ~= nil then
      local value = PenaltyFlag(case.plotIndex, case.flagKey)
      if value == 1 then return true end
    end
  end
  return false
end

local function PenaltyEntry(playerID, tier, stage, id)
  return { effectID = id, kind = "PENALTY_LEVEL", playerID = playerID, tier = tier, stage = stage, required = false }
end

local function ExpectedPenaltyText(config)
  local row = WBL_MATH.Penalties(PENALTY_TIER, "stage" .. PENALTY_STAGE, config)
  return "configured_" .. PENALTY_TIER .. "_stage" .. PENALTY_STAGE .. "_amenities:" .. Text(row.amenities) ..
    ",productionPercent:" .. Text(row.productionPercent) .. ",sciencePercent:" .. Text(row.sciencePercent) ..
    ",loyalty:" .. Text(row.loyalty)
end

-- ------------------------------------------------------------------ immediate steps

local function ProbeStep(say, config)
  local report = WBL_EFFECTS.Probe(config)
  for _, capability in ipairs(report.capabilities) do
    say("S4", "adapter_probe_" .. capability.name,
      "present:" .. Text(capability.present) .. ",attempt:" .. Text(capability.attempt) .. ",reason:" .. Text(capability.reason),
      "method_presence_only_not_behavior", capability.present and "RAW" or "PENDING")
  end
  say("S4", "adapter_probe_core", "core:" .. Text(report.core), "property_and_gold_present",
    report.core and "RAW" or "PENDING")
end

local function SnapshotStep(say, config, state, playerID)
  local major, snapshot = MajorFacts(state, config, playerID)
  local incomplete = snapshot.incomplete
  local first = type(incomplete) == "table" and incomplete[1] or nil
  say("S9", "adapter_snapshot",
    "complete:" .. Text(snapshot.complete) .. ",majors:" .. #snapshot.majors .. ",turn:" .. Text(snapshot.turn) ..
    ",era:" .. Text(snapshot.eraType) .. ",speedScale:" .. Text(snapshot.speedScale),
    "complete_true_with_a_row_for_the_human", snapshot.complete and major ~= nil and "PASS" or "PENDING", first)
  if major then
    say("S9", "adapter_snapshot_human",
      "treasury:" .. Text(major.treasury) .. ",netGPT:" .. Text(major.netGPT) .. ",favor:" .. Text(major.favor) ..
      ",production:" .. Text(major.production) .. ",cities:" .. Text(major.cityCount) .. ",techs:" .. Text(major.techs),
      "finite_scalars_from_production_reads", "RAW")
  end
  return major
end

-- Mirrors the existing S1 round trip (credit, debit clamped to cash, restore) through the adapter.
local function GoldStep(say, config, state, playerID)
  local major = MajorFacts(state, config, playerID, true)
  local before = major and major.treasury or nil
  local delta = Delta(config, "goldDelta")
  if not Finite(before) or before < config.spikes.goldSafetyReserve then
    say("S1", "adapter_gold_precondition", before, "snapshot_nonnegative_balance", "PENDING")
    return
  end
  local result = Apply({
    { effectID = "spike:gold:credit", kind = "GOLD", playerID = playerID, amount = delta, expectedBefore = before, required = true },
    { effectID = "spike:gold:clamped_debit", kind = "GOLD", playerID = playerID, amount = -(before + delta + delta),
      expectedBefore = before + delta, required = true },
    { effectID = "spike:gold:restore", kind = "GOLD", playerID = playerID, amount = before, expectedBefore = -delta, required = true }, -- running expectation: the clamped debit above leaves 0 live, which is -delta short of the assumed full debit
  }, { turn = snapshotTurn }, config)
  local credit, debit, restore = result.entries[1], result.entries[2], result.entries[3]
  -- Snapshot treasury vs the adapter's own live read: the production read paths agree.
  say("S1", "adapter_gold_snapshot_vs_apply_read", "snapshot:" .. Text(before) .. ",adapterBefore:" .. Text(credit and credit.before),
    "equal_within_epsilon", credit and Near(credit.before, before, config) and "PASS" or "FAIL")
  say("S1", "adapter_gold_credit", EntryText(credit), "after_equals_before_plus_delta:" .. Text(before + delta), Judge(credit, before + delta, config))
  local clampedOK = debit ~= nil and debit.clamped == true
  local clampedResult = Judge(debit, 0, config)
  if clampedResult == "PASS" and not clampedOK then clampedResult = "FAIL" end
  say("S1", "adapter_gold_clamped_debit", EntryText(debit), "clamped_true_and_balance_zero", clampedResult)
  say("S1", "adapter_gold_restore", EntryText(restore), "after_equals_original:" .. Text(before), Judge(restore, before, config))
  say("S1", "adapter_gold_batch", "ok:" .. Text(result.ok) .. ",reason:" .. Text(result.reason) ..
    ",compensation:" .. Text(result.compensation and result.compensation.ok), "ok_true_no_compensation",
    result.ok and "PASS" or "FAIL")
  local final = MajorFacts(state, config, playerID, true)
  say("S1", "adapter_gold_final_snapshot", final and final.treasury, before,
    final and (Near(final.treasury, before, config) and "PASS" or "FAIL") or "PENDING")
end

local function FavorStep(say, config, state, playerID)
  local major = MajorFacts(state, config, playerID, true)
  local before = major and major.favor or nil
  local delta = Delta(config, "favorDelta")
  if not Finite(before) then
    say("S4", "adapter_favor", before, "snapshot_favor_readable", "PENDING")
    return
  end
  local result = Apply({
    { effectID = "spike:favor:credit", kind = "FAVOR", playerID = playerID, amount = delta, expectedBefore = before, required = true },
    { effectID = "spike:favor:debit", kind = "FAVOR", playerID = playerID, amount = -delta, expectedBefore = before + delta, required = true },
  }, { turn = snapshotTurn }, config)
  local credit, debit = result.entries[1], result.entries[2]
  say("S4", "adapter_favor_credit", EntryText(credit), "after_equals_before_plus_delta:" .. Text(before + delta), Judge(credit, before + delta, config))
  say("S4", "adapter_favor_debit", EntryText(debit), "after_equals_original:" .. Text(before), Judge(debit, before, config))
  local final = MajorFacts(state, config, playerID, true)
  say("S4", "adapter_favor_restored_snapshot", final and final.favor, before,
    final and (Near(final.favor, before, config) and "PASS" or "FAIL") or "PENDING",
    "ok:" .. Text(result.ok) .. ",reason:" .. Text(result.reason))
end

-- A deliberately failing required effect after real FAVOR and GOLD credits: Apply must abort and its
-- internal Compensate must restore both. A second case calls WBL_EFFECTS.Compensate directly.
local function CompensationStep(say, config, state, playerID)
  local major = MajorFacts(state, config, playerID, true)
  if major == nil or not Finite(major.favor) or not Finite(major.treasury) then
    say("S4", "adapter_compensation", "snapshot_unavailable", "favor_and_treasury_readable", "PENDING")
    return
  end
  local favor, gold = major.favor, major.treasury
  local result = Apply({
    { effectID = "spike:comp:favor", kind = "FAVOR", playerID = playerID, amount = Delta(config, "favorDelta"), expectedBefore = favor, required = true },
    { effectID = "spike:comp:gold", kind = "GOLD", playerID = playerID, amount = Delta(config, "goldDelta"), expectedBefore = gold, required = true },
    { effectID = "spike:comp:forced_failure", kind = FORCED_KIND, playerID = playerID, required = true },
  }, { turn = snapshotTurn }, config)
  local applied = 0
  for _, entry in ipairs(result.entries) do
    if entry.status == "APPLIED" and (entry.kind == "FAVOR" or entry.kind == "GOLD") then applied = applied + 1 end
  end
  local compensation = result.compensation
  local reversed = compensation and #compensation.reversed or -1
  local final = MajorFacts(state, config, playerID, true)
  local restored = final ~= nil and Near(final.favor, favor, config) and Near(final.treasury, gold, config)
  say("S4", "adapter_compensation_abort",
    "ok:" .. Text(result.ok) .. ",reason:" .. Text(result.reason) .. ",applied:" .. applied .. ",reversed:" .. reversed ..
    ",compensationOk:" .. Text(compensation and compensation.ok) .. ",favorAfter:" .. Text(final and final.favor) ..
    ",goldAfter:" .. Text(final and final.treasury),
    "ok_false_REQUIRED_FAILED_all_applied_reversed_balances_restored",
    final == nil and "PENDING" or ((not result.ok and string.find(tostring(result.reason), "REQUIRED_FAILED", 1, true) == 1 and
      compensation ~= nil and compensation.ok and reversed == applied and restored) and "PASS" or "FAIL"))
  -- Direct call of the public Compensate on the entries of a successful batch.
  local before = MajorFacts(state, config, playerID, true)
  if before == nil then return end
  local ok = Apply({
    { effectID = "spike:comp2:favor", kind = "FAVOR", playerID = playerID, amount = Delta(config, "favorDelta"), expectedBefore = before.favor, required = true },
  }, { turn = snapshotTurn }, config)
  local report = WBL_EFFECTS.Compensate(ok.entries, config)
  local after = MajorFacts(state, config, playerID, true)
  local favorApplied = ok.entries[1] ~= nil and ok.entries[1].status == "APPLIED"
  say("S4", "adapter_compensation_direct",
    "applied:" .. Text(favorApplied) .. ",reversed:" .. #report.reversed .. ",notReversed:" .. #report.notReversed ..
    ",favorAfter:" .. Text(after and after.favor),
    "favor_restored_to:" .. Text(before.favor),
    favorApplied and (report.ok and after ~= nil and Near(after.favor, before.favor, config) and "PASS" or "FAIL") or "PENDING")
end

local function CounterStep(say, config, playerID, spike, label, kind, deltaName, reversible)
  if not Guard(playerID, label, spike, say) then return end
  local delta = Delta(config, deltaName)
  local result = Apply({ { effectID = "spike:" .. label, kind = kind, playerID = playerID, amount = delta, required = false } },
    { turn = snapshotTurn }, config)
  local entry = result.entries[1]
  local expected = entry and Finite(entry.before) and entry.before + delta or nil
  say(spike, label, EntryText(entry), "after_equals_before_plus_delta" .. (expected and (":" .. Text(expected)) or ""),
    Judge(entry, expected, config), reversible and "reversal_attempted_next" or "irreversible_one_time_dev_cost")
  if reversible and entry and entry.status == "APPLIED" then
    local back = Apply({ { effectID = "spike:" .. label .. ":reverse", kind = kind, playerID = playerID, amount = -delta, required = false } },
      { turn = snapshotTurn }, config)
    local reverse = back.entries[1]
    say(spike, label .. "_reversal", EntryText(reverse), "after_equals_original:" .. Text(entry.before),
      Judge(reverse, entry.before, config), "negative_domain_unverified")
  end
end

local function NotifyStep(say, config, playerID)
  local result = Apply({ { effectID = "spike:notify", kind = "NOTIFY", playerID = playerID, messageKey = MESSAGE_KEY, required = false } },
    { turn = snapshotTurn }, config)
  local entry = result.entries[1]
  local path = "unknown"
  if entry and entry.status == "APPLIED" then
    path = entry.reason == "FALLBACK_TYPE" and "USER_DEFINED_fallback" or "data_type"
  end
  local judged = Judge(entry, nil, config)
  if entry and entry.status == "APPLIED" then judged = path == "data_type" and "PASS" or "PENDING" end
  say("S9", "adapter_notify_send", "path:" .. path .. "," .. EntryText(entry), "sent_via_data_type_NOTIFICATION_WBL_LOAN_TAKEN", judged)
  say("S9", "adapter_notify_visible", "needs_human_LOOK", "notification_visible_and_openable_on_screen", "PENDING")
end

-- ------------------------------------------------------------------ public API

-- Called once from Run All Spikes. Returns the adapter record stored as run.adapterFx.
function M.Run(run, player, config, log)
  if not IsSinglePlayer() then
    print("[SPIKE GUARD] adapter_effects multiplayer_or_unknown_context REJECTED")
    return nil
  end
  if player == nil or not player:IsHuman() then
    print("[SPIKE GUARD] adapter_effects invalid_actor REJECTED")
    return nil
  end
  local fx = { state = "WAIT", pass = 0, fail = 0, pending = 0, deferrals = 0, lastTurn = run.startTurn,
    applyTurn = run.startTurn + config.spikes.observationTurns + 1 }
  run.adapterFx = fx
  local say = Tally(fx, log)
  if type(WBL_EFFECTS) ~= "table" or type(WBL_SNAPSHOT) ~= "table" or type(WBL_STATE) ~= "table" then
    say("S4", "adapter_modules", "missing", "WBL_EFFECTS_WBL_SNAPSHOT_WBL_STATE_imported", "PENDING")
    fx.state = "DONE"
    return fx
  end
  local playerID = run.playerID
  snapshotTurn = run.startTurn
  local state = WBL_STATE.New(config, run.startTurn, { speedScale = run.speedScale, eraType = "" })
  Step(say, "probe", function() ProbeStep(say, config) end)
  Step(say, "snapshot", function() SnapshotStep(say, config, state, playerID) end)
  Step(say, "gold", function() GoldStep(say, config, state, playerID) end)
  Step(say, "favor", function() FavorStep(say, config, state, playerID) end)
  Step(say, "compensation", function() CompensationStep(say, config, state, playerID) end)
  Step(say, "era_score", function()
    CounterStep(say, config, playerID, "S4", "adapter_era_score", "ERA_SCORE", "eraScoreDelta", false)
  end)
  Step(say, "merchant", function()
    CounterStep(say, config, playerID, "S9", "adapter_merchant", "MERCHANT_POINTS", "merchantPointsDelta", true)
  end)
  Step(say, "envoy", function()
    CounterStep(say, config, playerID, "S9", "adapter_envoy", "ENVOY", "envoyDelta", false)
  end)
  Step(say, "notify", function() NotifyStep(say, config, playerID) end)
  say("S4", "adapter_penalty_scheduled", "apply_turn:" .. fx.applyTurn,
    "after_S4_removal_turn:" .. (run.startTurn + config.spikes.observationTurns), "PENDING",
    "developing_stage1_applies_on_apply_turn_clears_next_turn")
  return fx
end

local function Finish(fx, say, run)
  fx.state = "DONE"
  print("[SUMMARY] adapter_effects " .. fx.pass .. " PASS, " .. fx.fail .. " FAIL, " .. fx.pending ..
    " PENDING run=" .. Text(run.runID) .. " effects_verified=false")
end

-- Per synced turn boundary: drives the PENALTY_LEVEL sequence. Duplicate calls for one turn are ignored.
function M.Turn(run, now, config, log)
  local fx = run.adapterFx
  if type(fx) ~= "table" or fx.state == "DONE" then return end
  if not IsSinglePlayer() then return end
  if now == fx.lastTurn then return end
  local say = Tally(fx, log)
  local playerID = run.playerID
  if now < fx.lastTurn then
    M.Clear(run, log)
    say("S4", "adapter_penalty_sequence", "clock_rewind", "monotonic_turns", "PENDING")
    Finish(fx, say, run)
    return
  end
  fx.lastTurn = now
  local ok, err = pcall(function()
    if fx.state == "WAIT" and now >= fx.applyTurn then
      if S4Active(run) then
        fx.deferrals = fx.deferrals + 1
        if fx.deferrals > config.spikes.observationTurns then
          say("S4", "adapter_penalty_sequence", "s4_fixture_still_active", "S4_flags_zero_before_adapter_penalty", "PENDING")
          Finish(fx, say, run)
        else
          fx.applyTurn = now + 1
          say("S4", "adapter_penalty_deferred", "s4_fixture_active", "no_stacked_penalties_in_one_capital", "RAW")
        end
        return
      end
      local expected = ExpectedPenaltyText(config)
      Remember(fx, "base", Readings(playerID, "baseline", say, "no_wbl_penalty_active"))
      local key = WBL_EFFECTS.PenaltyLevelKey(PENALTY_TIER, PENALTY_STAGE)
      local result = Apply({ PenaltyEntry(playerID, PENALTY_TIER, PENALTY_STAGE, "spike:penalty:apply") }, { turn = now }, config)
      local entry = result.entries[1]
      local judged = Judge(entry, nil, config)
      if entry and entry.status == "APPLIED" then judged = "PASS" end
      say("S4", "adapter_penalty_apply", EntryText(entry) .. ",modifiers:" .. Text(entry and entry.modifiers),
        key .. "_set_on_capital_plot_modifiers_attached_once", judged)
      if entry == nil or entry.status ~= "APPLIED" then
        Finish(fx, say, run)
        return
      end
      fx.plotIndex = entry.after
      fx.state = "APPLIED"
      fx.clearTurn = now + 1
      local attached = Read(function()
        local player = Players[playerID]
        return player:GetProperty(WBL_EFFECTS.PENALTY_ATTACHED_PROPERTY)
      end)
      say("S4", "adapter_penalty_attach_count", attached, entry.modifiers,
        Near(attached, entry.modifiers, config) and "PASS" or "FAIL")
      local flag = PenaltyFlag(fx.plotIndex, key)
      say("S4", "adapter_penalty_flag_set", flag, 1, flag == 1 and "PASS" or "FAIL")
      Readings(playerID, "apply_immediate", say, expected)
    elseif fx.state == "APPLIED" and now >= fx.clearTurn then
      local key = WBL_EFFECTS.PenaltyLevelKey(PENALTY_TIER, PENALTY_STAGE)
      local boundary = Readings(playerID, "applied_boundary", say, ExpectedPenaltyText(config))
      if boundary then
        say("S4", "adapter_penalty_effect_observed",
          "dAmenities:" .. Text(Finite(boundary.amenities) and Finite(fx.baseAmenities) and boundary.amenities - fx.baseAmenities or nil) ..
          ",dProduction:" .. Text(Finite(boundary.production) and Finite(fx.baseProduction) and boundary.production - fx.baseProduction or nil) ..
          ",dScience:" .. Text(Finite(boundary.science) and Finite(fx.baseScience) and boundary.science - fx.baseScience or nil) ..
          ",dLoyalty:" .. Text(Finite(boundary.loyalty) and Finite(fx.baseLoyalty) and boundary.loyalty - fx.baseLoyalty or nil),
          ExpectedPenaltyText(config), "RAW", "other_game_changes_confound_raw_deltas_review_breakdowns")
      end
      local result = Apply({ PenaltyEntry(playerID, "", 0, "spike:penalty:clear") }, { turn = now }, config)
      local entry = result.entries[1]
      say("S4", "adapter_penalty_clear", EntryText(entry), "stage_0_clears_all_level_flags",
        entry and entry.status == "APPLIED" and "PASS" or Judge(entry, nil, config))
      local flag = PenaltyFlag(fx.plotIndex, key)
      say("S4", "adapter_penalty_flag_cleared", flag, 0, flag == 0 and "PASS" or "FAIL")
      fx.state = "CLEARED"
      fx.finalTurn = now + 1
      Readings(playerID, "cleared_immediate", say, "baseline_values_restored")
    elseif fx.state == "CLEARED" and now >= fx.finalTurn then
      local final = Readings(playerID, "cleared_boundary", say, "baseline_values_restored")
      local same = final ~= nil and Near(final.amenities, fx.baseAmenities, config) and
        Near(final.production, fx.baseProduction, config) and Near(final.science, fx.baseScience, config) and
        Near(final.loyalty, fx.baseLoyalty, config)
      say("S4", "adapter_penalty_readings_restored", same and "equal_to_baseline" or "differs_or_unreadable",
        "equal_to_baseline", "RAW", "natural_yield_changes_between_turns_possible_human_review")
      Finish(fx, say, run)
    end
  end)
  if not ok then
    say("S4", "adapter_penalty_error", err, "no_error", "FAIL")
    M.Clear(run, log)
    Finish(fx, say, run)
  end
end

-- Switches an active adapter penalty off (error, rewind, new run). True when nothing remains active.
function M.Clear(run, log)
  local fx = run and run.adapterFx
  if type(fx) ~= "table" or fx.state ~= "APPLIED" then return true end
  if type(WBL_EFFECTS) ~= "table" then return false end
  local say = Tally(fx, log)
  local result = Apply({ PenaltyEntry(run.playerID, "", 0, "spike:penalty:rollback") }, { turn = fx.lastTurn }, WBL_CONFIG)
  local entry = result.entries[1]
  local cleared = entry ~= nil and entry.status == "APPLIED"
  say("S4", "adapter_penalty_rollback", EntryText(entry), "stage_0_clears_all_level_flags", cleared and "PASS" or "FAIL")
  -- Stopped for good: later turns must not continue the sequence from a half state.
  if cleared then fx.state = "DONE" end
  return cleared
end
