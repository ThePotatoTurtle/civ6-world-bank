-- Dev-only engine probes. Source evidence and unresolved semantics: research/ENGINE_APIS.md.
-- Every mutation runs from a synchronized GameEvents handler and refuses multiplayer.
include("WBL_Config");
include("WBL_Math");

local RUN_KEY = "WBL_SPIKE_RUN";
local STATUS_KEY = "WBL_SPIKE_STATUS";
local ATTACHED_KEY = "WBL_SPIKE_ATTACHED_CITIES";
local FLAG_KEY = "WBL_SPIKE_CITY_ACTIVE";
local MODIFIERS = {
  "WBL_SPIKE_DEVELOPED_STAGE2_AMENITY",
  "WBL_SPIKE_DEVELOPED_STAGE2_PRODUCTION",
  "WBL_SPIKE_DEVELOPED_STAGE2_SCIENCE",
  "WBL_SPIKE_DEVELOPED_STAGE2_LOYALTY"
};

local function Read(fn)
  local ok, value = pcall(fn);
  if ok then return value, nil; end
  return nil, tostring(value);
end

local function Text(value)
  return tostring(value):gsub("[\r\n]", " ");
end

local function IsSinglePlayer()
  local ok, allowed = pcall(function()
    return not GameConfiguration.IsAnyMultiplayer() and not GameConfiguration.IsHotseat();
  end);
  return ok and allowed;
end

local function ValidConfig(config)
  local ok, reason = pcall(function()
    local function finite(value)
      return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge;
    end
    assert(type(config) == "table" and type(config.spikes) == "table", "missing_spike_config");
    for _, name in ipairs({ "goldDelta", "goldSafetyReserve", "aiGrant", "favorDelta", "envoyDelta", "epsilon" }) do
      assert(finite(config.spikes[name]) and config.spikes[name] >= 0, "invalid_" .. name);
    end
    for _, name in ipairs({ "logEveryTurns", "difficultyLogEveryTurns", "observationTurns", "standardAutoplayTurns", "onlineAutoplayTurns" }) do
      local value = config.spikes[name];
      assert(finite(value) and value > 0 and value % 1 == 0, "invalid_" .. name);
    end
    assert(config.spikes.observationTurns >= 2, "observation_must_include_apply_and_remove_boundaries");
    assert(config.spikes.standardAutoplayTurns >= config.spikes.observationTurns, "short_standard_observation");
    assert(config.spikes.onlineAutoplayTurns >= config.spikes.observationTurns, "short_online_observation");
    assert(type(config.growth) == "table" and finite(config.growth.windowTurns) and config.growth.windowTurns > 0, "invalid_growth_window");
    for _, name in ipairs({ "standardDefault", "standardMin", "standardMax" }) do
      assert(finite(config.growth[name]) and config.growth[name] > -1, "invalid_growth_" .. name);
    end
    assert(config.growth.standardMin <= config.growth.standardMax, "inverted_growth_bounds");
    assert(type(WBL_MATH) == "table", "math_module_missing");
    for _, tierName in ipairs({ "DEVELOPED", "DEVELOPING", "UNDERDEVELOPED" }) do
      local tier = config.tiers[tierName];
      assert(finite(tier.valueRatio) and tier.valueRatio > 0, "invalid_tier_value");
      assert(finite(tier.graceTurns) and tier.graceTurns >= 0, "invalid_grace");
      for _, term in ipairs(tier.terms) do assert(finite(term) and term >= 1 and term % 1 == 0, "invalid_term"); end
    end
    for _, field in ipairs({ "amenities", "productionPercent", "sciencePercent", "loyalty" }) do
      assert(finite(config.penalties.stage2[field]), "invalid_penalty_" .. field);
    end
  end);
  return ok, reason;
end

local function Publish(run, phase, message)
  Game:SetProperty(STATUS_KEY, {
    text = message, phase = phase, turn = Game.GetCurrentGameTurn(),
    pass = run.pass, fail = run.fail, pending = run.pending,
    playerID = run.playerID, cityID = run.cityID, runID = run.runID
  });
  Game:SetProperty(RUN_KEY, run);
end

