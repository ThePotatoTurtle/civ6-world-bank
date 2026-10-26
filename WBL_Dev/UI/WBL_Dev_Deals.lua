-- Nonbinding AI inspection candidate. Exact semantics: research/S3_DEALS.md.
-- Never sends a binding offer/acceptance, copies a draft, or changes bank state.
WBL_DEALS = {}
local D = WBL_DEALS
local active = nil
local armed = false
local priorRun = nil
local armElapsed, armTimeout = 0, nil
local message = "S3: waiting for Run All Spikes."

local function Text(value)
  return tostring(value):gsub("[\r\n]", " ")
end

local function Log(s, result, detail)
  print("[SPIKE S3] run=" .. Text(s and s.runID) .. " turn=" .. Text(Game.GetCurrentGameTurn())
    .. " player=" .. Text(s and s.playerID) .. " " .. result .. " " .. Text(detail))
end

local function SinglePlayer()
  return not GameConfiguration.IsAnyMultiplayer() and not GameConfiguration.IsHotseat()
end

local function Snapshot(deal)
  if deal == nil then return {} end
  local items = {}
  for item in deal:Items() do
    items[#items + 1] = {id = item:GetID(), kind = item:GetType(), from = item:GetFromPlayerID(),
      amount = item:GetAmount(), duration = item:GetDuration()}
  end
  if #items ~= deal:GetItemCount() then error("draft_item_count_changed") end
  return items
end

