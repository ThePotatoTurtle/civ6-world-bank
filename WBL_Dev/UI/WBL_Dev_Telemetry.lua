-- UI-side read-only observers for the dev spikes (S2, S5, S10). Included by WBL_Dev_Panel.lua; it
-- writes no game or gameplay state and infers no eligibility. All output is "[WBL SPIKE]" log lines that
-- tools/summarize_log.py counts. Gameplay lines for the same turn use the "[SPIKE Sx]" prefix, so the two
-- sides are correlated by turn= in the log.
include("WBL_Config")
include("WBL_State")
include("WBL_SpikeState")

WBL_DEV_TELEMETRY = {}
local M = WBL_DEV_TELEMETRY

local STATUS_KEY = "WBL_SPIKE_STATUS"
local TELEMETRY_KEY = "WBL_SPIKE_TELEMETRY"

local attached = false
local sequence = 0
local lastS2Turn = nil
local lastS10Key = nil

local function Read(fn)
  local ok, value = pcall(fn)
  if ok then return value, nil end
  return nil, tostring(value)
end

local function Text(value)
  return (string.gsub(tostring(value), "[\r\n]", " "))
end

-- Monotonic sequence preserves arrival order; it is not a game clock.
local function Log(spike, variant, actual, expected, result, detail)
  sequence = sequence + 1
  local turn = Read(function() return Game.GetCurrentGameTurn() end)
  print("[WBL SPIKE] " .. spike .. " source=UI seq=" .. sequence .. " turn=" .. Text(turn) ..
    " variant=" .. variant .. " actual=" .. Text(actual) .. " expected=" .. expected .. " " .. result ..
    (detail and (" detail=" .. Text(detail)) or ""))
end

local function RunActive()
  local status = Game:GetProperty(STATUS_KEY)
  return type(status) == "table"
end

local function Scalar(value)
  local kind = type(value)
  if kind == "number" or kind == "boolean" or kind == "string" then return tostring(value) end
  return "<" .. kind .. ">"
end

