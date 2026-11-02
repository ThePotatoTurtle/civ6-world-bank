-- WBL_SNAPSHOT: engine read adapter (PLAN.md "Production module map and contracts", Snapshot).
-- Load WBL_Config.lua first. Every engine read is pcall'd; any failed, missing or nonfinite
-- read of a living major (or negative production) sets complete=false with a reason string.
-- Finite zero production stays valid (decision 24). The result holds only scalars and
-- ordered arrays. Read shapes reuse the dev spikes (WBL_Dev/Scripts/WBL_Spikes.lua).
-- Gameplay-included: no pairs, no randomness, no local player, no asynchronous Events.
--
-- API
--   Build(state, config, options) -> snapshot
--     options.extraMilestones: ordered {playerID, kind, target, cityID} also to be read
--     (request validation). state may be nil (first boundary: no milestone targets).
--   MilestoneKey(milestone) -> "KIND:target:cityID", the milestoneFacts key.
--   DisasterFactsReader: nil. A future S5-verified reader may be assigned; it is called
--     only while features.recoveryPredicateVerified is true. Nothing is ever guessed.
WBL_SNAPSHOT = {}
local S = WBL_SNAPSHOT
S.DisasterFactsReader = nil

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

local function Log(message)
  print("[WBL SNAPSHOT] " .. message)
end

local function SortedRows(info)
  local rows = {}
  for row in info() do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return a.Index < b.Index end)
  return rows
end

