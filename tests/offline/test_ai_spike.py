"""Real S8 helper fake-engine tests; no result validates live AI spending."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
FAKE = r'''
logs, grants, unitItems = {}, {}, {{id=9,t=2,x=3,y=4},{id=2,t=1,x=5,y=6}}
function logfn(spike,variant,actual,expected,status,detail)
  logs[#logs+1]={spike=spike,variant=variant,actual=actual,expected=expected,status=status,detail=detail}
end
local function members(items)
  return function()
    local i=0
    return function() i=i+1; if items[i] then return i,items[i] end end
  end
end
local buildingRows={{Index=2,BuildingType="BUILDING_TWO"},{Index=1,BuildingType="BUILDING_ONE"}}
GameInfo={Buildings=setmetatable({[90]={Index=1}}, {__call=function()
  local i=0; return function() i=i+1; return buildingRows[i] end
end}),Units={},Districts={}}
YieldTypes={PRODUCTION=1}
function makePlayer(id,human,gpt)
  local p={id=id,human=human,gold=10,gpt=gpt}
  function p:GetID() return self.id end
  function p:IsHuman() return self.human end
  function p:GetTreasury()
    return {GetGoldBalance=function() return p.gold end, GetGoldYield=function() return p.gpt+2 end,
      GetTotalMaintenance=function() return 2 end, ChangeGoldBalance=function(self,amount)
        if unsupportedGrant then error('unsupported') end
        p.gold=p.gold+amount; grants[#grants+1]={id=p.id,amount=amount}
      end}
  end
  function p:GetUnits()
    if unsupportedInventory then error('unsupported_units') end
    local units={}
    for _,item in ipairs(unitItems) do
      units[#units+1]={GetID=function() return item.id end,GetType=function() return item.t end,
        GetX=function() return item.x end,GetY=function() return item.y end}
    end
    return {Members=members(units)}
  end
  function p:GetCities()
    local cities={}
    for _,cid in ipairs({8,3}) do
      cities[#cities+1]={GetID=function() return cid end,GetOwner=function() return p.id end,
        GetPopulation=function() return 3 end,GetYield=function() return 5 end,
        GetBuildings=function() return {HasBuilding=function() return true end} end,
        GetBuildQueue=function() return {GetCurrentProductionTypeHash=function() return 90 end,
          GetBuildingProgress=function() return 2 end,GetBuildingCost=function() return 20 end} end}
    end
    return {Members=members(cities)}
  end
  return p
end
human=makePlayer(0,true,20)
first=makePlayer(1,false,5)
second=makePlayer(2,false,10)
third=makePlayer(3,false,15)
players={third,human,second,first}
'''


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(FAKE)
    lua.execute((ROOT / "WBL/Scripts/WBL_Config.lua").read_text(encoding="utf-8"))
    lua.execute((ROOT / "WBL_Dev/Scripts/WBL_SpikeAI.lua").read_text(encoding="utf-8"))
    return lua


class AISpikeTests(unittest.TestCase):
    def test_distinct_ordered_arms_control_gold_unchanged_and_no_stacked_grants(self):
        lua = runtime()
        lua.execute("probe=WBL_SPIKE_AI.Run(players,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("#grants"), 2)
        self.assertEqual(lua.eval("first.gold"), 10)
        self.assertEqual(lua.eval("second.gold"), 60)
        self.assertEqual(lua.eval("third.gold"), 310)
        self.assertEqual(lua.eval("human.gold"), 10)
        self.assertEqual(lua.eval("probe.arms[1].playerID"), 1)
        self.assertEqual(lua.eval("probe.arms[2].grantApplied"), 50)
        self.assertEqual(lua.eval("probe.arms[3].grantApplied"), 300)
        self.assertEqual(lua.eval("probe.purchaseAttribution"), "PENDING")
        self.assertTrue(lua.eval("(function() for _,row in ipairs(logs) do if row.variant=='control_gold_grant' then return row.detail:find('not_an_isolated_causal_control',1,true)~=nil end end return false end)()"))

    def test_snapshot_inventory_sorted_and_production_context_preserved(self):
        lua = runtime()
        lua.execute("probe=WBL_SPIKE_AI.Run(players,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("probe.arms[1].before.units[1].id"), 2)
        self.assertEqual(lua.eval("probe.arms[1].before.units[1].owner"), 1)
        self.assertEqual(lua.eval("probe.arms[1].before.units[1].unitType"), 1)
        self.assertEqual(lua.eval("probe.arms[1].before.cities[1].id"), 3)
        self.assertEqual(lua.eval("probe.arms[1].before.cities[1].buildings[1].index"), 1)
        self.assertEqual(lua.eval("probe.arms[1].before.cities[1].production.progress"), 2)
        self.assertTrue(lua.eval("probe.arms[1].before.inventoryComplete"))

    def test_missing_treatment_arms_are_pending_not_reassigned_to_human(self):
        lua = runtime()
        lua.execute("probe=WBL_SPIKE_AI.Run({human,first},WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("#grants"), 0)
        self.assertEqual(lua.eval("probe.arms[2].reason"), "missing_ai_arm")
        self.assertEqual(lua.eval("probe.arms[3].reason"), "missing_ai_arm")
        self.assertEqual(lua.eval("#probe.arms"), 3)

    def test_nonpositive_bank_treatment_gpt_never_gets_grant(self):
        lua = runtime()
        lua.execute("second.gpt=-1; probe=WBL_SPIKE_AI.Run(players,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("second.gold"), 10)
        self.assertEqual(lua.eval("probe.arms[2].reason"), "nonpositive_or_unreadable_treatment_GPT")
        self.assertEqual(lua.eval("#grants"), 1)

    def test_inventory_unsupported_is_visible_and_does_not_invent_zero_units(self):
        lua = runtime()
        lua.execute("unsupportedInventory=true; probe=WBL_SPIKE_AI.Run(players,WBL_CONFIG,logfn)")
        self.assertFalse(lua.eval("probe.arms[2].before.inventoryComplete"))
        self.assertIn("unsupported_units", lua.eval("probe.arms[2].before.readError"))
        self.assertEqual(lua.eval("probe.purchaseAttribution"), "PENDING")

    def test_unsupported_grant_leaves_pending_without_retry_or_negative_rollback(self):
        lua = runtime()
        lua.execute("unsupportedGrant=true; probe=WBL_SPIKE_AI.Run(players,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("#grants"), 0)
        self.assertEqual(lua.eval("second.gold"), 10)
        self.assertEqual(lua.eval("probe.arms[2].reason"), "grant_mutation_or_read_unsupported")

    def test_boundary_snapshots_do_not_grant_again_or_mutate_prior_probe(self):
        lua = runtime()
        lua.execute("probe=WBL_SPIKE_AI.Run(players,WBL_CONFIG,logfn); second.gold=20; updated=WBL_SPIKE_AI.Observe(players,probe,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("#grants"), 2)
        self.assertEqual(lua.eval("probe.observations"), 0)
        self.assertEqual(lua.eval("#probe.arms[2].observations"), 0)
        self.assertEqual(lua.eval("updated.arms[2].observations[1].gold"), 20)
        self.assertEqual(lua.eval("updated.purchaseAttribution"), "PENDING")

    def test_declining_treasury_or_extra_units_never_proves_purchase(self):
        lua = runtime()
        lua.execute("probe=WBL_SPIKE_AI.Run(players,WBL_CONFIG,logfn); second.gold=0; unitItems[#unitItems+1]={id=10,t=1,x=2,y=2}; updated=WBL_SPIKE_AI.Observe(players,probe,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("updated.arms[2].status"), "PENDING")
        self.assertEqual(lua.eval("updated.arms[2].observations[1].units[3].id"), 10)
        self.assertEqual(lua.eval("updated.purchaseAttribution"), "PENDING")

    def test_eliminated_arm_does_not_crash_or_inherit_another_player(self):
        lua = runtime()
        lua.execute("probe=WBL_SPIKE_AI.Run(players,WBL_CONFIG,logfn); updated=WBL_SPIKE_AI.Observe({human,first,third},probe,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("#updated.arms[2].observations"), 0)
        self.assertEqual(lua.eval("#grants"), 2)

    def test_invalid_negative_fixed_fixture_never_debits_ai(self):
        lua = runtime()
        lua.execute("WBL_CONFIG.spikes.aiGrant=-1; probe=WBL_SPIKE_AI.Run(players,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("third.gold"), 10)
        self.assertEqual(lua.eval("probe.arms[3].grantApplied"), 0)

    def test_unreadable_numeric_inventory_is_pending_instead_of_raw_or_crash(self):
        lua = runtime()
        lua.execute("unitItems[1].x=nil; probe=WBL_SPIKE_AI.Run(players,WBL_CONFIG,logfn)")
        self.assertFalse(lua.eval("probe.arms[1].before.inventoryComplete"))
        self.assertIn("unit_snapshot_incomplete", lua.eval("probe.arms[1].before.readError"))

    def test_invalid_bank_multiple_cannot_mutate_treasury(self):
        lua = runtime()
        lua.execute("WBL_CONFIG.ai.loanGptMultiple='invalid'; probe=WBL_SPIKE_AI.Run(players,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("second.gold"), 10)
        self.assertEqual(lua.eval("probe.arms[2].reason"), "invalid_bank_sized_multiple")


if __name__ == "__main__":
    unittest.main()
