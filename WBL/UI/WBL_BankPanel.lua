-- World Bank panel: display and synced requests only. State is read from the published property;
-- nothing here mutates game state. View model: WBL_BankView.lua. Layout and launch bar are S7 PENDING.
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
local MAX_TECH_OPTIONS = 5 -- Earliest unresearched technologies offered as milestone targets (picker space).
local PERCENT = 100 -- Fraction to percent for display.

local headerIM = InstanceManager:new("HeaderRow", "Root", Controls.BodyStack)
local textIM = InstanceManager:new("TextRow", "Text", Controls.BodyStack)
local actionIM = InstanceManager:new("ActionRow", "Root", Controls.BodyStack)
local selectorIM = InstanceManager:new("SelectorRow", "Root", Controls.BodyStack)
local spacerIM = InstanceManager:new("SpacerRow", "Root", Controls.BodyStack)
-- Selector label width inside the 240 px button, leaving room for the pull-down corner mark.
local SELECTOR_TEXT_WIDTH = 210
-- Pixels scrolled per wheel notch; the engine reports 120 per notch (WorldInput.lua:1455).
local WHEEL_PIXELS = 60
local WHEEL_NOTCH = 120
-- Rows drawn this build, for the wheel hover check (the hover registers on the control under the pointer).
local shownRows = {}

local function L(key, ...)
  return Locale.Lookup(key, ...)
end

-- Whole gold for display only; the bank keeps exact amounts (Leon, Session P 2026-11-04).
local function Gold(value)
  if type(value) ~= "number" then return "?" end
  return string.format("%d", math.floor(value + 0.5))
end

local function Pct(value)
  if type(value) ~= "number" then return "?" end
  return string.format("%.1f%%", value * PERCENT)
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

