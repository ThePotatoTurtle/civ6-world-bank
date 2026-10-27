# World Bank Loans

World Bank Loans is a Civilization VI: Gathering Storm mod in development. The planned bank lends gold to major civilizations and accepts deposits for influence and better borrowing terms.

The current build contains research tools and tested pure formulas. It does not implement a playable bank. The standalone dev mod probes engine APIs in a new single-player game and records PASS, FAIL and PENDING results. Multiplayer is untested; the dev tools refuse multiplayer and hotseat requests.

Planned disaster recovery loans replace payment pauses. The dev tools test pricing and Congress data; actual qualification, per-disaster claims and lending remain unimplemented. The approved base value ratios are 1.10 for Developed, 0.90 for Developing and 0.80 for Underdeveloped, with the same tier terms and grace, normal adjustments and 0.80 floor, and a 15 Standard turn claim window. Principal is capped by remaining normal credit and available bank cash.

Planned early repayment costs all unpaid principal, overdue interest and arrears fees, plus 10% of future interest. Early closure does not improve the credit rating. Pure settlement helpers are tested; live collection and loan closure remain unimplemented.

Planned milestone forgiveness is 10% for Developed, 15% for Developing and 20% for Underdeveloped civs. Players choose their goals; already-completed goals are ineligible.

Credit limits are 15× net GPT for A, 10× for B and 7.5× for C, with a shared world-era minimum scaled by game speed. D allows no new loans. Clearing all arrears ends default penalties; settling all existing bank debt restores C without requiring another loan.

| World era | Minimum credit limit (Standard gold) |
|---|---:|
| Ancient | 100 |
| Classical | 150 |
| Medieval | 200 |
| Renaissance | 300 |
| Industrial | 450 |
| Modern | 600 |
| Atomic | 750 |
| Information | 900 |
| Future | 1,000 |

These floors use Standard-speed planning incomes of 20 / 30 / 40 / 60 / 90 / 120 / 150 / 180 / 200 GPT, from Ancient through Future. These are tuning assumptions informed by player reports, not measured era averages. At those incomes, C’s limit is 50% above the floor; A and B have more headroom. Temporary income dips can still make the floor apply, and other speeds need separate balance validation.

For ratings A–C, `creditLimit = max(eraFloor × CostMultiplier / 100, max(0, netGPT) × ratingMultiple)`. The scaled floor is not rounded, and the GPT multipliers remain unchanged across game speeds. Existing outstanding principal counts against this aggregate limit; bank cash, liquidity, lending freezes and all usual borrowing restrictions still apply. Players may borrow less than the ceiling; the floor is not a required minimum loan amount. Production collection and the rating reducer remain unimplemented.

Requires Python 3.11+ with `lupa` for offline checks. The checker explicitly uses Lua 5.1. No ModBuddy is required.

```powershell
python tools/sync_dev.py
python tools/generate_spike_sql.py
python tools/check_all.py
python tests/offline/run_tests.py
```

The checker verifies Lua syntax, manifests, localization, source-backed API calls, numeric constants and generated-file parity. It validates experimental SQL in an in-memory copy of the installed game's debug database. It never modifies the live database. The clone skips the game's hash-maintenance triggers because ordinary SQLite lacks `Make_Hash`; game-generated hashes and engine behavior require an in-game check.

Install the dev mod only after confirming the actual Mods folder. Windows may redirect Documents. The installer requires an explicit existing folder and refuses to run while Civilization VI is open. Start with a dry run:

```powershell
./tools/install.ps1 -ModsPath 'C:\your\confirmed\Mods' -DevOnly -DryRun
./tools/install.ps1 -ModsPath 'C:\your\confirmed\Mods' -DevOnly
```

Use a new Gathering Storm single-player game at Standard speed with at least three AIs and only the dev mod enabled. Open **Bank** on the launch bar or press **Ctrl+Shift+D**, then click **Run All Spikes**. The fallback **World Bank Dev** button appears if the launch bar cannot attach. Wait until S3 says its queries are complete, stopped or timed out before ending the first turn. Nonbinding AI inspections may display diplomacy views; the tool never accepts a trade. It preserves existing negotiations and logs missing or unsafe samples as pending. The city probe selects its city after one turn; the second turn removes its experimental effects. Quit to desktop before reading Lua.log, because the game buffers it.

```powershell
python tools/summarize_log.py 'C:\path\to\Lua.log'
python tools/package.py --output dist/World_Bank_Loans_Dev_0.0.0.3.zip
```

Packages contain the modinfo and exactly its listed files. Generated dev copies of the config and formulas must match their single sources in `WBL/Scripts` byte for byte.

The dev panel's **Reload Config** logs include status and version after re-including the config in single player. Reading edits from disk during a running game remains unverified. The first session also leaves AI deal rates, Congress disaster eligibility, reversible penalties, perk writers and long-run balance pending where evidence is incomplete. The production bank UI and synced finance requests follow those checks.

## Update log

### Unreleased

- Feature: development panel and logged API spikes.
- Feature: pure formula tests and source validation tools.
- Feature: explicit-path installer and exact-file dev package.
- Feature: nonbinding AI deal inspections and more source-backed engine probes.
- Change: planned disaster recovery pricing replaces unused payment pause settings.
- Change: early repayment discounts future interest only and gives no rating upgrade.
- Balance: selected milestone forgiveness is 10% / 15% / 20% by development tier.
- Balance: revised credit limits and shared world-era floors scaled by game speed.
- Balance: lower fixed era floors run from 100 gold in Ancient to 1,000 in Future, keeping income-based credit useful at the stated planning incomes.
- Fix: recovery from D requires all existing bank debt to be settled, without another loan.