local function Fingerprint(items)
  local parts = {}
  for _, item in ipairs(items) do
    parts[#parts + 1] = Text(item.kind) .. ":" .. Text(item.from) .. ":" .. Text(item.amount) .. ":" .. Text(item.duration)
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

local function MajorIDs()
  local ids = {}
  for _, player in ipairs(PlayerManager.GetAliveMajors()) do ids[#ids + 1] = player:GetID() end
  table.sort(ids)
  return ids
end

local function NoOtherSessions(s)
  for _, id in ipairs(MajorIDs()) do
    if id ~= s.playerID then
      local sessionID = DiplomacyManager.FindOpenSessionID(s.playerID, id)
      if sessionID ~= nil and (id ~= s.aiID or sessionID ~= s.sessionID) then return false end
      if id ~= s.aiID and DealManager.HasPendingDeal(s.playerID, id) then return false end
    end
  end
  return true
end

local function Cash(playerID)
  local player = Players[playerID]
  local treasury = player:GetTreasury()
  local value = treasury:GetGoldBalance()
  if type(value) ~= "number" or value ~= value or value < 0 or value >= math.huge then error("cash_read_unsupported") end
  return value
end

-- Only empty drafts or exact copies of the owned query can be cleaned up.
-- Different contents are preserved, including content written by another UI.
local function Cleanup(s)
  if s.aiID ~= nil then
    local ok, current = pcall(function() return DiplomacyManager.FindOpenSessionID(s.playerID, s.aiID) end)
    if not ok or (current ~= nil and current ~= s.sessionID) then
      Log(s, "PENDING", "cleanup_ownership_unknown uncorrelated_session_preserved=true")
      return false
    end
    if current ~= nil then
      local readable, info = pcall(function() return DiplomacyManager.GetSessionInfo(current) end)
      if not readable or info == nil or info.FromPlayer ~= s.playerID then
        Log(s, "PENDING", "cleanup_session_owner_changed drafts_preserved=true")
        return false
      end
    end
  end
  local safe = true
  local plans = {}
  for _, entry in ipairs({{direction = DealDirection.OUTGOING, deal = s.outgoing},
    {direction = DealDirection.INCOMING, deal = s.incoming}}) do
    local deal = entry.deal
    if deal ~= nil then
      local ok, err = pcall(function()
        local current = Snapshot(deal)
        local signature = Fingerprint(current)
        local owned = #current == 0 or signature == s.expected
        -- A setter may fail before the full fingerprint was captured.
        if not owned and s.building and entry.direction == DealDirection.OUTGOING then
          owned = true
          for _, item in ipairs(current) do
            if not s.created[item.id] then owned = false end
          end
        end
        if not owned then error("foreign_draft_content_preserved") end
        plans[#plans + 1] = {deal = deal, items = current}
      end)
      if not ok then
        safe = false
        Log(s, "FAIL", "cleanup=" .. Text(err) .. " direction=" .. Text(entry.direction))
      end
    end
  end
  if not safe then return false end
  for _, plan in ipairs(plans) do
    local ok, err = pcall(function()
      for _, item in ipairs(plan.items) do plan.deal:RemoveItemByID(item.id) end
      if plan.deal:GetItemCount() ~= 0 then error("cleanup_items_remain") end
    end)
    if not ok then safe = false; Log(s, "FAIL", "item_cleanup=" .. Text(err)) end
  end
  if safe and s.sessionID ~= nil then
    local ok, err = pcall(function()
      local current = DiplomacyManager.FindOpenSessionID(s.playerID, s.aiID)
      if current == s.sessionID then
        local info = DiplomacyManager.GetSessionInfo(s.sessionID)
        if info == nil or info.FromPlayer ~= s.playerID then error("owned_session_changed") end
        DiplomacyManager.CloseSession(s.sessionID)
      elseif current ~= nil then
        error("replacement_session_preserved")
      end
    end)
    if not ok then safe = false; Log(s, "FAIL", "session_cleanup=" .. Text(err)) end
  end
  return safe
end

local function Stop(reason, result)
  local s = active
  if s == nil then return end
  s.phase = "STOPPING"
  local clean = Cleanup(s)
  Log(s, result or "PENDING", reason .. " cleanup=" .. Text(clean)
    .. " inspected=" .. s.responses .. " binding_actions_sent=0")
  local ending = string.find(reason, "timeout", 1, true) and "queries timed out" or "queries stopped"
  message = "S3: " .. ending .. ". PENDING review; " .. reason
  active = nil
end

local function ConfigValid(config)
  local c = config and config.spikes
  if type(c) ~= "table" or type(c.comparisonGold) ~= "table" or #c.comparisonGold == 0 then return false end
  local function positive(value)
    return type(value) == "number" and value == value and value > 0 and value < math.huge
  end
  for _, key in ipairs({"dealGPTMin", "dealGPTMax", "dealTurns", "minAttitudeSamples", "dealQueryTimeoutSeconds", "dealRunTimeoutSeconds"}) do
    if not positive(c[key]) then return false end
  end
  if c.dealGPTMin % 1 ~= 0 or c.dealGPTMax % 1 ~= 0 or c.dealTurns % 1 ~= 0 or c.dealGPTMax < c.dealGPTMin then return false end
  for _, value in ipairs(c.comparisonGold) do if not positive(value) or value % 1 ~= 0 then return false end end
  return true
end

local function NextGPT(task)
  if task.minimumResult == nil then return task.minimum end
  if task.maximum ~= task.minimum and task.maximumResult == nil then return task.maximum end
  if task.minimumResult and task.maximumResult == false and task.upper - task.lower > 1 then
    return math.floor((task.lower + task.upper) / 2)
  end
  return nil
end

local function NextSample(s)
  while s.index <= #s.tasks do
    local task = s.tasks[s.index]
    local gpt = NextGPT(task)
    if gpt ~= nil then
      s.task, s.gpt, s.aiID = task, gpt, task.aiID
      s.sessionID, s.outgoing, s.incoming, s.expected = nil, nil, nil, nil
      s.created, s.building = {}, false
      if not NoOtherSessions(s) or DealManager.HasPendingDeal(s.playerID, s.aiID) then
        Stop("active_negotiation_preserved")
        return
      end
      local outgoing = DealManager.GetWorkingDeal(DealDirection.OUTGOING, s.playerID, s.aiID)
      local incoming = DealManager.GetWorkingDeal(DealDirection.INCOMING, s.playerID, s.aiID)
      if #Snapshot(outgoing) > 0 or #Snapshot(incoming) > 0 then
        Log(s, "PENDING", "ai=" .. s.aiID .. " principal=" .. task.principal .. " preexisting_draft_preserved")
        s.index = s.index + 1
      else
        s.outgoing, s.incoming = outgoing, incoming
        s.phase, s.queryElapsed = "OPENING", 0
        message = "S3: inspecting AI " .. s.aiID .. ", gold " .. task.principal .. ", GPT " .. gpt .. ". Please wait."
        DiplomacyManager.RequestSession(s.playerID, s.aiID, "MAKE_DEAL")
        return
      end
    else
      Log(s, "RAW", "ai=" .. task.aiID .. " attitude=" .. task.attitude .. " principal=" .. task.principal
        .. " greatest_observed_accepted_GPT=" .. Text(task.observedBest)
        .. " threshold_candidate_only=true unqueried_acceptance_not_proven=true")
      s.index = s.index + 1
    end
  end
  local attitudes = 0
  for _ in pairs(s.attitudes) do attitudes = attitudes + 1 end
  Log(s, "PENDING", "matrix_complete inspected=" .. s.responses .. " distinct_attitudes=" .. attitudes
    .. " required_attitudes=" .. s.config.minAttitudeSamples
    .. " representative_rate_calibration_and_no_transfer_review_required=true binding_actions_sent=0")
  message = "S3: queries complete; " .. s.responses .. " raw responses. Calibration remains PENDING."
  active = nil
end

local function SendInspection(s)
  s.outgoing = DealManager.GetWorkingDeal(DealDirection.OUTGOING, s.playerID, s.aiID)
  s.incoming = DealManager.GetWorkingDeal(DealDirection.INCOMING, s.playerID, s.aiID)
  if s.outgoing == nil or s.incoming == nil then Stop("working_draft_unavailable"); return end
  if #Snapshot(s.outgoing) > 0 or #Snapshot(s.incoming) > 0 then Stop("session_draft_not_empty_preserved"); return end
  s.building = true
  local lump = s.outgoing:AddItemOfType(DealItemTypes.GOLD, s.playerID)
  if lump == nil then Stop("lump_item_unavailable"); return end
  s.created[lump:GetID()] = true
  lump:SetDuration(0)
  local gpt = s.outgoing:AddItemOfType(DealItemTypes.GOLD, s.aiID)
  if gpt == nil then Stop("GPT_item_unavailable"); return end
  s.created[gpt:GetID()] = true
  gpt:SetDuration(s.config.dealTurns)
  local lumpMax, gptMax = lump:GetMaxAmount(), gpt:GetMaxAmount()
  if s.task.principal > lumpMax or gptMax < s.task.minimum then
    Log(s, "PENDING", "ai=" .. s.aiID .. " requestedGold=" .. s.task.principal .. " requestedGPT=" .. s.gpt
      .. " maxGold=" .. Text(lumpMax) .. " maxGPT=" .. Text(gptMax) .. " sample_infeasible_not_rejected")
    -- No willingness inference from a treasury/legality bound.
    s.index = s.index + 1
    s.phase = "CLEANING"
    if not Cleanup(s) then Stop("infeasible_sample_cleanup_failed", "FAIL"); return end
    s.phase, s.queryElapsed = "CLOSING", 0
    return
  end
  if s.gpt > gptMax then
    local ceiling = math.floor(gptMax)
    Log(s, "RAW", "ai=" .. s.aiID .. " requestedGPTCeiling=" .. s.task.maximum
      .. " legalGPTCeiling=" .. ceiling .. " legal_bound_only_not_AI_rejection=true")
    s.task.maximum, s.task.upper, s.task.maximumResult = ceiling, ceiling, nil
    s.gpt = ceiling
  end
  lump:SetAmount(s.task.principal)
  gpt:SetAmount(s.gpt)
  s.expected = Fingerprint(Snapshot(s.outgoing))
  s.building = false
  if lump:GetAmount() ~= s.task.principal or gpt:GetAmount() ~= s.gpt
    or lump:GetDuration() ~= 0 or gpt:GetDuration() ~= s.config.dealTurns then
    Stop("engine_changed_requested_amount_or_duration")
    return
  end
  if s.outgoing:Validate() ~= DealValidationResult.VALID then
    Stop("deal_invalid_not_AI_rejection")
    return
  end
  s.humanCash, s.aiCash = Cash(s.playerID), Cash(s.aiID)
  s.phase, s.queryElapsed = "INSPECTING", 0
  -- Set awaiting state before sending in case a response is delivered immediately.
  DealManager.SendWorkingDeal(DealProposalAction.INSPECT, s.playerID, s.aiID)
end

function D.Arm(previousRunID, config)
  if active ~= nil then return false end
  armed, priorRun = true, previousRunID
  armElapsed, armTimeout = 0, config and config.spikes and config.spikes.dealQueryTimeoutSeconds
  message = "S3: waiting for the new synced spike run."
  return true
end

function D.Observe(status, config)
  if armed and config and config.spikes then armTimeout = config.spikes.dealQueryTimeoutSeconds end
  if not armed or active ~= nil or type(status) ~= "table" or status.runID == priorRun
    or status.phase ~= "OBSERVING" then return end
  armed = false
  local ok, err = pcall(function()
    if not SinglePlayer() or status.playerID ~= Game.GetLocalPlayer() then return end
    local localPlayer = Players[status.playerID]
    if localPlayer == nil or not localPlayer:IsHuman() or not ConfigValid(config) then
      message = "S3: PENDING invalid actor or query config."
      return
    end
    local s = {runID = status.runID, playerID = status.playerID, turn = Game.GetCurrentGameTurn(),
      config = config.spikes, tasks = {}, index = 1, responses = 0, elapsed = 0,
      queryElapsed = 0, attitudes = {}, created = {}, phase = "IDLE"}
    active = s
    if not NoOtherSessions(s) then Stop("preexisting_session_or_pending_deal_preserved"); return end
    local diplomacy = localPlayer:GetDiplomacy()
    for _, id in ipairs(MajorIDs()) do
      local other = Players[id]
      if id ~= s.playerID and not other:IsHuman() and diplomacy:HasMet(id) and not diplomacy:IsAtWarWith(id) then
        local diplomaticAI = other:GetDiplomaticAI()
        local index = diplomaticAI:GetDiplomaticStateIndex(s.playerID)
        local row = GameInfo.DiplomaticStates[index]
        local attitude = row and row.Name or tostring(index)
        for _, principal in ipairs(s.config.comparisonGold) do
          s.tasks[#s.tasks + 1] = {aiID = id, attitude = attitude, attitudeIndex = index,
            principal = principal, minimum = s.config.dealGPTMin, maximum = s.config.dealGPTMax,
            lower = s.config.dealGPTMin, upper = s.config.dealGPTMax}
        end
      end
    end
    NextSample(s)
  end)
  if not ok then if active then Stop("start_error=" .. Text(err)) else message = "S3: PENDING " .. Text(err) end end
end

function D.OnStatement(fromPlayer, toPlayer, variants)
  local s = active
  if s == nil or type(variants) ~= "table" or fromPlayer ~= s.aiID or toPlayer ~= s.playerID then return end
  local ok, err = pcall(function()
    if DiplomacyManager.GetKeyName(variants.StatementType) ~= "MAKE_DEAL" then Stop("surprise_statement_preserved"); return end
    if s.phase == "OPENING" then
      if variants.RespondingToDealAction ~= 0 then return end
      local current = DiplomacyManager.FindOpenSessionID(s.playerID, s.aiID)
      if current == nil or current ~= variants.SessionID then return end
      local info = DiplomacyManager.GetSessionInfo(current)
      if info == nil or info.FromPlayer ~= s.playerID then Stop("session_not_owned_preserved"); return end
      s.sessionID = current
      if not NoOtherSessions(s) then Stop("surprise_session_preserved"); return end
      SendInspection(s)
    elseif s.phase == "INSPECTING" then
      if variants.SessionID ~= s.sessionID or variants.RespondingToDealAction ~= DealProposalAction.INSPECT then return end
      if DiplomacyManager.FindOpenSessionID(s.playerID, s.aiID) ~= s.sessionID then Stop("session_changed_preserved"); return end
      if Fingerprint(Snapshot(s.outgoing)) ~= s.expected then Stop("outgoing_draft_changed_preserved"); return end
      local incoming = Snapshot(s.incoming)
      if #incoming > 0 and Fingerprint(incoming) ~= s.expected then Stop("incoming_draft_changed_preserved"); return end
      if Cash(s.playerID) ~= s.humanCash or Cash(s.aiID) ~= s.aiCash then Stop("cash_changed_during_inspection", "FAIL"); return end
      local accepted
      if variants.DealAction == DealProposalAction.ACCEPTED then accepted = true
      elseif variants.DealAction == DealProposalAction.REJECTED then accepted = false
      else Stop("unknown_inspection_response=" .. Text(variants.DealAction)); return end
      s.responses = s.responses + 1
      s.attitudes[s.task.attitudeIndex] = true
      local task = s.task
      if accepted and (task.observedBest == nil or s.gpt > task.observedBest) then task.observedBest = s.gpt end
      if s.gpt == task.minimum and task.minimumResult == nil then task.minimumResult = accepted
      elseif s.gpt == task.maximum and task.maximumResult == nil then task.maximumResult = accepted
      elseif accepted then task.lower = s.gpt else task.upper = s.gpt end
      Log(s, "RAW", "ai=" .. s.aiID .. " attitude=" .. task.attitude .. " principal=" .. task.principal
        .. " GPT=" .. s.gpt .. " duration=" .. s.config.dealTurns .. " inspectAccepted=" .. Text(accepted)
        .. " cashUnchanged=true session=" .. Text(s.sessionID) .. " binding_actions_sent=0")
      if task.minimumResult == false and task.maximumResult == true then
        Log(s, "PENDING", "nonmonotonic_endpoint_responses no_threshold_inference=true")
      end
      s.phase = "CLEANING"
      if not Cleanup(s) then Stop("query_cleanup_failed", "FAIL"); return end
      s.phase, s.queryElapsed = "CLOSING", 0
    end
  end)
  if not ok and active then Stop("response_error=" .. Text(err)) end
end

function D.Update(deltaSeconds)
  local s = active
  if type(deltaSeconds) ~= "number" or deltaSeconds ~= deltaSeconds or deltaSeconds < 0 or deltaSeconds >= math.huge then return end
  if s == nil then
    if armed and type(armTimeout) == "number" and armTimeout > 0 then
      armElapsed = armElapsed + deltaSeconds
      if armElapsed >= armTimeout then
        armed = false
        message = "S3: queries stopped. PENDING new synced run did not arrive."
      end
    end
    return
  end
  local ok, err = pcall(function()
    if not SinglePlayer() or Game.GetLocalPlayer() ~= s.playerID or Game.GetCurrentGameTurn() ~= s.turn then
      Stop("game_or_turn_changed")
      return
    end
    s.elapsed, s.queryElapsed = s.elapsed + deltaSeconds, s.queryElapsed + deltaSeconds
    if s.elapsed >= s.config.dealRunTimeoutSeconds then Stop("whole_run_timeout"); return end
    if s.queryElapsed >= s.config.dealQueryTimeoutSeconds then Stop("query_timeout"); return end
    if s.phase == "CLOSING" and DiplomacyManager.FindOpenSessionID(s.playerID, s.aiID) == nil then
      s.sessionID, s.outgoing, s.incoming, s.expected = nil, nil, nil, nil
      s.created = {}
      s.phase = "IDLE"
      NextSample(s)
    elseif s.phase ~= "OPENING" and not NoOtherSessions(s) then
      Stop("surprise_session_preserved")
    end
  end)
  if not ok and active then Stop("update_error=" .. Text(err)) end
end

function D.Status() return message end
function D.IsBusy() return active ~= nil end
function D.Shutdown()
  if active then Stop("context_shutdown") end
  armed, priorRun = false, nil
  armElapsed, armTimeout = 0, nil
  message = "S3: waiting for Run All Spikes."
end
