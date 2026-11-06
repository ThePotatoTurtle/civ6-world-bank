# World Bank Loans

World Bank Loans is a Civilization VI: Gathering Storm mod. It adds a neutral World Bank. Major civs can borrow gold and pay it back over time, or deposit gold to earn a return and some political perks.

**This is an early development build. It has not been run in game yet.** Expect bugs and use a throwaway game. It's built for single player first. Multiplayer is untested. Everything below describes how the mod is meant to work, not something I've seen work.

## Install

There's no Workshop release yet.

1. Copy the `WBL` folder into your Civilization VI `Mods` folder. Windows may redirect Documents, so check where your Mods folder really is.
2. Quit the game first, then start it and enable **World Bank Loans** in Additional Content.
3. Start a new Gathering Storm game.

Don't enable World Bank Loans and `WBL_Dev` at the same time. They share script names and game properties and will clash. `WBL_Dev` is the research mod I use to test engine calls. Most players don't need it.

## Using it

Open the bank with **B** (when no settler is selected, since B also founds a city) or the World Bank button on the launch bar. The panel has four tabs: Borrow, My loans, Invest and Bank.

- **Borrow:** loans, grants and milestone loans, with the terms shown before you accept.
- **My loans:** repayment, early repayment, restructuring and debt relief.
- **Invest:** deposits, your eligible capital, shares and the President.
- **Bank:** cash, liquidity, ratings and freezes.

AI civs borrow too, using simple rules.

## Loans

Your development tier sets your terms. It compares your techs and civics with a smoothed median of the other civs. Loan terms lock when you take the loan.

- Ordinary loans use base value ratios of 1.10 for Developed, 1.00 for Developing and 0.90 for Underdeveloped civs. The value ratio is what the repayments are worth per gold you borrow.
- All three tiers can pick 10, 20 or 30 Standard-turn terms. Grace periods are 0, 3 and 6 turns.
- Credit rating, bank liquidity, a credit scar and investor status adjust the price. The value ratio never drops below 0.80.
- At 50 to 99% bank liquidity, the non-investor credit-limit multiplier is 0.75.
- Developing civs can take infrastructure loans, and Underdeveloped civs can claim a development grant once per era. Both need a milestone.
- Milestones are goals you pick, like a district, city population or a tech. Finishing one early forgives part of the remaining principal: 10% for Developed, 15% for Developing and 20% for Underdeveloped. Goals you've already completed don't count.
- Early repayment costs all unpaid principal, overdue interest and arrears fees, plus 10% of future interest. Early closure does not improve your credit rating.

Loan pricing uses each living major civilization's production growth over 20 Standard turns, takes the median, and smooths it with a 5-Standard-turn half-life before applying the bounds. The fallback is 1.00% per Standard turn, with a 0% minimum and 5% maximum. On Online speed, those rates are 2.01%, 0% and 10.25%. Existing loans keep their original rate.

### Credit limits

Credit limits are 15x net GPT for A, 10x for B and 7.5x for C, with a shared world-era minimum scaled by game speed. D allows no new loans. New civs start at B. Three missed payments on one loan drop the rating one grade, and default sets D.

| World era | Minimum credit limit (Standard gold) | Minimum credit limit (Online gold) |
|---|---:|---:|
| Ancient | 100 | 50 |
| Classical | 200 | 100 |
| Medieval | 300 | 150 |
| Renaissance | 500 | 250 |
| Industrial | 800 | 400 |
| Modern | 1,250 | 625 |
| Atomic | 1,950 | 975 |
| Information | 3,000 | 1,500 |
| Future | 4,500 | 2,250 |

For ratings A to C, `creditLimit = max(eraFloor x CostMultiplier / 100, max(0, netGPT) x ratingMultiple)`. The scaled floor isn't rounded and the GPT multipliers stay the same across game speeds. Outstanding principal counts against the limit. Bank cash, liquidity, lending freezes and the usual borrowing restrictions still apply. You can borrow less than the limit. The floor isn't a minimum loan.

### Disaster recovery loans

These are planned and **currently dormant**. They replace payment pauses. The mod can't yet tell for sure which disasters qualify for a World Congress aid request, so it won't guess. They stay off until that check is verified in game. The design: one optional loan per hit civ, base value ratios of 1.10 / 0.90 / 0.80 for Developed / Developing / Underdeveloped, a 15 Standard-turn claim window, capped by your remaining normal credit and the bank's cash.

## Missed payments and default

