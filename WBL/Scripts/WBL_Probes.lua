-- WBL_Probes: read-only diagnostics for the MP test build (work plan stage 1). Active only when
-- bank.verboseLogging is on (off in production). Nothing here reads or writes bank state, so the lines
-- cannot change any job's inputs or outputs; every engine read is pcall'd and a failed read logs "nil"
-- plus the error.
--   [WBL TIMING] seq=N event=E player=P turn=T treasury=G goldYield=Y maintenance=M net=Y-M
--     PlayerTurnStarted / PlayerTurnStartComplete per player, and BankTurnJob when the bank's turn job
--     starts; seq orders them within this load (decision 41: when does the turn's income post?).
--   [WBL YIELD] / [WBL DEAL] / [WBL DEALS]: once per game turn, every living major's gold yield and
--     maintenance separately, and every active per-turn GOLD deal item (decisions 36 and 52; the S14
--     reads in WBL_Dev/Scripts/WBL_SpikeDealGold.lua).
-- Deal reads: GAME/Base/Assets/UI/Screens/ReportScreen.lua:363-384 (UI context in shipped source; the
-- S14 probe found DealManager.GetPlayerDeals, DealItemTypes.GOLD and DealItemSubTypes.NONE readable in
-- gameplay, SPIKES S14). Yield parts: GAME/Base/Assets/UI/ToolTipHelper_PlayerYields.lua:16-20.
WBL_PROBES = {}
local M = WBL_PROBES

local seq = 0
local lastDealTurn = nil

local function Read(fn)
  local ok, value = pcall(fn)
  if ok then return value, nil end
  return nil, tostring(value)
end

local function Text(value)
  return (string.gsub(tostring(value), "%c", " "))
end

local function Errors(list)
  local out = {}
  for _, e in ipairs(list) do
    if e ~= nil then out[#out + 1] = Text(e) end
  end
  if #out == 0 then return "" end
  return " error=" .. table.concat(out, "|")
end

-- "treasury=G goldYield=Y maintenance=M net=N" for one player object.
local function YieldText(player)
  local treasury, e1 = Read(function() return player:GetTreasury() end)
  local balance, e2 = Read(function() return treasury:GetGoldBalance() end)
  local yield, e3 = Read(function() return treasury:GetGoldYield() end)
  local maintenance, e4 = Read(function() return treasury:GetTotalMaintenance() end)
  local net = (type(yield) == "number" and type(maintenance) == "number") and yield - maintenance or nil
  return "treasury=" .. Text(balance) .. " goldYield=" .. Text(yield) .. " maintenance=" .. Text(maintenance) ..
    " net=" .. Text(net) .. Errors({e1, e2, e3, e4})
end

-- Sorted IDs and player objects of the living majors.
local function Majors()
  local alive, err = Read(function() return PlayerManager.GetAliveMajors() end)
  local list = {}
  if type(alive) ~= "table" then return list, err or "no_alive_majors" end
  for _, player in ipairs(alive) do
    local id = Read(function() return player:GetID() end)
    if type(id) == "number" then list[#list + 1] = {id = id, player = player} end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list, nil
end

function M.Reset()
  seq = 0
  lastDealTurn = nil
end

-- One timing line. playerID is nil for the bank's own turn job.
function M.Timing(event, playerID, turn)
  seq = seq + 1
  local line = "[WBL TIMING] seq=" .. seq .. " event=" .. Text(event) .. " player=" .. Text(playerID) ..
    " turn=" .. Text(turn)
  if playerID ~= nil then
    local player, err = Read(function() return Players[playerID] end)
    if player ~= nil then
      line = line .. " " .. YieldText(player)
    else
      line = line .. Errors({err or "no_player"})
    end
  end
  print(line)
end

local function DealItems(majors, turn)
  local getDeals, e1 = Read(function() return DealManager.GetPlayerDeals end)
  local gold, e2 = Read(function() return DealItemTypes.GOLD end)
  local none, e3 = Read(function() return DealItemSubTypes.NONE end)
  if getDeals == nil or gold == nil or none == nil then
    print("[WBL DEALS] turn=" .. Text(turn) .. " readable=false" .. Errors({e1, e2, e3}))
    return
  end
  local count = 0
  for i = 1, #majors do
    for j = i + 1, #majors do
      local a, b = majors[i].id, majors[j].id
      local deals, err = Read(function() return DealManager.GetPlayerDeals(a, b) end)
      if err ~= nil then
        print("[WBL DEAL] turn=" .. Text(turn) .. " pair=" .. a .. "-" .. b .. Errors({err}))
      elseif type(deals) == "table" then
        for _, deal in ipairs(deals) do
          for _, from in ipairs({a, b}) do
            local to = from == a and b or a
            local items, itemsErr = Read(function() return deal:FindItemsByType(gold, none, from) end)
            if itemsErr ~= nil then
              print("[WBL DEAL] turn=" .. Text(turn) .. " from=" .. from .. " to=" .. to .. Errors({itemsErr}))
            elseif type(items) == "table" then
              for _, item in ipairs(items) do
                local duration, d1 = Read(function() return item:GetDuration() end)
                if duration ~= 0 then
                  local amount, d2 = Read(function() return item:GetAmount() end)
                  local enacted, d3 = Read(function() return item:GetEnactedTurn() end)
                  count = count + 1
                  print("[WBL DEAL] turn=" .. Text(turn) .. " from=" .. from .. " to=" .. to .. " amount=" ..
                    Text(amount) .. " duration=" .. Text(duration) .. " enactedTurn=" .. Text(enacted) ..
                    Errors({d1, d2, d3}))
                end
              end
            end
          end
        end
      end
    end
  end
  print("[WBL DEALS] turn=" .. Text(turn) .. " readable=true items=" .. count .. " majors=" .. #majors)
end

-- Once per game turn: yield parts for every living major, then the per-turn gold deal items.
function M.TurnReads(turn)
  if lastDealTurn == turn then return false end
  lastDealTurn = turn
  local majors, err = Majors()
  if err ~= nil then print("[WBL YIELD] turn=" .. Text(turn) .. Errors({err})) end
  for _, m in ipairs(majors) do
    print("[WBL YIELD] turn=" .. Text(turn) .. " player=" .. m.id .. " " .. YieldText(m.player))
  end
  DealItems(majors, turn)
  return true
end
