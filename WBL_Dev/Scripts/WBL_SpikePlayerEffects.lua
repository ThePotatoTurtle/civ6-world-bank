-- Dev candidates only. Exact evidence: research/S4_PLAYER_EFFECTS.md.
WBL_SPIKE_PLAYER_EFFECTS = {};
local M = WBL_SPIKE_PLAYER_EFFECTS;
local CITY_FLAG = "WBL_SPIKE_CITY_ACTIVE";
local PLAYER_FLAG = "WBL_SPIKE_PLAYER_ACTIVE";
local ATTACHED = "WBL_SPIKE_COMPARISON_ATTACHED";
local GRANTS = "WBL_SPIKE_DIRECT_GRANTS";
local CITY_MODIFIERS = {
  "WBL_SPIKE_DEVELOPED_STAGE2_AMENITY", "WBL_SPIKE_DEVELOPED_STAGE2_PRODUCTION",
  "WBL_SPIKE_DEVELOPED_STAGE2_SCIENCE", "WBL_SPIKE_DEVELOPED_STAGE2_LOYALTY"
};
local PLAYER_MODIFIERS = {
  "WBL_SPIKE_PLAYER_DEVELOPED_STAGE2_AMENITY", "WBL_SPIKE_PLAYER_DEVELOPED_STAGE2_PRODUCTION",
  "WBL_SPIKE_PLAYER_DEVELOPED_STAGE2_SCIENCE", "WBL_SPIKE_PLAYER_DEVELOPED_STAGE2_LOYALTY",
  "WBL_SPIKE_PLAYER_DEVELOPED_STAGE2_TRADE", "WBL_SPIKE_PLAYER_FAVOR_RATE",
  "WBL_SPIKE_PLAYER_MERCHANT_RATE"
};

local function Read(fn)
  local ok, value = pcall(fn);
  if ok then return value, nil; end
  return nil, tostring(value);
end

local function Text(value)
  return tostring(value):gsub("[\r\n]", " ");
end