local function Fields(value)
  local keys = {}
  if type(value) ~= "table" then return Scalar(value) end
  for key in next, value do
    if type(key) == "string" or type(key) == "number" then keys[#keys + 1] = key end
  end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  local parts = {}
  for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. ":" .. Scalar(value[key]) end
  return table.concat(parts, ",")
end

-- S5: raw receipt of the shipped UI event. No disaster identity, ownership or eligibility is inferred;
-- the plot owner and per-plot totals are observations to compare with the gameplay Congress diagnostic.
function M.OnRandomEvent(eventType, severity, plotX, plotY, mitigation, randomEventID, playbackID)
  local info = Read(function() return GameInfo.RandomEvents[eventType] end)
  local plot = Read(function() return Map.GetPlot(plotX, plotY) end)
  local owner, ownerError = Read(function() return plot:GetOwner() end)
  local atPlot, atPlotError = Read(function() return GameRandomEvents.GetCurrentTurnEventAtPlot(Map.GetPlotIndex(plotX, plotY)) end)
  local localPlayer = Read(function() return Game.GetLocalPlayer() end)
  local perPlot = "none"
  if type(atPlot) == "table" then
    perPlot = "PopLost:" .. Scalar(atPlot.PopLost) .. ",UnitsLost:" .. Scalar(atPlot.UnitsLost) ..
      ",TilesDamaged:" .. Scalar(atPlot.TilesDamaged) .. ",FertilityAdded:" .. Scalar(atPlot.FertilityAdded)
  end
  Log("S5", "ui_random_event",
    "randomEventID:" .. Scalar(randomEventID) .. ",playbackID:" .. Scalar(playbackID) ..
    ",type:" .. Scalar(eventType) .. ",name:" .. Scalar(info and info.RandomEventType) ..
    ",severity:" .. Scalar(severity) .. ",plot:" .. Scalar(plotX) .. "/" .. Scalar(plotY) ..
    ",mitigation:" .. Scalar(mitigation) .. ",plotOwner:" .. Scalar(owner) ..
    ",localPlayer:" .. Scalar(localPlayer) .. ",atPlot:" .. perPlot,
    "raw_event_receipt_correlated_by_turn_no_eligibility_inference", "RAW",
    ownerError or atPlotError)
end

-- S5: the UI view of the current-turn event, once per local turn, for comparison with the gameplay read.
function M.ObserveCurrentEvent()
  if not RunActive() then return end
  local event, err = Read(function() return GameRandomEvents.GetCurrentTurnEvent() end)
  if type(event) == "table" then
    Log("S5", "ui_current_event", Fields(event), "raw_UI_event_fields_for_gameplay_comparison", "RAW",
      "readable_table_only_not_disaster_qualification")
  elseif event == nil and err == nil then
    Log("S5", "ui_current_event", "none", "raw_event_or_none", "RAW", "absence_is_not_disaster_ineligibility")
  else
    Log("S5", "ui_current_event", err or Scalar(event), "raw_event_or_none", "PENDING")
  end
end

local function CountTechs(playerTechs)
  local rows = {}
  for row in GameInfo.Technologies() do rows[#rows + 1] = row.Index end
  table.sort(rows)
  local count = 0
  for _, index in ipairs(rows) do
    if playerTechs:HasTech(index) then count = count + 1 end
  end
  return count
end

local function CountCivics(playerCulture)
  local rows = {}
  for row in GameInfo.Civics() do rows[#rows + 1] = row.Index end
  table.sort(rows)
  local count = 0
  for _, index in ipairs(rows) do
    if playerCulture:HasCivic(index) then count = count + 1 end
  end
  return count
end

local function GameplayCounts(localID)
  local published = Game:GetProperty(TELEMETRY_KEY)
  if type(published) ~= "table" or type(published.players) ~= "table" then return nil end
  for _, entry in ipairs(published.players) do
    if entry.id == localID then return entry, published.turn end
  end
  return nil, published.turn
end

-- S2: UI-side GetStats counts against HasTech/HasCivic counts for the local player (same moment), and
-- against the counts gameplay published this turn (different moment, so only RAW).
function M.ObserveDevelopment()
  if not RunActive() then return end
  local turn = Read(function() return Game.GetCurrentGameTurn() end)
  if turn == lastS2Turn then return end
  lastS2Turn = turn
  local localID, idError = Read(function() return Game.GetLocalPlayer() end)
  local player = Read(function() return Players[localID] end)
  if type(localID) ~= "number" or localID < 0 or player == nil then
    Log("S2", "ui_stats_vs_has", Text(idError), "valid_local_player", "PENDING")
    return
  end
  local stats, statsError = Read(function() return player:GetStats() end)
  local statTechs, statTechError = Read(function() return stats:GetNumTechsResearched() end)
  local statCivics, statCivicError = Read(function() return stats:GetNumCivicsCompleted() end)
  local hasTechs, hasTechError = Read(function() return CountTechs(player:GetTechs()) end)
  local hasCivics, hasCivicError = Read(function() return CountCivics(player:GetCulture()) end)
  local readable = type(statTechs) == "number" and type(hasTechs) == "number"
    and type(statCivics) == "number" and type(hasCivics) == "number"
  local match = readable and statTechs == hasTechs and statCivics == hasCivics
  local verdict = "PENDING"
  if readable then verdict = match and "PASS" or "FAIL" end
  Log("S2", "ui_stats_vs_has",
    "player:" .. localID .. ",statsTechs:" .. Text(statTechs) .. ",hasTechs:" .. Text(hasTechs) ..
    ",statsCivics:" .. Text(statCivics) .. ",hasCivics:" .. Text(hasCivics),
    "GetStats_counts_equal_HasTech_HasCivic_counts", verdict,
    statsError or statTechError or statCivicError or hasTechError or hasCivicError)
  local entry, publishedTurn = GameplayCounts(localID)
  if entry ~= nil and readable then
    Log("S2", "ui_vs_gameplay_counts",
      "ui:" .. hasTechs .. "/" .. hasCivics .. ",gameplay:" .. Text(entry.techs) .. "/" .. Text(entry.civics) ..
      ",gameplayTurn:" .. Text(publishedTurn) .. ",match:" ..
      Text(entry.techs == hasTechs and entry.civics == hasCivics),
      "gameplay_and_UI_counts_agree_when_nothing_completes_between_samples", "RAW",
      "different_moments_not_a_pass_or_fail")
  else
    Log("S2", "ui_vs_gameplay_counts", "published:" .. Text(entry ~= nil), "gameplay_property_readable_in_UI", "PENDING")
  end
end

-- S10: UI-context read of the gameplay-written properties. Never writes; a mismatch is a FAIL.
function M.ObserveState()
  if not RunActive() or type(WBL_SPIKE_STATE) ~= "table" then return end
  local store = { get = function(key) return Game:GetProperty(key) end }
  local result = WBL_SPIKE_STATE.Observe(store)
  local key = tostring(result.computed) .. "@" .. tostring(result.turn)
  if key == lastS10Key then return end
  lastS10Key = key
  local verdict = WBL_SPIKE_STATE.Verdict(result)
  Log("S10", "ui_property_read", WBL_SPIKE_STATE.Describe(result),
    "UI_reads_gameplay_property_with_equal_checksum", verdict,
    result.present and "compare_with_gameplay_state_checksum_for_this_turn" or "gameplay_property_not_visible_to_UI_yet")
  if type(WBL_STATE) == "table" and type(WBL_CONFIG) == "table" then
    local ok, results = pcall(WBL_SPIKE_STATE.ProductionObserve, store, WBL_CONFIG)
    if ok then
      for _, entry in ipairs(results) do
        Log("S10", "ui_production_" .. entry.mode,
          "kind:" .. entry.kind .. ",status:" .. Text(entry.status) .. ",checksum:" .. Text(entry.checksum),
          "UI_decode_checksum_equals_rebuilt_state_checksum",
          (not entry.present) and "PENDING" or (entry.ok and "PASS" or "FAIL"), entry.reason)
      end
    else
      Log("S10", "ui_production_read", Text(results), "decode_in_UI_context", "PENDING")
    end
  end
end

local function OnTurn()
  M.ObserveCurrentEvent()
  M.ObserveDevelopment()
  M.ObserveState()
end

-- Idempotent: the panel may build more than once in one session.
function M.Attach()
  if attached then return end
  attached = true
  Events.RandomEventOccurred.Add(M.OnRandomEvent)
  Events.PlayerTurnActivated.Add(OnTurn)
  Events.LoadGameViewStateDone.Add(OnTurn)
  Log("S5", "ui_observer_attached", "RandomEventOccurred,PlayerTurnActivated,LoadGameViewStateDone",
    "read_only_observers_registered", "PENDING", "no_state_writes")
end
