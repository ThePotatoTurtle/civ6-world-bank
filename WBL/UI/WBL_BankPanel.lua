-- World Bank panel: display and synced requests only. State is read from the published property;
-- nothing here mutates game state. View model: WBL_BankView.lua. Layout: the stage 5 redesign Leon approved
-- (2026-11-08, mock-up artifact), in shipped Civ VI controls; not yet seen in game.
include("InstanceManager")
include("WBL_Config")
include("WBL_Math")
include("WBL_BankView")
local hasState = pcall(include, "WBL_State") -- WP2 codec; guarded fallback below if absent.

local open = false
local dirty = true
local attached = false
local launch, pin = nil, nil
local tab = "BORROW"
local lastView = nil
local sentNonce = nil
local selection = {milestone = 1}
local MAX_TECH_OPTIONS = 8 -- Quickest qualifying technologies offered as milestone targets (picker space).
local PERCENT = 100 -- Fraction to percent for display.

local headerIM = InstanceManager:new("HeaderRow", "Root", Controls.BodyStack)
local textIM = InstanceManager:new("TextRow", "Root", Controls.BodyStack)
local hintIM = InstanceManager:new("HintRow", "Root", Controls.BodyStack)
local actionIM = InstanceManager:new("ActionRow", "Root", Controls.BodyStack)
local selectorIM = InstanceManager:new("SelectorRow", "Root", Controls.BodyStack)
local spacerIM = InstanceManager:new("SpacerRow", "Root", Controls.BodyStack)
-- Stage 5 layout (Leon approved the mock-up, 2026-11-08): cards, titles with status tags, button pairs, wrapping
-- grids, tiles and the ownership ring. Rows inside a card are reparented to its stack (InstanceManager.lua:33-54).
local cardIM = InstanceManager:new("CardRow", "Root", Controls.BodyStack)
local cardHeaderIM = InstanceManager:new("CardHeader", "Root", Controls.BodyStack)
local pairIM = InstanceManager:new("ButtonPairRow", "Root", Controls.BodyStack)
local gridRowIM = InstanceManager:new("GridRow", "Root", Controls.BodyStack)
local gridCellIM = InstanceManager:new("GridButtonCell", "Button", Controls.BodyStack)
local tileIM = InstanceManager:new("TileCell", "Root", Controls.BodyStack)
local pieIM = InstanceManager:new("PieRow", "Root", Controls.BodyStack)
local legendIM = InstanceManager:new("LegendLine", "Root", Controls.BodyStack)
-- Children first, so a card's rows go back to the body before the card itself (ResetInstances reparents).
local ALL_IMS = {legendIM, gridCellIM, tileIM, textIM, hintIM, actionIM, selectorIM, cardHeaderIM, pairIM, gridRowIM,
  pieIM, headerIM, spacerIM, cardIM}
-- Selector label width inside the 250 px button, leaving room for the arrow at each end (screenshot item 2).
local SELECTOR_TEXT_WIDTH = 180
-- Row widths: inside a card's stack, and in the body outside cards. Both put the hover mark at the same x as a
-- card header's (screenshot item 21: badges outside cards sat about 15 px left of the card badges).
local CARD_ROW_WIDTH = 666
local BODY_ROW_WIDTH = 678
local PIE_HEIGHT = 140
local LINE_HEIGHT = 22 -- Minimum text row height (one BodyTextDark16 line).
local CARD_PADDING = 20 -- Card frame height beyond its stack: 10 px above and below.
local EMBLEM_SIZE = 44 -- Civ emblem atlas size in the ownership ring (CivilizationIcon sizes).
-- Pixels scrolled per wheel notch; the engine reports 120 per notch (WorldInput.lua:1455).
local WHEEL_PIXELS = 60
local WHEEL_NOTCH = 120
-- Rows drawn this build, for the wheel hover check (the hover registers on the control under the pointer).
local shownRows = {}

local function L(key, ...)
  return Locale.Lookup(key, ...)
end

-- ui.verboseLogging (MP test build): every open, close, tab, click, request and result goes to Lua.log.
local function Verbose()
  return type(WBL_CONFIG.ui) == "table" and WBL_CONFIG.ui.verboseLogging == true
end

local function UILog(text)
  if Verbose() then print("[WBL UI] " .. string.gsub(tostring(text), "[\r\n]", " ")) end
end

-- Request kinds turned off for this build (features.disabledRequests); gameplay refuses them too.
local function Disabled(kind)
  local list = WBL_CONFIG.features.disabledRequests
  if type(list) ~= "table" then return false end
  for _, item in ipairs(list) do
    if item == kind then return true end
  end
  return false
end

local DISABLED_KEY = "LOC_WBL_UI_REASON_DISABLED_BUILD"

-- Current game turn for log lines only; nil when unreadable.
local function Turn()
  local ok, turn = pcall(function() return Game.GetCurrentGameTurn() end)
  return ok and turn or nil
end