- Payments come out of your gold at turn start, oldest loan first. If you're short, you pay what you have and the rest becomes arrears. Gold never goes below 0.
- Arrears grow by a 5% fee per Standard turn, simple, never on fees. The fee and all the clocks below scale with game speed.
- Any arrears block new loans and new deposits.
- After 7 Standard turns of arrears you get a warning. After 10 you're in default, your rating drops to D and unpaid milestone forgiveness is cancelled. Stage 2 starts on default turn 11.
- Before default, the bank takes what it's owed from your gold. **While in default, it stops sweeping your treasury.** Instead each turn it garnishes a share of your positive net GPT (50% in stage 1, 75% in stage 2), arrears first, then scheduled payments. You keep the rest and your existing treasury.
- Default ends when all arrears across all loans are cleared. Rating D returns to C once all arrears and all bank debt are settled. No new loan is needed.
- Restructuring (once per loan) rolls arrears and remaining principal into a new 30 Standard-turn loan with no grace. It costs 50 Favor, or all you have, and drops your rating one grade. A restructured loan gets no investor discount.
- Debt relief (Underdeveloped only, once per game): finish a milestone within 15 Standard turns to forgive 50% of your debt and arrears. Garnishing continues meanwhile, but the other penalties pause.

### Default penalties

Garnishing is the same for every tier. The other penalties are scaled by tier (1.25 for Developed, 1.00 for Developing, 0.75 for Underdeveloped). Nothing destroys cities or units, and everything lifts when the arrears are cleared.

| Penalty | Developed stage 1 / 2 | Developing stage 1 / 2 | Underdeveloped stage 1 / 2 |
|---|---|---|---|
| Garnishing, share of positive GPT | 50% / 75% | 50% / 75% | 50% / 75% |
| Amenities per city | −1 / −3 | −1 / −3 | −1 / −2 |
| Production per city | −6% / −18% | −5% / −15% | −3% / −11% |
| Science | −6% / −18% | −5% / −15% | −3% / −11% |
| Loyalty per city | 0 / −6 | 0 / −5 | 0 / −3 |
| Diplomatic Favor per turn | 0 / −6 | 0 / −5 | 0 / −3 |
| Own international trade route yields | −12% / −31% | −10% / −25% | −7% / −18% |

## Investing

- Any major civ can deposit gold for 20 or 30 Standard turns, except while in arrears or default.
- Only **eligible capital** counts: your active deposits minus what you owe the bank. Recent forgiveness, debt relief and grants also count against you for 30 Standard turns. Rewards, President eligibility and your cash return all scale with it.
- At maturity you get your full principal back plus the return earned on the eligible part. If you have arrears, the payout clears those first. Early withdrawal gives back 90% of the deposit and no return, and also pays arrears first.
- Deposit returns (5% for 20 turns, 8% for 30) are placeholders and not tuned.
- Perks: Diplomatic Favor from your share, a cheaper own-loan price and a credit extension, shared Favor when the bank lends to others, and Era Score. Each one needs enough eligible capital, not just a big share.
- The **President** is the largest eligible depositor with at least a 25% share and enough capital held for 3 turns. They get extra Favor, Great Merchant points and envoys, can see every civ's debts, and can freeze one enemy at war.
- Allied investors at war with a civ, holding at least 40% of the eligible share together and enough eligible capital, can freeze new loans and grants to it for as long as that war lasts. There is no separate vote.

## What's unverified

Some effects are attempted in game but I haven't confirmed the game accepts them. If one fails, the mod logs it and shows the reward as unpaid.

- Diplomatic Favor changes, Era Score, envoys and Great Merchant points.
- Default penalties other than garnishing (amenities, production, science, loyalty and trade yields).
- AI borrowing.
- Notifications, saving and loading bank state, and whether district milestones can be detected.
- Disaster recovery loans (dormant, see above).
- The UI layout, and everything in multiplayer.

Full rules are in the spec and decision log, and every tunable number is in [WBL_Config.lua](WBL/Scripts/WBL_Config.lua).

## Update log

### Unreleased

- New: production mod `WBL` with a bank panel (B or launch bar), loans, repayment, arrears, default, restructuring, debt relief, milestones, grants, deposits, the President, lending freezes and AI borrowing. Not run in game yet.
- New: dev mod now exercises the same adapters the production mod uses, plus a bank dry run.
- New: packaging and install tools handle both `WBL` and `WBL_Dev`.
- Change: in default, the bank garnishes positive GPT instead of sweeping the treasury.
- Change: the arrears fee is 5% per Standard turn, and the warning, default and stage 2 clocks scale with game speed.
- Change: deposit rewards, returns and President eligibility depend on eligible capital. No deposits while in arrears or default.
- Change: payouts from maturing and early-withdrawn deposits go to arrears first.
- Change: restructured loans get a fresh quote with the rating drop and any scar, and no investor pricing.
- Change: the bank's cash reserve and development grants scale with the world-era credit floor.
- Change: Favor, Era Score, envoys, Great Merchant points and non-garnish penalties are attempted live and logged. Disaster recovery loans stay dormant until the qualifying-disaster check is verified.
- Change: planned disaster recovery pricing replaces unused payment pause settings.
- Change: early repayment discounts future interest only and gives no rating upgrade.
- Change: production growth drives loan pricing through a matched-major median and smoothing, defaulting to 1.00% per Standard turn.
- Change: all tiers can choose 10, 20 or 30 Standard-turn loans. Milestone forgiveness is 10% / 15% / 20% by tier.
- Change: revised ordinary loan pricing, liquidity, default penalties, credit limits and world-era floors.
- Fix: recovery from D requires all existing bank debt to be settled, without another loan.
