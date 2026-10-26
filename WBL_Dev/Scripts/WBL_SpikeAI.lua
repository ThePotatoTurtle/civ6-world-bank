-- Source-backed observational fixtures, not bank loans or proof of AI purchase causation.
-- Main synced harness owns dispatch, player enumeration, turn IDs and persistence.
WBL_SPIKE_AI = {}
local M = WBL_SPIKE_AI

local function Read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
  return nil, tostring(value)
end

local function Finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function Report(logfn, variant, actual, expected, status, detail)
  logfn("S8", variant, actual, expected, status, detail)
end

local function Rows(info)
  local rows = {}
  for row in info() do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return a.Index < b.Index end)
  return rows
end

local function Units(player)
  local units, result = player:GetUnits(), {}
  for _, unit in units:Members() do
    local snapshot = {id = unit:GetID(), unitType = unit:GetType(),
      x = unit:GetX(), y = unit:GetY(), owner = player:GetID()}
    assert(Finite(snapshot.id) and Finite(snapshot.unitType) and Finite(snapshot.x)
      and Finite(snapshot.y) and Finite(snapshot.owner), "unit_snapshot_incomplete")
    result[#result + 1] = snapshot
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

local function Production(city)
  local queue = city:GetBuildQueue()
  local hash = queue:GetCurrentProductionTypeHash()
  assert(Finite(hash), "production_hash_unreadable")
  local result = {hash = hash}
  local building = GameInfo.Buildings[hash]
  local district = GameInfo.Districts[hash]
  local unit = GameInfo.Units[hash]
  if building then
    result.kind, result.objectIndex = "building", building.Index
    result.progress, result.cost = queue:GetBuildingProgress(building.Index), queue:GetBuildingCost(building.Index)
  elseif district then
    result.kind, result.objectIndex = "district", district.Index
    result.progress, result.cost = queue:GetDistrictProgress(district.Index), queue:GetDistrictCost(district.Index)
  elseif unit then
    result.kind, result.objectIndex = "unit", unit.Index
    result.progress, result.cost = queue:GetUnitProgress(unit.Index), queue:GetUnitCost(unit.Index)
  else result.kind = "empty_or_other" end
  if result.kind ~= "empty_or_other" then
    assert(Finite(result.progress) and Finite(result.cost), "production_progress_unreadable")
  end
  return result
end

local function Cities(player)
  local collection, result = player:GetCities(), {}
  for _, city in collection:Members() do
    local buildings, built = city:GetBuildings(), {}
    for _, row in ipairs(Rows(GameInfo.Buildings)) do
      local hasBuilding = buildings:HasBuilding(row.Index)
      assert(type(hasBuilding) == "boolean", "building_inventory_unreadable")
      if hasBuilding then
        built[#built + 1] = {index = row.Index, buildingType = row.BuildingType}
      end
    end
    local snapshot = {id = city:GetID(), owner = city:GetOwner(),
      population = city:GetPopulation(), productionYield = city:GetYield(YieldTypes.PRODUCTION),
      production = Production(city), buildings = built}
    assert(Finite(snapshot.id) and Finite(snapshot.owner) and Finite(snapshot.population)
      and Finite(snapshot.productionYield), "city_snapshot_incomplete")
    result[#result + 1] = snapshot
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

local function Snapshot(player)
  local gold, goldError = Read(function() local treasury = player:GetTreasury(); return treasury:GetGoldBalance() end)
  local gpt, gptError = Read(function()
    local treasury = player:GetTreasury()
    return treasury:GetGoldYield() - treasury:GetTotalMaintenance()
  end)
  local units, unitError = Read(function() return Units(player) end)
  local cities, cityError = Read(function() return Cities(player) end)
  return {gold = gold, netGPT = gpt, units = units or {}, cities = cities or {},
    treasuryReadable = Finite(gold) and Finite(gpt), inventoryComplete = units ~= nil and cities ~= nil,
    readError = goldError or gptError or unitError or cityError}
end

local function LogSnapshot(logfn, arm, phase, snapshot)
  local prefix = arm.label .. "_" .. phase
  Report(logfn, prefix .. "_treasury", "player:" .. tostring(arm.playerID) ..
    ",gold:" .. tostring(snapshot.gold) .. ",netGPT:" .. tostring(snapshot.netGPT),
    "raw_net_income_not_purchase_attribution", snapshot.treasuryReadable and "RAW" or "PENDING", snapshot.readError)
  Report(logfn, prefix .. "_inventory", "units:" .. #snapshot.units .. ",cities:" .. #snapshot.cities,
    "sorted_inventory_not_purchase_attribution", snapshot.inventoryComplete and "RAW" or "PENDING", snapshot.readError)
  for _, unit in ipairs(snapshot.units) do
    Report(logfn, prefix .. "_unit_" .. unit.id, "owner:" .. unit.owner .. ",type:" .. unit.unitType ..
      ",x:" .. unit.x .. ",y:" .. unit.y, "raw_unit_signature_not_purchase", "RAW")
  end
  for _, city in ipairs(snapshot.cities) do
    Report(logfn, prefix .. "_city_" .. city.id, "population:" .. city.population ..
      ",productionYield:" .. city.productionYield .. ",productionHash:" .. tostring(city.production.hash) ..
      ",productionKind:" .. tostring(city.production.kind) .. ",progress:" .. tostring(city.production.progress) ..
      ",cost:" .. tostring(city.production.cost) .. ",buildings:" .. #city.buildings,
      "raw_city_production_not_purchase", "RAW")
    for _, building in ipairs(city.buildings) do
      Report(logfn, prefix .. "_city_" .. city.id .. "_building_" .. building.index,
        building.buildingType, "raw_owned_building_not_purchase", "RAW")
    end
  end
end

local function OrderedAIs(players)
  local result = {}
  for i = 1, #players do
    local player = players[i]
    local human = Read(function() return player:IsHuman() end)
    local id = Read(function() return player:GetID() end)
    if human == false and Finite(id) then result[#result + 1] = player end
  end
  table.sort(result, function(a, b) return a:GetID() < b:GetID() end)
  return result
end

local function FindPlayer(players, id)
  for i = 1, #players do
    local player = players[i]
    if player:GetID() == id then return player end
  end
  return nil
end

function M.Run(players, config, logfn)
  assert(type(logfn) == "function", "S8 logger required")
  local probe = {version = 1, observations = 0, arms = {}, purchaseAttribution = "PENDING"}
  local aiPlayers = OrderedAIs(players)
  local labels = {"control", "bank_sized", "capability"}
  for index = 1, #labels do
    local arm = {label = labels[index], observations = {}, grantApplied = 0}
    probe.arms[index] = arm
    local player = aiPlayers[index]
    if not player then
      arm.status = "PENDING"
      arm.reason = "missing_ai_arm"
      Report(logfn, arm.label .. "_coverage", "no_living_AI_for_arm", "distinct_living_AI", "PENDING")
    else
      arm.playerID = player:GetID()
      arm.before = Snapshot(player)
      LogSnapshot(logfn, arm, "before", arm.before)
      local amount = 0
      if arm.label == "bank_sized" then
        local multiple = config and config.ai and config.ai.loanGptMultiple
        if not Finite(multiple) or multiple <= 0 then
          arm.reason = "invalid_bank_sized_multiple"
        elseif Finite(arm.before.netGPT) and arm.before.netGPT > 0 then
          amount = multiple * arm.before.netGPT
        else arm.reason = "nonpositive_or_unreadable_treatment_GPT" end
      elseif arm.label == "capability" then amount = config and config.spikes and config.spikes.aiGrant end
      arm.grantRequested = amount
      if arm.label ~= "control" and not arm.reason then
        if not arm.before.treasuryReadable or not Finite(amount) or amount <= 0 then
          arm.reason = "invalid_or_unreadable_positive_grant"
        else
          local ok, err = pcall(function() local treasury = player:GetTreasury(); treasury:ChangeGoldBalance(amount) end)
          arm.after = Snapshot(player)
          if ok and Finite(arm.after.gold) then
            arm.grantApplied = arm.after.gold - arm.before.gold
            local matches = math.abs(arm.grantApplied - amount) <= config.spikes.epsilon
            Report(logfn, arm.label .. "_script_grant", arm.grantApplied, amount, matches and "PASS" or "FAIL",
              "receipt_only_not_AI_spending")
          else arm.reason = "grant_mutation_or_read_unsupported"; arm.error = err end
        end
      end
      if not arm.after then arm.after = Snapshot(player) end
      LogSnapshot(logfn, arm, "after_setup", arm.after)
      if arm.label == "control" then
        Report(logfn, "control_gold_grant", 0, "no_script_gold_grant", "RAW",
          "other_spike_fixtures_may_change_this_AI_not_an_isolated_causal_control")
      end
      arm.status = "PENDING"
      Report(logfn, arm.label .. "_purchase_attribution", arm.reason or "awaiting_matched_gold_purchase_receipts",
        "AI_discretionary_gold_spend_confirmed", "PENDING", arm.error)
    end
  end
  return probe
end

function M.Observe(players, probe, config, logfn)
  assert(type(logfn) == "function", "S8 logger required")
  if probe == nil then return nil end
  local nextProbe = {version = probe.version, observations = probe.observations + 1,
    arms = {}, purchaseAttribution = "PENDING"}
  for i = 1, #probe.arms do
    local previous = probe.arms[i]
    local arm = {label = previous.label, playerID = previous.playerID, before = previous.before,
      after = previous.after, grantRequested = previous.grantRequested, grantApplied = previous.grantApplied,
      reason = previous.reason, status = "PENDING", observations = {}}
    for j = 1, #previous.observations do arm.observations[j] = previous.observations[j] end
    nextProbe.arms[i] = arm
    local player = FindPlayer(players, arm.playerID)
    if player then
      local snapshot = Snapshot(player)
      arm.observations[#arm.observations + 1] = snapshot
      LogSnapshot(logfn, arm, "boundary_" .. nextProbe.observations, snapshot)
      Report(logfn, arm.label .. "_purchase_attribution", "boundary:" .. nextProbe.observations,
        "matched_gold_purchase_receipts_required", "PENDING",
        "treasury_decline_or_new_units_alone_is_not_spending_proof")
    else
      Report(logfn, arm.label .. "_observation", "AI_arm_unavailable", "same_living_AI", "PENDING")
    end
  end
  return nextProbe
end

return WBL_SPIKE_AI
