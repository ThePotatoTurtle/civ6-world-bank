-- Read-only S5 diagnostic. Congress/random-event readers are sourced from UI;
-- their availability in ordinary synced gameplay remains a live spike result.
-- This module creates no recovery entitlement, claim, disaster or bank state.
WBL_SPIKE_DISASTER_RECOVERY = {}
local M = WBL_SPIKE_DISASTER_RECOVERY

local function Read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
  return nil, tostring(value)
end

local function Report(logfn, variant, actual, expected, result, detail)
  logfn("S5", variant, actual, expected, result, detail)
end

local function Scalar(value)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "number" or kind == "boolean" or kind == "nil" then return tostring(value) end
  return "<" .. kind .. ">"
end

-- Engine tables are inspected, then copied/logged in sorted key order. Unknown
-- scalar fields can reveal identity evidence without guessing an ID field name.
local function Keys(value)
  local keys = {}
  if type(value) ~= "table" then return keys end
  for key in next, value do
    if type(key) == "number" or type(key) == "string" then keys[#keys + 1] = key end
  end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  return keys
end

local function Fields(value)
  local fields = {}
  for _, key in ipairs(Keys(value)) do
    fields[#fields + 1] = { name = Scalar(key), value = Scalar(value[key]), kind = type(value[key]) }
  end
  return fields
end

local function Describe(fields)
  local parts = {}
  for _, field in ipairs(fields) do parts[#parts + 1] = field.name .. ":" .. field.value end
  return table.concat(parts, ",")
end

local function IsMajor(majorIDs, target)
  for _, playerID in ipairs(majorIDs) do if playerID == target then return true end end
  return false
end

local function Proposals(players, logfn)
  local majorIDs, candidates = {}, {}
  for _, player in ipairs(players) do
    local playerID, err = Read(function() return player:GetID() end)
    if type(playerID) == "number" then majorIDs[#majorIDs + 1] = playerID
    else Report(logfn, "major_identity", err or Scalar(playerID), "numeric_living_major_ID", "PENDING") end
  end
  table.sort(majorIDs)
  local congress, congressError = Read(function() return Game.GetWorldCongress() end)
  for _, playerID in ipairs(majorIDs) do
    local result, err = Read(function() return congress:GetEmergencies(playerID) end)
    if type(result) == "table" then
      Report(logfn, "available_envelope_" .. playerID, Describe(Fields(result)),
        "raw_reader_envelope", "RAW")
    end
    if type(result) ~= "table" or type(result.Proposals) ~= "table" then
      Report(logfn, "available_aid_read_" .. playerID, err or congressError or Scalar(result),
        "ordinary_gameplay_table_with_Proposals", "PENDING", "UI_sourced_candidate_no_entitlements")
    else
      Report(logfn, "available_aid_read_" .. playerID, "table_with_Proposals",
        "ordinary_gameplay_table_with_Proposals", "PASS", "reader_shape_only_not_disaster_qualification")
      local count = 0
      for _, categoryKey in ipairs(Keys(result.Proposals)) do
        local category = result.Proposals[categoryKey]
        local entries = type(category) == "table" and category.ProposalsOfType or nil
        if type(category) == "table" then
          Report(logfn, "available_category_fields_" .. playerID .. "_" .. Scalar(categoryKey),
            Describe(Fields(category)), "raw_category_including_FavorCost", "RAW")
        end
        if type(entries) ~= "table" then
          Report(logfn, "available_category_" .. playerID .. "_" .. Scalar(categoryKey), Scalar(entries),
            "table_ProposalsOfType", "PENDING")
        else
          for _, entryKey in ipairs(Keys(entries)) do
            local proposal = entries[entryKey]
            if type(proposal) == "table" then
              local fields = Fields(proposal)
              Report(logfn, "available_proposal_" .. playerID .. "_" .. Scalar(categoryKey) .. "_" .. Scalar(entryKey),
                Describe(fields), "raw_pre_vote_option_not_passed_competition", "RAW")
              if proposal.TypeName == "WC_EMERGENCY_REQUEST_AID" then
                if IsMajor(majorIDs, proposal.Target) then
                  count = count + 1
                  candidates[#candidates + 1] = {
                    observerID = playerID, targetID = proposal.Target,
                    observedFields = fields,
                    qualification = "PENDING", originalDisasterKey = "PENDING",
                    qualificationTurn = "PENDING",
                  }
                  Report(logfn, "disaster_aid_candidate_" .. playerID .. "_" .. proposal.Target,
                    Describe(fields), "living_major_disaster_aid_option_only", "RAW",
                    "Disabled_blockers_Sender_are_observations_not_dedup_keys")
                else
                  Report(logfn, "disaster_aid_target_" .. playerID, Scalar(proposal.Target),
                    "living_major_target", "PENDING")
                end
              end
            else
              Report(logfn, "available_proposal_shape_" .. playerID, Scalar(proposal), "table_record", "PENDING")
            end
          end
        end
      end
      Report(logfn, "available_aid_count_" .. playerID, count, "observed_options_not_event_count", "RAW")
    end
  end
  return candidates
end

local function EventRead(variant, fn, logfn)
  local value, err = Read(fn)
  local fields = Fields(value)
  if type(value) == "table" then
    Report(logfn, variant, Describe(fields), "raw_event_fields_in_synced_gameplay", "PASS",
      "readable_table_only_no_assumed_original_ID_or_owner")
  elseif value == nil and err == nil then
    Report(logfn, variant, "none", "raw_event_or_none", "RAW", "absence_is_not_disaster_ineligibility")
  else
    Report(logfn, variant, err or Scalar(value), "raw_event_or_none", "PENDING")
  end
  return { readable = err == nil, fields = fields, absent = value == nil, error = err }
end

function M.Observe(players, previous, turn, logfn)
  local probe = {
    observations = previous and previous.observations + 1 or 1,
    observedTurn = turn, candidates = {}, affectedCities = {}, history = {},
    originalDisasterKey = "PENDING", perMajorQualification = "PENDING",
    qualificationTurn = "PENDING", recoveryClaimsCreated = false,
  }
  probe.candidates = Proposals(players, logfn)
  probe.current = EventRead("current_event", function() return GameRandomEvents.GetCurrentTurnEvent() end, logfn)
  for _, historyTurn in ipairs({ turn - 1, turn }) do
    if historyTurn >= 0 then
      local snapshot = EventRead("history_" .. historyTurn,
        function() return GameRandomEvents.GetEventsForTurn(historyTurn) end, logfn)
      snapshot.turn = historyTurn
      probe.history[#probe.history + 1] = snapshot
    end
  end
  local affected, err = Read(function() return GameRandomEvents.GetCurrentAffectedCities() end)
  if type(affected) == "table" then
    Report(logfn, "current_affected_read", "table", "current_affected_city_array", "PASS",
      "current_event_only_not_per_major_aid_qualification")
    for _, key in ipairs(Keys(affected)) do
      local city = affected[key]
      if type(city) == "table" then
        local fields = Fields(city)
        probe.affectedCities[#probe.affectedCities + 1] = {
          cityOwner = type(city.CityOwner) == "number" and city.CityOwner or nil,
          cityID = type(city.CityID) == "number" and city.CityID or nil,
          observedFields = fields,
        }
        Report(logfn, "current_affected_city_" .. Scalar(key), Describe(fields),
          "raw_CityOwner_CityID_not_qualification", "RAW")
      else
        Report(logfn, "current_affected_city_shape", Scalar(city), "table_record", "PENDING")
      end
    end
  else
    Report(logfn, "current_affected_read", err or Scalar(affected), "current_affected_city_array", "PENDING")
  end
  Report(logfn, "recovery_release_gate", "original_key:PENDING,per_major:PENDING,qualification_turn:PENDING,claims_created:false",
    "exact_pre_vote_qualification_original_disaster_identity_and_timestamp", "PENDING",
    "no_threshold_substitute_no_proposal_key_entitlement_no_payment_pause")
  return probe
end
