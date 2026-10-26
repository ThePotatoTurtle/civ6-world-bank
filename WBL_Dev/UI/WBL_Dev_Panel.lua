-- Display and synced requests only. Local evidence: research/UI_TOOLING.md.
local open = false
local launch = nil
local pin = nil
local attached = false
local selectedRun = nil
local STATUS_PROPERTY = "WBL_SPIKE_STATUS"

local function IsSinglePlayer()
  return not GameConfiguration.IsAnyMultiplayer() and not GameConfiguration.IsHotseat()
end

local function Refresh()
  local status = Game:GetProperty(STATUS_PROPERTY)
  local canReload = IsSinglePlayer()
  Controls.RunButton:SetDisabled(not canReload)
  Controls.ReloadButton:SetDisabled(not canReload)
  Controls.ReloadButton:SetToolTipString(canReload
    and "Re-include the config and log status/version. Reading disk edits is UNVERIFIED."
    or "Reload Config is available only in single player.")
  if type(status) == "table" then
    Controls.StatusLabel:SetText(tostring(status.phase or "PENDING") .. ": " .. tostring(status.text or "No report."))
    Controls.CountsLabel:SetText("Turn " .. tostring(status.turn or "?")
      .. " | PASS " .. tostring(status.pass or 0) .. " | FAIL " .. tostring(status.fail or 0)
      .. " | PENDING " .. tostring(status.pending or 0))
    if status.phase == "S4_APPLIED" and status.playerID == Game.GetLocalPlayer()
      and status.cityID ~= nil and selectedRun ~= status.runID then
      local player = Players[status.playerID]
      local cities = player and player:GetCities()
      local city = cities and cities:FindID(status.cityID)
      if city then
        selectedRun = status.runID
        UI.SelectCity(city)
        -- Leave the city breakdown visible for the one visual check.
        open = false
        Controls.Main:SetHide(true)
        print("[WBL UI] S4 PENDING visual check; selected city=" .. tostring(status.cityID))
      end
    end
  else
    Controls.StatusLabel:SetText("PENDING: gameplay status has not arrived.")
    Controls.CountsLabel:SetText("Offline checks do not prove engine behavior.")
  end
end

local function SetOpen(value)
  open = value
  Controls.Main:SetHide(not open)
  if open then Refresh() end
end

local function Toggle()
  SetOpen(not open)
end

local function SendRequest(name)
  local playerID = Game.GetLocalPlayer()
  if playerID == nil or playerID < 0 then
    print("[WBL UI] PENDING request has no local player")
    return
  end
  if not IsSinglePlayer() then
    print("[WBL UI] dev request blocked: single player only")
    return
  end
  UI.RequestPlayerOperation(playerID, PlayerOperations.EXECUTE_SCRIPT, {OnStart = name})
  print("[WBL UI] request=" .. name .. " player=" .. tostring(playerID))
end

local function AttachLaunchButton()
  if attached then return end
  local stack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
  if stack == nil then
    print("[WBL UI] S7 PENDING launch bar unavailable; use WBL Dev fallback")
    return
  end
  launch, pin = {}, {}
  local ok, err = pcall(function()
    ContextPtr:BuildInstanceForControl("WBL_Dev_LaunchItem", launch, stack)
    launch.LaunchItemButton:RegisterCallback(Mouse.eLClick, Toggle)
    ContextPtr:BuildInstanceForControl("WBL_Dev_LaunchPin", pin, stack)
    stack:CalculateSize()
    local width = stack:GetSizeX()
    local backing = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking")
    local tile = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile")
    if backing then backing:SetSizeX(width + 116) end
    if tile then tile:SetSizeX(width - 20) end
    LuaEvents.LaunchBar_Resize(width)
  end)
  if ok then
    attached = true
    Controls.FallbackButton:SetHide(true)
    Controls.EntryLabel:SetText("Launch bar attached. S7 PENDING visual check. Ctrl+Shift+D also opens this panel.")
    print("[WBL UI] S7 PENDING launch bar attached; visual check required")
  else
    Controls.FallbackButton:SetHide(false)
    print("[WBL UI] S7 PENDING launch bar error=" .. tostring(err))
  end
end

local function OnInput(input)
  if input:GetMessageType() ~= KeyEvents.KeyUp then return false end
  local key = input:GetKey()
  if key == Keys.D and input:IsControlDown() and input:IsShiftDown() then
    Toggle()
    return true
  end
  if key == Keys.VK_ESCAPE and open then
    SetOpen(false)
    return true
  end
  return false
end

local function OnViewReady()
  AttachLaunchButton()
  Refresh()
end

local function Shutdown()
  Events.LoadGameViewStateDone.Remove(OnViewReady)
  Events.GameCoreEventPublishComplete.Remove(Refresh)
  Events.PlayerTurnActivated.Remove(Refresh)
  -- Built instances belong to this context; engine releases them with it.
end

ContextPtr:SetHide(false)
Controls.Main:SetHide(true)
Controls.FallbackButton:SetHide(false)
ContextPtr:SetInputHandler(OnInput, true)
ContextPtr:SetShutdown(Shutdown)
Controls.CloseButton:RegisterCallback(Mouse.eLClick, function() SetOpen(false) end)
Controls.FallbackButton:RegisterCallback(Mouse.eLClick, Toggle)
Controls.RunButton:RegisterCallback(Mouse.eLClick, function() SendRequest("WBL_RunAllSpikes") end)
Controls.ReloadButton:RegisterCallback(Mouse.eLClick, function() SendRequest("WBL_ReloadConfig") end)
Events.LoadGameViewStateDone.Add(OnViewReady)
Events.GameCoreEventPublishComplete.Add(Refresh)
Events.PlayerTurnActivated.Add(Refresh)
Refresh()
print("[WBL UI] ready; Ctrl+Shift+D; S7 PENDING")
