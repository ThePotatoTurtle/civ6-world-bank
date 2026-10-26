"""Control isolation, direct grant guards and fallbacks; fake engine is not live proof."""
import unittest

from test_spikes import engine


class PlayerEffectTests(unittest.TestCase):
    def test_comparison_uses_distinct_players_and_untouched_control(self):
        lua = engine()
        lua.execute("WBL_RunAllSpikes(0,{})")
        self.assertEqual(lua.eval("properties.WBL_SPIKE_RUN.effects.cases[1].playerID"), 0)
        self.assertEqual(lua.eval("properties.WBL_SPIKE_RUN.effects.cases[2].playerID"), 1)
        self.assertEqual(lua.eval("properties.WBL_SPIKE_RUN.effects.cases[3].playerID"), 2)
        self.assertEqual(lua.eval("fixturePlots[0].flags.WBL_SPIKE_PLAYER_ACTIVE"), 1)
        self.assertEqual(lua.eval("fixturePlots[1].flags.WBL_SPIKE_CITY_ACTIVE"), 1)
        self.assertIsNone(lua.eval("fixturePlots[2].flags.WBL_SPIKE_PLAYER_ACTIVE"))
        self.assertIsNone(lua.eval("fixturePlots[2].flags.WBL_SPIKE_CITY_ACTIVE"))
        log = lua.eval("allLogs()")
        self.assertIn("variant=apply_immediate_A_untouched actual=owner:2,city:5,amenities:7", log)
        self.assertIn("variant=apply_immediate_B_city_only actual=owner:1,city:4,amenities:5", log)
        self.assertIn("variant=apply_immediate_C_player_capital actual=owner:0,city:3,amenities:5", log)

    def test_remove_clears_every_mutated_comparison_plot(self):
        lua = engine()
        lua.execute("WBL_RunAllSpikes(0,{}); advance(); advance()")
        self.assertEqual(lua.eval("fixturePlots[0].flags.WBL_SPIKE_PLAYER_ACTIVE"), 0)
        self.assertEqual(lua.eval("fixturePlots[1].flags.WBL_SPIKE_CITY_ACTIVE"), 0)
        self.assertIn("variant=remove_immediate_C_player_capital actual=owner:0,city:3,amenities:7", lua.eval("allLogs()"))

    def test_direct_grants_and_favor_roundtrip(self):
        lua = engine()
        lua.execute("WBL_RunAllSpikes(0,{})")
        self.assertEqual(lua.eval("Players[0].eraScore"), 4)
        self.assertEqual(lua.eval("Players[0].merchant"), 10)
        self.assertEqual(lua.eval("Players[0].envoys"), 2)
        self.assertEqual(lua.eval("Players[0].favor"), 4)
        log = lua.eval("allLogs()")
        for label in ("era_score_direct", "merchant_direct", "envoy_direct", "favor_clamped_debit"):
            lines = [line for line in log.splitlines() if "variant=" + label + " " in line]
            self.assertTrue(any("PASS" in line for line in lines), label)

    def test_unsupported_ordinary_method_does_not_abort_other_grants(self):
        for variable in ("unsupportedEra", "unsupportedMerchant", "unsupportedEnvoy", "unsupportedFavor"):
            with self.subTest(variable=variable):
                lua = engine()
                lua.execute(variable + "=true; WBL_RunAllSpikes(0,{})")
                self.assertEqual(lua.eval("properties.WBL_SPIKE_STATUS.phase"), "OBSERVING")
                self.assertNotIn("[SPIKE HARNESS]", lua.eval("allLogs()"))
                if variable != "unsupportedEra":
                    self.assertEqual(lua.eval("Players[0].eraScore"), 4)
                if variable != "unsupportedEnvoy":
                    self.assertEqual(lua.eval("Players[0].envoys"), 2)

    def test_zero_favor_never_becomes_negative(self):
        lua = engine()
        lua.execute("Players[0].favor=0; WBL_RunAllSpikes(0,{})")
        self.assertEqual(lua.eval("Players[0].favor"), 0)
        self.assertIn("variant=favor_clamped_debit actual=0 expected=0 PASS", lua.eval("allLogs()"))

    def test_rejected_negative_favor_is_pending_and_not_retried(self):
        lua = engine()
        lua.execute("rejectNegativeFavor=true; WBL_RunAllSpikes(0,{}); advance(); advance(); WBL_RunAllSpikes(0,{})")
        self.assertEqual(lua.eval("Players[0].favor"), 5)
        lines = [line for line in lua.eval("allLogs()").splitlines() if "variant=favor_clamped_debit " in line]
        self.assertEqual(len(lines), 1)
        self.assertIn("PENDING", lines[0])

    def test_guard_is_persisted_before_a_grant_that_mutates_then_raises(self):
        lua = engine()
        lua.execute("""
          Players[0].GetGreatPeoplePoints=function(self)
            return {
              GetPointsTotal=function() return self.merchant end,
              GetPointsPerTurn=function() return 0 end,
              ChangePointsTotal=function(_,class,delta) self.merchant=self.merchant+delta; error('after_mutation') end
            }
          end
          WBL_RunAllSpikes(0,{}); advance(); advance(); WBL_RunAllSpikes(0,{})
        """)
        self.assertEqual(lua.eval("Players[0].merchant"), 10)
        lines = [line for line in lua.eval("allLogs()").splitlines() if "variant=merchant_direct " in line]
        self.assertEqual(len(lines), 1)
        self.assertIn("PENDING", lines[0])

    def test_invalid_saved_grant_guard_refuses_gifts(self):
        lua = engine()
        lua.execute("properties.WBL_SPIKE_DIRECT_GRANTS=99; WBL_RunAllSpikes(0,{})")
        self.assertEqual(lua.eval("Players[0].eraScore"), 3)
        self.assertEqual(lua.eval("Players[0].merchant"), 9)
        self.assertEqual(lua.eval("Players[0].envoys"), 1)
        self.assertIn("invalid_saved_guard", lua.eval("allLogs()"))

    def test_missing_control_is_explicit_pending(self):
        lua = engine()
        lua.execute("PlayerManager.GetAliveMajors=function() return {Players[1],Players[0]} end; WBL_RunAllSpikes(0,{})")
        self.assertIn("variant=A_untouched actual=missing_major expected=three_distinct_majors_for_controls PENDING", lua.eval("allLogs()"))

    def test_contact_only_changes_major_reciprocal_met_flags(self):
        lua = engine()
        lua.execute("WBL_RunAllSpikes(0,{})")
        for other in (1, 2):
            self.assertTrue(lua.eval(f"Players[0].met[{other}]"))
            self.assertTrue(lua.eval(f"Players[{other}].met[0]"))
        self.assertIsNone(lua.eval("Players[0].met[62]"))
        self.assertIsNone(lua.eval("Players[62].met[0]"))

    def test_zero_gold_deal_fixture_has_full_requested_principal(self):
        lua = engine()
        lua.execute("Players[0].gold=0; WBL_RunAllSpikes(0,{})")
        self.assertEqual(lua.eval("Players[0].gold"), 1000)
        self.assertIn("variant=fixture_cash actual=before:0,credit:1000,after:1000", lua.eval("allLogs()"))

    def test_invalid_deal_amounts_rejected_before_all_mutations(self):
        for expression in ("{}", "{-1}", "{0/0}", "{true}"):
            with self.subTest(expression=expression):
                lua = engine()
                lua.execute("WBL_CONFIG.spikes.comparisonGold=" + expression + "; WBL_RunAllSpikes(0,{})")
                self.assertEqual(lua.eval("writes"), 0)
                self.assertEqual(lua.eval("#changes"), 0)


if __name__ == "__main__":
    unittest.main()
