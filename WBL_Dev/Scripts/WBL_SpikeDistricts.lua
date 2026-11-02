-- S6 district milestone observer (dev only, read-only). Polls each living major's cities at synced
-- turn boundaries and logs incomplete -> complete transitions seen in ordinary play. It builds nothing.
-- Reads: city:GetDistricts() (BlackDeathScenario.lua:274); HasDistrict(index, true) as the built
-- query (CitySupport.lua:668) and HasDistrict(index) as the placed query (ProductionPanel.lua:1910).
-- Whether the plain query includes districts under construction is itself an observation here.
WBL_SPIKE_DISTRICTS = {}
local M = WBL_SPIKE_DISTRICTS

-- Known district states keyed "owner:city:district". Local on purpose: after a reload every district
-- is a new baseline and cannot be reported as a transition.
local known = {}
local transitions = 0
local lastTurn = nil

local function Read(fn)
  local ok, value = pcall(fn)
  if ok then return value, nil end
  return nil, tostring(value)
end

local function Text(value)
  return (string.gsub(tostring(value), "[\r\n]", " "))
end

local function Rows(info)
  local rows = {}
  for row in info() do rows[#rows + 1] = { index = row.Index, name = row.DistrictType } end
  table.sort(rows, function(a, b) return a.index < b.index end)
  return rows
end

local function Cities(player)
  local cities = {}
  local playerCities = player:GetCities()
  for _, city in playerCities:Members() do cities[#cities + 1] = city end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID() end)
  return cities
end

function M.Reset()
  known, transitions, lastTurn = {}, 0, nil
end

function M.Transitions()
  return transitions
end

-- districtRows: GameInfo.Districts passed by the caller (keeps database access in one place).
function M.Observe(players, districtRows, now, logfn)
  if lastTurn ~= nil and now < lastTurn then known, transitions = {}, 0 end
  if lastTurn == now then return end
  lastTurn = now
  local rows, rowError = Read(function() return Rows(districtRows) end)
  if rows == nil or #rows == 0 then
    logfn("S6", "district_poll", Text(rowError), "sorted_district_database_rows", "PENDING")
    return
  end
  local cityCount, complete, incomplete, failures, found = 0, 0, 0, 0, 0
  for _, player in ipairs(players) do
    local owner = Read(function() return player:GetID() end)
    local cities, cityError = Read(function() return Cities(player) end)
    if owner == nil or cities == nil then
      failures = failures + 1
      logfn("S6", "district_cities", Text(cityError), "sorted_city_enumeration", "PENDING")
    else
      for _, city in ipairs(cities) do
        cityCount = cityCount + 1
        local cityID = city:GetID()
        local districts, districtError = Read(function() return city:GetDistricts() end)
        for _, row in ipairs(rows) do
          local isPlaced, placedError = Read(function() return districts:HasDistrict(row.index) end)
          local isComplete, completeError = Read(function() return districts:HasDistrict(row.index, true) end)
          if type(isPlaced) ~= "boolean" or type(isComplete) ~= "boolean" then
            failures = failures + 1
            if failures == 1 then
              logfn("S6", "district_read", "placed:" .. Text(isPlaced) .. ",complete:" .. Text(isComplete),
                "boolean_HasDistrict_with_and_without_built_flag", "PENDING",
                districtError or placedError or completeError)
            end
          elseif isPlaced or isComplete then
            found = found + 1
            if isComplete then complete = complete + 1 else incomplete = incomplete + 1 end
            local key = owner .. ":" .. cityID .. ":" .. row.index
            local before = known[key]
            local label = row.name .. "_city_" .. cityID .. "_owner_" .. owner
            if before == nil then
              known[key] = { complete = isComplete, firstTurn = now }
              if not isComplete then
                logfn("S6", "district_incomplete_seen_" .. label, "placed:true,complete:false,turn:" .. now,
                  "natural_play_observation", "RAW")
              end
            elseif not before.complete and isComplete then
              transitions = transitions + 1
              logfn("S6", "district_transition_" .. label,
                "incomplete@" .. before.firstTurn .. "->complete@" .. now,
                "incomplete_then_complete_in_natural_play", "PASS", "observation_not_a_forgiveness_trigger")
              known[key] = { complete = true, firstTurn = now }
            elseif before.complete and not isComplete then
              known[key] = { complete = false, firstTurn = now }
              logfn("S6", "district_regressed_" .. label, "complete->incomplete@" .. now,
                "stable_after_completion", "RAW", "pillage_or_replacement_possible")
            end
          end
        end
      end
    end
  end
  logfn("S6", "district_poll", "cities:" .. cityCount .. ",placedOrComplete:" .. found ..
    ",complete:" .. complete .. ",incomplete:" .. incomplete .. ",readFailures:" .. failures ..
    ",transitionsSoFar:" .. transitions, "every_city_readable_each_boundary",
    failures == 0 and "RAW" or "PENDING")
  logfn("S6", "district_gate", "transitions:" .. transitions,
    "at_least_one_natural_incomplete_to_complete_transition",
    transitions > 0 and "PASS" or "PENDING",
    transitions > 0 and "capability_observed_for_that_district_only" or "needs_a_district_to_finish_in_ordinary_play")
end