-- Sorted "key=value" text of a flat request table, for the log.
local function Flat(params)
  local keys = {}
  for key in next, params do keys[#keys + 1] = tostring(key) end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. tostring(params[key]) end
  return table.concat(parts, " ")
end

-- Whole gold for display only; the bank keeps exact amounts (Leon, Session P 2026-11-04).
local function Gold(value)
  if type(value) ~= "number" then return "?" end
  return string.format("%d", math.floor(value + 0.5))
end

local function Pct(value)
  if type(value) ~= "number" then return "?" end
  -- The number only: the % sign lives in the text template. A % inside a Locale.Lookup argument is re-read as a
  -- format code ("10.0% of" showed as "10.010077720170f", MP game A 2026-11-07); a template % is safe, as in the
  -- shipped "{1_Amount}% chance" rows (Base/Assets/Text/en_US). Whole numbers drop the ".0" (screenshot item 12).
  local text = string.format("%.1f", value * PERCENT)
  return (string.gsub(text, "%.0$", ""))
end

local function CivName(playerID)
  local ok, name = pcall(function()
    return PlayerConfigurations[playerID]:GetCivilizationShortDescription()
  end)
  if ok and name ~= nil and name ~= "" then return L(name) end
  return L("LOC_WBL_UI_PLAYER", playerID)
end

-- Decode the published property. WBL_State.Decode validates; without it only an unencoded table is accepted.
local function ReadState()
  local raw = Game:GetProperty(WBL_CONFIG.state.propertyKey)
  if raw == nil then return nil end
  if hasState and WBL_STATE ~= nil and WBL_STATE.Decode ~= nil then
    local ok, decoded, status, reason = pcall(WBL_STATE.Decode, raw, WBL_CONFIG)
    if ok and type(decoded) == "table" then
      -- A suspended fallback state carries suspended=true and its reason; the view shows it.
      if status == "SUSPENDED" then print("[WBL UI] state decode suspended: " .. tostring(reason)) end
      return decoded
    end
    print("[WBL UI] state decode failed: " .. tostring(decoded))
    return nil
  end
  if type(raw) == "table" then return raw end
  return nil
end

-- The local player's treasury, for display only (nil when it cannot be read). Same reads as the
-- base top panel; the reducer checks the boundary treasury itself.
local function LocalGold()
  local ok, gold = pcall(function()
    return Players[Game.GetLocalPlayer()]:GetTreasury():GetGoldBalance()
  end)
  if ok and type(gold) == "number" then return gold end
  return nil
end

-- Engine-side milestone targets. Display only; the reducer revalidates (decision 54).
-- Techs: two to three research steps away (WBL_MATH.TechSteps over GameInfo.TechnologyPrereqs), with a
-- rough turns estimate: the research left on the tech and its missing prerequisites / science per turn.
-- Cities: the decision 54 population target, estimated as turns to the next growth x the steps
-- (optimistic, since later growth is slower). turnsNeeded nil = unknown; never = the city isn't growing.
local function GatherFacts(playerID)
  local options = {}
  local ok, err = pcall(function()
    local player = Players[playerID]
    local techs = player:GetTechs()
    local prereqs = {}
    for row in GameInfo.TechnologyPrereqs() do
      local list = prereqs[row.Technology]
      if list == nil then list = {}; prereqs[row.Technology] = list end
      list[#list + 1] = row.PrereqTech
    end
    local function researched(tech)
      local row = GameInfo.Technologies[tech]
      return row ~= nil and techs:HasTech(row.Index)
    end
    local science = techs:GetScienceYield()
    local ms = WBL_CONFIG.milestones
    local candidates = {}
    for row in GameInfo.Technologies() do
      local steps = WBL_MATH.TechSteps(row.TechnologyType, prereqs, researched, ms.techMaxSteps + 1)
      if steps >= ms.techMinSteps and steps <= ms.techMaxSteps then
        local left = 0
        for _, tech in ipairs(WBL_MATH.TechChain(row.TechnologyType, prereqs, researched)) do
          local index = GameInfo.Technologies[tech].Index
          left = left + math.max(0, techs:GetResearchCost(index) - techs:GetResearchProgress(index))
        end
        local turns = nil
        if type(science) == "number" and science > 0 then turns = math.ceil(left / science) end
        candidates[#candidates + 1] = {kind = "TECH", target = row.TechnologyType, cityID = 0, name = L(row.Name),
          steps = steps, turnsNeeded = turns, order = #candidates + 1}
      end
    end
    table.sort(candidates, function(a, b)
      local ta, tb = a.turnsNeeded or math.huge, b.turnsNeeded or math.huge
      if ta ~= tb then return ta < tb end
      return a.order < b.order
    end)
    for i = 1, math.min(MAX_TECH_OPTIONS, #candidates) do options[#options + 1] = candidates[i] end
    for _, city in player:GetCities():Members() do
      local population = city:GetPopulation()
      local target = WBL_MATH.PopulationMilestoneTarget(population, WBL_CONFIG)
      local growth = city:GetGrowth():GetTurnsUntilGrowth()
      local option = {kind = "POPULATION", target = target, cityID = city:GetID(), name = L(city:GetName()),
        population = target}
      if type(growth) == "number" and growth >= 0 then
        option.turnsNeeded = math.max(1, growth) * (target - population)
      else
        option.never = true
      end
      options[#options + 1] = option
    end
  end)
  if not ok then print("[WBL UI] PENDING milestone options unavailable: " .. tostring(err)) end
  return {milestoneOptions = options}
end

local function MilestoneName(option)
  if option == nil or option.kind == "NONE" then return L("LOC_WBL_UI_MS_NAME_NONE") end
  local name
  if option.kind == "POPULATION" then name = L("LOC_WBL_UI_MS_NAME_POPULATION", option.name, option.target)
  else name = L("LOC_WBL_UI_MS_NAME_TECH", option.name) end
  if type(option.turnsNeeded) == "number" then name = name .. " " .. L("LOC_WBL_UI_MS_ESTIMATE", option.turnsNeeded) end
  return name
end

-- A loan's own milestone by name: the tech's name, or the city and its target size (fix 5).
local function LoanMilestoneName(m)
  if m.kind == "TECH" then
    local ok, name = pcall(function() return L(GameInfo.Technologies[m.target].Name) end)
    return L("LOC_WBL_UI_MS_NAME_TECH", ok and name or tostring(m.target))
  end
  if m.kind == "POPULATION" then
    local city = L("LOC_WBL_UI_MS_CITY")
    pcall(function()
      local player = Players[Game.GetLocalPlayer()]
      for _, member in player:GetCities():Members() do
        if member:GetID() == m.cityID then city = L(member:GetName()) end
      end
    end)
    return L("LOC_WBL_UI_MS_NAME_POPULATION", city, m.target)
  end
  return tostring(m.kind)
end

-- Options that can be finished within `window` game turns (decision 54); nil window = no time limit.
-- Unknown estimates stay listed; a city that isn't growing is dropped when there is a limit.
local function MilestoneOptions(window)
  local all = lastView and lastView.milestoneOptions or {}
  if window == nil then return all end
  local out = {}
  for _, option in ipairs(all) do
    if option.kind == "NONE" or (not option.never and (option.turnsNeeded == nil or option.turnsNeeded <= window)) then
      out[#out + 1] = option
    end
  end
  return out
end

local function CurrentMilestone(window)
  local options = MilestoneOptions(window)
  local option = options[selection.milestone] or options[1]
  return option
end

local function CycleMilestone(window)
  local options = MilestoneOptions(window)
  selection.milestone = selection.milestone + 1
  if selection.milestone > #options then selection.milestone = 1 end
end

-- Game turns left to finish a milestone chosen now: it must be done before the halfway boundary.
local function MilestoneWindow(graceTurns, paymentTurns)
  if type(graceTurns) ~= "number" or type(paymentTurns) ~= "number" then return nil end
  return math.max(0, math.ceil((graceTurns + paymentTurns) / 2) - 1)
end

-- Row helpers --------------------------------------------------------------------------------------
-- Lua-side wheel pass-through (Leon, 2026-11-06: with ConsumeMouseWheel="0" in XML the wheel still scrolled only
-- off the rows, while the input handler did receive it there). SetConsumeMouseWheel is the control method behind
-- TunerUtilities.lua:364-369. pcall: a control without the method is left as it is.
local function PassWheel(control)
  if control ~= nil then pcall(function() control:SetConsumeMouseWheel(false) end) end
end

local function TrackRow(row)
  shownRows[#shownRows + 1] = row
  PassWheel(row.Root)
  PassWheel(row.Text)
  PassWheel(row.Button)
  PassWheel(row.Button2)
end

-- Rows go into the open card's stack, else the body (stage 5 cards).
local currentParent = nil
-- Screenshot item 21: one hover mark per card, on its header. Line tooltips inside a card are merged into it.
local currentCard = nil

local function Get(im)
  if currentParent ~= nil then return im:GetInstance(currentParent) end
  return im:GetInstance()
end

-- Hover detail (stage 5 items 3 and 4): the tooltip goes on the row and its badge is shown.
local function SetDetail(row, tooltip)
  local has = tooltip ~= nil and tooltip ~= ""
  if row.Info ~= nil then row.Info:SetHide(not has) end
  local text = has and tooltip or ""
  if row.Root ~= nil then row.Root:SetToolTipString(text) end
  if row.Text ~= nil then row.Text:SetToolTipString(text) end
  if row.Info ~= nil then row.Info:SetToolTipString(text) end
end

local function Header(text)
  if #shownRows > 0 then PassWheel(spacerIM:GetInstance().Root) end
  local row = headerIM:GetInstance()
  TrackRow(row)
  row.Text:SetText(text)
end

local function Line(text, tooltip)
  local row = Get(textIM)
  TrackRow(row)
  row.Text:SetText(text)
  row.Root:SetSizeX(currentParent ~= nil and CARD_ROW_WIDTH or BODY_ROW_WIDTH)
  row.Root:SetSizeY(math.max(LINE_HEIGHT, row.Text:GetSizeY()))
  if currentCard ~= nil and tooltip ~= nil and tooltip ~= "" then
    -- The line keeps its own hover text; its mark moves to the card header.
    currentCard.details[#currentCard.details + 1] = tooltip
    SetDetail(row, nil)
    row.Root:SetToolTipString(tooltip)
    row.Text:SetToolTipString(tooltip)
  else
    SetDetail(row, tooltip)
  end
  return row
end

-- A framed card holding the rows built until EndCard.
local function BeginCard()
  local card = cardIM:GetInstance()
  TrackRow(card)
  currentParent = card.Stack
  currentCard = {header = nil, headerTip = nil, details = {}}
  return card
end

local function EndCard(card)
  local info = currentCard
  currentParent, currentCard = nil, nil
  if info ~= nil and info.header ~= nil and #info.details > 0 then
    local parts = {}
    if info.headerTip ~= nil and info.headerTip ~= "" then parts[1] = info.headerTip end
    for _, d in ipairs(info.details) do parts[#parts + 1] = d end
    SetDetail(info.header, table.concat(parts, "[NEWLINE][NEWLINE]"))
  end
  card.Stack:CalculateSize()
  card.Root:SetSizeY(card.Stack:GetSizeY() + CARD_PADDING)
end

-- Status tag colours (stage 5 item 7): blue on time, orange in arrears, red in default. Screenshot item 3:
-- tinting the frame texture didn't show, so each tag gets a solid backing box in its colour with light text.
local PILL = {
  ON_TIME = {frame = {58, 112, 182}, text = {244, 246, 250}},
  ARREARS = {frame = {196, 122, 30}, text = {255, 248, 236}},
  DEFAULT = {frame = {186, 62, 44}, text = {255, 240, 236}},
  DEFAULT_STAGE2 = {frame = {150, 36, 28}, text = {255, 240, 236}},
  TIER = {frame = {44, 92, 150}, text = {236, 240, 246}},
}
local PILL_PADDING = 20 -- Tag width beyond its text.
local PILL_INSET = 4 -- The colour box sits 2 px inside the tag frame on each side.
local LEGEND_MARGIN = 16 -- Space below the legend when it is taller than the ring.
-- Lit benefit tile (fix 4): a green backing; unlit tiles keep the plain card look.
local TILE_LIT = {54, 120, 70}
local TILE_TEXT_LIT = {250, 250, 244}
local TILE_SUB_LIT = {224, 240, 222}
local TILE_SUB = {168, 180, 194}

local function Color(rgb, alpha)
  -- 0xAABBGGRR, as the shipped hex literals (0xFF0101F5 is the HP meter's red); converted like
  -- UI.GetColorValueFromHexLiteral(0x00FFFFFF) in Choosers/EspionageChooser.lua:286.
  return UI.GetColorValueFromHexLiteral((alpha or 255) * 16777216 + rgb[3] * 65536 + rgb[2] * 256 + rgb[1])
end

local function CardHeader(text, sub, pillText, pillKind, tooltip)
  local row = Get(cardHeaderIM)
  TrackRow(row)
  row.Text:SetText(text)
  row.Sub:SetText(sub or "")
  local pill = pillText ~= nil and pillText ~= ""
  row.Pill:SetHide(not pill)
  if pill then
    local colors = PILL[pillKind] or PILL.TIER
    row.PillText:SetText(pillText)
    local width = row.PillText:GetSizeX() + PILL_PADDING
    row.Pill:SetSizeX(width)
    row.PillBack:SetSizeX(width - PILL_INSET)
    row.PillBack:SetColor(Color(colors.frame))
    row.PillText:SetColor(Color(colors.text))
  end
  SetDetail(row, tooltip)
  if currentCard ~= nil then currentCard.header, currentCard.headerTip = row, tooltip end
  return row
end

-- Last refused request per action key (stage 5 item 9): shown under that button until the next request.
local refusals = {}
local lastSent = nil
local sentAmounts = {}

local function RefusalText(actionKey)
  local reason = actionKey and refusals[actionKey]
  if reason == nil then return "" end
  return L("LOC_WBL_UI_REFUSED", L(reason))
end

local function Waiting()
  return lastView ~= nil and sentNonce ~= nil and lastView.nonce == sentNonce
end

-- Shared button set-up: disabled with its reason as tooltip; a refusal line when one is recorded.
local function SetButton(button, note, buttonText, reasonKey, onClick, kind, actionKey, tooltip)
  if kind ~= nil and Disabled(kind) then reasonKey = DISABLED_KEY end
  button:SetText(buttonText)
  local waiting = Waiting()
  local disabled = (reasonKey ~= nil and reasonKey ~= "") or waiting
  button:SetDisabled(disabled)
  if reasonKey ~= nil and reasonKey ~= "" then
    button:SetToolTipString(L(reasonKey))
  elseif waiting then
    button:SetToolTipString(L("LOC_WBL_UI_WAITING"))
  else
    button:SetToolTipString(tooltip or "")
  end
  if note ~= nil then
    -- A greyed-out button says why under it too (mock-up); otherwise a refusal of the last request.
    local text = RefusalText(actionKey)
    if text == "" and reasonKey ~= nil and reasonKey ~= "" and reasonKey ~= DISABLED_KEY then text = L(reasonKey) end
    note:SetText(text)
  end
  button:RegisterCallback(Mouse.eLClick, function()
    UILog("click action kind=" .. tostring(kind) .. " button=" .. tostring(buttonText) .. " disabled=" .. tostring(disabled) ..
      " reason=" .. tostring(reasonKey))
    onClick()
  end)
end

local function Action(text, buttonText, reasonKey, onClick, kind, actionKey, tooltip)
  local row = Get(actionIM)
  TrackRow(row)
  row.Text:SetText(text)
  SetButton(row.Button, row.Note, buttonText, reasonKey, onClick, kind, actionKey, tooltip)
  return row
end

-- Two buttons side by side: each spec = {text, reason, onClick, kind, key, tooltip}.
local function ButtonPair(a, b)
  local row = Get(pairIM)
  TrackRow(row)
  SetButton(row.Button, row.Note, a.text, a.reason, a.onClick, a.kind, a.key, a.tooltip)
  row.Button2:SetHide(b == nil)
  row.Note2:SetHide(b == nil)
  if b ~= nil then SetButton(row.Button2, row.Note2, b.text, b.reason, b.onClick, b.kind, b.key, b.tooltip) end
  return row
end

-- Option row: cycles a choice in place, between the game's arrow button images (stage 5 item 10; screenshot item 2:
-- the [ICON_PressureLeft/Right] glyphs drew as brackets).
-- Long labels truncate with the full text as tooltip, following SupportFunctions.lua:17-41 (TruncateString)
-- and :65-72 (WithTooltip).
local function Selector(text, value, onClick, tooltip)
  local row = Get(selectorIM)
  TrackRow(row)
  row.Text:SetText(text)
  row.Text:SetToolTipString(tooltip or "")
  local buttonText = L("LOC_WBL_UI_SELECTOR_BTN", value)
  local textControl = row.Button:GetTextControl()
  textControl:SetTruncateWidth(SELECTOR_TEXT_WIDTH)
  row.Button:SetText(buttonText)
  row.Button:SetToolTipString(textControl:IsTextTruncated() and buttonText or (tooltip or ""))
  row.Button:SetDisabled(false)
  row.Button:RegisterCallback(Mouse.eLClick, function()
    UILog("click selector label=" .. tostring(text) .. " was=" .. tostring(buttonText))
    onClick()
  end)
end

-- Three cells per row, wrapping (stage 5 item 11).
local function Grid()
  local row = Get(gridRowIM)
  TrackRow(row)
  return row
end

local function EndGrid(row)
  row.Stack:CalculateSize()
  row.Root:SetSizeY(row.Stack:GetSizeY())
end

local function GridButton(grid, buttonText, reasonKey, onClick, kind, tooltip)
  local cell = gridCellIM:GetInstance(grid.Stack)
  TrackRow(cell)
  SetButton(cell.Button, nil, buttonText, reasonKey, onClick, kind, nil, tooltip)
end

local function Tile(grid, title, sub, active, tooltip)
  local cell = tileIM:GetInstance(grid.Stack)
  TrackRow(cell)
  cell.Text:SetText(title)
  cell.Sub:SetText(sub)
  -- Fix 4 (MP game F): a lit tile has a solid green backing and bright text, not only a frame tint.
  cell.Lit:SetHide(not active)
  if active then cell.Lit:SetColor(Color(TILE_LIT)) end
  cell.Text:SetColor(Color(active and TILE_TEXT_LIT or {236, 230, 214}))
  cell.Sub:SetColor(Color(active and TILE_SUB_LIT or TILE_SUB))
  cell.Root:SetToolTipString(tooltip or "")
end

-- "(i) Hover a mark like this for more details", the mark first (screenshot item 22).
local function HintLine()
  local row = hintIM:GetInstance()
  TrackRow(row)
  row.Text:SetText(L("LOC_WBL_UI_HINT"))
  row.Info:SetHide(false)
  local tip = L("LOC_WBL_UI_HINT_TT")
  row.Root:SetToolTipString(tip)
  row.Text:SetToolTipString(tip)
  row.Info:SetToolTipString(tip)
  return row
end

-- "No milestone can be finished in time" when the window leaves nothing but None.
local function NoMilestoneFits(window)
  return window ~= nil and #MilestoneOptions(window) <= 1 and #MilestoneOptions(nil) > 1
end

local function MilestoneFitLine(window)
  if NoMilestoneFits(window) then Line(L("LOC_WBL_UI_MS_NONE_FITS", window)) end
end

local function Send(kind, args, actionKey)
  local view = lastView
  local playerID = Game.GetLocalPlayer()
  if view == nil or playerID == nil or playerID < 0 or view.playerID ~= playerID then
    print("[WBL UI] request " .. tostring(kind) .. " skipped: no local bank player")
    return
  end
  if Disabled(kind) then
    print("[WBL UI] request " .. tostring(kind) .. " not sent: disabled in this build")
    return
  end
  local params, err = WBL_BANKVIEW.BuildRequest(view, kind, args)
  if params == nil then
    print("[WBL UI] request " .. tostring(kind) .. " not sent: " .. tostring(err))
    return
  end
  sentNonce = view.nonce
  -- A new request clears every shown refusal; this one's result is matched by nonce (item 9).
  refusals = {}
  lastSent = {nonce = view.nonce, key = actionKey or kind}
  -- Screenshot item 7: the status line names the amount of the request this panel sent.
  sentAmounts[view.nonce] = args and (args.amount or args.quotedAmount) or nil
  UI.RequestPlayerOperation(playerID, PlayerOperations.EXECUTE_SCRIPT, params)
  print("[WBL UI] request=" .. kind .. " nonce=" .. tostring(view.nonce) .. " player=" .. tostring(playerID))
  if Verbose() then UILog("request params turn=" .. tostring(Turn()) .. " " .. Flat(params)) end
  dirty = true
end

local function Pick(list, key, field)
  selection[key] = selection[key] or {}
  local s = selection[key]
  s[field] = s[field] or 1
  if s[field] > #list then s[field] = 1 end
  return s[field], s
end

local function Redraw()
  dirty = true
  ContextPtr:RequestRefresh()
end

-- The local player's gold per turn as the top bar shows it (TopPanel.lua:145-146); nil when unreadable.
local function LocalGPT()
  local ok, gpt = pcall(function()
    local treasury = Players[Game.GetLocalPlayer()]:GetTreasury()
    return treasury:GetGoldYield() - treasury:GetTotalMaintenance()
  end)
  if ok and type(gpt) == "number" then return gpt end
  return nil
end

local function Signed(value)
  local whole = math.floor(value + 0.5)
  if whole > 0 then return "+" .. whole end
  return tostring(whole)
end

-- Item 1: income after the bank's own payments, top right on every tab.
local function UpdateIncome(view)
  local gpt = LocalGPT()
  local loans = view and view.ok and view.loans or nil
  if gpt == nil or loans == nil then
    Controls.IncomeLabel:SetText("")
    Controls.IncomeSub:SetText("")
    return
  end
  local due = loans.dueThisTurn or 0
  -- Screenshot item 5: a negative figure in red.
  local net = math.floor(gpt - due + 0.5)
  Controls.IncomeLabel:SetText(L(net < 0 and "LOC_WBL_UI_INCOME_NEG" or "LOC_WBL_UI_INCOME", Signed(gpt - due)))
  Controls.IncomeSub:SetText(due > 0 and L("LOC_WBL_UI_INCOME_SUB", Gold(due)) or L("LOC_WBL_UI_INCOME_NONE"))
  Controls.IncomeArea:SetToolTipString(L("LOC_WBL_UI_INCOME_TT", Signed(gpt), Gold(due), Gold(loans.perTurn or 0)))
end

-- Item 8 (decision 43): confirmation before a loan that would push payments above income.
local pendingConfirm = nil

local function CloseConfirm()
  pendingConfirm = nil
  Controls.Confirm:SetHide(true)
end

local function OpenConfirm(warning, onOk)
  pendingConfirm = onOk
  Controls.ConfirmText:SetText(L("LOC_WBL_UI_WARN_TEXT", Gold(warning.total), Gold(warning.income), Gold(-warning.after)))
  Controls.ConfirmLines:SetText(L("LOC_WBL_UI_WARN_LINES", Gold(warning.current), Gold(warning.new), Signed(warning.after)))
  Controls.Confirm:SetHide(false)
  UILog("loan warning shown total=" .. tostring(warning.total) .. " income=" .. tostring(warning.income))
end

-- Turns shown in game turns at this speed (item 5); requests keep Standard terms.
local function FirstPayment(graceTurns)
  if type(graceTurns) ~= "number" or graceTurns <= 0 then return L("LOC_WBL_UI_FIRST_NEXT") end
  return L("LOC_WBL_UI_FIRST_IN", graceTurns + 1)
end

-- Loan chooser shared by ordinary products and recovery offers.
local function LoanChooser(key, entry, kind, extra)
  local steps = WBL_BANKVIEW.AMOUNT_STEPS
  local stepIndex, state = Pick(steps, key, "step")
  local termIndex = Pick(entry.terms, key, "term")
  local amount = WBL_BANKVIEW.AmountForStep(entry.maxAmount, stepIndex)
  local term = entry.terms[termIndex]
  Selector(L("LOC_WBL_UI_SEL_AMOUNT"), L("LOC_WBL_UI_GOLD_VALUE", Gold(amount)), function()
    state.step = state.step + 1
    Redraw()
  end)
  Selector(L("LOC_WBL_UI_SEL_TERM"), L("LOC_WBL_UI_TURNS_VALUE", term.paymentTurns), function()
    state.term = termIndex + 1
    Redraw()
  end, L("LOC_WBL_UI_TERM_TT", term.termStandardTurns))
  local window = MilestoneWindow(term.graceTurns, term.paymentTurns)
  local option = CurrentMilestone(window)
  local pct = Pct(entry.forgivenessFraction or 0)
  Selector(entry.milestoneRequired and L("LOC_WBL_UI_SEL_MILESTONE_REQ", pct) or L("LOC_WBL_UI_SEL_MILESTONE", pct),
    MilestoneName(option), function()
      CycleMilestone(window)
      Redraw()
    end, L("LOC_WBL_UI_MILESTONE_TT"))
  MilestoneFitLine(window)
  local preview, perr = WBL_BANKVIEW.Preview(entry, amount, term.termStandardTurns)
  if preview then
    local total = math.floor(preview.totalRepayment + 0.5)
    local borrowed = math.floor(amount + 0.5)
    local detail = L("LOC_WBL_UI_PREVIEW_TT", string.format("%.2f", entry.quotedV or 0), Pct(preview.nominalRate))
    if lastView and lastView.borrow.priceNoteKey then detail = detail .. "[NEWLINE]" .. L(lastView.borrow.priceNoteKey) end
    -- Screenshot item 25: the interest as a percentage of the amount borrowed.
    local interestPct = borrowed > 0 and (total - borrowed) / borrowed or 0
    Line(L("LOC_WBL_UI_PREVIEW_1", preview.paymentTurns, Gold(preview.payment), FirstPayment(preview.graceTurns)) ..
      "[NEWLINE]" .. L("LOC_WBL_UI_PREVIEW_2", total, borrowed, total - borrowed, string.format("%d",
        math.floor(interestPct * PERCENT + 0.5))), detail)
    if option ~= nil and option.kind ~= "NONE" and lastView then
      Line(L("LOC_WBL_UI_PREVIEW_MS", MilestoneName(option),
        lastView.turn + math.ceil((term.graceTurns + term.paymentTurns) / 2) - 1, pct))
    end
  else
    Line(L("LOC_WBL_UI_REASON_QUOTE_UNAVAILABLE"))
    print("[WBL UI] preview unavailable: " .. tostring(perr))
  end
  -- Decision 58: warn that the loan cancels part or all of the borrower's ownership.
  local impact = lastView and WBL_BANKVIEW.LoanOwnershipImpact(lastView.invest, amount)
  if impact then
    Line(L("LOC_WBL_UI_LOAN_OWNERSHIP", Gold(impact.cancelled), Pct(impact.shareBefore), Pct(impact.shareAfter)),
      L("LOC_WBL_UI_OWN_EXPLAIN"))
    if #impact.lostKeys > 0 then
      local names = {}
      for _, key in ipairs(impact.lostKeys) do names[#names + 1] = L(key) end
      Line(L("LOC_WBL_UI_LOAN_OWNERSHIP_LOST", table.concat(names, ", ")))
    end
  end
  local reason = ""
  if entry.milestoneRequired and (option == nil or option.kind == "NONE") then reason = "LOC_WBL_UI_REASON_MILESTONE_REQUIRED" end
  if preview == nil then reason = "LOC_WBL_UI_REASON_QUOTE_UNAVAILABLE" end
  local args = {amount = amount, termStandardTurns = term.termStandardTurns, quotedV = entry.quotedV, milestone = option}
  for k, v in pairs(extra) do args[k] = v end
  local function send() Send(kind, args, key) end
  Action("", L("LOC_WBL_UI_BORROW_TAKE_BTN", Gold(amount)), reason, function()
    local warning = preview and WBL_BANKVIEW.LoanWarning(LocalGPT(), lastView.loans.perTurn or 0, preview.payment)
    if warning then OpenConfirm(warning, send) else send() end
  end, kind, key)
end

-- Tabs ---------------------------------------------------------------------------------------------
local function BuildBorrow(view)
  local b = view.borrow
  local card = BeginCard()
  local creditTT = L("LOC_WBL_UI_CREDIT_TT", Gold(b.limit or 0), L(b.ratingKey), Gold(b.outstandingPrincipal or 0),
    Gold(b.pool or 0), Gold(b.cap or 0), b.liquidityKey and L(b.liquidityKey) or "", Pct(b.growth or 0))
  CardHeader(L("LOC_WBL_UI_CREDIT_LINE", Gold(b.availableDraw or 0)), "", L(view.borrow.tierKey) .. " · " ..
    L("LOC_WBL_UI_RATING_PILL", L(b.ratingKey)), "TIER", creditTT)
  if b.scarActive then Line(L("LOC_WBL_UI_BORROW_SCAR")) end
  if not b.available then Line(L("LOC_WBL_UI_BORROW_BLOCKED", L(b.reasonKey))) end
  if #b.products == 0 and b.available then Line(L("LOC_WBL_UI_BORROW_NO_PRODUCTS")) end
  EndCard(card)
  for _, entry in ipairs(b.products) do
    card = BeginCard()
    local open = entry.available and b.available
    CardHeader(L(entry.productKey), open and L("LOC_WBL_UI_UP_TO", Gold(entry.maxAmount)) or "", nil, nil,
      not open and L(entry.available and b.reasonKey or entry.reasonKey) or nil)
    if not open then
      if entry.reason == "TIER_INELIGIBLE" and entry.product == "INFRASTRUCTURE" then
        Line(L("LOC_WBL_UI_ONLY_INFRASTRUCTURE"))
      else
        Line(L("LOC_WBL_UI_BORROW_BLOCKED", L(entry.available and b.reasonKey or entry.reasonKey)))
      end
    else
      LoanChooser("P:" .. entry.product, entry, "TAKE_LOAN", {product = entry.product})
    end
    EndCard(card)
  end
  for _, entry in ipairs(b.recoveryOffers) do
    card = BeginCard()
    CardHeader(L("LOC_WBL_UI_RECOVERY_HEADER", L(entry.disasterKey)), "", nil, nil,
      L("LOC_WBL_UI_RECOVERY_INFO", entry.expiryTurn, entry.turnsLeft, Gold(entry.maxAmount)))
    if not entry.available then
      Line(L("LOC_WBL_UI_BORROW_BLOCKED", L(entry.reasonKey)))
    else
      LoanChooser("R:" .. tostring(entry.entitlementID), entry, "CLAIM_RECOVERY", {entitlementID = entry.entitlementID})
    end
    EndCard(card)
  end
  if b.grant.available or b.grant.reason ~= "NO_OFFER" then
    card = BeginCard()
    CardHeader(L("LOC_WBL_UI_GRANT_HEADER"), b.grant.available and L("LOC_WBL_UI_GOLD_VALUE", Gold(b.grant.amount)) or "",
      nil, nil, L("LOC_WBL_UI_GRANT_INFO", Gold(b.grant.amount)))
    if b.grant.available then
      local option = CurrentMilestone()
      Selector(L("LOC_WBL_UI_SEL_MILESTONE_REQ", Pct(0)), MilestoneName(option), function() CycleMilestone() Redraw() end)
      local reason = (option == nil or option.kind == "NONE") and "LOC_WBL_UI_REASON_MILESTONE_REQUIRED" or ""
      Action("", L("LOC_WBL_UI_GRANT_BTN"), reason, function()
        Send("REQUEST_GRANT", {quotedAmount = b.grant.amount, milestone = option}, "GRANT")
      end, "REQUEST_GRANT", "GRANT")
    elseif b.grant.reason == "TIER_INELIGIBLE" then
      Line(L("LOC_WBL_UI_ONLY_GRANT"))
    else
      Line(L("LOC_WBL_UI_BORROW_BLOCKED", L(b.grant.reasonKey)))
    end
    EndCard(card)
  end
  HintLine()
end

local STAGE_PILL = {ON_TIME = "LOC_WBL_UI_PILL_ON_TIME", ARREARS = "LOC_WBL_UI_PILL_ARREARS",
  DEFAULT = "LOC_WBL_UI_PILL_DEFAULT", DEFAULT_STAGE2 = "LOC_WBL_UI_PILL_DEFAULT_STAGE2"}

local function BuildLoans(view)
  local l = view.loans
  if l.inDefault then
    Line(L("LOC_WBL_UI_LOANS_DEFAULT", l.defaultTurn, l.penaltyStage), nil)
  elseif l.warning then
    Line(L("LOC_WBL_UI_LOANS_WARNING", l.warningLoanID, l.turnsToDefault))
  elseif l.arrearsActive then
    Line(L("LOC_WBL_UI_LOANS_ARREARS"))
  end
  if #l.penalties > 0 then
    local parts = {}
    for _, p in ipairs(l.penalties) do
      parts[#parts + 1] = L(p.textKey, p.value) .. (p.suspended and L("LOC_WBL_UI_PENALTY_SUSPENDED") or "")
    end
    Line(L("LOC_WBL_UI_PENALTIES_LINE", #l.penalties), table.concat(parts, "[NEWLINE]"))
  end
  if #l.rows == 0 then Line(L("LOC_WBL_UI_LOANS_NONE")) end
  for _, row in ipairs(l.rows) do
    local s = row.summary
    local card = BeginCard()
    local detail = L("LOC_WBL_UI_LOAN_TT", Gold(row.arrears), Gold(row.overduePrincipal), Gold(row.overdueInterest),
      Gold(row.arrearsFees), row.missedCount, row.arrearsTurns, row.defaultTurns, Pct(row.interestPremium))
    CardHeader(L("LOC_WBL_UI_LOAN_TITLE", L(row.productKey), row.loanID),
      L("LOC_WBL_UI_LOAN_SUB", Gold(row.originalPrincipal), row.originTurn),
      L(STAGE_PILL[row.stage] or STAGE_PILL.ON_TIME, row.turnsToDefault), row.stage, detail)
    if row.isRecovery then Line(L("LOC_WBL_UI_LOAN_RECOVERY", L(row.disasterKey))) end
    Line(L("LOC_WBL_UI_LOAN_OWE", s.owe, s.borrowed, s.interest), detail)
    if row.installmentsLeft > 0 then
      Line(L("LOC_WBL_UI_LOAN_PAYMENTS", s.payments, s.payment, row.nextDueTurn))
    else
      Line(L("LOC_WBL_UI_LOAN_PAID_UP"))
    end
    if row.inArrears then Line(L("LOC_WBL_UI_LOAN_OVERDUE", s.overdue)) end
    if row.milestone.kind ~= "NONE" and row.milestone.kind ~= nil then
      -- Fix 5 (Leon, MP game F): what the milestone is, its deadline, the forgiveness and its status.
      local m = row.milestone
      Line(L("LOC_WBL_UI_LOAN_MILESTONE2", LoanMilestoneName(m), m.deadlineTurn, Pct(m.forgiveness), L(m.statusKey)),
        L("LOC_WBL_UI_MILESTONE_TT"))
    end
    local repayKey, restructureKey = "REPAY:" .. row.loanID, "RESTRUCTURE:" .. row.loanID
    ButtonPair(
      {text = s.payNow and L("LOC_WBL_UI_PAY_NOW", s.payNow, s.save) or L("LOC_WBL_UI_REPAY_BTN", Gold(row.repay.totalDue or 0)),
       reason = row.repay.reasonKey, kind = "REPAY_EARLY", key = repayKey,
       tooltip = row.repay.available and L("LOC_WBL_UI_REPAY_INFO", Gold(row.repay.totalDue), Gold(row.repay.waived)) or nil,
       onClick = function() Send("REPAY_EARLY", {loanID = row.loanID, quotedAmount = row.repay.totalDue}, repayKey) end},
      {text = L("LOC_WBL_UI_RESTRUCTURE_BTN2", row.restructure.favorCost), reason = row.restructure.reasonKey,
       kind = "RESTRUCTURE", key = restructureKey,
       tooltip = L("LOC_WBL_UI_RESTRUCTURE_INFO", row.restructure.termTurns or row.restructure.termStandardTurns,
         row.restructure.favorCost),
       onClick = function() Send("RESTRUCTURE", {loanID = row.loanID, quotedV = row.restructure.quotedV}, restructureKey) end})
    local msWindow = row.selectMilestone.available and MilestoneWindow(row.graceTurns, row.paymentTurns) or nil
    if row.selectMilestone.available and NoMilestoneFits(msWindow) then
      -- Screenshot item 4: no picker or dead button when nothing can be finished before the halfway point.
      Line(L("LOC_WBL_UI_MS_NONE_FITS_LOAN"))
    elseif row.selectMilestone.available then
      local window = msWindow
      local option = CurrentMilestone(window)
      local tierRow = WBL_CONFIG.tiers[view.tier]
      Selector(L("LOC_WBL_UI_SEL_MILESTONE", Pct(tierRow and tierRow.milestoneForgiveness or 0)), MilestoneName(option),
        function() CycleMilestone(window) Redraw() end, L("LOC_WBL_UI_SELECT_MILESTONE_INFO"))
      local msKey = "MILESTONE:" .. row.loanID
      Action("", L("LOC_WBL_UI_SELECT_MILESTONE_BTN"),
        (option == nil or option.kind == "NONE") and "LOC_WBL_UI_REASON_MILESTONE_REQUIRED" or "", function()
          Send("SELECT_MILESTONE", {loanID = row.loanID, milestone = option}, msKey)
        end, "SELECT_MILESTONE", msKey)
    end
    EndCard(card)
  end
  local r = l.debtRelief
  if r.status == "PENDING" or r.reason ~= "RELIEF_TIER" then
    local card = BeginCard()
    CardHeader(L("LOC_WBL_UI_RELIEF_HEADER"), "", nil, nil, L("LOC_WBL_UI_RELIEF_INFO", Pct(r.fraction), Gold(r.forgiveAmount)))
    if r.status == "PENDING" then
      Line(L("LOC_WBL_UI_RELIEF_PENDING_INFO", r.turnsLeft, r.deadlineTurn))
    else
      local option = CurrentMilestone()
      Selector(L("LOC_WBL_UI_SEL_MILESTONE_REQ", Pct(r.fraction)), MilestoneName(option), function() CycleMilestone() Redraw() end)
      local reason = r.reasonKey
      if reason == "" and (option == nil or option.kind == "NONE") then reason = "LOC_WBL_UI_REASON_MILESTONE_REQUIRED" end
      Action("", L("LOC_WBL_UI_RELIEF_BTN"), reason, function() Send("DEBT_RELIEF", {milestone = option}, "RELIEF") end,
        "DEBT_RELIEF", "RELIEF")
    end
    EndCard(card)
  else
    -- Developed and Developing civs can't use relief: one line, the rules in its tooltip.
    Line(L("LOC_WBL_UI_RELIEF_TIER_LINE"), L("LOC_WBL_UI_RELIEF_INFO", Pct(r.fraction), Gold(r.forgiveAmount)))
  end
  HintLine()
end

-- Unmet civs show as unknown (CivilizationIcon.lua:48-50: met or the local player).
local function Met(playerID)
  local localID = Game.GetLocalPlayer()
  if playerID == localID then return true end
  local ok, met = pcall(function() return Players[localID]:GetDiplomacy():HasMet(playerID) end)
  return ok and met == true
end

local function OwnerName(playerID)
  if playerID == Game.GetLocalPlayer() then return L("LOC_WBL_UI_YOU") end
  if not Met(playerID) then return L("LOC_WBL_UI_UNKNOWN_CIV") end
  return CivName(playerID)
end

-- Civ colours (UI.GetPlayerColors, CivilizationIcon.lua:76); unknown civs grey.
local function OwnerColor(playerID)
  if not Met(playerID) then return Color({120, 120, 120}) end
  local ok, back = pcall(function() return UI.GetPlayerColors(playerID) end)
  if ok and type(back) == "number" then return back end
  return Color({200, 200, 200})
end

local MAX_SLICES = 8
local GREY = {120, 120, 120}

-- Item 12: the ownership ring. Slice k covers the shares of owners 1..k (largest first) and sits above
-- slice k+1, so each owner's colour shows only on its own share. Decision 59: with deposits but no counting
-- share, the whole ring is grey (greyed is true, owners empty).
local function Pie(owners, presidentID, greyed, book)
  local row = Get(pieIM)
  TrackRow(row)
  local cumulative = 0
  for k = 1, MAX_SLICES do
    local meter = row["Slice" .. k]
    local owner = owners[k]
    if owner ~= nil then
      cumulative = cumulative + owner.share
      meter:SetHide(false)
      meter:SetPercent(math.min(1, cumulative))
      meter:SetColor(OwnerColor(owner.playerID))
    elseif k == 1 and greyed then
      meter:SetHide(false)
      meter:SetPercent(1)
      meter:SetColor(Color(GREY, 160))
    else
      meter:SetHide(true)
    end
  end
  -- Draw order: the smallest cumulative (slice 1) must be on top; Slice1 is last in the XML.
  local top = owners[1]
  local icon = "ICON_CIVILIZATION_UNKNOWN"
  if top ~= nil and Met(top.playerID) then
    local ok, name = pcall(function() return PlayerConfigurations[top.playerID]:GetCivilizationTypeName() end)
    if ok and name then icon = "ICON_" .. name end
  end
  local ok = pcall(function()
    local x, y, sheet = IconManager:FindIconAtlas(icon, EMBLEM_SIZE)
    if sheet ~= nil and sheet ~= "" then row.Emblem:SetTexture(x, y, sheet) end
    if top ~= nil and Met(top.playerID) then
      local _, front = UI.GetPlayerColors(top.playerID)
      row.Emblem:SetColor(front)
    end
  end)
  row.Emblem:SetHide(not ok or top == nil)
  -- Item 19: everyone sees each owner's share and net deposit (floored at 0, the figure the share comes from).
  for k, owner in ipairs(owners) do
    if k > MAX_SLICES then break end
    local line = legendIM:GetInstance(row.Legend)
    line.Swatch:SetHide(false)
    line.Swatch:SetColor(OwnerColor(owner.playerID))
    local name = OwnerName(owner.playerID)
    if owner.playerID == presidentID then name = name .. " " .. L("LOC_WBL_UI_OWNER_PRESIDENT") end
    line.Text:SetText(L("LOC_WBL_UI_OWNER_LINE2", name, Pct(owner.share), Gold(owner.eligibleCapital)))
  end
  if greyed then
    local line = legendIM:GetInstance(row.Legend)
    line.Swatch:SetHide(false)
    line.Swatch:SetColor(Color(GREY))
    line.Text:SetText(L("LOC_WBL_UI_OWNERS_NOT_COUNTING"))
  end
  -- Item 19: the President also sees every civ's deposited, owed and net amounts here.
  if book ~= nil and #book > 0 then
    local head = legendIM:GetInstance(row.Legend)
    head.Swatch:SetHide(true)
    head.Text:SetText(L("LOC_WBL_UI_BOOK_HEADER"))
    for _, entry in ipairs(book) do
      local line = legendIM:GetInstance(row.Legend)
      line.Swatch:SetHide(false)
      line.Swatch:SetColor(OwnerColor(entry.playerID))
      line.Text:SetText(L("LOC_WBL_UI_BOOK_LINE", OwnerName(entry.playerID), Gold(entry.deposited), Gold(entry.owed),
        Signed(entry.net)))
    end
  end
  row.Legend:CalculateSize()
  row.Root:SetSizeY(math.max(PIE_HEIGHT, row.Legend:GetSizeY() + LEGEND_MARGIN))
end

-- Fix 3 (MP game F): every President condition still missing, in words.
local function PresidentMissing(pr)
  local parts = {}
  if not pr.shareMet then parts[#parts + 1] = L("LOC_WBL_UI_PRESIDENT_NEED_SHARE", Pct(pr.shareNeeded)) end
  if not pr.capitalMet then parts[#parts + 1] = L("LOC_WBL_UI_PRESIDENT_NEED_CAPITAL", Gold(pr.capitalRemaining)) end
  if pr.shareMet and pr.capitalMet and pr.confirmCount < pr.confirmNeeded then
    parts[#parts + 1] = L("LOC_WBL_UI_PRESIDENT_NEED_TURNS", pr.confirmCount, pr.confirmNeeded)
  end
  return parts
end

local function BuildInvest(view)
  local i = view.invest
  local pr = i.president
  -- Who owns the bank (decisions 58 and 59, item 19).
  local card = BeginCard()
  CardHeader(L("LOC_WBL_UI_OWNERS_HEADER"), "", nil, nil, L("LOC_WBL_UI_OWNERS_TT"))
  local owners = i.owners or {}
  if #owners == 0 and not i.anyDeposits then
    Line(L("LOC_WBL_UI_OWNERS_NONE"))
  else
    Pie(owners, pr.presidentID, #owners == 0, i.book)
  end
  EndCard(card)
  -- Item 18: your own deposits in their own card, with deposited, owed and net (decision 58).
  card = BeginCard()
  CardHeader(L("LOC_WBL_UI_DEPOSITS_HEADER"), "", nil, nil, L("LOC_WBL_UI_OWN_EXPLAIN"))
  Line(L("LOC_WBL_UI_OWN_FIGURES", Gold(i.deposited), Gold(i.owed), Signed(i.net)))
  Line(L("LOC_WBL_UI_OWN_COUNTS", Gold(i.eligibleCapital), Pct(i.eligibleShare)))
  if i.blockKey ~= nil and i.blockKey ~= "" then Line(L(i.blockKey)) end
  if #i.deposits == 0 then Line(L("LOC_WBL_UI_DEPOSITS_NONE")) end
  for _, d in ipairs(i.deposits) do
    local key = "WITHDRAW:" .. d.depositID
    -- Item 10: "earned N gold so far"; the early-withdrawal loss only in the button's tooltip.
    Action(L("LOC_WBL_UI_DEPOSIT_ROW3", d.depositID, Gold(d.principal), d.maturityTurn, Gold(d.accruedReturn)),
      L("LOC_WBL_UI_WITHDRAW_BTN2", Gold(d.earlyPayout)), d.withdraw.reasonKey,
      function() Send("WITHDRAW", {depositID = d.depositID, quotedAmount = d.withdraw.quotedAmount}, key) end,
      "WITHDRAW", key, L("LOC_WBL_UI_WITHDRAW_INFO2", Gold(d.earlyPayout), Gold(d.principal),
        Gold(d.principal - d.earlyPayout), Gold(d.accruedReturn)))
  end
  EndCard(card)
  -- Item 2: the benefits as three tiles in one row (item 17).
  card = BeginCard()
  CardHeader(L("LOC_WBL_UI_BENEFITS_HEADER"), "", nil, nil, i.perks.isInvestor and nil or
    L("LOC_WBL_UI_INVEST_NOT_INVESTOR", Gold(i.thresholds[1].needed)))
  local p = i.perks
  if not p.isInvestor and i.blockReason == "NETTED" then Line(L("LOC_WBL_UI_BENEFITS_NETTED")) end
  local grid = Grid()
  local favorSub = p.favor > 0 and L("LOC_WBL_UI_TILE_HAVE") or
    (p.nextFavorAt and L("LOC_WBL_UI_TILE_NEXT", Gold(p.nextFavorAt)) or L("LOC_WBL_UI_TILE_NONE"))
  Tile(grid, L("LOC_WBL_UI_TILE_FAVOR", math.max(1, p.favor)), favorSub, p.favor > 0,
    L("LOC_WBL_UI_PERK_FAVOR", p.favor, p.shareFavor, p.capitalFavor, p.favorCap))
  local thresholds = {}
  for _, th in ipairs(i.thresholds) do thresholds[th.textKey] = th end
  local half = thresholds["LOC_WBL_UI_THRESHOLD_PREFERRED_HALF"]
  local full = thresholds["LOC_WBL_UI_THRESHOLD_PREFERRED_FULL"]
  local discountSub
  if p.preferredStep >= 2 then discountSub = L("LOC_WBL_UI_TILE_FULL")
  elseif p.preferredStep == 1 then discountSub = L("LOC_WBL_UI_TILE_HALF_NOW", full and Gold(full.needed) or "?")
  else discountSub = L("LOC_WBL_UI_TILE_HALF_AT", half and Gold(half.needed) or "?") end
  Tile(grid, L("LOC_WBL_UI_TILE_DISCOUNT"), discountSub, p.preferredStep > 0,
    L(WBL_BANKVIEW.Key("PERK_PREFERRED", p.preferredStep)) .. "[NEWLINE]" ..
      L(p.liquidityExempt and "LOC_WBL_UI_PERK_EXEMPT" or "LOC_WBL_UI_PERK_NOT_EXEMPT"))
  local presidentSub
  local missing = PresidentMissing(pr)
  if pr.isPresident then presidentSub = L("LOC_WBL_UI_TILE_PRESIDENT_YOU")
  elseif pr.presidentID >= 0 then presidentSub = L("LOC_WBL_UI_PRESIDENT_OTHER", OwnerName(pr.presidentID))
  elseif #missing > 0 then presidentSub = L("LOC_WBL_UI_TILE_PRESIDENT_NEEDS", table.concat(missing, ", "))
  else presidentSub = L("LOC_WBL_UI_TILE_PRESIDENT_SOON") end
  Tile(grid, L("LOC_WBL_UI_PRESIDENT_HEADER"), presidentSub, pr.isPresident,
    (pr.isPresident and (L("LOC_WBL_UI_PRESIDENT_YOU", pr.sinceTurn, pr.perks.favor, pr.perks.merchantPoints,
      pr.perks.envoyTurns) .. "[NEWLINE]") or "") ..
    L("LOC_WBL_UI_PRESIDENT_PROGRESS2", Pct(pr.shareNeeded), pr.shareMet and L("LOC_WBL_UI_MET") or L("LOC_WBL_UI_MISSING"),
      Gold(pr.capitalNeeded), pr.capitalMet and L("LOC_WBL_UI_MET") or L("LOC_WBL_UI_MISSING"),
      pr.confirmCount, pr.confirmNeeded, pr.eraTurns, pr.eraTurnsNeeded))
  EndGrid(grid)
  if #i.unpaid > 0 then
    local parts = {}
    for _, u in ipairs(i.unpaid) do parts[#parts + 1] = L(u.textKey, Gold(u.amount)) end
    Line(L("LOC_WBL_UI_UNPAID_HEADER"), table.concat(parts, "[NEWLINE]"))
  end
  EndCard(card)
  -- New deposit.
  card = BeginCard()
  CardHeader(L("LOC_WBL_UI_DEPOSIT_NEW_HEADER"), "", nil, nil, L("LOC_WBL_UI_DEPOSIT_TT", Gold(i.unit)))
  if not i.deposit.available then
    Line(L("LOC_WBL_UI_DEPOSIT_REFUSED") .. " " .. L(i.deposit.reasonKey))
  else
    local steps = WBL_BANKVIEW.DEPOSIT_UNIT_STEPS
    local stepIndex, state = Pick(steps, "DEPOSIT", "step")
    local termIndex = Pick(i.deposit.terms, "DEPOSIT", "term")
    local amount = WBL_BANKVIEW.DepositAmount(i, stepIndex)
    local term = i.deposit.terms[termIndex]
    Selector(L("LOC_WBL_UI_SEL_AMOUNT"), L("LOC_WBL_UI_GOLD_VALUE", Gold(amount)), function()
      state.step = stepIndex + 1
      Redraw()
    end, L("LOC_WBL_UI_DEPOSIT_REFUSED_NOTE"))
    -- Screenshot item 1: the term in this game's turns, like loans.
    Selector(L("LOC_WBL_UI_SEL_TERM"), L("LOC_WBL_UI_TURNS_VALUE", term.termTurns), function()
      state.term = termIndex + 1
      Redraw()
    end, L("LOC_WBL_UI_TERM_TT", term.termStandardTurns))
    local preview = WBL_BANKVIEW.DepositPreview(i, amount, term.termStandardTurns)
    if preview then
      Line(L("LOC_WBL_UI_DEPOSIT_PAYS", Gold(preview.payoutAtMaturity), view.turn + term.termTurns,
        Gold(preview.expectedReturn)),
        L("LOC_WBL_UI_DEPOSIT_PREVIEW", Gold(preview.eligiblePart), Gold(preview.amount), Gold(preview.expectedReturn),
          Gold(preview.payoutAtMaturity)))
    end
    -- Grey the button out when the treasury can't cover it (MP game A: 25 offered to players
    -- holding 5). The reducer still checks the boundary treasury.
    local gold = LocalGold()
    local reason = (gold ~= nil and amount > gold) and "LOC_WBL_UI_REASON_INSUFFICIENT_GOLD" or ""
    Action("", L("LOC_WBL_UI_DEPOSIT_BTN2", Gold(amount)), reason, function()
      Send("DEPOSIT", {amount = amount, termStandardTurns = term.termStandardTurns}, "DEPOSIT")
    end, "DEPOSIT", "DEPOSIT")
  end
  EndCard(card)
  -- Freezes: three per row, only civs at war (item 11).
  local f = i.freezes
  card = BeginCard()
  CardHeader(L("LOC_WBL_UI_FREEZE_HEADER"), "", nil, nil, L("LOC_WBL_UI_FREEZE_RULE"))
  for _, row in ipairs(f.rows) do
    if row.canLift then
      Action(L("LOC_WBL_UI_FREEZE_ROW", OwnerName(row.targetID), L(row.modeKey), row.placedTurn),
        L("LOC_WBL_UI_FREEZE_LIFT_BTN", OwnerName(row.targetID)), "", function()
          Send("FREEZE_LIFT", {freezeID = row.freezeID}, "FREEZE")
        end, "FREEZE_LIFT", "FREEZE")
    else
      Line(L("LOC_WBL_UI_FREEZE_ROW", OwnerName(row.targetID), L(row.modeKey), row.placedTurn))
    end
  end
  if not f.canPlace then
    Line(L("LOC_WBL_UI_BORROW_BLOCKED", L(f.reasonKey)))
  elseif f.noTargetKey then
    Line(L("LOC_WBL_UI_BORROW_BLOCKED", L(f.noTargetKey)))
  else
    Line(L("LOC_WBL_UI_FREEZE_SHORT"))
    local fgrid = Grid()
    for _, target in ipairs(f.targets) do
      for _, mode in ipairs(target.modes) do
        GridButton(fgrid, L("LOC_WBL_UI_FREEZE_BTN2", OwnerName(target.playerID)), "", function()
          Send("FREEZE_PLACE", {targetID = target.playerID, mode = mode}, "FREEZE")
        end, "FREEZE_PLACE", L("LOC_WBL_UI_FREEZE_BTN", OwnerName(target.playerID), L(WBL_BANKVIEW.Key("FREEZE", mode))))
      end
    end
    EndGrid(fgrid)
  end
  local note = RefusalText("FREEZE")
  if note ~= "" then Line(note) end
  EndCard(card)
  HintLine()
end

local function BuildBank(view)
  local b = view.bank
  local card = BeginCard()
  CardHeader(L("LOC_WBL_UI_TAB_BANK"), "", L(b.liquidityKey), "TIER",
    b.valueAdjustment and L("LOC_WBL_UI_BANK_EFFECT", string.format("%+.2f", b.valueAdjustment),
      string.format("%.2f", b.limitMultiplier)) or nil)
  Line(L("LOC_WBL_UI_BANK_POOL", Gold(b.pool), Gold(b.cap), Pct(b.fillFraction)),
    L("LOC_WBL_UI_BANK_LENT", Gold(b.receivables), Gold(b.disbursed), Gold(b.depositLiabilities)))
  -- Screenshot item 13: what the pool is and what the current state means.
  if b.liquidityTier ~= nil and b.liquidityTier ~= "" then
    Line(L(WBL_BANKVIEW.Key("BANK_STATE", b.liquidityTier)), L("LOC_WBL_UI_BANK_POOL_TT"))
  end
  if b.emergency then Line(L("LOC_WBL_UI_BANK_EMERGENCY")) end
  EndCard(card)
  card = BeginCard()
  CardHeader(L("LOC_WBL_UI_BANK_CIVS_HEADER"), "", nil, nil, not b.canSeeAll and L("LOC_WBL_UI_BANK_PRIVATE") or nil)
  for _, civ in ipairs(b.civs) do
    Line(L("LOC_WBL_UI_BANK_CIV_ROW", civ.isSelf and L("LOC_WBL_UI_YOU") or OwnerName(civ.playerID), L(civ.tierKey),
      L(civ.ratingKey), Gold(civ.debt),
      civ.inDefault and L("LOC_WBL_UI_BANK_DEFAULT_STAGE", civ.defaultStage) or L("LOC_WBL_UI_BANK_NO_DEFAULT")))
  end
  if not b.canSeeAll then Line(L("LOC_WBL_UI_BANK_PRIVATE")) end
  EndCard(card)
  if #b.freezes > 0 then
    card = BeginCard()
    CardHeader(L("LOC_WBL_UI_BANK_FREEZES_HEADER"))
    for _, row in ipairs(b.freezes) do
      Line(L("LOC_WBL_UI_FREEZE_ROW", OwnerName(row.targetID), L(row.modeKey), row.placedTurn))
    end
    EndCard(card)
  end
  HintLine()
end

local BUILDERS = {BORROW = BuildBorrow, LOANS = BuildLoans, INVEST = BuildInvest, BANK = BuildBank}

-- What the local player's panel shows (ui.verboseLogging). One summary line per rebuild, a result line whenever the
-- published lastResult changes, and the full view text (WBL_STATE.CanonicalString) on open and after each result.
local lastLoggedResult = nil
local lastLoggedSummary = nil

-- Long text over numbered lines, like the gameplay "[WBL DUMP]" lines.
local function UIDump(label, text)
  local size = WBL_CONFIG.bank.dumpChunkSize
  local body = string.gsub(tostring(text), "[%c]", " ")
  local total = math.max(1, math.ceil(string.len(body) / size))
  for part = 1, total do
    local first = (part - 1) * size + 1
    UILog("dump " .. label .. " part=" .. part .. "/" .. total .. " " .. string.sub(body, first, first + size - 1))
  end
end
local function LogView(label, view)
  if not Verbose() or type(view) ~= "table" then return end
  local ok, err = pcall(function()
    local b = type(view.borrow) == "table" and view.borrow or {}
    local l = type(view.loans) == "table" and view.loans or {}
    local i = type(view.invest) == "table" and view.invest or {}
    local summary = ("tab=" .. tostring(tab) .. " ok=" .. tostring(view.ok) .. " reason=" .. tostring(view.reasonKey) ..
      " player=" .. tostring(view.playerID) .. " nonce=" .. tostring(view.nonce) .. " sentNonce=" .. tostring(sentNonce) ..
      " suspended=" .. tostring(view.suspended) .. " tier=" .. tostring(b.tierKey) .. " rating=" .. tostring(b.ratingKey) ..
      " limit=" .. tostring(b.limit) .. " draw=" .. tostring(b.availableDraw) .. " pool=" .. tostring(b.pool) ..
      " borrowAvailable=" .. tostring(b.available) .. " borrowReason=" .. tostring(b.reasonKey) ..
      " products=" .. tostring(type(b.products) == "table" and #b.products or nil) ..
      " loans=" .. tostring(type(l.rows) == "table" and #l.rows or nil) .. " inDefault=" .. tostring(l.inDefault) ..
      " deposits=" .. tostring(type(i.deposits) == "table" and #i.deposits or nil) .. " E=" .. tostring(i.eligibleCapital))
    if summary ~= lastLoggedSummary or label ~= "rebuild" then
      lastLoggedSummary = summary
      UILog("view " .. label .. " " .. summary)
    end
    local result = view.lastResult
    local key = type(result) == "table" and (tostring(result.nonce) .. ":" .. tostring(result.kind) .. ":" ..
      tostring(result.ok) .. ":" .. tostring(result.reason)) or "none"
    local changed = key ~= lastLoggedResult
    if changed then
      lastLoggedResult = key
      UILog("result " .. key .. " text=" .. tostring(type(result) == "table" and result.reasonKey or ""))
    end
    if (label == "open" or changed) and hasState and WBL_STATE ~= nil and WBL_STATE.CanonicalString ~= nil then
      UIDump("view_" .. label, WBL_STATE.CanonicalString(view))
    end
  end)
  if not ok then print("[WBL UI] view log error=" .. tostring(err)) end
end

-- Once per local turn (ui.verboseLogging): what the bank offers the local player, without opening the panel.
local function OnTurnActivated(ePlayer, isFirstTime)
  if not Verbose() then return end
  local localID = Game.GetLocalPlayer()
  if ePlayer ~= localID then return end
  local ok, err = pcall(function()
    UILog("turn activated player=" .. tostring(ePlayer) .. " first=" .. tostring(isFirstTime) .. " turn=" ..
      tostring(Turn()) .. " open=" .. tostring(open))
    LogView("turn", WBL_BANKVIEW.BuildView(ReadState(), localID, WBL_CONFIG, nil, GatherFacts(localID)))
  end)
  if not ok then print("[WBL UI] turn log error=" .. tostring(err)) end
end

-- Selected-tab overlay as ReportScreen.lua:1714-1718 (show the selected tab's overlay, hide the others).
local function SetTabButtons()
  Controls.TabBorrowSelected:SetHide(tab ~= "BORROW")
  Controls.TabLoansSelected:SetHide(tab ~= "LOANS")
  Controls.TabInvestSelected:SetHide(tab ~= "INVEST")
  Controls.TabBankSelected:SetHide(tab ~= "BANK")
end

-- Screenshot item 7: the last request in plain words, with its amount when this panel sent it.
local AMOUNT_KINDS = {TAKE_LOAN = true, CLAIM_RECOVERY = true, REPAY_EARLY = true, DEPOSIT = true, WITHDRAW = true}
local function ResultText(result)
  local kind = tostring(result.kind)
  if result.ok then
    local amount = sentAmounts[result.nonce]
    if AMOUNT_KINDS[kind] and type(amount) == "number" then
      return L(WBL_BANKVIEW.Key("LAST_OK_AMOUNT", kind), Gold(amount))
    end
    return L(WBL_BANKVIEW.Key("LAST_OK", kind))
  end
  return L(WBL_BANKVIEW.Key("LAST_FAIL", kind), L(result.reasonKey))
end

-- Item 9: the published result of the request this panel sent becomes that button's refusal line.
local function NoteResult(view)
  local result = view.lastResult
  if lastSent == nil or type(result) ~= "table" or result.nonce ~= lastSent.nonce then return end
  if not result.ok then refusals[lastSent.key] = result.reasonKey end
  lastSent = nil
end

local function Rebuild()
  dirty = false
  for _, im in ipairs(ALL_IMS) do im:ResetInstances() end
  currentParent = nil
  shownRows = {}
  SetTabButtons()
  local playerID = Game.GetLocalPlayer()
  local state = ReadState()
  local facts = GatherFacts(playerID)
  local view = WBL_BANKVIEW.BuildView(state, playerID, WBL_CONFIG, nil, facts)
  lastView = view
  LogView("rebuild", view)
  if not view.ok then
    -- Fix 2: a suspended bank names its reason (FUTURE_SCHEMA: another player runs a newer version).
    if view.suspendReason ~= nil then
      Controls.StatusLabel:SetText(L(view.reasonKey, view.suspendReason))
    else
      Controls.StatusLabel:SetText(L(view.reasonKey))
    end
  else
    if sentNonce ~= nil and view.nonce ~= sentNonce then sentNonce = nil end
    NoteResult(view)
    local status = ""
    if view.suspended then status = L("LOC_WBL_UI_SUSPENDED", view.suspendReason) end
    if view.lastResult then
      status = status .. " " .. ResultText(view.lastResult)
    end
    Controls.StatusLabel:SetText(status)
    BUILDERS[tab](view)
  end
  UpdateIncome(view)
  Controls.BodyStack:CalculateSize()
  Controls.BodyScroll:CalculateInternalSize()
end

local function OnRefresh()
  ContextPtr:ClearRequestRefresh()
  if open and dirty then Rebuild() end
end

-- One line per opening: what the scroll controls and the first row of each kind report for wheel, hover and button
-- consumption (Get* methods behind TunerUtilities.lua:352-369), so a live wheel failure names the control.
local function ConsumeFlags(control)
  if control == nil then return "nil" end
  local ok, flags = pcall(function()
    return tostring(control:GetConsumeMouseWheel()) .. "/" .. tostring(control:GetConsumeMouseOver()) .. "/" ..
      tostring(control:GetConsumeMouseButton())
  end)
  return ok and flags or "error"
end

local function ReportWheelConsumers()
  local parts = {"scroll=" .. ConsumeFlags(Controls.BodyScroll), "bar=" .. ConsumeFlags(Controls.BodyScrollBar),
    "stack=" .. ConsumeFlags(Controls.BodyStack)}
  local seen = {}
  for _, row in ipairs(shownRows) do
    for _, name in ipairs({"Root", "Text", "Button"}) do
      local key = tostring(row.kind or "row") .. "." .. name
      if row[name] ~= nil and not seen[key] then
        seen[key] = true
        parts[#parts + 1] = key .. "=" .. ConsumeFlags(row[name])
      end
    end
  end
  print("[WBL UI] wheel consumers (wheel/over/button) " .. table.concat(parts, " "))
end

-- Modal open and close as ReportScreen.lua:90-123 and FDT_Panel.lua (QueuePopup / DequeuePopup, vignette anim).
-- DequeuePopup hides the context; it is shown again so the launch-bar callbacks, the fallback button and the
-- B hotkey keep working while the panel is closed (the context also hosts them).
local function SetOpen(value)
  if value == open then return end
  open = value
  if Verbose() then
    UILog((open and "open" or "close") .. " tab=" .. tostring(tab) .. " turn=" .. tostring(Turn()) ..
      " local=" .. tostring(Game.GetLocalPlayer()))
  end
  Controls.Main:SetHide(not open)
  if open then
    if not UIManager:IsInPopupQueue(ContextPtr) then UIManager:QueuePopup(ContextPtr, PopupPriority.Medium) end
    Controls.ScreenAnimIn:SetToBeginning()
    Controls.ScreenAnimIn:Play()
    UI.PlaySound("UI_Screen_Open")
    sentNonce = nil
    dirty = true
    Rebuild()
    PassWheel(Controls.BodyScrollBar)
    ReportWheelConsumers()
    LogView("open", lastView)
  else
    CloseConfirm()
    UI.PlaySound("UI_Screen_Close")
    UIManager:DequeuePopup(ContextPtr)
    ContextPtr:SetHide(false)
  end
end

local function Toggle()
  SetOpen(not open)
end

local function SetTab(name)
  UILog("tab " .. tostring(tab) .. " -> " .. tostring(name))
  tab = name
  dirty = true
  if open then Rebuild() end
end

-- Many publish events arrive per second during AI turns: only mark dirty, rebuild when visible.
local function MarkDirty()
  dirty = true
  if open then ContextPtr:RequestRefresh() end
end

local function AttachLaunchButton()
  if attached then return end
  local stack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
  if stack == nil then
    print("[WBL UI] S7 PENDING launch bar unavailable; use the World Bank fallback button")
    return
  end
  launch, pin = {}, {}
  local ok, err = pcall(function()
    ContextPtr:BuildInstanceForControl("WBL_Bank_LaunchItem", launch, stack)
    launch.LaunchItemButton:RegisterCallback(Mouse.eLClick, Toggle)
    ContextPtr:BuildInstanceForControl("WBL_Bank_LaunchPin", pin, stack)
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
    print("[WBL UI] S7 PENDING launch bar attached; visual check required")
  else
    Controls.FallbackButton:SetHide(false)
    print("[WBL UI] S7 PENDING launch bar error=" .. tostring(err))
  end
end

-- B toggles (Leon, 2026-11-05). B is the game's default Found City key (InputActionDefaultGestures), so while
-- the panel is closed and the selected unit can found a city, B passes through to the game. Settler test as
-- UnitPanel.lua:2371 (UI.GetHeadSelectedUnit) and SelectedUnit.lua:198 (GameInfo.Units[...].FoundCity).
-- Esc closes only while open. The dev panel uses Ctrl+Shift+D.
local function SettlerSelected()
  local ok, settler = pcall(function()
    local unit = UI.GetHeadSelectedUnit()
    if unit == nil then return false end
    local row = GameInfo.Units[unit:GetUnitType()]
    return row ~= nil and row.FoundCity == true
  end)
  return ok and settler == true
end

-- FDT_Panel.lua: the hover check must include each row, because only the control under the pointer reports it.
local function OverBody()
  if Controls.BodyScroll:HasMouseOver() or Controls.BodyStack:HasMouseOver() then return true end
  for _, row in ipairs(shownRows) do
    for _, name in ipairs({"Root", "Text", "Button"}) do
      local control = row[name]
      if control ~= nil and control:HasMouseOver() then return true end
    end
  end
  return false
end

local function OnInput(input)
  local message = input:GetMessageType()
  -- Wheel over the open panel scrolls the body (Session P 2026-11-04: it did not). Reads as DiplomacyRibbon.lua:394
  -- (GetScrollValue), DiplomacyActionView.lua:1767-1770 (GetSizeY, GetRatio), CivilopediaSupport.lua:770
  -- (SetScrollValue), NotificationPanel.lua:818 (HasMouseOver), WorldInput.lua:1455 and :3803 (GetWheel, MouseWheel).
  -- Modal: the body is the only scrollable thing on screen, so any wheel scrolls it (Session P recheck
  -- 2026-11-05: the hover check never fired, likely because bare labels report no hover). The first wheel per
  -- opening is logged so a live failure shows whether the handler saw it.
  if message == MouseEvents.MouseWheel and open then
    local ratio = Controls.BodyScroll:GetRatio()
    local before = Controls.BodyScroll:GetScrollValue()
    if type(ratio) == "number" and ratio > 0 and ratio < 1 then
      local visible = Controls.BodyScroll:GetSizeY()
      local hidden = visible / ratio - visible
      local value = Controls.BodyScroll:GetScrollValue() - (input:GetWheel() / WHEEL_NOTCH) * WHEEL_PIXELS / hidden
      Controls.BodyScroll:SetScrollValue(math.max(0, math.min(1, value)))
    end
    -- Every wheel event the handler sees, for the live check (Leon, 2026-11-06).
    print("[WBL UI] wheel received delta=" .. tostring(input:GetWheel()) .. " ratio=" .. tostring(ratio) ..
      " before=" .. tostring(before) .. " after=" .. tostring(Controls.BodyScroll:GetScrollValue()) ..
      " over=" .. tostring(OverBody()) .. " overScroll=" .. tostring(Controls.BodyScroll:HasMouseOver()))
    return true
  end
  -- Open: every other key is swallowed so map panning and other screens' hotkeys can't fire underneath
  -- (FDT_Panel.lua; EndGameMenu.lua:494-512 swallows KeyDown and KeyUp the same way).
  if message ~= KeyEvents.KeyUp then return open and message == KeyEvents.KeyDown end
  local key = input:GetKey()
  if key == Keys.B and WBL_CONFIG.ui.hotkeyB == true and not input:IsControlDown() and not input:IsShiftDown()
      and not input:IsAltDown() then
    if not open and SettlerSelected() then return false end
    Toggle()
    return true
  end
  if key == Keys.VK_ESCAPE and open then
    if pendingConfirm ~= nil then CloseConfirm() else SetOpen(false) end
    return true
  end
  return open
end

local function OnViewReady()
  AttachLaunchButton()
  MarkDirty()
end

local function Shutdown()
  Events.LoadGameViewStateDone.Remove(OnViewReady)
  Events.GameCoreEventPublishComplete.Remove(MarkDirty)
  Events.PlayerTurnActivated.Remove(MarkDirty)
  Events.PlayerTurnActivated.Remove(OnTurnActivated)
end

-- Explicit initialization: the context is visible, the content panel starts closed (playbook).
ContextPtr:SetHide(false)
Controls.Main:SetHide(true)
Controls.FallbackButton:SetHide(false)
ContextPtr:SetInputHandler(OnInput, true)
ContextPtr:SetShutdown(Shutdown)
ContextPtr:SetRefreshHandler(OnRefresh)
Controls.CloseButton:RegisterCallback(Mouse.eLClick, function() SetOpen(false) end)
Controls.ConfirmCancel:RegisterCallback(Mouse.eLClick, function()
  UILog("loan warning cancelled")
  CloseConfirm()
end)
Controls.ConfirmOk:RegisterCallback(Mouse.eLClick, function()
  local onOk = pendingConfirm
  UILog("loan warning accepted")
  CloseConfirm()
  if onOk ~= nil then onOk() end
end)
Controls.Confirm:SetHide(true)
Controls.FallbackButton:RegisterCallback(Mouse.eLClick, Toggle)
Controls.TabBorrow:RegisterCallback(Mouse.eLClick, function() SetTab("BORROW") end)
Controls.TabLoans:RegisterCallback(Mouse.eLClick, function() SetTab("LOANS") end)
Controls.TabInvest:RegisterCallback(Mouse.eLClick, function() SetTab("INVEST") end)
Controls.TabBank:RegisterCallback(Mouse.eLClick, function() SetTab("BANK") end)
Events.LoadGameViewStateDone.Add(OnViewReady)
Events.GameCoreEventPublishComplete.Add(MarkDirty)
Events.PlayerTurnActivated.Add(MarkDirty)
Events.PlayerTurnActivated.Add(OnTurnActivated)
print("[WBL UI] bank panel ready; B=" .. tostring(WBL_CONFIG.ui.hotkeyB) .. " verbose=" .. tostring(Verbose()) ..
  " build=" .. tostring(WBL_CONFIG.build) .. " version=" .. tostring(WBL_CONFIG.version) .. "; S7 PENDING")