-- Engine-side milestone targets (unresearched techs, own cities). Display only; the reducer revalidates.
local function GatherFacts(playerID)
  local options = {}
  local ok, err = pcall(function()
    local player = Players[playerID]
    local techs = player:GetTechs()
    local count = 0
    for row in GameInfo.Technologies() do
      if count < MAX_TECH_OPTIONS and not techs:HasTech(row.Index) then
        options[#options + 1] = {kind = "TECH", target = row.TechnologyType, cityID = 0, name = L(row.Name)}
        count = count + 1
      end
    end
    for _, city in player:GetCities():Members() do
      options[#options + 1] = {kind = "POPULATION", target = city:GetPopulation() + 1, cityID = city:GetID(),
        name = L(city:GetName()), population = city:GetPopulation() + 1}
    end
  end)
  if not ok then print("[WBL UI] PENDING milestone options unavailable: " .. tostring(err)) end
  return {milestoneOptions = options}
end

local function MilestoneName(option)
  if option == nil or option.kind == "NONE" then return L("LOC_WBL_UI_MS_NAME_NONE") end
  if option.kind == "POPULATION" then return L("LOC_WBL_UI_MS_NAME_POPULATION", option.name, option.target) end
  return L("LOC_WBL_UI_MS_NAME_TECH", option.name)
end

local function CurrentMilestone()
  local options = lastView and lastView.milestoneOptions or {}
  local option = options[selection.milestone] or options[1]
  return option
end

local function CycleMilestone()
  local options = lastView and lastView.milestoneOptions or {}
  selection.milestone = selection.milestone + 1
  if selection.milestone > #options then selection.milestone = 1 end
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
end

local function Header(text)
  if #shownRows > 0 then PassWheel(spacerIM:GetInstance().Root) end
  local row = headerIM:GetInstance()
  TrackRow(row)
  row.Text:SetText(text)
end

local function Line(text)
  local row = textIM:GetInstance()
  TrackRow(row)
  row.Text:SetText(text)
end

local function Action(text, buttonText, reasonKey, onClick)
  local row = actionIM:GetInstance()
  TrackRow(row)
  row.Text:SetText(text)
  row.Button:SetText(buttonText)
  local waiting = lastView ~= nil and sentNonce ~= nil and lastView.nonce == sentNonce
  local disabled = (reasonKey ~= nil and reasonKey ~= "") or waiting
  row.Button:SetDisabled(disabled)
  if reasonKey ~= nil and reasonKey ~= "" then
    row.Button:SetToolTipString(L(reasonKey))
  elseif waiting then
    row.Button:SetToolTipString(L("LOC_WBL_UI_WAITING"))
  else
    row.Button:SetToolTipString("")
  end
  row.Button:RegisterCallback(Mouse.eLClick, onClick)
end

-- Option row: cycles a choice in place. Long labels truncate with the full text as tooltip, following
-- SupportFunctions.lua:17-41 (TruncateString) and :65-72 (WithTooltip).
local function Selector(text, buttonText, onClick)
  local row = selectorIM:GetInstance()
  TrackRow(row)
  row.Text:SetText(text)
  local textControl = row.Button:GetTextControl()
  textControl:SetTruncateWidth(SELECTOR_TEXT_WIDTH)
  row.Button:SetText(buttonText)
  row.Button:SetToolTipString(textControl:IsTextTruncated() and buttonText or "")
  row.Button:SetDisabled(false)
  row.Button:RegisterCallback(Mouse.eLClick, onClick)
end

local function Send(kind, args)
  local view = lastView
  local playerID = Game.GetLocalPlayer()
  if view == nil or playerID == nil or playerID < 0 or view.playerID ~= playerID then
    print("[WBL UI] request " .. tostring(kind) .. " skipped: no local bank player")
    return
  end
  local params, err = WBL_BANKVIEW.BuildRequest(view, kind, args)
  if params == nil then
    print("[WBL UI] request " .. tostring(kind) .. " not sent: " .. tostring(err))
    return
  end
  sentNonce = view.nonce
  UI.RequestPlayerOperation(playerID, PlayerOperations.EXECUTE_SCRIPT, params)
  print("[WBL UI] request=" .. kind .. " nonce=" .. tostring(view.nonce) .. " player=" .. tostring(playerID))
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

-- Loan chooser shared by ordinary products and recovery offers.
local function LoanChooser(key, entry, kind, extra)
  local steps = WBL_BANKVIEW.AMOUNT_STEPS
  local stepIndex, state = Pick(steps, key, "step")
  local termIndex = Pick(entry.terms, key, "term")
  local amount = WBL_BANKVIEW.AmountForStep(entry.maxAmount, stepIndex)
  local term = entry.terms[termIndex]
  Selector(L("LOC_WBL_UI_BORROW_AMOUNT", Gold(amount)), L("LOC_WBL_UI_BORROW_AMOUNT_BTN", Gold(amount)), function()
    state.step = state.step + 1
    Redraw()
  end)
  Selector(L("LOC_WBL_UI_BORROW_TERM"), L("LOC_WBL_UI_BORROW_TERM_BTN", term.termStandardTurns), function()
    state.term = termIndex + 1
    Redraw()
  end)
  local option = CurrentMilestone()
  Selector(entry.milestoneRequired and L("LOC_WBL_UI_BORROW_MILESTONE_REQ", Pct(entry.forgivenessFraction or 0))
      or L("LOC_WBL_UI_BORROW_MILESTONE_OPT", Pct(entry.forgivenessFraction or 0)),
    L("LOC_WBL_UI_BORROW_MILESTONE_BTN", MilestoneName(option)), function()
      CycleMilestone()
      Redraw()
    end)
  local preview, perr = WBL_BANKVIEW.Preview(entry, amount, term.termStandardTurns)
  if preview then
    Line(L("LOC_WBL_UI_BORROW_PREVIEW", preview.paymentTurns, Gold(preview.payment), preview.graceTurns,
      Gold(preview.totalRepayment), Gold(preview.totalCost), Pct(preview.nominalRate)))
  else
    Line(L("LOC_WBL_UI_REASON_QUOTE_UNAVAILABLE"))
    print("[WBL UI] preview unavailable: " .. tostring(perr))
  end
  local reason = ""
  if entry.milestoneRequired and (option == nil or option.kind == "NONE") then reason = "LOC_WBL_UI_REASON_MILESTONE_REQUIRED" end
  if preview == nil then reason = "LOC_WBL_UI_REASON_QUOTE_UNAVAILABLE" end
  local args = {amount = amount, termStandardTurns = term.termStandardTurns, quotedV = entry.quotedV, milestone = option}
  for k, v in pairs(extra) do args[k] = v end
  Action("", L("LOC_WBL_UI_BORROW_TAKE_BTN", Gold(amount)), reason, function() Send(kind, args) end)
end

-- Tabs ---------------------------------------------------------------------------------------------
local function BuildBorrow(view)
  local b = view.borrow
  Header(L("LOC_WBL_UI_TAB_BORROW"))
  Line(L("LOC_WBL_UI_BORROW_SUMMARY", L(b.tierKey), L(b.ratingKey), Gold(b.limit or 0), Gold(b.availableDraw or 0),
    Pct(b.growth or 0)))
  if b.pool then
    Line(L("LOC_WBL_UI_BORROW_LIQUIDITY", Gold(b.pool), Gold(b.cap), L(b.liquidityKey)))
  end
  if b.scarActive then Line(L("LOC_WBL_UI_BORROW_SCAR")) end
  if not b.available then Line(L("LOC_WBL_UI_BORROW_BLOCKED", L(b.reasonKey))) end
  if #b.products == 0 and b.available then Line(L("LOC_WBL_UI_BORROW_NO_PRODUCTS")) end
  if b.priceNoteKey and (#b.products > 0 or #b.recoveryOffers > 0) then Line(L(b.priceNoteKey)) end
  for _, entry in ipairs(b.products) do
    Header(L("LOC_WBL_UI_BORROW_PRODUCT_HEADER", L(entry.productKey), Gold(entry.maxAmount)))
    if not entry.available or not b.available then
      Line(L("LOC_WBL_UI_BORROW_BLOCKED", L(entry.available and b.reasonKey or entry.reasonKey)))
    else
      local c = entry.vComponents
      if type(c) == "table" then
        Line(L("LOC_WBL_UI_BORROW_V", string.format("%.2f", entry.quotedV), string.format("%.2f", c.base or 0),
          string.format("%+.2f", c.rating or 0), string.format("%+.2f", c.liquidity or 0),
          string.format("%+.2f", c.scar or 0), string.format("%+.2f", c.investor or 0),
          c.floorApplied and L("LOC_WBL_UI_BORROW_V_FLOOR") or ""))
      end
      LoanChooser("P:" .. entry.product, entry, "TAKE_LOAN", {product = entry.product})
    end
  end
  for _, entry in ipairs(b.recoveryOffers) do
    Header(L("LOC_WBL_UI_RECOVERY_HEADER", L(entry.disasterKey)))
    Line(L("LOC_WBL_UI_RECOVERY_INFO", entry.expiryTurn, entry.turnsLeft, Gold(entry.maxAmount)))
    if not entry.available then
      Line(L("LOC_WBL_UI_BORROW_BLOCKED", L(entry.reasonKey)))
    else
      LoanChooser("R:" .. tostring(entry.entitlementID), entry, "CLAIM_RECOVERY", {entitlementID = entry.entitlementID})
    end
  end
  if b.grant.available or b.grant.reason ~= "NO_OFFER" then
    Header(L("LOC_WBL_UI_GRANT_HEADER"))
    if b.grant.available then
      local option = CurrentMilestone()
      Line(L("LOC_WBL_UI_GRANT_INFO", Gold(b.grant.amount)))
      Selector(L("LOC_WBL_UI_BORROW_MILESTONE_REQ", Pct(0)), L("LOC_WBL_UI_BORROW_MILESTONE_BTN", MilestoneName(option)),
        function() CycleMilestone() Redraw() end)
      local reason = (option == nil or option.kind == "NONE") and "LOC_WBL_UI_REASON_MILESTONE_REQUIRED" or ""
      Action("", L("LOC_WBL_UI_GRANT_BTN"), reason, function()
        Send("REQUEST_GRANT", {quotedAmount = b.grant.amount, milestone = option})
      end)
    else
      Line(L("LOC_WBL_UI_BORROW_BLOCKED", L(b.grant.reasonKey)))
    end
  end
end

local function BuildLoans(view)
  local l = view.loans
  Header(L("LOC_WBL_UI_TAB_LOANS"))
  if l.inDefault then
    Line(L("LOC_WBL_UI_LOANS_DEFAULT", l.defaultTurn, l.penaltyStage))
  elseif l.warning then
    Line(L("LOC_WBL_UI_LOANS_WARNING", l.arrearsTurns, l.defaultTurns or WBL_CONFIG.arrears.defaultTurns))
  elseif l.arrearsActive then
    Line(L("LOC_WBL_UI_LOANS_ARREARS"))
  end
  if #l.penalties > 0 then
    Header(L("LOC_WBL_UI_PENALTIES_HEADER"))
    for _, p in ipairs(l.penalties) do
      Line(L(p.textKey, p.value) .. (p.suspended and L("LOC_WBL_UI_PENALTY_SUSPENDED") or ""))
    end
  end
  if #l.rows == 0 then Line(L("LOC_WBL_UI_LOANS_NONE")) end
  -- Total scheduled payments: the top panel's gold breakdown cannot show them (Leon, Session P 2026-11-04).
  local due = 0
  for _, row in ipairs(l.rows) do
    if type(row.nextPayment) == "number" then due = due + row.nextPayment end
  end
  if due > 0 then Line(L("LOC_WBL_UI_LOANS_DUE_TOTAL", Gold(due))) end
  for _, row in ipairs(l.rows) do
    Header(L("LOC_WBL_UI_LOAN_HEADER", L(row.productKey), row.loanID))
    if row.isRecovery then Line(L("LOC_WBL_UI_LOAN_RECOVERY", L(row.disasterKey))) end
    Line(L("LOC_WBL_UI_LOAN_BALANCE", Gold(row.principal), Gold(row.totalOwed), Gold(row.futureInterest)))
    if row.installmentsLeft > 0 then
      Line(L("LOC_WBL_UI_LOAN_NEXT", Gold(row.nextPayment), row.nextDueTurn, row.installmentsLeft))
    else
      Line(L("LOC_WBL_UI_LOAN_PAID_UP"))
    end
    if row.inArrears then
      Line(L("LOC_WBL_UI_LOAN_ARREARS", Gold(row.arrears), Gold(row.overduePrincipal), Gold(row.overdueInterest),
        Gold(row.arrearsFees), row.missedCount))
    end
    Line(L("LOC_WBL_UI_LOAN_MILESTONE", L(row.milestone.statusKey)))
    Action(row.repay.available and L("LOC_WBL_UI_REPAY_INFO", Gold(row.repay.totalDue), Gold(row.repay.waived)) or "",
      L("LOC_WBL_UI_REPAY_BTN", Gold(row.repay.totalDue or 0)), row.repay.reasonKey, function()
        Send("REPAY_EARLY", {loanID = row.loanID, quotedAmount = row.repay.totalDue})
      end)
    Action(L("LOC_WBL_UI_RESTRUCTURE_INFO", row.restructure.termStandardTurns, row.restructure.favorCost),
      L("LOC_WBL_UI_RESTRUCTURE_BTN"), row.restructure.reasonKey, function()
        Send("RESTRUCTURE", {loanID = row.loanID, quotedV = row.restructure.quotedV})
      end)
    if row.selectMilestone.available then
      local option = CurrentMilestone()
      Selector(L("LOC_WBL_UI_SELECT_MILESTONE_INFO"), L("LOC_WBL_UI_BORROW_MILESTONE_BTN", MilestoneName(option)),
        function() CycleMilestone() Redraw() end)
      Action("", L("LOC_WBL_UI_SELECT_MILESTONE_BTN"),
        (option == nil or option.kind == "NONE") and "LOC_WBL_UI_REASON_MILESTONE_REQUIRED" or "", function()
          Send("SELECT_MILESTONE", {loanID = row.loanID, milestone = option})
        end)
    end
  end
  local r = l.debtRelief
  Header(L("LOC_WBL_UI_RELIEF_HEADER"))
  if r.status == "PENDING" then
    Line(L("LOC_WBL_UI_RELIEF_PENDING_INFO", r.turnsLeft, r.deadlineTurn))
  else
    Line(L("LOC_WBL_UI_RELIEF_INFO", Pct(r.fraction), Gold(r.forgiveAmount)))
    local option = CurrentMilestone()
    Selector("", L("LOC_WBL_UI_BORROW_MILESTONE_BTN", MilestoneName(option)), function() CycleMilestone() Redraw() end)
    local reason = r.reasonKey
    if reason == "" and (option == nil or option.kind == "NONE") then reason = "LOC_WBL_UI_REASON_MILESTONE_REQUIRED" end
    Action("", L("LOC_WBL_UI_RELIEF_BTN"), reason, function() Send("DEBT_RELIEF", {milestone = option}) end)
  end
end

local function BuildInvest(view)
  local i = view.invest
  Header(L("LOC_WBL_UI_TAB_INVEST"))
  Line(L("LOC_WBL_UI_INVEST_SUMMARY", Gold(i.eligibleCapital), Gold(i.unit), Pct(i.eligibleShare)))
  if not i.perks.isInvestor then
    Line(L("LOC_WBL_UI_INVEST_NOT_INVESTOR", Gold(i.thresholds[1].needed)))
  end
  Header(L("LOC_WBL_UI_DEPOSITS_HEADER"))
  if #i.deposits == 0 then Line(L("LOC_WBL_UI_DEPOSITS_NONE")) end
  for _, d in ipairs(i.deposits) do
    Line(L("LOC_WBL_UI_DEPOSIT_ROW", d.depositID, Gold(d.principal), d.maturityTurn, d.turnsLeft, Gold(d.accruedReturn)))
    Action(L("LOC_WBL_UI_WITHDRAW_INFO", Pct(i.deposit.earlyFraction)), L("LOC_WBL_UI_WITHDRAW_BTN", Gold(d.earlyPayout)),
      d.withdraw.reasonKey, function() Send("WITHDRAW", {depositID = d.depositID, quotedAmount = d.withdraw.quotedAmount}) end)
  end
  Header(L("LOC_WBL_UI_DEPOSIT_NEW_HEADER"))
  if not i.deposit.available then
    Line(L("LOC_WBL_UI_DEPOSIT_REFUSED") .. " " .. L(i.deposit.reasonKey))
  else
    local steps = WBL_BANKVIEW.DEPOSIT_UNIT_STEPS
    local stepIndex, state = Pick(steps, "DEPOSIT", "step")
    local termIndex = Pick(i.deposit.terms, "DEPOSIT", "term")
    local amount = WBL_BANKVIEW.DepositAmount(i, stepIndex)
    local term = i.deposit.terms[termIndex]
    Selector(L("LOC_WBL_UI_DEPOSIT_REFUSED_NOTE"), L("LOC_WBL_UI_BORROW_AMOUNT_BTN", Gold(amount)), function()
      state.step = stepIndex + 1
      Redraw()
    end)
    Selector("", L("LOC_WBL_UI_BORROW_TERM_BTN", term.termStandardTurns), function()
      state.term = termIndex + 1
      Redraw()
    end)
    local preview = WBL_BANKVIEW.DepositPreview(i, amount, term.termStandardTurns)
    if preview then
      Line(L("LOC_WBL_UI_DEPOSIT_PREVIEW", Gold(preview.eligiblePart), Gold(preview.amount), Gold(preview.expectedReturn),
        Gold(preview.payoutAtMaturity)))
    end
    Action("", L("LOC_WBL_UI_DEPOSIT_BTN"), "", function()
      Send("DEPOSIT", {amount = amount, termStandardTurns = term.termStandardTurns})
    end)
  end
  Header(L("LOC_WBL_UI_LADDER_HEADER"))
  local p = i.perks
  Line(L("LOC_WBL_UI_PERK_FAVOR", p.favor, p.shareFavor, p.capitalFavor, p.favorCap))
  if p.nextFavorAt then Line(L("LOC_WBL_UI_PERK_NEXT_FAVOR", Gold(p.nextFavorAt))) end
  Line(L(WBL_BANKVIEW.Key("PERK_PREFERRED", p.preferredStep)))
  Line(L(p.liquidityExempt and "LOC_WBL_UI_PERK_EXEMPT" or "LOC_WBL_UI_PERK_NOT_EXEMPT"))
  if p.aidCap then Line(L("LOC_WBL_UI_PERK_AID", Gold(p.aidCap))) end
  for _, t in ipairs(i.thresholds) do
    Line(L("LOC_WBL_UI_THRESHOLD_LINE", L(t.textKey), Gold(t.needed),
      t.reached and L("LOC_WBL_UI_THRESHOLD_REACHED") or L("LOC_WBL_UI_THRESHOLD_MISSING", Gold(t.remaining))))
  end
  if #i.unpaid > 0 then
    Header(L("LOC_WBL_UI_UNPAID_HEADER"))
    for _, u in ipairs(i.unpaid) do Line(L(u.textKey, Gold(u.amount))) end
  end
  Header(L("LOC_WBL_UI_PRESIDENT_HEADER"))
  local pr = i.president
  if pr.isPresident then
    Line(L("LOC_WBL_UI_PRESIDENT_YOU", pr.sinceTurn, pr.perks.favor, pr.perks.merchantPoints, pr.perks.envoyTurns))
  elseif pr.presidentID >= 0 then
    Line(L("LOC_WBL_UI_PRESIDENT_OTHER", CivName(pr.presidentID)))
  else
    Line(L("LOC_WBL_UI_PRESIDENT_NONE"))
  end
  Line(L("LOC_WBL_UI_PRESIDENT_PROGRESS", pr.eligible and L("LOC_WBL_UI_YES") or L("LOC_WBL_UI_NO"),
    pr.confirmCount, pr.confirmNeeded, Pct(pr.shareNeeded), pr.eraTurns, pr.eraTurnsNeeded))
  Header(L("LOC_WBL_UI_FREEZE_HEADER"))
  Line(L("LOC_WBL_UI_FREEZE_RULE"))
  local f = i.freezes
  if #f.rows == 0 then Line(L("LOC_WBL_UI_FREEZE_NONE")) end
  for _, row in ipairs(f.rows) do
    Line(L("LOC_WBL_UI_FREEZE_ROW", CivName(row.targetID), L(row.modeKey), row.placedTurn))
    if row.canLift then
      Action("", L("LOC_WBL_UI_FREEZE_LIFT_BTN", CivName(row.targetID)), "", function()
        Send("FREEZE_LIFT", {freezeID = row.freezeID})
      end)
    end
  end
  if not f.canPlace then
    Line(L("LOC_WBL_UI_BORROW_BLOCKED", L(f.reasonKey)))
  else
    for _, t in ipairs(f.targets) do
      for _, mode in ipairs(t.modes) do
        Action("", L("LOC_WBL_UI_FREEZE_BTN", CivName(t.playerID), L(WBL_BANKVIEW.Key("FREEZE", mode))), "", function()
          Send("FREEZE_PLACE", {targetID = t.playerID, mode = mode})
        end)
      end
    end
  end
end

local function BuildBank(view)
  local b = view.bank
  Header(L("LOC_WBL_UI_TAB_BANK"))
  Line(L("LOC_WBL_UI_BANK_POOL", Gold(b.pool), Gold(b.cap), Pct(b.fillFraction)))
  Line(L("LOC_WBL_UI_BANK_TIER", L(b.liquidityKey)))
  if b.valueAdjustment then
    Line(L("LOC_WBL_UI_BANK_EFFECT", string.format("%+.2f", b.valueAdjustment), string.format("%.2f", b.limitMultiplier)))
  end
  if b.emergency then Line(L("LOC_WBL_UI_BANK_EMERGENCY")) end
  Line(L("LOC_WBL_UI_BANK_LENT", Gold(b.receivables), Gold(b.disbursed), Gold(b.depositLiabilities)))
  Header(L("LOC_WBL_UI_BANK_FREEZES_HEADER"))
  if #b.freezes == 0 then Line(L("LOC_WBL_UI_FREEZE_NONE")) end
  for _, row in ipairs(b.freezes) do
    Line(L("LOC_WBL_UI_FREEZE_ROW", CivName(row.targetID), L(row.modeKey), row.placedTurn))
  end
  Header(L("LOC_WBL_UI_BANK_CIVS_HEADER"))
  for _, civ in ipairs(b.civs) do
    Line(L("LOC_WBL_UI_BANK_CIV_ROW", civ.isSelf and L("LOC_WBL_UI_YOU") or CivName(civ.playerID), L(civ.tierKey),
      L(civ.ratingKey), Gold(civ.debt),
      civ.inDefault and L("LOC_WBL_UI_BANK_DEFAULT_STAGE", civ.defaultStage) or L("LOC_WBL_UI_BANK_NO_DEFAULT")))
  end
  if not b.canSeeAll then Line(L("LOC_WBL_UI_BANK_PRIVATE")) end
end

local BUILDERS = {BORROW = BuildBorrow, LOANS = BuildLoans, INVEST = BuildInvest, BANK = BuildBank}

-- Selected-tab overlay as ReportScreen.lua:1714-1718 (show the selected tab's overlay, hide the others).
local function SetTabButtons()
  Controls.TabBorrowSelected:SetHide(tab ~= "BORROW")
  Controls.TabLoansSelected:SetHide(tab ~= "LOANS")
  Controls.TabInvestSelected:SetHide(tab ~= "INVEST")
  Controls.TabBankSelected:SetHide(tab ~= "BANK")
end

local function Rebuild()
  dirty = false
  headerIM:ResetInstances()
  textIM:ResetInstances()
  actionIM:ResetInstances()
  selectorIM:ResetInstances()
  spacerIM:ResetInstances()
  shownRows = {}
  SetTabButtons()
  local playerID = Game.GetLocalPlayer()
  local state = ReadState()
  local facts = GatherFacts(playerID)
  local view = WBL_BANKVIEW.BuildView(state, playerID, WBL_CONFIG, nil, facts)
  lastView = view
  if not view.ok then
    Controls.StatusLabel:SetText(L(view.reasonKey))
  else
    if sentNonce ~= nil and view.nonce ~= sentNonce then sentNonce = nil end
    local status = ""
    if view.suspended then status = L("LOC_WBL_UI_SUSPENDED", view.suspendReason) end
    if view.lastResult then
      status = status .. " " .. (view.lastResult.ok and L("LOC_WBL_UI_LAST_OK", view.lastResult.kind)
        or L("LOC_WBL_UI_LAST_FAIL", view.lastResult.kind, L(view.lastResult.reasonKey)))
    end
    Controls.StatusLabel:SetText(status)
    BUILDERS[tab](view)
  end
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
  else
    UI.PlaySound("UI_Screen_Close")
    UIManager:DequeuePopup(ContextPtr)
    ContextPtr:SetHide(false)
  end
end

local function Toggle()
  SetOpen(not open)
end

local function SetTab(name)
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
  if key == Keys.B and not input:IsControlDown() and not input:IsShiftDown() and not input:IsAltDown() then
    if not open and SettlerSelected() then return false end
    Toggle()
    return true
  end
  if key == Keys.VK_ESCAPE and open then
    SetOpen(false)
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
end

-- Explicit initialization: the context is visible, the content panel starts closed (playbook).
ContextPtr:SetHide(false)
Controls.Main:SetHide(true)
Controls.FallbackButton:SetHide(false)
ContextPtr:SetInputHandler(OnInput, true)
ContextPtr:SetShutdown(Shutdown)
ContextPtr:SetRefreshHandler(OnRefresh)
Controls.CloseButton:RegisterCallback(Mouse.eLClick, function() SetOpen(false) end)
Controls.FallbackButton:RegisterCallback(Mouse.eLClick, Toggle)
Controls.TabBorrow:RegisterCallback(Mouse.eLClick, function() SetTab("BORROW") end)
Controls.TabLoans:RegisterCallback(Mouse.eLClick, function() SetTab("LOANS") end)
Controls.TabInvest:RegisterCallback(Mouse.eLClick, function() SetTab("INVEST") end)
Controls.TabBank:RegisterCallback(Mouse.eLClick, function() SetTab("BANK") end)
Events.LoadGameViewStateDone.Add(OnViewReady)
Events.GameCoreEventPublishComplete.Add(MarkDirty)
Events.PlayerTurnActivated.Add(MarkDirty)
print("[WBL UI] bank panel ready; B; S7 PENDING")
