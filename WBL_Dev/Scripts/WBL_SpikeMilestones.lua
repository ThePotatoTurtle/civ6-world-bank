-- Positive fixtures only, for disposable single-player dev games.
-- Gameplay mutation sources: BlackDeathScenario_Support.lua:266 (population),
-- NubiaScenario.lua:228-234 (SetTech). The caller owns synced dispatch and persistence.
WBL_SPIKE_MILESTONES = {}
local M = WBL_SPIKE_MILESTONES

local function Read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
  return nil, tostring(value)
end

local function IsFinite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function Report(logfn, variant, actual, expected, status, detail)
  logfn("S6", variant, actual, expected, status, detail)
end

local function CopyTarget(target)
  return {
    kind = target.kind, status = target.status, reason = target.reason,
    baseline = target.baseline, target = target.target, immediate = target.immediate,
    boundary = target.boundary, cityID = target.cityID, techIndex = target.techIndex,
    techType = target.techType, mutationAttempted = target.mutationAttempted,
    immediateMet = target.immediateMet, boundaryChecked = target.boundaryChecked,
  }
end

local function PlayerID(player)
  return Read(function() return player:GetID() end)
end

local function PopulationRun(player, city, config, logfn)
  local target = {kind = "population", status = "PENDING", mutationAttempted = false}
  local delta = config and config.spikes and config.spikes.populationDelta
  if not IsFinite(delta) or delta <= 0 or delta % 1 ~= 0 then
    target.reason = "invalid_positive_population_delta"
    Report(logfn, "population_config", delta, "positive_integer_delta", "FAIL")
    return target
  end
  local owner = Read(function() return city:GetOwner() end)
  local playerID = PlayerID(player)
  if city == nil or playerID == nil or owner ~= playerID then
    target.reason = "missing_or_unowned_fixture_city"
    Report(logfn, "population_fixture", target.reason, "requesting_players_city", "PENDING")
    return target
  end
  target.cityID = Read(function() return city:GetID() end)
  target.baseline = Read(function() return city:GetPopulation() end)
  if not IsFinite(target.baseline) or target.cityID == nil then
    target.reason = "population_read_unsupported"
    Report(logfn, "population_read", target.baseline, "numeric_population", "PENDING")
    return target
  end
  target.target = target.baseline + delta
  Report(logfn, "population_control", target.baseline, "below_target_" .. target.target,
    target.baseline < target.target and "PASS" or "FAIL", "before_fixture_mutation")
  target.mutationAttempted = true
  local ok, err = pcall(function() city:ChangePopulation(delta) end)
  target.immediate = Read(function() return city:GetPopulation() end)
  target.immediateMet = IsFinite(target.immediate) and target.immediate == target.target
  if not ok then
    target.reason = "population_mutation_unsupported"
    Report(logfn, "population_transition", target.immediate, target.target, "PENDING", err)
  elseif not IsFinite(target.immediate) then
    target.reason = "population_read_unsupported"
    Report(logfn, "population_transition", target.immediate, target.target, "PENDING")
  else
    target.status = target.immediateMet and "PASS" or "FAIL"
    Report(logfn, "population_transition", target.immediate, target.target, target.status,
      "positive_fixture_persists_in_disposable_game")
  end
  return target
end

