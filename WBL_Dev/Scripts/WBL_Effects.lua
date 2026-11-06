-- WBL_EFFECTS: engine write adapter (PLAN.md "Production module map and contracts", Effects).
-- Load WBL_Config.lua first. Effects commit in array order. Every engine call is pcall'd and
-- logged with a "[WBL EFFECT]" line. Decision 33: an unverified capability is attempted only
-- through its shipped-source candidate API (tools/source_policy.d/adapters.json) and only
-- while its features.attempt* flag is true; otherwise the entry is PENDING with applied=false.
-- The dev spikes call these same functions. Gameplay-included: no pairs, no randomness.
--
-- API
--   Apply(effects, snapshot, config, options) -> result
--     options.deferNotify: NOTIFY entries become DEFERRED (send after persisting with Notify).
--     result = {ok, revalidate, aborted, reason, turn, entries[], compensation}
--     entry  = {effectID, kind, playerID, required, status, applied, reason, requested,
--               amount, before, after, clamped}
--     status: APPLIED, NOOP, PENDING (gate off), FAILED, MISMATCH (expectedBefore),
--             SKIPPED (after an abort), DEFERRED (notification held back).
--   Notify(effects, config) -> entries for the NOTIFY effects only.
--   Compensate(entries, config) -> {ok, reversed[], notReversed[]}; reverses applied
--     GOLD/FAVOR deltas newest first (never below zero); other applied kinds are reported.
--   Probe(config) -> {core, capabilities[] {name, present, attempt, reason}, has{name=bool}}
--   PenaltyLevelKey(tier, stage), PenaltyModifierID(tier, stage, effect), PenaltyModifiers()
--
-- Penalty contract (WP8 data, WBL/Data/WBL_Penalties.sql): capital center-plot property
-- WBL_PENALTY_<TIER>_S<stage> (1 active, 0 inactive) gates player modifiers
-- WBL_PENALTY_<TIER>_S<stage>_<EFFECT>, EFFECT in PENALTY_EFFECTS; zero-amount rows may be
-- absent and are skipped. Player properties: WBL_PENALTY_ATTACHED = number of contract
-- modifiers attached so far (attach once, resumable); WBL_PENALTY_PLOT = flagged plot index
-- (-1 none) so a moved capital's old plot is cleared.
WBL_EFFECTS = {}
local E = WBL_EFFECTS
E.PENALTY_TIERS = { "DEVELOPED", "DEVELOPING", "UNDERDEVELOPED" }
E.PENALTY_EFFECTS = { "AMENITY", "PRODUCTION", "SCIENCE", "LOYALTY", "FAVOR", "TRADE" }
E.PENALTY_ATTACHED_PROPERTY = "WBL_PENALTY_ATTACHED"
E.PENALTY_PLOT_PROPERTY = "WBL_PENALTY_PLOT"
E.MERCHANT_CLASS = "GREAT_PERSON_CLASS_MERCHANT"
E.KINDS = { "GOLD", "FAVOR", "ERA_SCORE", "MERCHANT_POINTS", "ENVOY", "PENALTY_LEVEL", "NOTIFY" }
local GATES = {
  FAVOR = "attemptFavorWrite", ERA_SCORE = "attemptEraScoreWrite", MERCHANT_POINTS = "attemptMerchantPoints",
  ENVOY = "attemptEnvoyWrite", PENALTY_LEVEL = "attemptPenaltyEffects"
}
local STAGES = { 1, 2 }
-- Split so the manifest localization audit does not read the prefix as an undefined key.
local NOTIFY_PREFIX = "LOC_WBL" .. "_NOTIFY_"

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

local function Contains(list, value)
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
end

local function Tolerance(config)
  return config.precision.balanceTolerance
end

local function Near(a, b, config)
  return Finite(a) and Finite(b) and math.abs(a - b) <= Tolerance(config)
end

-- Readback after a balance write: the engine stores gold in 1/256 steps, rounding each change down, so the
-- result may differ from the request by less than one step (live, Session P 2026-11-04).
local function NearWritten(a, b, config)
  local step = math.max(Tolerance(config), config.precision.treasuryResolution or 0)
  return Finite(a) and Finite(b) and math.abs(a - b) <= step
