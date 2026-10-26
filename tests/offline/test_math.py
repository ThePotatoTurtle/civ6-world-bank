"""Execute real pure Lua and compare with independent mathematical expectations."""
from pathlib import Path
import math
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]


class MathTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((ROOT / "WBL/Scripts/WBL_Config.lua").read_text(encoding="utf-8"))
        self.lua.execute((ROOT / "WBL/Scripts/WBL_Math.lua").read_text(encoding="utf-8"))
        self.m = self.lua.globals().WBL_MATH
        self.c = self.lua.globals().WBL_CONFIG

    def table(self, value):
        if isinstance(value, list):
            return self.lua.table_from([self.table(v) for v in value])
        if isinstance(value, dict):
            return self.lua.table_from({k: self.table(v) for k, v in value.items()})
        return value

    def test_published_rate_grid_and_exact_pv(self):
        displayed = {
            .034: {"DEVELOPED": [60, 85], "DEVELOPING": [54, 78], "UNDERDEVELOPED": [45, 67, 92]},
            .015: {"DEVELOPED": [34, 44], "DEVELOPING": [22, 31], "UNDERDEVELOPED": [8, 16, 24]},
        }
        for growth, tiers in displayed.items():
            for tier, expected_rates in tiers.items():
                cfg = self.c.tiers[tier]
                for index, expected in enumerate(expected_rates, start=1):
                    term = cfg.terms[index]
                    quote = self.m.LoanQuote(300, cfg.valueRatio, growth, term, cfg.graceTurns)
                    self.assertEqual(self.m.RoundNearest(quote.nominalRate * 100), expected)
                    pv = sum(quote.payment / (1 + growth) ** turn
                             for turn in range(int(cfg.graceTurns) + 1, int(cfg.graceTurns + term) + 1))
                    self.assertAlmostEqual(pv, 300 * cfg.valueRatio, places=8)
        q = self.m.LoanQuote(300, 1.15, .034, 20, 0)
        self.assertAlmostEqual(q.totalRepayment, 481.10891404083696, places=8)
        self.assertAlmostEqual(q.payment, 24.055445702041848, places=8)
        self.assertNotEqual(q.totalRepayment, 480)

    def test_nominal_floor_and_zero_growth_limit(self):
        q = self.m.LoanQuote(100, .80, 0, 20, 0)
        self.assertEqual(q.nominalRate, 0)
        self.assertEqual(q.totalRepayment, 100)
        self.assertEqual(q.payment, 5)
        q = self.m.LoanQuote(100, 1.15, 0, 20, 0)
        self.assertAlmostEqual(q.totalRepayment, 115)

    def test_growth_conversion_rounding_and_real_value_across_speeds(self):
        expected_terms = {0.5: 10, .67: 13, 1: 20, 1.5: 30, 3: 60}
        for scale, term in expected_terms.items():
            self.assertEqual(self.m.ScaleTurns(20, scale), term)
            self.assertEqual(self.m.ScaleTurns(0, scale), 0)
            g = self.m.SpeedGrowth(.034, scale)
            self.assertAlmostEqual((1 + g) ** scale, 1.034)
            q = self.m.LoanQuote(300, 1.15, g, term, self.m.ScaleTurns(3, scale))
            pv = sum(q.payment / (1 + g) ** t for t in range(int(q.graceTurns) + 1, int(q.graceTurns + term) + 1))
            self.assertAlmostEqual(pv, 345, places=7)
        self.assertEqual(self.m.ScaleTurns(.1, .5), 1)

    def test_growth_history_bootstrap_clamps_and_invalid_signal(self):
        g, status = self.m.Growth(10, None, 1)
        self.assertEqual(status, "bootstrap")
        self.assertAlmostEqual(g, .035)
        g, status, raw = self.m.Growth(10 * 1.02 ** 20, 10, 1)
        self.assertEqual(status, "measured")
        self.assertAlmostEqual(g, .02)
        self.assertAlmostEqual(raw, .02)
        self.assertAlmostEqual(self.m.Growth(1, 100, 1)[0], .005)
        self.assertAlmostEqual(self.m.Growth(10000, 1, 1)[0], .06)
        self.assertEqual(self.m.Growth(1, 0, 1), (None, "nonpositive_or_invalid_index"))
        self.assertEqual(self.m.Growth(-1, 10, 1), (None, "nonpositive_or_invalid_index"))

    def test_median_smoothing_boundaries_and_blend_cap(self):
        values = self.table([9, 1, 5, 3])
        self.assertEqual(self.m.Median(values), 4)
        self.assertEqual(values[1], 9)
        self.assertEqual(self.m.Median(self.table([9, 1, 5])), 5)
        self.assertIsNone(self.m.Median(self.table([])))
        self.assertAlmostEqual(self.m.DevelopmentRatio(3, 5), 13 / 15)
        self.assertEqual(self.m.ClassifyTier(.9, 0, 1, 3), "DEVELOPED")
        self.assertEqual(self.m.ClassifyTier(.75, 0, 1, 3), "DEVELOPING")
        self.assertEqual(self.m.ClassifyTier(.749, 0, 1, 3), "UNDERDEVELOPED")
        self.assertEqual(self.m.ClassifyTier(.5, 0, 0, 3), "DEVELOPING")
        self.assertEqual(self.m.ClassifyTier(.5, -2, -3, 3), "DEVELOPING")
        self.assertEqual(self.m.ClassifyTier(.1, -2, 0, 1), "DEVELOPED")

    def test_world_income_is_net_gpt_living_majors_only_and_debits_never_negative(self):
        self.assertEqual(self.m.NetGPT(30, 10), 20)
        self.assertEqual(self.m.NetGPT(5, 10), -5)
        facts = self.table([
            dict(alive=True, isMajor=True, netGPT=20),
            dict(alive=True, isMajor=True, netGPT=-10),
            dict(alive=False, isMajor=True, netGPT=100),
            dict(alive=True, isMajor=False, netGPT=100),
        ])
        self.assertEqual(self.m.WorldIncome(facts), (5, 2))
        self.assertEqual(self.m.WorldIncome(self.table([])), (None, 0))
        for gold in [0, .1, 5, 100]:
            for due in [0, 1, 5, 500]:
                paid, remaining = self.m.ClampedDebit(gold, due)
                self.assertGreaterEqual(remaining, 0)
                self.assertLessEqual(paid, gold)
                self.assertAlmostEqual(paid + remaining, gold)

    def test_reference_groups_filter_eliminated_and_normalize_only_ai_reference(self):
        facts = [
            dict(id=8, alive=True, isMajor=True, human=False, score=100, netGPT=200, difficulty="DIFFICULTY_DEITY"),
            dict(id=1, alive=True, isMajor=True, human=True, score=40, netGPT=10),
            dict(id=3, alive=True, isMajor=True, human=True, score=60, netGPT=20),
            dict(id=4, alive=False, isMajor=True, human=True, score=1000, netGPT=1000),
            dict(id=62, alive=True, isMajor=False, human=False, score=1000, netGPT=1000),
        ]
        humans = self.m.ReferenceMedians(self.table(facts), True)
        ais = self.m.ReferenceMedians(self.table(facts), False)
        self.assertEqual(humans, (50, 15, 2))
        self.assertEqual(ais, (60, 20, 3))
        group = self.m.ReferenceGroup(self.table(facts), False)
        self.assertEqual(group[1].id, 1)
        self.assertEqual(group[3].score, 80)
        self.assertAlmostEqual(self.m.DevelopmentRatio(100, ais[0]), 110 / 70)
        facts[2]["alive"] = False
        self.assertEqual(self.m.ReferenceMedians(self.table(facts), True), (60, 105, 2))

    def test_hysteresis_streak_interruptions_and_distant_jump(self):
        current, pending, count = "DEVELOPING", None, 0
        for ratio in [.92, .92]:
            current, pending, count = self.m.Hysteresis(current, pending, count, ratio)
            self.assertEqual(current, "DEVELOPING")
        current, pending, count = self.m.Hysteresis(current, pending, count, .91)
        self.assertEqual((current, pending, count), ("DEVELOPING", None, 0))
        for _ in range(3):
            current, pending, count = self.m.Hysteresis(current, pending, count, .92)
        self.assertEqual(current, "DEVELOPED")
        current, pending, count = self.m.Hysteresis(current, None, 0, .88)
        self.assertEqual((current, pending, count), ("DEVELOPED", None, 0))
        for _ in range(3):
            current, pending, count = self.m.Hysteresis(current, pending, count, .5)
        self.assertEqual(current, "UNDERDEVELOPED")
        for _ in range(3):
            current, pending, count = self.m.Hysteresis(current, pending, count, 1)
        self.assertEqual(current, "DEVELOPED")

    def test_value_adjustments_floor_and_investor_exemption(self):
        self.assertAlmostEqual(self.m.AdjustedV("DEVELOPED", "B", True, .10, False), 1.05)
        self.assertAlmostEqual(self.m.AdjustedV("UNDERDEVELOPED", "A", True, .10, False), .80)
        self.assertAlmostEqual(self.m.AdjustedV("DEVELOPING", "C", False, .10, True), 1.30)
        with self.assertRaises(Exception):
            self.m.AdjustedV("DEVELOPED", "D", False, 0, False)

    def test_credit_limits_negative_gpt_and_available_principal(self):
        for rating, expected in [("A", 240), ("B", 200), ("C", 120), ("D", 0)]:
            self.assertEqual(self.m.BaseCreditLimit(rating, 20, 50), expected)
        self.assertEqual(self.m.BaseCreditLimit("B", -20, 50), 50)
        self.assertEqual(self.m.AvailableCredit(200, 50), 150)
        self.assertEqual(self.m.AvailableCredit(200, 250), 0)

    def test_liquidity_thresholds_and_ruled_investor_floor_counterexample(self):
        for pool, expected in [(100, "NORMAL"), (99.9, "TIGHT"), (50, "TIGHT"), (49.9, "STRAINED"), (20, "STRAINED"), (19.9, "EMERGENCY")]:
            self.assertEqual(self.m.LiquidityTier(pool, 100)[0], expected)
        investor_before = self.m.AdjustedV("UNDERDEVELOPED", "A", False, .05, False)
        investor_after = self.m.AdjustedV("UNDERDEVELOPED", "A", True, 0, False)
        benefit = investor_before - investor_after
        self.assertAlmostEqual(benefit, .05)
        capped = self.m.BoundRivalVBenefit(.05, .05, benefit)
        self.assertAlmostEqual(capped, .025)
        self.assertLessEqual(2 * capped, benefit + 1e-12)
        self.assertEqual(self.m.BoundRivalVBenefit(.10, .05, 0), 0)
        self.assertAlmostEqual(self.m.BoundRivalVBenefit(.10, .05, .30), .05)
        for raw in [0, .01, .05, .1]:
            for donor in [0, .01, .05, .1, .2]:
                capped = self.m.BoundRivalVBenefit(raw, .05, donor)
                self.assertLessEqual(capped, raw)
                self.assertLessEqual(capped, .05)
                self.assertLessEqual(2 * capped, donor + 1e-12)

    def test_default_penalty_scaling_uses_percent_points(self):
        p = self.m.Penalties("UNDERDEVELOPED", "stage2")
        self.assertEqual(p.amenities, -1)
        self.assertEqual(p.productionPercent, -5)
        self.assertEqual(p.loyalty, -1)
        self.assertEqual(p.garnishPercent, 37)
        self.assertEqual(p.tradePercent, -12)
        self.assertEqual(self.m.ScalePenalty(-1, .75), -1)
        self.assertEqual(self.m.ScalePenalty(-5, .75), -3)
        self.assertEqual(self.m.ScalePenalty(0, .75), 0)

    def test_shares_aggregate_sort_favor_and_fractional_aid(self):
        rows, total = self.m.Shares(self.table([dict(id=8, amount=100), dict(id=2, amount=200), dict(id=8, amount=100)]))
        self.assertEqual(total, 400)
        self.assertEqual(rows[1].id, 2)
        self.assertEqual(rows[2].share, .5)
        rows, total = self.m.Shares(self.table([dict(id=1, amount=0)]))
        self.assertEqual(total, 0)
        self.assertEqual(rows[1].share, 0)
        self.assertEqual(self.m.ShareFavor(.3), 3)
        self.assertEqual(self.m.ShareFavor(.099), 0)
        self.assertEqual(self.m.ShareFavor(1), 5)
        self.assertEqual(self.m.AidCredit(.25, 100), .25)
        self.assertEqual(self.m.AidCredit(.5, 1000), 3)

    def test_ai_trigger_boundaries(self):
        self.assertTrue(self.m.AIShouldBorrow(59, 20, 0, 1))
        self.assertFalse(self.m.AIShouldBorrow(60, 20, 0, 1))
        self.assertFalse(self.m.AIShouldBorrow(0, 0, 0, 0))
        self.assertFalse(self.m.AIShouldBorrow(0, -1, 0, 0))
        self.assertFalse(self.m.AIShouldBorrow(0, 20, 1, 0))
        self.assertFalse(self.m.AIShouldBorrow(0, 20, 0, 2))
        self.assertEqual(self.m.AILoanAmount(20), 100)

    def test_arrears_are_simple_not_compounded(self):
        self.assertEqual(self.m.SimpleArrears(100, 10), 50)
        self.assertNotAlmostEqual(100 + self.m.SimpleArrears(100, 10), 100 * 1.05 ** 10)
        self.assertEqual(self.m.SimpleArrears(0, 10), 0)

    def test_cash_ledger_does_not_double_count_remaining_receivables(self):
        cash, status = self.m.CashLedger(1000, self.table([dict(kind="loan", amount=100), dict(kind="repayment", amount=20)]))
        self.assertEqual((cash, status), (920, "ok"))
        flows = [dict(kind="deposit", amount=100), dict(kind="grant", amount=50), dict(kind="deposit_return", amount=90), dict(kind="refill", amount=5)]
        self.assertEqual(self.m.CashLedger(100, self.table(flows)), (65, "ok"))
        self.assertEqual(self.m.CashLedger(0, self.table([dict(kind="loan", amount=1)])), (None, "insufficient_cash", 1))
        self.assertEqual(self.m.CashLedger(0, self.table([dict(kind="other", amount=1)])), (None, "unknown_movement", 1))


if __name__ == "__main__":
    unittest.main()