local function TechnologyRun(player, logfn)
  local target = {kind = "technology", status = "PENDING", mutationAttempted = false}
  local techs, techError = Read(function() return player:GetTechs() end)
  local rows, rowError = Read(function()
    local result = {}
    for row in GameInfo.Technologies() do result[#result + 1] = row end
    table.sort(result, function(a, b) return a.Index < b.Index end)
    return result
  end)
  if not techs or not rows then
    target.reason = "technology_read_unsupported"
    Report(logfn, "technology_fixture", target.reason, "readable_player_and_technology_rows", "PENDING", techError or rowError)
    return target
  end
  for i = 1, #rows do
    local row = rows[i]
    local known, err = Read(function() return techs:HasTech(row.Index) end)
    if type(known) ~= "boolean" then
      target.reason = "technology_read_unsupported"
      Report(logfn, "technology_fixture", known, "boolean_named_tech_state", "PENDING", err)
      return target
    end
    if not known then
      target.techIndex, target.techType = row.Index, row.TechnologyType
      target.baseline, target.target = false, true
      break
    end
  end
  if target.techIndex == nil then
    target.reason = "all_named_technologies_already_owned"
    Report(logfn, "technology_fixture", target.reason, "absent_named_technology", "PENDING",
      "no_already_complete_target_can_pass")
    return target
  end
  Report(logfn, "technology_control_" .. tostring(target.techType), target.baseline, false, "PASS",
    "absent_target_before_fixture_mutation")
  target.mutationAttempted = true
  local ok, err = pcall(function() techs:SetTech(target.techIndex, true) end)
  target.immediate = Read(function() return techs:HasTech(target.techIndex) end)
  target.immediateMet = target.immediate == true
  if not ok then
    target.reason = "technology_mutation_unsupported"
    Report(logfn, "technology_transition_" .. tostring(target.techType), target.immediate, true, "PENDING", err)
  elseif type(target.immediate) ~= "boolean" then
    target.reason = "technology_read_unsupported"
    Report(logfn, "technology_transition_" .. tostring(target.techType), target.immediate, true, "PENDING")
  else
    target.status = target.immediateMet and "PASS" or "FAIL"
    Report(logfn, "technology_transition_" .. tostring(target.techType), target.immediate, true, target.status,
      "named_tech_fixture_grant_not_natural_research")
  end
  return target
end

function M.Run(player, city, config, logfn)
  assert(type(logfn) == "function", "S6 logger required")
  local probe = {version = 1, observations = 0, completed = false, targets = {}}
  probe.targets[1] = PopulationRun(player, city, config, logfn)
  probe.targets[#probe.targets + 1] = TechnologyRun(player, logfn)
  probe.targets[#probe.targets + 1] = {
    kind = "district", status = "PENDING", reason = "no_generic_context_verified_district_fixture",
    mutationAttempted = false,
  }
  Report(logfn, "district_transition", "not_exercised", "completed_specialty_district_transition", "PENDING",
    "no_worldbuilder_context_assumption")
  return probe
end

-- Returns a fresh, scalar-only probe table. Reusing completed state emits no duplicate checks.
function M.Observe(player, city, probe, config, logfn)
  assert(type(logfn) == "function", "S6 logger required")
  if probe == nil then return nil end
  local nextProbe = {version = probe.version, observations = probe.observations,
    completed = probe.completed, targets = {}}
  for i = 1, #probe.targets do nextProbe.targets[i] = CopyTarget(probe.targets[i]) end
  if probe.completed then return nextProbe end
  local required = config and config.spikes and config.spikes.milestoneObservationTurns
  if not IsFinite(required) or required < 1 or required % 1 ~= 0 then
    Report(logfn, "observation_config", required, "positive_integer_observations", "FAIL")
    return nextProbe
  end
  nextProbe.observations = nextProbe.observations + 1
  if nextProbe.observations < required then return nextProbe end
  nextProbe.completed = true
  for i = 1, #nextProbe.targets do
    local target = nextProbe.targets[i]
    if target.immediateMet and target.status == "PASS" then
      if target.kind == "population" then
        local currentID = Read(function() return city:GetID() end)
        local owner = Read(function() return city:GetOwner() end)
        if currentID ~= target.cityID or owner ~= PlayerID(player) then
          target.reason = "fixture_city_changed_or_missing"
          target.status = "PENDING"
          Report(logfn, "population_boundary", target.reason, "same_owned_fixture_city", "PENDING")
        else
          target.boundary = Read(function() return city:GetPopulation() end)
          target.status = IsFinite(target.boundary) and (target.boundary >= target.target and "PASS" or "FAIL") or "PENDING"
          target.boundaryChecked = true
          Report(logfn, "population_boundary", target.boundary, "at_least_" .. target.target, target.status,
            "queried_at_synced_boundary")
        end
      elseif target.kind == "technology" then
        target.boundary = Read(function()
          local techs = player:GetTechs()
          return techs:HasTech(target.techIndex)
        end)
        target.status = type(target.boundary) == "boolean" and (target.boundary and "PASS" or "FAIL") or "PENDING"
        target.boundaryChecked = true
        Report(logfn, "technology_boundary_" .. tostring(target.techType), target.boundary, true, target.status,
          "same_named_technology_queried_at_synced_boundary")
      end
    end
  end
  return nextProbe
end

return WBL_SPIKE_MILESTONES