end

local function Log(entry)
  print("[WBL EFFECT] id=" .. Text(entry.effectID) .. " kind=" .. Text(entry.kind) ..
    " player=" .. Text(entry.playerID) .. " status=" .. entry.status .. " reason=" .. Text(entry.reason) ..
    " requested=" .. Text(entry.requested) .. " amount=" .. Text(entry.amount) ..
    " before=" .. Text(entry.before) .. " after=" .. Text(entry.after) ..
    (entry.clamped and " clamped=true" or "") .. (entry.detail and (" detail=" .. Text(entry.detail)) or ""))
end

local function Finish(entry, status, reason, detail)
  entry.status = status
  entry.reason = reason
  entry.detail = detail
  entry.applied = status == "APPLIED" or status == "NOOP"
  return entry
end

function E.PenaltyLevelKey(tier, stage)
  return "WBL_PENALTY_" .. tier .. "_S" .. stage
end

function E.PenaltyModifierID(tier, stage, effect)
  return E.PenaltyLevelKey(tier, stage) .. "_" .. effect
end

-- Contract modifiers that exist in the loaded database, in fixed contract order.
function E.PenaltyModifiers()
  local names = {}
  for _, tier in ipairs(E.PENALTY_TIERS) do
    for _, stage in ipairs(STAGES) do
      for _, effect in ipairs(E.PENALTY_EFFECTS) do
        local name = E.PenaltyModifierID(tier, stage, effect)
        -- Keyed GameInfo lookup by ModifierId, as GAME/Base/Assets/UI/Civilopedia/CivilopediaPage_Civic.lua:90.
        if GameInfo.Modifiers[name] ~= nil then names[#names + 1] = name end
      end
    end
  end
  return names
end

local function PlayerObject(playerID)
  local player = Players[playerID]
  if player == nil then error("player_missing") end
  return player
end

-- Shared signed-balance writer for GOLD and FAVOR: expectedBefore check, zero floor, readback.
local function BalanceWrite(effect, entry, config, read, write)
  local before, readError = Read(read)
  entry.before = before
  if not Finite(before) then return Finish(entry, "FAILED", "READ_FAILED", readError) end
  if not Finite(effect.expectedBefore) then return Finish(entry, "FAILED", "MALFORMED", "expectedBefore") end
  if math.abs(before - effect.expectedBefore) > Tolerance(config) then
    entry.after = before
    return Finish(entry, "MISMATCH", "EXPECTED_BEFORE_MISMATCH", "expected=" .. Text(effect.expectedBefore))
  end
  local delta = effect.amount
  if delta < 0 then delta = -math.min(-delta, math.max(before, 0)) end
  entry.clamped = delta ~= effect.amount
  entry.amount = 0
  if delta == 0 then
    entry.after = before
    return Finish(entry, "NOOP", entry.clamped and "CLAMPED_TO_ZERO" or "ZERO_AMOUNT")
  end
  local ok, err = pcall(write, delta)
  local after, afterError = Read(read)
  entry.after = after
  if Finite(after) then entry.amount = after - before end
  if not ok then
    -- A raised call may still have moved the balance; keep the observed delta for compensation.
    local status = Finish(entry, "FAILED", "CALL_FAILED", err)
    entry.applied = Finite(after) and not Near(after, before, config)
    return status
  end
  if not Finite(after) then
    Finish(entry, "FAILED", "READBACK_FAILED", afterError)
    entry.amount = delta
    entry.applied = true -- The call succeeded; assume it moved so compensation is attempted.
    return entry
  end
  if not NearWritten(after, before + delta, config) then
    Finish(entry, "FAILED", "READBACK_MISMATCH", "expectedAfter=" .. Text(before + delta))
    entry.applied = not Near(after, before, config)
    return entry
  end
  -- Keep the observed change (after - before, set above): within a 1/256 step of delta, and exactly what
  -- compensation must reverse.
  return Finish(entry, "APPLIED", entry.clamped and "CLAMPED" or "OK")
end

local function GoldRead(playerID)
  return function()
    local player = PlayerObject(playerID)
    local treasury = player:GetTreasury()
    return treasury:GetGoldBalance()
  end
end

local function GoldWrite(playerID)
  return function(delta)
    local player = PlayerObject(playerID)
    local treasury = player:GetTreasury()
    treasury:ChangeGoldBalance(delta)
  end
end

local function FavorRead(playerID)
  return function()
    local player = PlayerObject(playerID)
    local diplomacy = player:GetDiplomacy()
    return diplomacy:GetFavor()
  end
end

local function FavorWrite(playerID)
  return function(delta)
    local player = PlayerObject(playerID)
    local diplomacy = player:GetDiplomacy()
    diplomacy:ChangeFavor(delta)
  end
end

local function MerchantClass()
  local row = GameInfo.GreatPersonClasses[E.MERCHANT_CLASS]
  if row == nil then error("merchant_class_missing") end
  return row.Index
end

-- Unsigned-balance writers (Era Score, Merchant points, envoys): readback is diagnostic when
-- the read candidate is unavailable; a successful call with no readback stays APPLIED unverified.
local function CounterWrite(effect, entry, config, read, write)
  local before = Read(read)
  entry.before = before
  if effect.amount == 0 then
    entry.amount = 0
    return Finish(entry, "NOOP", "ZERO_AMOUNT")
  end
  local ok, err = pcall(write, effect.amount)
  local after = Read(read)
  entry.after = after
  if not ok then
    Finish(entry, "FAILED", "CALL_FAILED", err)
    entry.amount = 0
    return entry
  end
  entry.amount = effect.amount
  if Finite(before) and Finite(after) then
    if not Near(after, before + effect.amount, config) then
      Finish(entry, "FAILED", "READBACK_MISMATCH", "expectedAfter=" .. Text(before + effect.amount))
      entry.amount = after - before
      entry.applied = not Near(after, before, config)
      return entry
    end
    return Finish(entry, "APPLIED", "OK")
  end
  return Finish(entry, "APPLIED", "UNVERIFIED_READBACK")
end

local function EraScore(effect, entry, config)
  local playerID = effect.playerID
  return CounterWrite(effect, entry, config,
    function()
      local eras = Game.GetEras()
      return eras:GetPlayerCurrentScore(playerID)
    end,
    function(delta)
      local eras = Game.GetEras()
      eras:ChangePlayerEraScore(playerID, delta)
    end)
end

local function MerchantPoints(effect, entry, config)
  local playerID = effect.playerID
  return CounterWrite(effect, entry, config,
    function()
      local player = PlayerObject(playerID)
      local points = player:GetGreatPeoplePoints()
      return points:GetPointsTotal(MerchantClass())
    end,
    function(delta)
      local player = PlayerObject(playerID)
      local points = player:GetGreatPeoplePoints()
      points:ChangePointsTotal(MerchantClass(), delta)
    end)
end

local function Envoys(effect, entry, config)
  local playerID = effect.playerID
  return CounterWrite(effect, entry, config,
    function()
      local player = PlayerObject(playerID)
      local influence = player:GetInfluence()
      return influence:GetTokensToGive()
    end,
    function(delta)
      local player = PlayerObject(playerID)
      local influence = player:GetInfluence()
      influence:ChangeTokensToGive(delta)
    end)
end

-- Contract order (WP8): clear every other level first, then switch the target level on.
local function SetLevelFlags(plot, targetKey)
  local function write(key, value)
    plot:SetProperty(key, value)
    local observed = plot:GetProperty(key)
    if observed ~= value then error("plot_property_readback:" .. key) end
  end
  for _, tier in ipairs(E.PENALTY_TIERS) do
    for _, stage in ipairs(STAGES) do
      local key = E.PenaltyLevelKey(tier, stage)
      if key ~= targetKey then write(key, 0) end
    end
  end
  if targetKey ~= "" then write(targetKey, 1) end
end

local function AttachPenaltyModifiers(player)
  local names = E.PenaltyModifiers()
  if #names == 0 then error("no_penalty_modifier_rows") end
  local attached = player:GetProperty(E.PENALTY_ATTACHED_PROPERTY)
  if not Finite(attached) or attached < 0 then attached = 0 end
  for index = attached + 1, #names do
    player:AttachModifierByID(names[index])
    player:SetProperty(E.PENALTY_ATTACHED_PROPERTY, index)
  end
  return #names
end

local function PenaltyLevel(effect, entry, config)
  local stage, tier = effect.stage, effect.tier
  entry.requested = tostring(tier) .. ":" .. tostring(stage)
  if not (stage == 0 or Contains(STAGES, stage)) or (stage ~= 0 and not Contains(E.PENALTY_TIERS, tier)) then
    return Finish(entry, "FAILED", "MALFORMED", "tier_or_stage")
  end
  local targetKey = stage == 0 and "" or E.PenaltyLevelKey(tier, stage)
  local ok, err = pcall(function()
    local player = PlayerObject(effect.playerID)
    if stage ~= 0 then entry.modifiers = AttachPenaltyModifiers(player) end
    local cities = player:GetCities()
    local capital = cities:GetCapitalCity()
    local plotIndex = -1
    local plot = nil
    if capital ~= nil then
      plot = capital:GetPlot()
      plotIndex = plot:GetIndex()
    end
    local previous = player:GetProperty(E.PENALTY_PLOT_PROPERTY)
    if Finite(previous) and previous >= 0 and previous ~= plotIndex then
      SetLevelFlags(Map.GetPlotByIndex(previous), "")
    end
    if plot ~= nil then SetLevelFlags(plot, targetKey) end
    player:SetProperty(E.PENALTY_PLOT_PROPERTY, plotIndex)
    entry.before, entry.after = previous, plotIndex
    if plot == nil and stage ~= 0 then error("no_capital") end
  end)
  entry.amount = stage
  if not ok then return Finish(entry, "FAILED", "CALL_FAILED", err) end
  return Finish(entry, "APPLIED", targetKey == "" and "CLEARED" or targetKey)
end

local function NotificationType(messageKey, config)
  local event = string.match(messageKey, "^" .. NOTIFY_PREFIX .. "(.+)_MESSAGE$")
  if event ~= nil then
    -- Data-defined row (WBL/Data/WBL_Notifications.xml); keyed lookup as TutorialUIRoot.lua:2633.
    local row = GameInfo.Notifications["NOTIFICATION_WBL_" .. event]
    if row ~= nil then
      return row.Hash, NOTIFY_PREFIX .. event .. "_SUMMARY", false
    end
  end
  -- Fallback member as PiratesScenario_PropKeys.lua:74.
  return NotificationTypes[config.adapters.notificationFallbackType], messageKey, true
end

local function Notification(effect, entry, config)
  if type(effect.messageKey) ~= "string" or string.find(effect.messageKey, "LOC_WBL_", 1, true) ~= 1 then
    return Finish(entry, "FAILED", "MALFORMED", "messageKey")
  end
  entry.requested = effect.messageKey
  local ok, err = pcall(function()
    local notificationType, summaryKey, fallback = NotificationType(effect.messageKey, config)
    if notificationType == nil then error("notification_type_missing") end
    entry.fallback = fallback
    local data = {}
    -- Live Session A (2026-11-04): Locale.Lookup rejects nil arguments ("Argument must be [boolean, number,
    -- or string]"), so unused parameters are passed as "" as the reducer already does.
    local p1, p2, p3, p4 = effect.p1 or "", effect.p2 or "", effect.p3 or "", effect.p4 or ""
    data[ParameterTypes.MESSAGE] = Locale.Lookup(effect.messageKey, p1, p2, p3, p4)
    data[ParameterTypes.SUMMARY] = Locale.Lookup(summaryKey, p1, p2, p3, p4)
    NotificationManager.SendNotification(effect.playerID, notificationType, data)
  end)
  if not ok then return Finish(entry, "FAILED", "CALL_FAILED", err) end
  return Finish(entry, "APPLIED", entry.fallback and "FALLBACK_TYPE" or "OK")
end

local HANDLERS = {
  GOLD = function(effect, entry, config)
    return BalanceWrite(effect, entry, config, GoldRead(effect.playerID), GoldWrite(effect.playerID))
  end,
  FAVOR = function(effect, entry, config)
    return BalanceWrite(effect, entry, config, FavorRead(effect.playerID), FavorWrite(effect.playerID))
  end,
  ERA_SCORE = EraScore,
  MERCHANT_POINTS = MerchantPoints,
  ENVOY = Envoys,
  PENALTY_LEVEL = PenaltyLevel,
  NOTIFY = Notification,
}

local function NewEntry(effect)
  return { effectID = effect.effectID, kind = effect.kind, playerID = effect.playerID,
    required = effect.required == true, status = "SKIPPED", applied = false, reason = "",
    requested = effect.amount, amount = 0, clamped = false }
end

local function Malformed(effect)
  if type(effect) ~= "table" or not Contains(E.KINDS, effect.kind) then return "kind" end
  if not Finite(effect.playerID) then return "playerID" end
  local numeric = effect.kind ~= "PENALTY_LEVEL" and effect.kind ~= "NOTIFY"
  if numeric and not Finite(effect.amount) then return "amount" end
  return nil
end

local function ApplyOne(effect, config)
  local entry = NewEntry(type(effect) == "table" and effect or {})
  local problem = Malformed(effect)
  if problem then
    Finish(entry, "FAILED", "MALFORMED", problem)
  elseif GATES[effect.kind] and not config.features[GATES[effect.kind]] then
    Finish(entry, "PENDING", "GATE_OFF", GATES[effect.kind])
  else
    local ok, result = pcall(HANDLERS[effect.kind], effect, entry, config)
    if not ok then Finish(entry, "FAILED", "ADAPTER_ERROR", result) end
  end
  Log(entry)
  return entry
end

-- First GOLD/FAVOR effect per player must match the live balance before anything is written.
local function Preflight(effects, config)
  local seen = {}
  for _, effect in ipairs(effects) do
    local balance = type(effect) == "table" and (effect.kind == "GOLD" or
      (effect.kind == "FAVOR" and config.features.attemptFavorWrite))
    if balance and not Malformed(effect) then
      local key = effect.kind .. ":" .. effect.playerID
      if not Contains(seen, key) then
        seen[#seen + 1] = key
        local read = effect.kind == "GOLD" and GoldRead(effect.playerID) or FavorRead(effect.playerID)
        local live = Read(read)
        if Finite(live) and Finite(effect.expectedBefore) and math.abs(live - effect.expectedBefore) > Tolerance(config) then
          return key, live, effect.expectedBefore
        end
      end
    end
  end
  return nil
end

function E.Compensate(entries, config)
  config = config or WBL_CONFIG
  local report = { ok = true, reversed = {}, notReversed = {} }
  for index = #entries, 1, -1 do
    local entry = entries[index]
    if entry.applied and entry.status ~= "NOOP" and not entry.compensated then
      if (entry.kind == "GOLD" or entry.kind == "FAVOR") and Finite(entry.amount) and entry.amount ~= 0 then
        local read = entry.kind == "GOLD" and GoldRead(entry.playerID) or FavorRead(entry.playerID)
        local write = entry.kind == "GOLD" and GoldWrite(entry.playerID) or FavorWrite(entry.playerID)
        local current = Read(read)
        local reverse = -entry.amount
        if reverse < 0 and Finite(current) then reverse = -math.min(-reverse, math.max(current, 0)) end
        local ok, err = true, nil
        if reverse ~= 0 then ok, err = pcall(write, reverse) end
        local after = Read(read)
        local reversed = (ok and Finite(current) and Finite(after)) and (after - current) or 0
        local record = { effectID = entry.effectID, kind = entry.kind, playerID = entry.playerID,
          amount = entry.amount, reversed = reversed, shortfall = -entry.amount - reversed }
        entry.compensated = true
        if ok and math.abs(record.shortfall) <= Tolerance(config) then
          report.reversed[#report.reversed + 1] = record
        else
          local short = Finite(current) and -entry.amount < 0 and current < entry.amount
          record.reason = not ok and ("CALL_FAILED:" .. Text(err)) or (short and "INSUFFICIENT_BALANCE" or "READBACK_MISMATCH")
          report.notReversed[#report.notReversed + 1] = record
          report.ok = false
        end
        print("[WBL EFFECT] compensate id=" .. Text(entry.effectID) .. " kind=" .. entry.kind ..
          " player=" .. Text(entry.playerID) .. " amount=" .. Text(entry.amount) .. " reversed=" .. Text(reversed) ..
          " " .. (record.reason or "OK"))
      else
        report.notReversed[#report.notReversed + 1] = { effectID = entry.effectID, kind = entry.kind,
          playerID = entry.playerID, amount = entry.amount, reversed = 0, shortfall = 0, reason = "IRREVERSIBLE" }
        print("[WBL EFFECT] compensate id=" .. Text(entry.effectID) .. " kind=" .. Text(entry.kind) ..
          " player=" .. Text(entry.playerID) .. " IRREVERSIBLE")
      end
    end
  end
  return report
end

function E.Apply(effects, snapshot, config, options)
  config = config or WBL_CONFIG
  options = options or {}
  effects = effects or {}
  local result = { ok = true, revalidate = false, aborted = false, reason = "OK",
    turn = type(snapshot) == "table" and snapshot.turn or -1, entries = {}, compensation = nil }
  local key, live, expected = Preflight(effects, config)
  if key ~= nil then
    result.ok, result.revalidate, result.aborted, result.reason = false, true, true, "EXPECTED_BEFORE_MISMATCH"
    for _, effect in ipairs(effects) do
      local entry = NewEntry(type(effect) == "table" and effect or {})
      Finish(entry, "SKIPPED", "PREFLIGHT_MISMATCH", key)
      result.entries[#result.entries + 1] = entry
    end
    print("[WBL EFFECT] preflight mismatch " .. key .. " live=" .. Text(live) .. " expected=" .. Text(expected) ..
      " no writes; revalidate")
    return result
  end
  -- Per (player, kind) offset = expected deltas minus deltas actually applied so far. The reducer's
  -- running expectedBefore assumes every earlier effect applied in full; a failed, gated-off or
  -- clamped earlier effect must not make later balance checks read as external changes.
  local offsets = {}
  for _, effect in ipairs(effects) do
    local entry
    if result.aborted then
      entry = NewEntry(type(effect) == "table" and effect or {})
      Finish(entry, "SKIPPED", "ABORTED")
    elseif options.deferNotify and type(effect) == "table" and effect.kind == "NOTIFY" then
      entry = NewEntry(effect)
      Finish(entry, "DEFERRED", "AFTER_COMMIT")
    else
      local balanceKey = nil
      local toApply = effect
      if type(effect) == "table" and (effect.kind == "GOLD" or effect.kind == "FAVOR") and not Malformed(effect) then
        balanceKey = effect.kind .. ":" .. effect.playerID
        local offset = offsets[balanceKey] or 0
        if offset ~= 0 and Finite(effect.expectedBefore) then
          toApply = { effectID = effect.effectID, kind = effect.kind, playerID = effect.playerID,
            amount = effect.amount, required = effect.required, expectedBefore = effect.expectedBefore - offset }
        end
      end
      entry = ApplyOne(toApply, config)
      if balanceKey ~= nil and entry.status ~= "MISMATCH" then
        local actual = (entry.applied and Finite(entry.amount)) and entry.amount or 0
        offsets[balanceKey] = (offsets[balanceKey] or 0) + (effect.amount - actual)
      end
      if entry.status == "MISMATCH" then
        result.aborted, result.revalidate, result.reason = true, true, "EXPECTED_BEFORE_MISMATCH"
      elseif entry.required and not entry.applied then
        result.aborted, result.reason = true, "REQUIRED_FAILED:" .. Text(entry.effectID)
      end
    end
    result.entries[#result.entries + 1] = entry
  end
  if result.aborted then
    result.ok = false
    result.compensation = E.Compensate(result.entries, config)
  end
  print("[WBL EFFECT] batch turn=" .. Text(result.turn) .. " count=" .. #result.entries .. " ok=" .. tostring(result.ok) ..
    " reason=" .. result.reason .. " revalidate=" .. tostring(result.revalidate))
  return result
end

function E.Notify(effects, config)
  config = config or WBL_CONFIG
  local entries = {}
  for _, effect in ipairs(effects or {}) do
    if type(effect) == "table" and effect.kind == "NOTIFY" then entries[#entries + 1] = ApplyOne(effect, config) end
  end
  return entries
end

function E.Probe(config)
  config = config or WBL_CONFIG
  local report = { core = false, capabilities = {}, has = {} }
  local player = Read(function()
    local majors = PlayerManager.GetAliveMajors()
    local chosen = nil
    for _, major in ipairs(majors) do
      local id = major:GetID()
      if not Contains(config.adapters.excludedPlayerIDs, id) and (chosen == nil or id < chosen:GetID()) then chosen = major end
    end
    return chosen
  end)
  -- Method-presence checks follow GAME/Debug/Player.ltp:316 and 364 (`X.Method ~= nil`).
  local checks = {
    { name = "property", gate = nil, test = function() return Game.GetProperty ~= nil and Game.SetProperty ~= nil end },
    { name = "gold", gate = nil, test = function()
      local treasury = player:GetTreasury()
      return treasury.GetGoldBalance ~= nil and treasury.ChangeGoldBalance ~= nil
    end },
    { name = "favor", gate = "attemptFavorWrite", test = function()
      local diplomacy = player:GetDiplomacy()
      return diplomacy.GetFavor ~= nil and diplomacy.ChangeFavor ~= nil
    end },
    { name = "eraScore", gate = "attemptEraScoreWrite", test = function()
      if Game.GetEras == nil then return false end
      local eras = Game.GetEras()
      return eras.ChangePlayerEraScore ~= nil
    end },
    { name = "merchantPoints", gate = "attemptMerchantPoints", test = function()
      local points = player:GetGreatPeoplePoints()
      return points.ChangePointsTotal ~= nil and GameInfo.GreatPersonClasses[E.MERCHANT_CLASS] ~= nil
    end },
    { name = "envoy", gate = "attemptEnvoyWrite", test = function()
      local influence = player:GetInfluence()
      return influence.ChangeTokensToGive ~= nil
    end },
    { name = "penalty", gate = "attemptPenaltyEffects", test = function()
      return player.AttachModifierByID ~= nil and player.SetProperty ~= nil and player.GetProperty ~= nil and
        Map.GetPlotByIndex ~= nil and #E.PenaltyModifiers() > 0
    end },
    { name = "notify", gate = nil, test = function()
      return NotificationManager ~= nil and NotificationManager.SendNotification ~= nil and Locale.Lookup ~= nil
    end },
  }
  for _, check in ipairs(checks) do
    local name, gate, test = check.name, check.gate, check.test
    local present, err = Read(function()
      if player == nil and name ~= "property" and name ~= "notify" then error("no_living_major") end
      return test() == true
    end)
    local capability = { name = name, present = present == true, attempt = gate == nil or config.features[gate] == true,
      reason = err or (present and "OK" or "MISSING") }
    report.capabilities[#report.capabilities + 1] = capability
    report.has[name] = capability.present
    print("[WBL PROBE] capability=" .. name .. " present=" .. tostring(capability.present) ..
      " attempt=" .. tostring(capability.attempt) .. " reason=" .. Text(capability.reason))
  end
  report.core = report.has.property == true and report.has.gold == true
  print("[WBL PROBE] core=" .. tostring(report.core))
  return report
end
