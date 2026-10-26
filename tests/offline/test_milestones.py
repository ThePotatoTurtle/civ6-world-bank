"""Real S6 helper tests with fake facts; these do not prove engine capabilities."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
FAKE = r'''
logs, known, population, changes, unsupported = {}, {[0]=true}, 3, {}, false
function logfn(spike,variant,actual,expected,status,detail)
  logs[#logs+1]={spike=spike,variant=variant,actual=actual,expected=expected,status=status,detail=detail}
end
techs={}
function techs:HasTech(index) return known[index] or false end
function techs:SetTech(index,value)
  if unsupported then error("unsupported_SetTech") end
  changes[#changes+1]="tech"; known[index]=value
end
player={GetID=function() return 0 end,GetTechs=function() return techs end}
city={GetID=function() return 7 end,GetOwner=function() return 0 end,GetPopulation=function() return population end}
function city:ChangePopulation(delta)
  if unsupported then error("unsupported_ChangePopulation") end
  changes[#changes+1]="population"; population=population+delta
end
GameInfo={Technologies=function()
  local rows={{Index=2,TechnologyType="TECH_TWO"},{Index=0,TechnologyType="TECH_ZERO"},{Index=1,TechnologyType="TECH_ONE"}}
  local index=0
  return function() index=index+1; return rows[index] end
end}
'''


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(FAKE)
    lua.execute((ROOT / "WBL/Scripts/WBL_Config.lua").read_text(encoding="utf-8"))
    lua.execute((ROOT / "WBL_Dev/Scripts/WBL_SpikeMilestones.lua").read_text(encoding="utf-8"))
    return lua


class MilestoneTests(unittest.TestCase):
    def test_actual_positive_transitions_select_absent_tech_in_index_order(self):
        lua = runtime()
        lua.execute("probe=WBL_SPIKE_MILESTONES.Run(player,city,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("population"), 4)
        self.assertTrue(lua.eval("known[1]"))
        self.assertIsNone(lua.eval("known[2]"))
        self.assertEqual(lua.eval("probe.targets[1].baseline"), 3)
        self.assertEqual(lua.eval("probe.targets[1].target"), 4)
        self.assertFalse(lua.eval("probe.targets[2].baseline"))
        self.assertEqual(lua.eval("probe.targets[2].techType"), "TECH_ONE")
        self.assertTrue(lua.eval("probe.targets[2].immediateMet"))
        self.assertEqual(lua.eval("probe.targets[3].status"), "PENDING")

    def test_boundary_observation_requeries_and_does_not_mutate_prior_snapshot(self):
        lua = runtime()
        lua.execute("probe=WBL_SPIKE_MILESTONES.Run(player,city,WBL_CONFIG,logfn); updated=WBL_SPIKE_MILESTONES.Observe(player,city,probe,WBL_CONFIG,logfn)")
        self.assertFalse(lua.eval("probe.completed"))
        self.assertTrue(lua.eval("updated.completed"))
        self.assertEqual(lua.eval("updated.targets[1].boundary"), 4)
        self.assertEqual(lua.eval("updated.targets[2].status"), "PASS")
        before = lua.eval("#logs")
        lua.execute("updated=WBL_SPIKE_MILESTONES.Observe(player,city,updated,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("#logs"), before)
        self.assertEqual(lua.eval("#changes"), 2)

    def test_no_city_does_not_hide_technology_transition(self):
        lua = runtime()
        lua.execute("probe=WBL_SPIKE_MILESTONES.Run(player,nil,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("population"), 3)
        self.assertEqual(lua.eval("probe.targets[1].status"), "PENDING")
        self.assertEqual(lua.eval("probe.targets[2].status"), "PASS")
        self.assertEqual(lua.eval("#changes"), 1)

    def test_all_techs_fulfilled_is_pending_never_false_transition_pass(self):
        lua = runtime()
        lua.execute("known[1]=true; known[2]=true; probe=WBL_SPIKE_MILESTONES.Run(player,city,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("probe.targets[2].status"), "PENDING")
        self.assertFalse(lua.eval("probe.targets[2].mutationAttempted"))
        self.assertEqual(lua.eval("#changes"), 1)

    def test_unsupported_mutations_leave_pending_without_negative_rollback(self):
        lua = runtime()
        lua.execute("unsupported=true; probe=WBL_SPIKE_MILESTONES.Run(player,city,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("population"), 3)
        self.assertFalse(lua.eval("known[1] or false"))
        self.assertEqual(lua.eval("probe.targets[1].status"), "PENDING")
        self.assertEqual(lua.eval("probe.targets[2].status"), "PENDING")
        self.assertEqual(lua.eval("#changes"), 0)

    def test_wrong_owner_never_receives_population_gift(self):
        lua = runtime()
        lua.execute("city.GetOwner=function() return 2 end; probe=WBL_SPIKE_MILESTONES.Run(player,city,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("population"), 3)
        self.assertEqual(lua.eval("probe.targets[1].reason"), "missing_or_unowned_fixture_city")

    def test_silent_noop_mutation_fails_instead_of_claiming_success(self):
        lua = runtime()
        lua.execute("city.ChangePopulation=function() end; techs.SetTech=function() end; probe=WBL_SPIKE_MILESTONES.Run(player,city,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("probe.targets[1].status"), "FAIL")
        self.assertEqual(lua.eval("probe.targets[2].status"), "FAIL")

    def test_boundary_target_loss_is_observed_not_reused_immediate_pass(self):
        lua = runtime()
        lua.execute("probe=WBL_SPIKE_MILESTONES.Run(player,city,WBL_CONFIG,logfn); population=3; known[1]=false; updated=WBL_SPIKE_MILESTONES.Observe(player,city,probe,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("updated.targets[1].status"), "FAIL")
        self.assertEqual(lua.eval("updated.targets[2].status"), "FAIL")

    def test_boundary_missing_city_and_unsupported_reads_stay_pending(self):
        lua = runtime()
        lua.execute("probe=WBL_SPIKE_MILESTONES.Run(player,city,WBL_CONFIG,logfn); techs.HasTech=function() error('unsupported') end; updated=WBL_SPIKE_MILESTONES.Observe(player,nil,probe,WBL_CONFIG,logfn)")
        self.assertEqual(lua.eval("updated.targets[1].status"), "PENDING")
        self.assertEqual(lua.eval("updated.targets[2].status"), "PENDING")

    def test_bad_positive_fixture_config_cannot_reduce_population(self):
        for delta in (0, -1, 1.5):
            lua = runtime()
            lua.execute(f"WBL_CONFIG.spikes.populationDelta={delta}; probe=WBL_SPIKE_MILESTONES.Run(player,city,WBL_CONFIG,logfn)")
            self.assertEqual(lua.eval("population"), 3)
            self.assertFalse(lua.eval("probe.targets[1].mutationAttempted"))


if __name__ == "__main__":
    unittest.main()
