-- S1 income-posting order probe (dev only, read-only). Samples every living major's balance and net
-- GPT at three synced hooks across a few turns so the order in which yields post can be inferred
-- from balance deltas. It never writes the treasury; the +/- reversible probe stays in WBL_Spikes.
-- Hook evidence: OnGameTurnStarted (PiratesScenario_StartScript.lua:1614), PlayerTurnStarted
-- (PolandScenario.lua:545), PlayerTurnStartComplete (PiratesScenario_StartScript.lua:1621).
WBL_SPIKE_TREASURY = {}
local M = WBL_SPIKE_TREASURY

-- Last sample per player. Local on purpose: a reload loses it and the next sample is a new baseline.
local last = {}

local function Read(fn)
  local ok, value = pcall(fn)
  if ok then return value, nil end
  return nil, tostring(value)
end

local function IsFinite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function Text(value)
  return (string.gsub(tostring(value), "[\r\n]", " "))
end

local function Near(a, b, epsilon)
  return IsFinite(a) and IsFinite(b) and math.abs(a - b) <= epsilon
end

-- Opens the sampling window for turns startTurn+1 .. startTurn+turns. Stored on the run record.
function M.Begin(run, startTurn, turns, logfn)
  last = {}
  if not IsFinite(turns) or turns < 1 or turns % 1 ~= 0 then
    run.treasuryTiming = nil
    logfn("S1", "timing_window", Text(turns), "positive_integer_spikes.treasuryTimingTurns", "PENDING")
    return false
  end
  run.treasuryTiming = { startTurn = startTurn, turns = turns, closed = false }
  logfn("S1", "timing_window", "start:" .. startTurn .. ",turns:" .. turns,
    "samples_at_OnGameTurnStarted_PlayerTurnStarted_PlayerTurnStartComplete", "PENDING",
    "window_opens_next_turn_boundary")
  return true
end

function M.Active(run, now)
  local window = type(run) == "table" and run.treasuryTiming or nil
  return type(window) == "table" and now > window.startTurn and now <= window.startTurn + window.turns
end

local function SampleOne(player, id, phase, now, logfn, epsilon)
  local treasury, treasuryError = Read(function() return player:GetTreasury() end)
  local balance, balanceError = Read(function() return treasury:GetGoldBalance() end)
  local gpt, gptError = Read(function() return treasury:GetGoldYield() - treasury:GetTotalMaintenance() end)
  local previous = last[id]
  if previous ~= nil and previous.turn == now and previous.phase == phase then return end
  if previous ~= nil and now < previous.turn then previous = nil end -- clock rewind: new baseline
  local readable = IsFinite(balance)
  if readable then last[id] = { turn = now, phase = phase, balance = balance, gpt = IsFinite(gpt) and gpt or nil } end
  local detail = balanceError or treasuryError or gptError
  local actual = "turn:" .. now .. ",balance:" .. Text(balance) .. ",netGPT:" .. Text(gpt)
  if previous ~= nil and readable then
    local delta = balance - previous.balance
    actual = actual .. ",prev:" .. previous.phase .. "@" .. previous.turn ..
      ",prevBalance:" .. Text(previous.balance) .. ",prevNetGPT:" .. Text(previous.gpt) ..
      ",delta:" .. Text(delta) ..
      ",deltaMatchesPrevNetGPT:" .. Text(previous.gpt ~= nil and previous.gpt ~= 0 and Near(delta, previous.gpt, epsilon))
  else
    actual = actual .. ",prev:none"
  end
  logfn("S1", "timing_" .. phase .. "_player_" .. id, actual,
    "income_posting_phase_is_first_transition_whose_delta_matches_prior_netGPT",
    readable and "RAW" or "PENDING", detail)
end

-- players: sorted living-major player objects; onlyID restricts a per-player hook to that major.
function M.Sample(players, phase, now, run, logfn, epsilon, onlyID)
  if not M.Active(run, now) and phase ~= "RunStart" then return end
  for _, player in ipairs(players) do
    local id = Read(function() return player:GetID() end)
    if type(id) == "number" and (onlyID == nil or id == onlyID) then
      SampleOne(player, id, phase, now, logfn, epsilon)
    end
  end
end

-- Logs one closing line after the window, so a reviewer knows the sampling ended.
function M.Close(run, now, logfn)
  local window = type(run) == "table" and run.treasuryTiming or nil
  if type(window) ~= "table" or window.closed or now <= window.startTurn + window.turns then return false end
  window.closed = true
  logfn("S1", "timing_window_closed", "turns:" .. window.turns,
    "human_review_of_posting_order_across_three_hooks", "PENDING",
    "inference_is_a_log_review_not_an_automatic_pass")
  return true
end