local function Log(run, spike, variant, actual, expected, result, detail)
  print("[SPIKE " .. spike .. "] run=" .. run.runID ..
    " turn=" .. Game.GetCurrentGameTurn() .. " player=" .. run.playerID ..
    " variant=" .. variant .. " actual=" .. Text(actual) ..
    " expected=" .. Text(expected) .. " " .. result ..
    (detail and (" detail=" .. Text(detail)) or ""));
  if result == "PASS" then run.pass = run.pass + 1;
  elseif result == "FAIL" then run.fail = run.fail + 1;
  elseif result == "PENDING" then run.pending = run.pending + 1; end
end

local function Near(a, b)
  return type(a) == "number" and type(b) == "number" and
    math.abs(a - b) <= WBL_CONFIG.spikes.epsilon;
end

local function Majors()
  local players = PlayerManager.GetAliveMajors();
  table.sort(players, function(a, b) return a:GetID() < b:GetID(); end);
  return players;
end

local function Cities(player)
  local cities = {};
  local playerCities = player:GetCities();
  for _, city in playerCities:Members() do cities[#cities + 1] = city; end
  table.sort(cities, function(a, b) return a:GetID() < b:GetID(); end);
  return cities;
end

local function Rows(info)
  local rows = {};
  for row in info() do rows[#rows + 1] = row; end
  table.sort(rows, function(a, b) return a.Index < b.Index; end);
  return rows;
end

local function Development(player)
  local techs, civics = 0, 0;
  local playerTechs, playerCulture = player:GetTechs(), player:GetCulture();
  for _, row in ipairs(Rows(GameInfo.Technologies)) do
    if playerTechs:HasTech(row.Index) then techs = techs + 1; end
  end
  for _, row in ipairs(Rows(GameInfo.Civics)) do
    if playerCulture:HasCivic(row.Index) then civics = civics + 1; end
  end
  return { techs = techs, civics = civics };
end

local function PlayerSnapshot(player)
  local development = Development(player);
  local treasury = player:GetTreasury();
  local playerID = player:GetID();
  local configuration = PlayerConfigurations[playerID];
  local difficulty = GameInfo.Difficulties[configuration:GetHandicapTypeID()];
  local production = Read(function()
    local total = 0;
    for _, city in ipairs(Cities(player)) do total = total + city:GetYield(YieldTypes.PRODUCTION); end
    return total;
  end);
  return {
    playerID = player:GetID(), human = player:IsHuman(),
    gold = treasury:GetGoldBalance(),
    gpt = treasury:GetGoldYield() - treasury:GetTotalMaintenance(),
    techs = development.techs, civics = development.civics,
    difficulty = difficulty and difficulty.DifficultyType or "UNRESOLVED"
    , production = production
  };
end

local function GoldRoundTrip(run, player)
  local treasury = player:GetTreasury();
  local before = treasury:GetGoldBalance();
  if type(before) ~= "number" or before < WBL_CONFIG.spikes.goldSafetyReserve then
    Log(run, "S1", "precondition", before, "nonnegative_balance", "FAIL");
    return;
  end
  local delta = WBL_CONFIG.spikes.goldDelta;
  local ok, err = pcall(function()
    treasury:ChangeGoldBalance(delta);
    local added = treasury:GetGoldBalance();
    Log(run, "S1", "credit", added, before + delta,
      Near(added, before + delta) and "PASS" or "FAIL");
    -- The requested debit exceeds cash; clamp to the observed cash before calling the engine.
    local requested = added + delta;
    local debit = math.min(math.max(added, 0), requested);
    treasury:ChangeGoldBalance(-debit);
    local empty = treasury:GetGoldBalance();
    Log(run, "S1", "clamped_debit", empty, 0,
      Near(empty, 0) and empty >= 0 and "PASS" or "FAIL");
  end);
  -- Restore the original balance even when a check or mutation raised an error.
  local restored, restoreError = pcall(function()
    local current = treasury:GetGoldBalance();
    local restoreDelta = before - current;
    if restoreDelta < 0 then restoreDelta = -math.min(current, -restoreDelta); end
    treasury:ChangeGoldBalance(restoreDelta);
  end);
  local after = treasury:GetGoldBalance();
  Log(run, "S1", "restore", after, before,
    restored and Near(after, before) and after >= 0 and "PASS" or "FAIL", restoreError);
  if not ok then Log(run, "S1", "engine_error", err, "no_error", "FAIL"); end
end

local function CitySnapshot(city)
  local snapshot = { cityID = city:GetID(), population = city:GetPopulation() };
  snapshot.amenities = Read(function() local growth = city:GetGrowth(); return growth:GetAmenities(); end);
  snapshot.loyalty = Read(function() local identity = city:GetCulturalIdentity(); return identity:GetLoyaltyPerTurn(); end);
  snapshot.production = Read(function() return city:GetYield(YieldTypes.PRODUCTION); end);
  snapshot.science = Read(function() return city:GetYield(YieldTypes.SCIENCE); end);
  snapshot.productionTooltip = Read(function() return city:GetYieldToolTip(YieldTypes.PRODUCTION); end);
  snapshot.scienceTooltip = Read(function() return city:GetYieldToolTip(YieldTypes.SCIENCE); end);
  return snapshot;
end

local function CityRaw(run, phase, snapshot)
  local p = WBL_CONFIG.penalties.stage2;
  Log(run, "S4", phase .. "_city_" .. snapshot.cityID,
    "amenities:" .. Text(snapshot.amenities) .. ",production:" .. Text(snapshot.production) ..
    ",science:" .. Text(snapshot.science) .. ",loyalty:" .. Text(snapshot.loyalty),
    "candidate_developed_stage2_amenities:" .. p.amenities ..
    ",productionPercent:" .. p.productionPercent .. ",sciencePercent:" .. p.sciencePercent ..
    ",loyalty:" .. p.loyalty, "RAW");
  Log(run, "S4", phase .. "_production_breakdown", snapshot.productionTooltip,
    "negative_modifier_while_applied_and_absent_after_remove", "RAW");
  Log(run, "S4", phase .. "_science_breakdown", snapshot.scienceTooltip,
    "negative_modifier_while_applied_and_absent_after_remove", "RAW");
end

local function CandidateCity(run)
  if run.cityID == nil then return nil; end
  local player = Players[run.playerID];
  if player == nil then return nil; end
  for _, city in ipairs(Cities(player)) do
    if city:GetID() == run.cityID then return city; end
  end
  return nil;
end

local function ClearFlag(run)
  if run.plotIndex == nil then return true; end
  local ok, err = pcall(function()
    local plot = Map.GetPlotByIndex(run.plotIndex);
    if plot == nil then error("candidate_plot_missing"); end
    plot:SetProperty(FLAG_KEY, 0);
  end);
  if not ok then Log(run, "S4", "rollback_flag", err, "flag_zero", "FAIL"); end
  return ok;
end

local function StartCityCandidate(run, player)
  local city = Cities(player)[1];
  if city == nil then
    -- A new game still has a settler. Create one disposable fixture city through the
    -- shipped Pirates gameplay API, checking the engine's own location predicate.
    local collection = player:GetCities();
    local start = player:GetStartingPlot();
    local function CreateAt(plot)
      if plot and collection:IsValidFoundLocation(plot:GetX(), plot:GetY()) then
        return collection:Create(plot:GetX(), plot:GetY());
      end
      return nil;
    end
    city = CreateAt(start);
    if city == nil then
      for index = 0, Map.GetPlotCount() - 1 do
        city = CreateAt(Map.GetPlotByIndex(index));
        if city ~= nil then break; end
      end
    end
    Log(run, "S4", "fixture_city", city and city:GetID() or "none", "engine_valid_created_city",
      city and "PASS" or "PENDING", "disposable_dev_game_city_gift_settler_not_deleted");
  end
  if city == nil then
    Log(run, "S4", "candidate", "no_city", "founded_city", "PENDING");
    return;
  end
  run.cityID = city:GetID();
  local plot = city:GetPlot();
  run.plotIndex = plot:GetIndex();
  plot:SetProperty(FLAG_KEY, 0);
  local attached = Game:GetProperty(ATTACHED_KEY) or {};
  local key = tostring(run.playerID) .. ":" .. tostring(run.cityID) .. ":" .. tostring(run.plotIndex);
  -- Mark each completed attachment so an error or a repeated run cannot stack successful effects.
  local done = attached[key] or {};
  for i, modifier in ipairs(MODIFIERS) do
    if not done[i] then
      city:AttachModifierByID(modifier);
      done[i] = true;
      attached[key] = done;
      Game:SetProperty(ATTACHED_KEY, attached);
    end
  end
  run.s4Control = CitySnapshot(city);
  CityRaw(run, "control", run.s4Control);
  plot:SetProperty(FLAG_KEY, 1);
  run.s4Immediate = CitySnapshot(city);
  CityRaw(run, "apply_immediate", run.s4Immediate);
  Log(run, "S4", "candidate_gate", "city_owner_plot_resolution_unverified",
    "apply_and_remove_all_four_effects", "PENDING");
end

local function Milestones(run, player)
  for _, city in ipairs(Cities(player)) do
    Log(run, "S6", "city_" .. city:GetID() .. "_population", city:GetPopulation(),
      "nonnegative_population_read", "RAW");
  end
  local result, err = Read(function()
    local result = {};
    local districts = player:GetDistricts();
    for _, district in districts:Members() do
      result[#result + 1] = { districtType = district:GetType(), complete = district:IsComplete() };
    end
    table.sort(result, function(a, b) return a.districtType < b.districtType; end);
    return result;
  end);
  if result == nil then
    Log(run, "S6", "district_read", err, "gameplay_read_supported", "PENDING");
  else
    for _, district in ipairs(result) do
      Log(run, "S6", "district_" .. district.districtType, district.complete,
        "completion_state_only_no_new_target_completion_claimed", "RAW");
    end
  end
  Log(run, "S6", "transitions", "read_snapshots_only", "new_completed_target_transition", "PENDING");
end

local function PendingPlayerPerks(run, player)
  local favor = Read(function() return player:GetFavor(); end);
  local favorRate = Read(function() return player:GetFavorPerTurn(); end);
  local score = Read(function() local eras = Game.GetEras(); return eras:GetPlayerCurrentScore(run.playerID); end);
  Log(run, "S4", "favor_and_era_read", "favor:" .. Text(favor) ..
    ",favorRate:" .. Text(favorRate) .. ",eraScore:" .. Text(score),
    "read_capability_only_writers_unverified", "RAW");
  Log(run, "S4", "player_effects", "no_source_backed_reversible_player_gate_or_era_writer",
    "favor_floor_era_grant_international_route_percent", "PENDING");
  local envoy = Read(function() local influence = player:GetInfluence(); return influence:GetTokensToGive(); end);
  local merchant = Read(function()
    local points = player:GetGreatPeoplePoints();
    return points:GetPointsTotal(GameInfo.GreatPersonClasses["GREAT_PERSON_CLASS_MERCHANT"].Index);
  end);
  Log(run, "S9", "perk_read", "envoys:" .. Text(envoy) .. ",merchantPoints:" .. Text(merchant),
    "read_capability_only", "RAW");
  Log(run, "S9", "perk_write", "data_grant_candidates_only_removal_repeat_semantics_unverified",
    "timed_envoy_and_reversible_merchant_points", "PENDING");
end

local function OneShotGrants(run, player)
  local completed = Game:GetProperty("WBL_SPIKE_GRANTS_DONE") or {};
  local actorKey = tostring(run.playerID);
  local actorDone = completed[actorKey] or {};
  local candidates = {
    { label = "favor", spike = "S4", modifier = "WBL_SPIKE_GRANT_FAVOR",
      delta = WBL_CONFIG.spikes.favorDelta,
      read = function() return player:GetFavor(); end },
    { label = "envoy", spike = "S9", modifier = "WBL_SPIKE_GRANT_ENVOY",
      delta = WBL_CONFIG.spikes.envoyDelta,
      read = function() local influence = player:GetInfluence(); return influence:GetTokensToGive(); end }
  };
  for i, candidate in ipairs(candidates) do
    if not actorDone[i] then
      local before, readError = Read(candidate.read);
      if type(before) == "number" then
        local ok, attachError = pcall(function() player:AttachModifierByID(candidate.modifier); end);
        if ok then
          -- These positive fixture gifts intentionally remain in the disposable dev game.
          actorDone[i] = true;
          completed[actorKey] = actorDone;
          Game:SetProperty("WBL_SPIKE_GRANTS_DONE", completed);
          local after = Read(candidate.read);
          Log(run, candidate.spike, "one_shot_" .. candidate.label, after, before + candidate.delta,
            Near(after, before + candidate.delta) and "PASS" or "PENDING",
            "positive_fixture_grant_only_negative_and_repeat_semantics_unverified");
        else
          Log(run, candidate.spike, "one_shot_" .. candidate.label, attachError,
            "source_backed_data_effect_attaches", "PENDING");
        end
      else
        Log(run, candidate.spike, "one_shot_" .. candidate.label, readError,
          "gameplay_read_available_before_grant", "PENDING");
      end
    else
      Log(run, candidate.spike, "one_shot_" .. candidate.label, "already_attempted_this_game",
        "no_duplicate_fixture_grant", "RAW");
    end
  end
end

local function Relationships(run)
  local players = Majors();
  for _, player in ipairs(players) do
    local diplomacy = player:GetDiplomacy();
    for _, other in ipairs(players) do
      if player:GetID() < other:GetID() then
        local war, warError = Read(function() return diplomacy:IsAtWarWith(other:GetID()); end);
        local allied, allyError = Read(function() return diplomacy:HasAllied(other:GetID()); end);
        local supported = type(war) == "boolean" and type(allied) == "boolean";
        Log(run, "S10", "major_pair_" .. player:GetID() .. "_" .. other:GetID(),
          "war:" .. Text(war) .. ",allied:" .. Text(allied), "boolean_major_only_relationships",
          supported and "PASS" or "PENDING", warError or allyError);
      end
    end
  end
end

local function DisasterHistory(run, turn)
  local event, err = Read(function() return GameRandomEvents.GetEventsForTurn(turn); end);
  if err then
    Log(run, "S5", "history_" .. turn, err, "history_available_in_gameplay", "RAW");
  elseif event ~= nil then
    Log(run, "S5", "history_" .. turn,
      "type:" .. Text(event.RandomEvent) .. ",start:" .. Text(event.StartLocation) ..
      ",current:" .. Text(event.CurrentLocation) .. ",tilesDamaged:" .. Text(event.TilesDamaged) ..
      ",populationLost:" .. Text(event.PopLost), "raw_history_not_city_owner_attribution", "RAW");
  else
    Log(run, "S5", "history_" .. turn, "none", "raw_history_not_city_owner_attribution", "RAW");
  end
end

local function ObserveEconomy(run, turn)
  local snapshots, total, totalProduction, productionComplete = {}, 0, 0, true;
  local living = Majors();
  for _, player in ipairs(living) do
    local snapshot, err = Read(function() return PlayerSnapshot(player); end);
    if snapshot then
      snapshots[#snapshots + 1] = snapshot;
      total = total + snapshot.gpt;
      if snapshot.production == nil then productionComplete = false;
      else totalProduction = totalProduction + snapshot.production; end
      if (turn - run.startTurn) % WBL_CONFIG.spikes.logEveryTurns == 0 then
        Log(run, "S11", "economy_player_" .. snapshot.playerID,
          "gold:" .. snapshot.gold .. ",netGPT:" .. snapshot.gpt ..
          ",techs:" .. snapshot.techs .. ",civics:" .. snapshot.civics,
          "raw_living_major_snapshot", "RAW");
      end
      if (turn - run.startTurn) % WBL_CONFIG.spikes.difficultyLogEveryTurns == 0 then
        Log(run, "S12", "difficulty_player_" .. snapshot.playerID,
          snapshot.difficulty .. ",human:" .. Text(snapshot.human) ..
          ",techs:" .. snapshot.techs .. ",civics:" .. snapshot.civics,
          "raw_profile_not_calibration", "RAW");
      end
    else
      Log(run, "S11", "economy_player_" .. player:GetID(), err, "snapshot_readable", "PENDING");
    end
  end
  local complete = #snapshots == #living and #living > 0;
  local average = complete and total / #snapshots or nil;
  run.history[#run.history + 1] = { turn = turn, averageNetGPT = average, players = snapshots };
  Log(run, "S11", "world_income", "I(t):" .. Text(average) .. ",majors:" .. #living ..
    ",readable:" .. #snapshots .. ",averageProduction:" .. Text(complete and productionComplete and totalProduction / #snapshots or nil),
    "complete_living_major_average_netGPT", complete and "RAW" or "PENDING");
  if average ~= nil and average > 0 and average ~= math.huge then
    local window = WBL_MATH.ScaleTurns(WBL_CONFIG.growth.windowTurns, run.speedScale);
    local prior;
    for _, observation in ipairs(run.history) do
      if observation.turn == turn - window then prior = observation.averageNetGPT; end
    end
    local growth, mode, raw;
    if turn - run.startTurn >= window and prior == nil then
      mode = "missing_reference_observation";
    else
      growth, mode, raw = WBL_MATH.Growth(average, prior, run.speedScale);
    end
    Log(run, "S11", "growth", "g:" .. Text(growth) .. ",mode:" .. Text(mode) ..
      ",raw:" .. Text(raw) .. ",prior:" .. Text(prior) .. ",window:" .. window ..
      ",speed:" .. run.speedType .. ",scale:" .. run.speedScale,
      "speed_scaled_default_or_measured_clamped_g", growth and "RAW" or "PENDING");
    if growth then
      for _, name in ipairs({ "DEVELOPED", "DEVELOPING", "UNDERDEVELOPED" }) do
        local tier = WBL_CONFIG.tiers[name];
        for _, term in ipairs(tier.terms) do
          local turns = WBL_MATH.ScaleTurns(term, run.speedScale);
          local grace = WBL_MATH.ScaleTurns(tier.graceTurns, run.speedScale);
          -- A unit principal is a dimensional normalization; nominal rate is principal-independent.
          local quote = WBL_MATH.LoanQuote(1, tier.valueRatio, growth, turns, grace);
          Log(run, "S11", "nominal_" .. name .. "_" .. term,
            "rate:" .. quote.nominalRate .. ",payments:" .. turns .. ",grace:" .. grace,
            "unadjusted_tier_quote_from_current_g", "RAW");
        end
      end
    end
  else
    Log(run, "S11", "growth", average, "positive_complete_world_index", "PENDING");
  end
  if run.aiID ~= nil then
    for _, snapshot in ipairs(snapshots) do
      if snapshot.playerID == run.aiID then
        Log(run, "S8", "granted_ai_observation_" .. run.aiID,
          "gold:" .. snapshot.gold .. ",netGPT:" .. snapshot.gpt ..
          ",elapsed:" .. (turn - run.startTurn), "raw_no_purchase_attribution", "RAW");
      end
    end
  end
end

local function Finish(run)
  if run.summaryPrinted then return; end
  run.summaryPrinted = true;
  print("[SUMMARY] " .. run.pass .. " PASS, " .. run.fail .. " FAIL, " .. run.pending ..
    " PENDING run=" .. run.runID .. " turn=" .. Game.GetCurrentGameTurn() ..
    " production_verified=false");
end

function WBL_RunAllSpikes(ePlayer, params)
  if not IsSinglePlayer() then
    print("[SPIKE GUARD] player=" .. Text(ePlayer) .. " multiplayer_or_unknown_context REJECTED");
    return;
  end
  local player = Players[ePlayer];
  if player == nil or not player:IsHuman() then
    print("[SPIKE GUARD] invalid_request_actor REJECTED");
    return;
  end
  local configOK, configError = ValidConfig(WBL_CONFIG);
  if not configOK then
    print("[SPIKE HARNESS] variant=config actual=" .. Text(configError) .. " expected=valid_config FAIL");
    return;
  end
  local previous = Game:GetProperty(RUN_KEY);
  if previous and not previous.summaryPrinted then
    print("[SPIKE GUARD] observation_already_active REJECTED");
    return;
  end
  if previous and not ClearFlag(previous) then
    Publish(previous, "ERROR", "Previous candidate flag could not be cleared; a new run was refused.");
    return;
  end
  local turn = Game.GetCurrentGameTurn();
  local speed = Read(function() return GameInfo.GameSpeeds[GameConfiguration.GetGameSpeedType()]; end);
  if not speed or type(speed.CostMultiplier) ~= "number" or speed.CostMultiplier <= 0 then
    print("[SPIKE HARNESS] variant=speed actual=invalid expected=positive_cost_multiplier FAIL");
    return;
  end
  local run = {
    playerID = ePlayer, runID = previous and previous.runID + 1 or 1,
    startTurn = turn, lastTurn = turn, pass = 0, fail = 0, pending = 0, history = {},
    speedType = speed.GameSpeedType, speedScale = speed.CostMultiplier / 100
  };
  print("[WBL RUN] BEGIN run=" .. run.runID .. " turn=" .. turn .. " player=" .. ePlayer);
  Publish(run, "RUNNING", "Running source-backed probes; unresolved checks stay pending.");
  local ok, err = pcall(function()
    GoldRoundTrip(run, player);
    for _, major in ipairs(Majors()) do
      local development = Development(major);
      Log(run, "S2", "development_player_" .. major:GetID(),
        "techs:" .. development.techs .. ",civics:" .. development.civics,
        "HasTech_HasCivic_counts_in_database_order", "PASS");
    end
    local marker = { runID = run.runID, turn = turn, playerID = ePlayer };
    Game:SetProperty("WBL_SPIKE_PERSISTENCE", marker);
    local readback = Game:GetProperty("WBL_SPIKE_PERSISTENCE");
    Log(run, "S10", "property_roundtrip", readback and readback.runID, run.runID,
      readback and readback.runID == run.runID and "PASS" or "FAIL");
    Log(run, "S10", "save_reload_mp", "not_exercised", "new_game_save_reload_and_MP_session", "PENDING");
    Relationships(run);
    Log(run, "S7", "launch_bar", "request_reached_gameplay", "visible_working_launch_bar_entry_LOOK", "PENDING");
    StartCityCandidate(run, player);
    Milestones(run, player);
    PendingPlayerPerks(run, player);
    OneShotGrants(run, player);
    Log(run, "S3", "deal_rate", "no_safe_automated_acceptability_probe",
      "AI_accepted_gold_for_30_turn_GPT_raw_matrix", "PENDING");
    Log(run, "S5", "damage_attribution", "aggregate_history_only",
      "damaged_city_owner_at_synced_boundary", "PENDING");
    DisasterHistory(run, turn);
    for _, major in ipairs(Majors()) do
      if not major:IsHuman() then
        local treasury = major:GetTreasury();
        run.aiID = major:GetID();
        run.aiGoldBefore = treasury:GetGoldBalance();
        treasury:ChangeGoldBalance(WBL_CONFIG.spikes.aiGrant);
        run.aiGoldAfter = treasury:GetGoldBalance();
        Log(run, "S8", "script_grant_ai_" .. run.aiID, run.aiGoldAfter,
          run.aiGoldBefore + WBL_CONFIG.spikes.aiGrant,
          Near(run.aiGoldAfter, run.aiGoldBefore + WBL_CONFIG.spikes.aiGrant) and "PASS" or "FAIL");
        break;
      end
    end
    Log(run, "S8", "spending", run.aiID and "observing_granted_AI" or "no_AI_present",
      "controlled_purchase_spend_attribution", "PENDING");
    ObserveEconomy(run, turn);
    Log(run, "S11", "growth_tuning", "telemetry_started", "representative_speed_histories", "PENDING");
    Log(run, "S12", "difficulty_tuning", "telemetry_started", "representative_difficulty_histories", "PENDING");
  end);
  if not ok then
    Log(run, "HARNESS", "engine_error", err, "all_probes_complete", "FAIL");
    ClearFlag(run);
    Finish(run);
    Publish(run, "ERROR", "Probe error logged; candidate flag cleared where possible.");
  else
    Publish(run, "OBSERVING", "End turn once for applied city candidate, twice for removal. Unresolved APIs remain pending.");
  end
end

function WBL_ReloadConfig(ePlayer, params)
  if not IsSinglePlayer() then
    print("[SPIKE GUARD] config_reload multiplayer_or_unknown_context REJECTED");
    return;
  end
  local player = Players[ePlayer];
  if player == nil or not player:IsHuman() then return; end
  local previous = WBL_CONFIG;
  local active = Game:GetProperty(RUN_KEY);
  if active and not active.summaryPrinted then
    print("[SPIKE CONFIG] active_observation REJECTED");
    return;
  end
  local ok, err = pcall(function() include("WBL_Config"); end);
  local valid, validationError = ValidConfig(WBL_CONFIG);
  if not ok or not valid then WBL_CONFIG = previous; end
  print("[SPIKE CONFIG] include_request=" .. Text(ok) .. " version=" .. Text(WBL_CONFIG and WBL_CONFIG.version) ..
    " valid=" .. Text(valid) .. " generated_SQL_requires_new_game=true fresh_disk_reload_verified=false error=" .. Text(err or validationError));
end

local function OnGameTurnStarted(turn)
  if not IsSinglePlayer() then return; end
  local run = Game:GetProperty(RUN_KEY);
  if run == nil then return; end
  local configOK, configError = ValidConfig(WBL_CONFIG);
  if not configOK then
    Log(run, "HARNESS", "config", configError, "valid_config", "FAIL");
    ClearFlag(run);
    Finish(run);
    Publish(run, "ERROR", "Invalid config; candidate flag cleared.");
    return;
  end
  local now = Game.GetCurrentGameTurn();
  if run.lastTurn ~= nil and now <= run.lastTurn then return; end
  run.lastTurn = now;
  local ok, err = pcall(function()
    local elapsed = now - run.startTurn;
    local horizon = run.speedType == "GAMESPEED_ONLINE" and WBL_CONFIG.spikes.onlineAutoplayTurns or WBL_CONFIG.spikes.standardAutoplayTurns;
    if elapsed > horizon and run.summaryPrinted then return; end
    if elapsed <= horizon then ObserveEconomy(run, now); end
    Relationships(run);
    DisasterHistory(run, now - 1);
    if elapsed == 1 and run.plotIndex ~= nil then
      local city = CandidateCity(run);
      if city then CityRaw(run, "applied_boundary", CitySnapshot(city)); end
      Publish(run, "S4_APPLIED", "Candidate city effects active. Inspect the selected city breakdowns, then end turn once to remove.");
    elseif elapsed >= WBL_CONFIG.spikes.observationTurns and not run.summaryPrinted then
      local city = CandidateCity(run);
      if city then CityRaw(run, "before_remove", CitySnapshot(city)); end
      ClearFlag(run);
      if city then CityRaw(run, "remove_immediate", CitySnapshot(city)); end
      Log(run, "S4", "release_gate", "candidate_raw_results_require_review",
        "all_effects_apply_remove_all_tiers_and_player_perks", "PENDING");
      Finish(run);
      Publish(run, "S4_REMOVED", "Candidate flag removed. Logs contain raw effect and AI observations; production gates remain pending.");
    else
      Game:SetProperty(RUN_KEY, run);
    end
  end);
  if not ok then
    Log(run, "HARNESS", "turn_error", err, "observation_complete", "FAIL");
    ClearFlag(run);
    Finish(run);
    Publish(run, "ERROR", "Turn probe error logged; candidate flag cleared where possible.");
  end
end

GameEvents.WBL_RunAllSpikes.Add(WBL_RunAllSpikes);
GameEvents.WBL_ReloadConfig.Add(WBL_ReloadConfig);
GameEvents.OnGameTurnStarted.Add(OnGameTurnStarted);
local resumed = Game:GetProperty(RUN_KEY);
if resumed then
  print("[SPIKE S10] loaded_property run=" .. Text(resumed.runID) .. " lastTurn=" .. Text(resumed.lastTurn) ..
    " actual=present expected=saved_marker PENDING save_reload_origin_not_proven");
end
