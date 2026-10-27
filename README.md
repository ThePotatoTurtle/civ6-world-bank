# World Bank Loans

World Bank Loans is a Civilization VI: Gathering Storm mod in development. The planned bank lends gold to major civilizations and accepts deposits for influence and better borrowing terms.

The current build contains research tools and tested pure formulas. It does not implement a playable bank. The standalone dev mod probes engine APIs in a new single-player game and records PASS, FAIL and PENDING results. Multiplayer is untested; the dev tools refuse multiplayer and hotseat requests.

Planned disaster recovery loans replace payment pauses. The dev tools test pricing and Congress data; actual qualification, per-disaster claims and lending remain unimplemented. The approved base value ratios are 1.10 for Developed, 0.90 for Developing and 0.80 for Underdeveloped, with the same tier terms and grace, normal adjustments and 0.80 floor, and a 15 Standard turn claim window. Principal is capped by remaining normal credit and available bank cash.

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