local function Number(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge;
end

local function Near(a, b, config)
  return Number(a) and Number(b) and math.abs(a - b) <= config.spikes.epsilon;
end

local function Cities(player)
  local result = {};
  local collection = player:GetCities();
  for _, city in collection:Members() do result[#result + 1] = city; end
  table.sort(result, function(a, b) return a:GetID() < b:GetID(); end);
  return result;
end

function M.FindCity(case)
  if case == nil or case.cityID == nil then return nil; end
  local player = Players[case.playerID];
  if player == nil then return nil; end
  for _, city in ipairs(Cities(player)) do
    if city:GetID() == case.cityID then return city; end
  end
  return nil;
end

local function EnsureCity(player, capital)
  local collection = player:GetCities();
  if capital then
    local city = collection:GetCapitalCity();
    if city then return city, false; end
  else
    local city = Cities(player)[1];
    if city then return city, false; end
  end
  local function CreateAt(plot)
    if plot and collection:IsValidFoundLocation(plot:GetX(), plot:GetY()) then
      return collection:Create(plot:GetX(), plot:GetY());
    end
    return nil;
  end
  local city = CreateAt(player:GetStartingPlot());
  if city == nil then
    for index = 0, Map.GetPlotCount() - 1 do
      city = CreateAt(Map.GetPlotByIndex(index));
      if city then break; end
    end
  end
  if capital and city then city = collection:GetCapitalCity(); end
  return city, city ~= nil;
end

local function AttachCase(case, log)
  if case.mode == "control" or case.cityID == nil then return; end
  local player = Players[case.playerID];
  local city = M.FindCity(case);
  local attached = Game:GetProperty(ATTACHED) or {};
  if type(attached) ~= "table" then
    log("S4", case.label .. "_attachment_guard", "invalid_saved_guard", "table_guard", "PENDING");
    return;
  end
  local names = case.mode == "player" and PLAYER_MODIFIERS or CITY_MODIFIERS;
  for _, name in ipairs(names) do
    local key = case.playerID .. ":" .. case.cityID .. ":" .. case.plotIndex .. ":" .. name;
    if not attached[key] then
      local ok, err = pcall(function()
        if case.mode == "player" then player:AttachModifierByID(name);
        else city:AttachModifierByID(name); end
      end);
      if ok then
        attached[key] = true;
        Game:SetProperty(ATTACHED, attached);
      else
        log("S4", case.label .. "_attach_" .. name, err, "ordinary_context_attachment", "PENDING");
      end
    end
  end
end

function M.Clear(probe, log)
  if probe == nil then return true; end
  local allOK = true;
  for _, case in ipairs(probe.cases or {}) do
    if case.flagKey and case.plotIndex ~= nil then
      local ok, err = pcall(function()
        local plot = Map.GetPlotByIndex(case.plotIndex);
        if plot == nil then error("comparison_plot_missing"); end
        plot:SetProperty(case.flagKey, 0);
      end);
      if not ok then
        allOK = false;
        log("S4", case.label .. "_rollback", err, "flag_zero", "FAIL");
      end
    end
  end
  return allOK;
end

function M.Prepare(player, config, log)
  local majors = PlayerManager.GetAliveMajors();
  table.sort(majors, function(a, b) return a:GetID() < b:GetID(); end);
  local others = {};
  for _, major in ipairs(majors) do
    if major:GetID() ~= player:GetID() then others[#others + 1] = major; end
  end
  local probe = { version = 1, cases = {} };
  local definitions = {
    { label = "C_player_capital", mode = "player", actor = player, flagKey = PLAYER_FLAG },
    { label = "B_city_only", mode = "city", actor = others[1], flagKey = CITY_FLAG },
    { label = "A_untouched", mode = "control", actor = others[2] }
  };
  for _, definition in ipairs(definitions) do
    local actor = definition.actor;
    if actor == nil then
      log("S4", definition.label, "missing_major", "three_distinct_majors_for_controls", "PENDING");
    else
      local case = { label = definition.label, mode = definition.mode,
        playerID = actor:GetID(), flagKey = definition.flagKey };
      probe.cases[#probe.cases + 1] = case;
      local ok, err = pcall(function()
        local city, created = EnsureCity(actor, definition.mode == "player");
        if city == nil then
          log("S4", case.label .. "_fixture", "none", "valid_city", "PENDING");
          return;
        end
        case.cityID = city:GetID();
        local plot = city:GetPlot();
        case.plotIndex = plot:GetIndex();
        if case.flagKey then plot:SetProperty(case.flagKey, 0); end
        log("S4", case.label .. "_fixture", "owner:" .. case.playerID .. ",city:" .. case.cityID .. ",created:" .. Text(created),
          "distinct_actor_fixture", "RAW");
        AttachCase(case, log);
      end);
      if not ok then log("S4", case.label .. "_prepare", err, "fixture_and_inactive_attachment", "PENDING"); end
    end
  end
  M.Clear(probe, log);
  return probe;
end

function M.Apply(probe, log)
  for _, case in ipairs(probe.cases) do
    if case.cityID and case.flagKey then
      local ok, err = pcall(function()
        local plot = Map.GetPlotByIndex(case.plotIndex);
        plot:SetProperty(case.flagKey, 1);
      end);
      if not ok then log("S4", case.label .. "_apply", err, "flag_one", "PENDING"); end
    end
  end
end

local function ModifierStates(phase, log)
  local modifiers, err = Read(function() return GameEffects.GetModifiers(); end);
  if type(modifiers) ~= "table" then
    log("S4", phase .. "_modifier_states", err or "unavailable", "ordinary_context_GameEffects_read", "PENDING");
    return;
  end
  table.sort(modifiers, function(a, b) return tostring(a) < tostring(b); end);
  local found = 0;
  for _, id in ipairs(modifiers) do
    local definition = Read(function() return GameEffects.GetModifierDefinition(id); end);
    if definition and type(definition.Id) == "string" and string.find(definition.Id, "WBL_SPIKE", 1, true) == 1 then
      found = found + 1;
      local active = Read(function() return GameEffects.GetModifierActive(id); end);
      local owner = Read(function() return GameEffects.GetModifierOwner(id); end);
      local subjects = Read(function() return GameEffects.GetModifierSubjectCount(id); end);
      log("S4", phase .. "_instance_" .. tostring(id),
        "id:" .. definition.Id .. ",active:" .. Text(active) .. ",owner:" .. Text(owner) .. ",subjects:" .. Text(subjects),
        "inactive_control_active_applied_inactive_removed_for_gated_effects", "RAW");
    end
  end
  if found == 0 then
    log("S4", phase .. "_modifier_states", "no_candidate_instances_returned", "candidate_instance_metadata", "PENDING");
  end
end

function M.Capture(probe, phase, config, log)
  for _, case in ipairs(probe.cases) do
    local city = M.FindCity(case);
    local player = Players[case.playerID];
    if city then
      local amenities = Read(function() local growth = city:GetGrowth(); return growth:GetAmenities(); end);
      local loyalty = Read(function() local identity = city:GetCulturalIdentity(); return identity:GetLoyaltyPerTurn(); end);
      local production = Read(function() return city:GetYield(YieldTypes.PRODUCTION); end);
      local science = Read(function() return city:GetYield(YieldTypes.SCIENCE); end);
      local favor = Read(function() return player:GetFavorPerTurn(); end);
      local merchantRate = Read(function()
        local points = player:GetGreatPeoplePoints();
        local class = GameInfo.GreatPersonClasses["GREAT_PERSON_CLASS_MERCHANT"];
        return points:GetPointsPerTurn(class.Index);
      end);
      log("S4", phase .. "_" .. case.label,
        "owner:" .. case.playerID .. ",city:" .. case.cityID .. ",amenities:" .. Text(amenities) ..
        ",production:" .. Text(production) .. ",science:" .. Text(science) .. ",loyalty:" .. Text(loyalty) ..
        ",favorRate:" .. Text(favor) .. ",merchantRate:" .. Text(merchantRate),
        case.mode == "control" and "untouched_control" or "configured_developed_stage2_candidate_when_applied", "RAW");
      local productionTooltip = Read(function() return city:GetYieldToolTip(YieldTypes.PRODUCTION); end);
      local scienceTooltip = Read(function() return city:GetYieldToolTip(YieldTypes.SCIENCE); end);
      log("S4", phase .. "_" .. case.label .. "_production", productionTooltip, "raw_breakdown", "RAW");
      log("S4", phase .. "_" .. case.label .. "_science", scienceTooltip, "raw_breakdown", "RAW");
    else
      log("S4", phase .. "_" .. case.label, "city_unavailable", "same_owned_fixture_city", "PENDING");
    end
  end
  ModifierStates(phase, log);
end

local function GrantGuard(playerID, label, log)
  local completed = Game:GetProperty(GRANTS) or {};
  if type(completed) ~= "table" then
    log("S9", label .. "_guard", "invalid_saved_guard", "no_repeated_gifts", "PENDING");
    return false;
  end
  local actorKey = tostring(playerID);
  local actor = completed[actorKey] or {};
  if type(actor) ~= "table" then
    log("S9", label .. "_guard", "invalid_actor_guard", "no_repeated_gifts", "PENDING");
    return false;
  end
  if actor[label] then
    log("S9", label .. "_guard", "already_attempted", "no_repeated_gifts", "RAW");
    return false;
  end
  -- Persist before the call: a raised engine error may still have applied a gift.
  actor[label] = true;
  completed[actorKey] = actor;
  Game:SetProperty(GRANTS, completed);
  return true;
end

function M.DirectGrants(player, config, log)
  local id = player:GetID();
  local candidates = {
    { label = "era_score_direct", spike = "S4", delta = config.spikes.eraScoreDelta,
      read = function() local eras = Game.GetEras(); return eras:GetPlayerCurrentScore(id); end,
      grant = function(delta) local eras = Game.GetEras(); eras:ChangePlayerEraScore(id, delta); end },
    { label = "envoy_direct", spike = "S9", delta = config.spikes.envoyDelta,
      read = function() local influence = player:GetInfluence(); return influence:GetTokensToGive(); end,
      grant = function(delta) local influence = player:GetInfluence(); influence:ChangeTokensToGive(delta); end },
    { label = "merchant_direct", spike = "S9", delta = config.spikes.merchantPointsDelta,
      read = function()
        local points = player:GetGreatPeoplePoints();
        return points:GetPointsTotal(GameInfo.GreatPersonClasses["GREAT_PERSON_CLASS_MERCHANT"].Index);
      end,
      grant = function(delta)
        local points = player:GetGreatPeoplePoints();
        points:ChangePointsTotal(GameInfo.GreatPersonClasses["GREAT_PERSON_CLASS_MERCHANT"].Index, delta);
      end }
  };
  for _, candidate in ipairs(candidates) do
    if GrantGuard(id, candidate.label, log) then
      local before, readError = Read(candidate.read);
      if Number(before) and before >= 0 then
        local ok, err = pcall(function() candidate.grant(candidate.delta); end);
        local after = Read(candidate.read);
        log(candidate.spike, candidate.label, after, before + candidate.delta,
          ok and Near(after, before + candidate.delta, config) and "PASS" or "PENDING", err);
      else
        log(candidate.spike, candidate.label, readError or before, "finite_nonnegative_baseline", "PENDING");
      end
    end
  end
  if GrantGuard(id, "favor_roundtrip", log) then
    local diplomacy = Read(function() return player:GetDiplomacy(); end);
    local before = Read(function() return diplomacy:GetFavor(); end);
    if Number(before) and before >= 0 then
      local creditOK, creditError = pcall(function() diplomacy:ChangeFavor(config.spikes.favorDelta); end);
      local credited = Read(function() return diplomacy:GetFavor(); end);
      local negativeCredit = Number(credited) and credited < 0;
      log("S4", "favor_credit_direct", credited, before + config.spikes.favorDelta,
        negativeCredit and "FAIL" or creditOK and Near(credited, before + config.spikes.favorDelta, config) and "PASS" or "PENDING", creditError);
      if negativeCredit then
        local restored, restoreError = pcall(function() diplomacy:ChangeFavor(before - credited); end);
        local final = Read(function() return diplomacy:GetFavor(); end);
        log("S4", "favor_positive_restore", final, before,
          restored and Near(final, before, config) and final >= 0 and "PASS" or "FAIL", restoreError);
      end
      if creditOK and Number(credited) and credited >= 0 then
        local debit = math.min(credited, config.spikes.favorDelta);
        local debitOK, debitError = pcall(function() diplomacy:ChangeFavor(-debit); end);
        local after = Read(function() return diplomacy:GetFavor(); end);
        local negativeDebit = Number(after) and after < 0;
        log("S4", "favor_clamped_debit", after, credited - debit,
          negativeDebit and "FAIL" or debitOK and Near(after, credited - debit, config) and after >= 0 and "PASS" or "PENDING", debitError);
        if Number(after) and after < before then
          local restored, restoreError = pcall(function() diplomacy:ChangeFavor(before - after); end);
          local final = Read(function() return diplomacy:GetFavor(); end);
          log("S4", "favor_positive_restore", final, before,
            restored and Near(final, before, config) and final >= 0 and "PASS" or "FAIL", restoreError);
        end
      end
    else
      log("S4", "favor_roundtrip", before, "ordinary_context_nonnegative_favor_read", "PENDING");
    end
  end
end

function M.EstablishContact(player, log)
  local majors = PlayerManager.GetAliveMajors();
  table.sort(majors, function(a, b) return a:GetID() < b:GetID(); end);
  for _, other in ipairs(majors) do
    if other:GetID() ~= player:GetID() then
      local ok, err = pcall(function()
        local diplomacy = player:GetDiplomacy();
        local otherDiplomacy = other:GetDiplomacy();
        if not diplomacy:HasMet(other:GetID()) then diplomacy:SetHasMet(other:GetID()); end
        if not otherDiplomacy:HasMet(player:GetID()) then otherDiplomacy:SetHasMet(player:GetID()); end
      end);
      log("S3", "fixture_contact_" .. other:GetID(), ok, "reciprocal_major_contact_only",
        ok and "RAW" or "PENDING", err);
    end
  end
end
