"""Exercise the real dev Lua with a fake engine. This is not live-engine evidence."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]

FAKE = r'''
logs, writes, changes, attachedNames, hooks, relationshipReads = {}, 0, {}, {}, {}, {}
turn, multiplayer, hotseat, invalidConfig, cityAttachFailOn, nextCity = 0, false, false, false, nil, 3
function print(...)
  local parts = {...}
  for i = 1, #parts do parts[i] = tostring(parts[i]) end
  logs[#logs + 1] = table.concat(parts, " ")
end
function include(name)
  if invalidConfig and name == "WBL_Config" then WBL_CONFIG = {spikes={goldDelta=-500}} end
end
local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = clone(v) end
  return result
end
properties = {}
Game = {
  GetCurrentGameTurn = function() return turn end,
  GetProperty = function(self, key) return clone(properties[key]) end,
  SetProperty = function(self, key, value) writes = writes + 1; properties[key] = clone(value) end,
  GetEras = function() return {GetPlayerCurrentScore=function(self,id) return Players[id].eraScore end,ChangePlayerEraScore=function(self,id,delta) if unsupportedEra then error("unsupportedEra") end; Players[id].eraScore=Players[id].eraScore+delta end,GetCurrentEra=function() return 0 end} end
}
GameConfiguration = {
  IsAnyMultiplayer=function() return multiplayer end,
  IsHotseat=function() return hotseat end,
  GetGameSpeedType=function() return "GAMESPEED_STANDARD" end
}
GameEvents = setmetatable({}, {__index=function(self,name)
  local event={Add=function(fn) hooks[name]=fn end}; rawset(self,name,event); return event
end})
YieldTypes={PRODUCTION=1,SCIENCE=2}
plot={flags={},GetIndex=function() return 0 end,GetX=function() return 1 end,GetY=function() return 1 end}
function plot:SetProperty(k,v) self.flags[k]=v end
function plot:GetProperty(k) return self.flags[k] end
Map={GetPlotByIndex=function() return plot end,GetPlotCount=function() return 1 end}
local function active() return plot.flags.WBL_SPIKE_PLAYER_ACTIVE == 1 end
city={GetID=function() return nextCity end,GetPopulation=function() return 5 end,GetPlot=function() return plot end}
function city:AttachModifierByID(name)
  if name == cityAttachFailOn then error("forced_city_attach_error") end
  attachedNames[#attachedNames+1] = name
end
function city:GetGrowth() return {GetAmenities=function() return active() and 5 or 7 end} end
function city:GetCulturalIdentity() return {GetLoyaltyPerTurn=function() return active() and 3 or 5 end} end
function city:GetYield(yield) return (yield==1 and 20 or 10) * (active() and 0.9 or 1) end
function city:GetYieldToolTip(yield) return active() and "negative candidate modifier" or "control" end
local function members(items)
  return function()
    local index=0
    return function() index=index+1; if items[index] then return index,items[index] end end
  end
end
function makePlayer(id,human,gold,gpt,hasCity)
  local p={id=id,gold=gold,gpt=gpt,human=human,favor=4,envoys=1,merchant=9,eraScore=3,hasCity=hasCity,met={},researched={[0]=true,[1]=true},population=5}
  function p:GetID() return self.id end
  function p:IsHuman() return self.human end
  function p:GetTreasury()
    return {
      GetGoldBalance=function() return p.gold end,
      GetGoldYield=function() if unreadablePlayer==p.id then error("unreadable") end; return p.gpt+2 end,
      GetTotalMaintenance=function() return 2 end,
      ChangeGoldBalance=function(self,delta)
        p.gold=p.gold+delta; changes[#changes+1]={id=p.id,delta=delta,after=p.gold}
        assert(p.gold>=0,"negative gold")
      end
    }
  end
  function p:GetTechs() return {HasTech=function(self,index) return p.researched[index]==true end,SetTech=function(self,index,value) p.researched[index]=value end} end
  function p:GetCulture() return {HasCivic=function(self,index) return index == 0 end} end
  function p:GetDistricts() return {Members=members({{GetType=function() return 1 end,IsComplete=function() return true end}})} end
  function p:GetCities()
    return {
      Members=function() return members(p.hasCity and {p.fixtureCity} or {})() end,
      GetCapitalCity=function() return p.hasCity and p.fixtureCity or nil end,
      GetCount=function() return p.hasCity and 1 or 0 end,
      IsValidFoundLocation=function(self,x,y) return not p.hasCity and x==p.id+1 and y==1 end,
      Create=function(self,x,y) p.hasCity=true; return p.fixtureCity end
    }
  end
  function p:GetStartingPlot() return p.fixturePlot end
  function p:GetFavor() return self.favor end
  function p:GetFavorPerTurn() return p.fixturePlot and p.fixturePlot.flags.WBL_SPIKE_PLAYER_ACTIVE==1 and 2 or 1 end
  function p:GetInfluence() return {GetTokensToGive=function() return p.envoys end,ChangeTokensToGive=function(self,delta) if unsupportedEnvoy then error("unsupportedEnvoy") end; p.envoys=p.envoys+delta end} end
  function p:GetGreatPeoplePoints() return {GetPointsTotal=function() return p.merchant end,ChangePointsTotal=function(self,class,delta) if unsupportedMerchant then error("unsupportedMerchant") end; p.merchant=p.merchant+delta end,GetPointsPerTurn=function() return p.fixturePlot and p.fixturePlot.flags.WBL_SPIKE_PLAYER_ACTIVE==1 and 2 or 0 end} end
  function p:GetDiplomacy()
    return {
      GetFavor=function() return p.favor end,
      ChangeFavor=function(self,delta) if unsupportedFavor then error("unsupportedFavor") end; if rejectNegativeFavor and delta<0 then error("negativeUnsupported") end; p.favor=p.favor+delta; assert(p.favor>=0,"negative favor") end,
      HasMet=function(self,other) return p.met[other]==true end,
      SetHasMet=function(self,other) p.met[other]=true end,
      IsAtWarWith=function(self,other) relationshipReads[#relationshipReads+1]={p.id,other}; return false end,
      HasAllied=function(self,other) relationshipReads[#relationshipReads+1]={p.id,other}; return p.id==0 and other==2 end
    }
  end
  function p:AttachModifierByID(name)
    if name == playerAttachFailOn then error("forced_player_attach_error") end
    attachedNames[#attachedNames+1]=name
    if name=="WBL_SPIKE_GRANT_FAVOR" then self.favor=self.favor+WBL_CONFIG.spikes.favorDelta end
    if name=="WBL_SPIKE_GRANT_ENVOY" then self.envoys=self.envoys+WBL_CONFIG.spikes.envoyDelta end
  end
  return p
end
Players={[0]=makePlayer(0,true,7.5,10,true),[1]=makePlayer(1,false,12,3,false),[2]=makePlayer(2,false,20,5,false),[62]=makePlayer(62,false,0,0,false)}
fixturePlots={}
for _,playerID in ipairs({0,1,2}) do
  local actor=Players[playerID]
  local ownPlot={flags={}}
  function ownPlot:GetIndex() return actor.id end
  function ownPlot:GetX() return actor.id+1 end
  function ownPlot:GetY() return 1 end
  function ownPlot:SetProperty(k,v) self.flags[k]=v end
  function ownPlot:GetProperty(k) return self.flags[k] end
  actor.fixturePlot=ownPlot
  fixturePlots[playerID]=ownPlot
  local ownCity={}
  function ownCity:GetID() return actor.id+3 end
  function ownCity:GetOwner() return actor.id end
  function ownCity:GetPopulation() return actor.population end
  function ownCity:ChangePopulation(delta) actor.population=actor.population+delta end
  function ownCity:GetPlot() return ownPlot end
  function ownCity:AttachModifierByID(name)
    if name==cityAttachFailOn then error("forced_city_attach_error") end
    attachedNames[#attachedNames+1]=name
  end
  local function ownActive() return ownPlot.flags.WBL_SPIKE_CITY_ACTIVE==1 or ownPlot.flags.WBL_SPIKE_PLAYER_ACTIVE==1 end
  function ownCity:GetGrowth() return {GetAmenities=function() return ownActive() and 5 or 7 end} end
  function ownCity:GetCulturalIdentity() return {GetLoyaltyPerTurn=function() return ownActive() and 3 or 5 end} end
  function ownCity:GetYield(yield) return (yield==1 and 20 or 10)*(ownActive() and 0.9 or 1) end
  function ownCity:GetYieldToolTip(yield) return ownActive() and "negative candidate modifier" or "control" end
  actor.fixtureCity=ownCity
end
plot,city=Players[0].fixturePlot,Players[0].fixtureCity
Map={GetPlotByIndex=function(index) return fixturePlots[index] end,GetPlotCount=function() return 3 end}
PlayerManager={GetAliveMajors=function() return {Players[2],Players[0],Players[1]} end}
PlayerConfigurations={}
for _,id in ipairs({0,1,2}) do PlayerConfigurations[id]={GetHandicapTypeID=function() return "PRINCE" end} end
local function info(rows)
  return setmetatable({}, {__call=function()
    local i=0
    return function() i=i+1; return rows[i] end
  end})
end
GameInfo={
  Technologies=info({{Index=2,TechnologyType="TECH_C"},{Index=0,TechnologyType="TECH_A"},{Index=1,TechnologyType="TECH_B"}}), Civics=info({{Index=1},{Index=0}}),
  Difficulties={PRINCE={DifficultyType="DIFFICULTY_PRINCE"}},
  GameSpeeds={GAMESPEED_STANDARD={GameSpeedType="GAMESPEED_STANDARD",CostMultiplier=100}},
  GreatPersonClasses={GREAT_PERSON_CLASS_MERCHANT={Index=1}}
}
GameRandomEvents={GetEventsForTurn=function() return nil end}
function advance() turn=turn+1; hooks.OnGameTurnStarted(turn) end
function allLogs() return table.concat(logs,"\n") end
'''


def engine():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(FAKE)
    lua.execute((ROOT / "WBL/Scripts/WBL_Config.lua").read_text(encoding="utf-8"))
    lua.execute((ROOT / "WBL/Scripts/WBL_Math.lua").read_text(encoding="utf-8"))
    lua.execute((ROOT / "WBL_Dev/Scripts/WBL_SpikePlayerEffects.lua").read_text(encoding="utf-8"))
    lua.execute((ROOT / "WBL_Dev/Scripts/WBL_SpikeMilestones.lua").read_text(encoding="utf-8"))
    lua.execute((ROOT / "WBL_Dev/Scripts/WBL_SpikeAI.lua").read_text(encoding="utf-8"))
    lua.execute((ROOT / "WBL_Dev/Scripts/WBL_Spikes.lua").read_text(encoding="utf-8"))
    return lua


class SpikeHarnessTests(unittest.TestCase):
    def test_gold_roundtrip_is_clamped_and_restored(self):
        lua = engine()
        lua.execute("WBL_RunAllSpikes(0,{playerID=2})")
        self.assertEqual(lua.eval("Players[0].gold"), 1000)
        self.assertIn("variant=restore actual=7.5 expected=7.5 PASS", lua.eval("allLogs()"))
        self.assertEqual(lua.eval("changes[2].after"), 0)
        self.assertEqual(lua.eval("Players[1].gold"), 12)
        self.assertEqual(lua.eval("Players[2].gold"), 45)
        self.assertTrue(lua.eval("allLogs():find('expected=0 PASS',1,true) ~= nil"))

    def test_zero_starting_cash_never_goes_negative(self):
        lua = engine()
        lua.execute("Players[0].gold=0; WBL_RunAllSpikes(0,{})")
        self.assertEqual(lua.eval("Players[0].gold"), 1000)
        self.assertIn("variant=restore actual=0 expected=0 PASS", lua.eval("allLogs()"))
        self.assertEqual(lua.eval("changes[2].after"), 0)

    def test_multiplayer_and_hotseat_refuse_every_mutation(self):
        for guard in ("multiplayer", "hotseat"):
            with self.subTest(guard=guard):
                lua = engine()
                lua.execute(f"{guard}=true; WBL_RunAllSpikes(0,{{}}); WBL_ReloadConfig(0,{{}})")
                self.assertEqual(lua.eval("writes"), 0)
                self.assertEqual(lua.eval("#changes"), 0)
                self.assertEqual(lua.eval("#attachedNames"), 0)

    def test_invalid_config_is_rejected_before_gold_or_properties(self):
        invalid = ("spikes.goldDelta=-1", "spikes.aiGrant=-999", "spikes.epsilon=-1",
                   "spikes.observationTurns=1", "spikes.logEveryTurns=0",
                   "spikes.aiGrant=0/0", "growth.windowTurns=0")
        for assignment in invalid:
            with self.subTest(assignment=assignment):
                lua = engine()
                lua.execute("WBL_CONFIG." + assignment + "; WBL_RunAllSpikes(0,{})")
                self.assertEqual(lua.eval("writes"), 0)
                self.assertEqual(lua.eval("#changes"), 0)

    def test_invalid_reload_restores_old_config(self):
        lua = engine()
        lua.execute("invalidConfig=true; WBL_ReloadConfig(0,{})")
        self.assertEqual(lua.eval("WBL_CONFIG.spikes.goldDelta"), 10)
        self.assertTrue(lua.eval("allLogs():find('fresh_disk_reload_verified=false',1,true) ~= nil"))

    def test_phases_rollback_and_turn_deduplication(self):
        lua = engine()
        lua.execute("WBL_RunAllSpikes(0,{}); advance()")
        self.assertEqual(lua.eval("properties.WBL_SPIKE_STATUS.phase"), "S4_APPLIED")
        self.assertEqual(lua.eval("plot.flags.WBL_SPIKE_PLAYER_ACTIVE"), 1)
        count = lua.eval("#properties.WBL_SPIKE_RUN.history")
        lua.execute("hooks.OnGameTurnStarted(turn)")
        self.assertEqual(lua.eval("#properties.WBL_SPIKE_RUN.history"), count)
        lua.execute("advance()")
        self.assertEqual(lua.eval("properties.WBL_SPIKE_STATUS.phase"), "S4_REMOVED")
        self.assertEqual(lua.eval("plot.flags.WBL_SPIKE_PLAYER_ACTIVE"), 0)
        self.assertTrue(lua.eval("properties.WBL_SPIKE_RUN.summaryPrinted"))
        lua.execute("advance()")
        self.assertEqual(lua.eval("select(2,allLogs():gsub('%[SUMMARY%]',''))"), 1)

    def test_fixture_city_is_created_on_first_click(self):
        lua = engine()
        lua.execute("Players[0].hasCity=false; WBL_RunAllSpikes(0,{})")
        self.assertTrue(lua.eval("Players[0].hasCity"))
        self.assertEqual(lua.eval("properties.WBL_SPIKE_STATUS.cityID"), 3)
        self.assertEqual(lua.eval("plot.flags.WBL_SPIKE_PLAYER_ACTIVE"), 1)

    def test_partial_attachment_failure_keeps_other_probes_and_retry_does_not_stack(self):
        lua = engine()
        lua.execute("cityAttachFailOn='WBL_SPIKE_DEVELOPED_STAGE2_SCIENCE'; WBL_RunAllSpikes(0,{})")
        self.assertEqual(lua.eval("plot.flags.WBL_SPIKE_PLAYER_ACTIVE"), 1)
        self.assertEqual(lua.eval("properties.WBL_SPIKE_STATUS.phase"), "OBSERVING")
        lua.execute("advance(); advance(); cityAttachFailOn=nil; WBL_RunAllSpikes(0,{})")
        self.assertEqual(lua.eval("select(2,table.concat(attachedNames,','):gsub('WBL_SPIKE_DEVELOPED_STAGE2_AMENITY',''))"), 1)

    def test_no_false_pass_for_unknown_gates_and_one_summary_per_run(self):
        lua = engine()
        lua.execute("WBL_RunAllSpikes(0,{}); advance(); advance()")
        log = lua.eval("allLogs()")
        self.assertIn("[WBL RUN] BEGIN run=1", log)
        for line in log.splitlines():
            if any(key in line for key in ("variant=deal_rate", "variant=damage_attribution",
                                           "variant=player_effects", "variant=perk_write",
                                           "variant=release_gate", "variant=launch_bar")):
                self.assertIn("PENDING", line)
        self.assertIn("production_verified=false", log)

    def test_rerun_never_repeats_one_shot_fixture_grants(self):
        lua = engine()
        lua.execute("WBL_RunAllSpikes(0,{}); advance(); advance(); WBL_RunAllSpikes(0,{})")
        self.assertEqual(lua.eval("Players[0].favor"), 4)
        self.assertEqual(lua.eval("Players[0].envoys"), 2)
        self.assertEqual(lua.eval("properties.WBL_SPIKE_RUN.runID"), 2)

    def test_growth_and_quotes_use_math_and_incomplete_world_is_not_silently_dropped(self):
        lua = engine()
        lua.execute("WBL_RunAllSpikes(0,{})")
        log = lua.eval("allLogs()")
        self.assertIn("mode:bootstrap", log)
        self.assertIn("variant=nominal_UNDERDEVELOPED_40", log)
        lua.execute("unreadablePlayer=1; advance()")
        log = lua.eval("allLogs()")
        self.assertIn("actual=I(t):nil,majors:3,readable:2", log)
        self.assertIn("expected=positive_complete_world_index PENDING", log)

    def test_war_and_alliance_reads_only_use_sorted_major_pairs(self):
        lua = engine()
        lua.execute("WBL_RunAllSpikes(0,{})")
        pairs = [tuple(lua.eval(f"relationshipReads[{i}][{j}]") for j in (1, 2))
                 for i in range(1, lua.eval("#relationshipReads") + 1)]
        self.assertEqual(pairs, [(0, 1), (0, 1), (0, 2), (0, 2), (1, 2), (1, 2)])


if __name__ == "__main__":
    unittest.main()
