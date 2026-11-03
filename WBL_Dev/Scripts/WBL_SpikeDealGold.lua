-- S14 deal-gold probe (dev only, read-only). Logs each living major's yield parts every turn and every
-- active per-turn GOLD deal item, so a reviewer can see whether GetGoldYield/GetTotalMaintenance move by the
-- deal amount at enactment, and whether gameplay can read deals at all. Design: SPIKES.md S14.
-- Deal reads: GAME/Base/Assets/UI/Screens/ReportScreen.lua:363-384 (UI context only in shipped source).
-- Yield parts: GAME/Base/Assets/UI/ToolTipHelper_PlayerYields.lua:16-20.
WBL_SPIKE_DEAL_GOLD = {}
local M = WBL_SPIKE_DEAL_GOLD

-- Local on purpose: a reload re-probes and re-logs the current turn.
local lastTurn = {}
local probed = {}

local function Read(fn)
  local ok, value = pcall(fn)
  if ok then return value, nil end
  return nil, tostring(value)
end

local function Text(value)
  return (string.gsub(tostring(value), "[\r\n]", " "))
end

function M.Reset()
  lastTurn = {}
  probed = {}
end

local function YieldParts(players, now, logfn)
  for _, player in ipairs(players) do
    local id = Read(function() return player:GetID() end)
    local treasury, treasuryError = Read(function() return player:GetTreasury() end)
    local balance, balanceError = Read(function() return treasury:GetGoldBalance() end)
    local yield, yieldError = Read(function() return treasury:GetGoldYield() end)
    local maintenance, maintenanceError = Read(function() return treasury:GetTotalMaintenance() end)
    local readable = type(yield) == "number" and type(maintenance) == "number"
    logfn("S14", "yield_parts",
      "player:" .. Text(id) .. ",turn:" .. now .. ",balance:" .. Text(balance) .. ",goldYield:" .. Text(yield) ..
      ",totalMaintenance:" .. Text(maintenance) .. ",netGPT:" .. Text(readable and yield - maintenance or nil),
      "yield_or_maintenance_moves_by_deal_GPT_at_enactment", readable and "RAW" or "PENDING",
      treasuryError or balanceError or yieldError or maintenanceError)
  end
end

-- Returns the deal API pieces, or nil and the reason. Logs the probe once per context per load.
local function Probe(context, logfn)
  local getDeals = Read(function() return DealManager.GetPlayerDeals end)
  local gold = Read(function() return DealItemTypes.GOLD end)
  local none = Read(function() return DealItemSubTypes.NONE end)
  local available = getDeals ~= nil and gold ~= nil and none ~= nil
  if not probed[context] then
    probed[context] = true
    logfn("S14", "deal_api_probe_" .. context,
      "GetPlayerDeals:" .. type(getDeals) .. ",GOLD:" .. Text(gold) .. ",NONE:" .. Text(none),
      "deal_api_readable_in_" .. context .. "_context", available and "RAW" or "PENDING")
  end
  if not available then return nil end
  return gold, none
end

local function DealItems(context, players, now, logfn)
  local gold, none = Probe(context, logfn)
  if gold == nil then return end
  local ids = {}
  for _, player in ipairs(players) do
    local id = Read(function() return player:GetID() end)
    if type(id) == "number" then ids[#ids + 1] = id end
  end
  local count = 0
  for i = 1, #ids do
    for j = i + 1, #ids do
      local a, b = ids[i], ids[j]
      local deals, dealsError = Read(function() return DealManager.GetPlayerDeals(a, b) end)
      if dealsError ~= nil then
        logfn("S14", "deal_read_error_" .. context, "pair:" .. a .. "-" .. b, "readable_deals", "PENDING", dealsError)
      elseif deals ~= nil then
        for _, deal in ipairs(deals) do
          for _, from in ipairs({ a, b }) do
            local to = from == a and b or a
            local items, itemsError = Read(function() return deal:FindItemsByType(gold, none, from) end)
            if itemsError ~= nil then
              logfn("S14", "deal_read_error_" .. context, "from:" .. from .. ",to:" .. to, "readable_gold_items", "PENDING", itemsError)
            elseif items ~= nil then
              for _, item in ipairs(items) do
                local duration, durationError = Read(function() return item:GetDuration() end)
                if duration ~= 0 then
                  local amount, amountError = Read(function() return item:GetAmount() end)
                  local enacted, enactedError = Read(function() return item:GetEnactedTurn() end)
                  count = count + 1
                  logfn("S14", "deal_gold_item_" .. context,
                    "from:" .. from .. ",to:" .. to .. ",amount:" .. Text(amount) .. ",duration:" .. Text(duration) ..
                    ",enactedTurn:" .. Text(enacted) .. ",turn:" .. now,
                    "matches_UI_read_and_DiplomacyDeals_log", "RAW", durationError or amountError or enactedError)
                end
              end
            end
          end
        end
      end
    end
  end
  logfn("S14", "deal_gold_count_" .. context, "items:" .. count .. ",majors:" .. #ids .. ",turn:" .. now,
    "count_of_active_per_turn_gold_items", "RAW")
end

-- context: "gameplay" or "ui". players: sorted living majors. Runs at most once per context per turn;
-- only the gameplay context logs yield parts, because that is the context the bank reads net GPT in.
function M.Observe(context, players, now, logfn)
  if lastTurn[context] == now then return false end
  lastTurn[context] = now
  if context == "gameplay" then YieldParts(players, now, logfn) end
  DealItems(context, players, now, logfn)
  return true
end