local function SortedCities(player)
  local cities = {}
  local collection = player:GetCities()
  for _, city in collection:Members() do cities[#cities + 1] = city end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID() end)
  return cities
end

local function Contains(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then return true end
  end
  return false
end

function S.MilestoneKey(milestone)
  return tostring(milestone.kind) .. ":" .. tostring(milestone.target) .. ":" .. tostring(milestone.cityID or 0)
end

-- Milestone targets referenced by active state, per owner, deduplicated by key.
local function MilestoneTargets(state, options)
  local targets = {}
  local function add(playerID, milestone)
    if type(milestone) ~= "table" or milestone.kind == nil or milestone.kind == "NONE" then return end
    targets[#targets + 1] = { playerID = playerID, kind = milestone.kind, target = milestone.target,
      cityID = milestone.cityID or 0, key = S.MilestoneKey(milestone) }
  end
  if type(state) == "table" then
    for _, loan in ipairs(state.loans or {}) do
      if loan.status == "ACTIVE" and type(loan.milestone) == "table" and loan.milestone.status == "PENDING" then
        add(loan.playerID, loan.milestone)
      end
    end
    for _, player in ipairs(state.players or {}) do
      if type(player.relief) == "table" and player.relief.status == "PENDING" then
        add(player.playerID, player.relief.milestone)
      end
    end
    for _, grant in ipairs(state.grants or {}) do
      if grant.status == "PENDING_MILESTONE" then add(grant.playerID, grant.milestone) end
    end
  end
  for _, extra in ipairs((options and options.extraMilestones) or {}) do add(extra.playerID, extra) end
  return targets
end

local function MilestoneFact(player, cities, target, config)
  local fact = { key = target.key, kind = target.kind, done = false, valid = true }
  local function FindCity()
    for _, city in ipairs(cities) do
      if city:GetID() == target.cityID then return city end
    end
    return nil
  end
  if target.kind == "POPULATION" then
    if not Finite(target.target) then fact.valid = false; return fact, nil end
    local city = FindCity()
    if city == nil then return fact, nil end -- Lost or razed city: not complete, not a read failure.
    local population, err = Read(function() return city:GetPopulation() end)
    if not Finite(population) then return fact, err or "nonfinite_population" end
    fact.done = population >= target.target
  elseif target.kind == "TECH" then
    local row = GameInfo.Technologies[target.target] -- Keyed lookup; AustraliaScenario.lua:771 iterates the same table.
    if row == nil then fact.valid = false; return fact, nil end
    local has, err = Read(function()
      local playerTechs = player:GetTechs()
      return playerTechs:HasTech(row.Index)
    end)
    if type(has) ~= "boolean" then return fact, err or "missing_tech_read" end
    fact.done = has
  elseif target.kind == "DISTRICT" then
    if not config.features.districtMilestoneVerified then return nil, nil end -- S6 gate: row omitted.
    local row = GameInfo.Districts[target.target]
    if row == nil then fact.valid = false; return fact, nil end
    local city = FindCity()
    if city == nil then return fact, nil end
    local has, err = Read(function()
      local districts = city:GetDistricts()
      return districts:HasDistrict(row.Index, true)
    end)
    if type(has) ~= "boolean" then return fact, err or "missing_district_read" end
    fact.done = has
  else
    fact.valid = false
  end
  return fact, nil
end

local function ReadMajor(player, playerID, targets, config, fail)
  local major = { playerID = playerID, teamID = -1, isHuman = false, civType = "", difficultyType = "UNRESOLVED",
    difficultyID = -1, production = 0, techs = 0, civics = 0, treasury = 0, netGPT = 0, favor = 0,
    cityCount = 0, wars = {}, allies = {}, milestoneFacts = {} }
  local function need(field, value, err, check)
    if err ~= nil or value == nil or (check and not check(value)) then
      fail(field .. ":player=" .. playerID .. ":" .. Text(err or (value == nil and "missing" or "invalid")))
      return false
    end
    major[field] = value
    return true
  end
  local teamID, teamError = Read(function() return player:GetTeam() end)
  need("teamID", teamID, teamError, Finite)
  local human, humanError = Read(function() return player:IsHuman() end)
  need("isHuman", human, humanError, function(value) return type(value) == "boolean" end)
  local civType, civError = Read(function()
    local configuration = PlayerConfigurations[playerID]
    return configuration:GetCivilizationTypeName()
  end)
  need("civType", civType, civError, function(value) return type(value) == "string" and value ~= "" end)
  local handicap, handicapError = Read(function()
    local configuration = PlayerConfigurations[playerID]
    return configuration:GetHandicapTypeID()
  end)
  if need("difficultyID", handicap, handicapError, Finite) then
    local row = GameInfo.Difficulties[handicap]
    major.difficultyType = row and row.DifficultyType or "UNRESOLVED" -- Custom rows: reducer fallback.
  end
  local cities, citiesError = Read(function() return SortedCities(player) end)
  if cities == nil then
    fail("cities:player=" .. playerID .. ":" .. Text(citiesError))
    cities = {}
  else
    major.cityCount = #cities
  end
  local production, productionError = Read(function()
    local total = 0
    for _, city in ipairs(cities) do
      local value = city:GetYield(YieldTypes.PRODUCTION)
      assert(Finite(value), "nonfinite_city_production")
      assert(value >= 0, "negative_city_production")
      total = total + value
    end
    assert(Finite(total), "nonfinite_total_production")
    return total
  end)
  need("production", production, productionError, function(value) return Finite(value) and value >= 0 end)
  local development, developmentError = Read(function()
    local techs, civics = 0, 0
    local playerTechs, playerCulture = player:GetTechs(), player:GetCulture()
    for _, row in ipairs(SortedRows(GameInfo.Technologies)) do
      if playerTechs:HasTech(row.Index) then techs = techs + 1 end
    end
    for _, row in ipairs(SortedRows(GameInfo.Civics)) do
      if playerCulture:HasCivic(row.Index) then civics = civics + 1 end
    end
    return { techs = techs, civics = civics }
  end)
  if type(development) == "table" and Finite(development.techs) and Finite(development.civics) then
    major.techs, major.civics = development.techs, development.civics
  else
    fail("development:player=" .. playerID .. ":" .. Text(developmentError or "invalid"))
  end
  local gold, goldError = Read(function()
    local treasury = player:GetTreasury()
    return treasury:GetGoldBalance()
  end)
  need("treasury", gold, goldError, Finite)
  local gpt, gptError = Read(function()
    local treasury = player:GetTreasury()
    return treasury:GetGoldYield() - treasury:GetTotalMaintenance()
  end)
  need("netGPT", gpt, gptError, Finite)
  local favor, favorError = Read(function()
    local diplomacy = player:GetDiplomacy()
    return diplomacy:GetFavor()
  end)
  need("favor", favor, favorError, Finite)
  local seen = {}
  for _, target in ipairs(targets) do
    if target.playerID == playerID and not Contains(seen, target.key) then
      seen[#seen + 1] = target.key
      local ok, fact, err = pcall(MilestoneFact, player, cities, target, config)
      if not ok then
        fail("milestone:player=" .. playerID .. ":" .. target.key .. ":" .. Text(fact))
      elseif err ~= nil then
        fail("milestone:player=" .. playerID .. ":" .. target.key .. ":" .. Text(err))
      elseif fact ~= nil then
        major.milestoneFacts[#major.milestoneFacts + 1] = fact
      end
    end
  end
  table.sort(major.milestoneFacts, function(a, b) return a.key < b.key end)
  return major
end

local function Relationships(players, majors, fail)
  for i = 1, #majors do
    local player = players[i]
    local diplomacy, diplomacyError = Read(function() return player:GetDiplomacy() end)
    for j = i + 1, #majors do
      local otherID = majors[j].playerID
      local war, warError = Read(function() return diplomacy:IsAtWarWith(otherID) end)
      local allied, allyError = Read(function() return diplomacy:HasAllied(otherID) end)
      if type(war) ~= "boolean" or type(allied) ~= "boolean" then
        fail("relationship:" .. majors[i].playerID .. ":" .. otherID .. ":" ..
          Text(diplomacyError or warError or allyError or "missing"))
      else
        if war then
          majors[i].wars[#majors[i].wars + 1] = otherID
          majors[j].wars[#majors[j].wars + 1] = majors[i].playerID
        end
        if allied then
          majors[i].allies[#majors[i].allies + 1] = otherID
          majors[j].allies[#majors[j].allies + 1] = majors[i].playerID
        end
      end
    end
  end
  for _, major in ipairs(majors) do
    table.sort(major.wars)
    table.sort(major.allies)
  end
end

local function DisasterFacts(config, snapshot, fail)
  if not config.features.recoveryPredicateVerified then return {} end
  if type(S.DisasterFactsReader) ~= "function" then
    Log("recoveryPredicateVerified=true but no verified qualifying-disaster reader exists; disasterFacts empty")
    return {}
  end
  local facts, err = Read(function() return S.DisasterFactsReader(snapshot, config) end)
  local result = {}
  if type(facts) ~= "table" then
    fail("disasterFacts:" .. Text(err or "invalid"))
    return result
  end
  for _, fact in ipairs(facts) do
    if type(fact.eventKey) == "string" and Finite(fact.victimID) and Finite(fact.qualifyingTurn) then
      result[#result + 1] = { eventKey = fact.eventKey, victimID = fact.victimID, qualifyingTurn = fact.qualifyingTurn }
    else
      fail("disasterFacts:invalid_entry")
    end
  end
  table.sort(result, function(a, b)
    if a.qualifyingTurn ~= b.qualifyingTurn then return a.qualifyingTurn < b.qualifyingTurn end
    if a.victimID ~= b.victimID then return a.victimID < b.victimID end
    return a.eventKey < b.eventKey
  end)
  return result
end

function S.Build(state, config, options)
  config = config or WBL_CONFIG
  local snapshot = { turn = 0, speedType = "", costMultiplier = 0, speedScale = 0, eraType = "", eraIndex = -1,
    difficulty = {}, majors = {}, disasterFacts = {}, complete = true, incomplete = {} }
  local function fail(reason)
    snapshot.complete = false
    snapshot.incomplete[#snapshot.incomplete + 1] = reason
  end
  local turn, turnError = Read(function() return Game.GetCurrentGameTurn() end)
  if Finite(turn) then snapshot.turn = turn else fail("turn:" .. Text(turnError or "invalid")) end
  local speed, speedError = Read(function() return GameInfo.GameSpeeds[GameConfiguration.GetGameSpeedType()] end)
  if type(speed) == "table" and Finite(speed.CostMultiplier) and speed.CostMultiplier > 0 then
    snapshot.speedType = tostring(speed.GameSpeedType)
    snapshot.costMultiplier = speed.CostMultiplier
    snapshot.speedScale = speed.CostMultiplier / config.adapters.costMultiplierPercent
  else
    fail("speed:" .. Text(speedError or "invalid"))
  end
  local era, eraError = Read(function()
    local eras = Game.GetEras()
    local index = eras:GetCurrentEra()
    return { index = index, row = GameInfo.Eras[index] }
  end)
  if type(era) == "table" and Finite(era.index) and type(era.row) == "table" and type(era.row.EraType) == "string" then
    snapshot.eraIndex = era.index
    snapshot.eraType = era.row.EraType
  else
    fail("era:" .. Text(eraError or "invalid"))
  end
  local alive, aliveError = Read(function() return PlayerManager.GetAliveMajors() end)
  if type(alive) ~= "table" then
    fail("majors:" .. Text(aliveError or "invalid"))
    alive = {}
  end
  local players = {}
  for _, player in ipairs(alive) do
    local playerID, idError = Read(function() return player:GetID() end)
    if not Finite(playerID) then
      fail("playerID:" .. Text(idError or "invalid"))
    elseif not Contains(config.adapters.excludedPlayerIDs, playerID) then
      players[#players + 1] = { player = player, playerID = playerID }
    end
  end
  table.sort(players, function(a, b) return a.playerID < b.playerID end)
  if #players == 0 then fail("majors:none_living") end
  local targets = MilestoneTargets(state, options)
  local objects = {}
  for _, entry in ipairs(players) do
    local major = ReadMajor(entry.player, entry.playerID, targets, config, fail)
    snapshot.majors[#snapshot.majors + 1] = major
    objects[#objects + 1] = entry.player
    snapshot.difficulty[#snapshot.difficulty + 1] = { playerID = major.playerID,
      difficultyID = major.difficultyID, difficultyType = major.difficultyType }
  end
  Relationships(objects, snapshot.majors, fail)
  snapshot.disasterFacts = DisasterFacts(config, snapshot, fail)
  if not snapshot.complete then
    Log("turn=" .. snapshot.turn .. " complete=false reasons=" .. table.concat(snapshot.incomplete, ","))
  end
  return snapshot
end
