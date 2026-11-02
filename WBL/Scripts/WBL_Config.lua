-- Canonical defaults. Calibration and unspecified production values are documented in TUNING.md.
-- The standalone dev mod receives an identical generated copy of this file.
WBL_CONFIG = {
  version = "0.0.0", -- Production semantic version; no playable release exists yet.
  devVersion = "0.0.0.4", -- Dev version targeting the production version above.
  growth = {
    model = "production_median_log_ema_v1", -- Matched living-major production log growth; no Gold input.
    standardDefault = 0.01, -- Fallback growth fraction per Standard turn; Leon 2026-10-28.
    standardMin = 0, -- Minimum published growth fraction per Standard turn.
    standardMax = 0.05, -- Maximum published growth fraction per Standard turn.
    windowTurns = 20, -- Matched endpoint window in Standard turns; rounded only for game-turn history.
    emaHalfLifeTurns = 5, -- Continuous EMA half-life in Standard turns; never duration-rounded.
    minimumPairs = 3, -- Minimum matched pairs for ordinary worlds, subject to coverageFraction.
    coverageFraction = 0.50, -- Required fraction of current living majors with positive endpoint pairs.
    smallWorldPlayers = 2, -- A world with exactly this many majors requires every one to match.
  },
  tiers = {
    developedBoundary = 0.90, -- Development ratio at/above Developed.
    underdevelopedBoundary = 0.75, -- Development ratio below Underdeveloped.
    smoothingK = 10, -- Tech-plus-civic smoothing count.
    hysteresisMargin = 0.02, -- Ratio distance beyond a boundary.
    hysteresisTurns = 3, -- Consecutive boundary observations in Standard turns.
    blendCapEnabled = true, -- Rich borrowers cannot be Underdeveloped.
    difficultyFactor = {
      DIFFICULTY_SETTLER = 1.00, -- Reference-score divisor; provisional until S12.
      DIFFICULTY_CHIEFTAIN = 1.00, -- Reference-score divisor; provisional until S12.
      DIFFICULTY_WARLORD = 1.00, -- Reference-score divisor; provisional until S12.
      DIFFICULTY_PRINCE = 1.00, -- Reference-score divisor; spec baseline, pending S12.
      DIFFICULTY_KING = 1.05, -- Reference-score divisor; provisional seed, not measured.
      DIFFICULTY_EMPEROR = 1.10, -- Reference-score divisor; provisional seed, not measured.
      DIFFICULTY_IMMORTAL = 1.175, -- Reference-score divisor; provisional seed, not measured.
      DIFFICULTY_DEITY = 1.25, -- Reference-score divisor; approximate spec seed, pending S12.
    },
    DEVELOPED = {
      valueRatio = 1.10, -- Ordinary repayment present value per gold borrowed; Leon 2026-10-28.
      terms = {10, 20, 30}, -- Payment durations in Standard turns.
      graceTurns = 0, -- Grace duration in Standard turns.
      milestoneForgiveness = 0.10, -- Fraction of remaining principal forgiven for a selected milestone.
      penaltyStrength = 1.25, -- Fraction of base default penalties, excluding garnishing.
    },
    DEVELOPING = {
      valueRatio = 1.00, -- Ordinary repayment present value per gold borrowed; Leon 2026-10-28.
      terms = {10, 20, 30}, -- Payment durations in Standard turns.
      graceTurns = 3, -- Grace duration in Standard turns.
      milestoneForgiveness = 0.15, -- Fraction of remaining principal forgiven for a selected milestone.
      penaltyStrength = 1.00, -- Fraction of base default penalties, excluding garnishing.
    },
    UNDERDEVELOPED = {
      valueRatio = 0.90, -- Ordinary repayment present value per gold borrowed; Leon 2026-10-28.
      terms = {10, 20, 30}, -- Payment durations in Standard turns.
      graceTurns = 6, -- Grace duration in Standard turns.
      milestoneForgiveness = 0.20, -- Fraction of remaining principal forgiven for a selected milestone.
      penaltyStrength = 0.75, -- Fraction of base default penalties, excluding garnishing.
    },
  },
  credit = {
    A = {limitMultiple = 15, valueAdjustment = -0.05}, -- GPT multiple and V fraction.
    B = {limitMultiple = 10, valueAdjustment = 0}, -- GPT multiple and V fraction.
    C = {limitMultiple = 7.5, valueAdjustment = 0.10}, -- GPT multiple and V fraction.
    D = {limitMultiple = 0, valueAdjustment = 0}, -- No new borrowing; restore C after all current bank debt is settled.
    scarValueAdjustment = 0.10, -- V fraction added after leaving default.
    scarTurns = 30, -- Credit scar duration in Standard turns.
    missedPaymentsToDowngrade = 3, -- Missed installments on one loan.
    earlyRepayInterestFraction = 0.10, -- Lock at origination; fraction of unmatured interest due on early repayment.
    eraMinimums = {
      ERA_ANCIENT = 100, -- Base credit floor in Standard gold; scale by game-speed CostMultiplier / 100.
      ERA_CLASSICAL = 200, -- Base credit floor in Standard gold.
      ERA_MEDIEVAL = 300, -- Base credit floor in Standard gold.
      ERA_RENAISSANCE = 500, -- Base credit floor in Standard gold.
      ERA_INDUSTRIAL = 800, -- Base credit floor in Standard gold.
      ERA_MODERN = 1250, -- Base credit floor in Standard gold.
      ERA_ATOMIC = 1950, -- Base credit floor in Standard gold.
      ERA_INFORMATION = 3000, -- Base credit floor in Standard gold.
      ERA_FUTURE = 4500, -- Base credit floor in Standard gold.
    },
  },
  liquidity = {
    normalThreshold = 1.00, -- Pool divided by base reserve cap.
    tightThreshold = 0.50, -- Pool divided by base reserve cap.
    strainedThreshold = 0.20, -- Pool divided by base reserve cap.
    normalValueAdjustment = 0, -- Non-investor V increase.
    tightValueAdjustment = 0.05, -- Non-investor V increase.
    strainedValueAdjustment = 0.10, -- Non-investor V increase.
    normalLimitMultiplier = 1.00, -- Non-investor credit limit fraction.
    tightLimitMultiplier = 0.75, -- Non-investor credit limit fraction at 50-99% liquidity.
    strainedLimitMultiplier = 0.50, -- Non-investor credit limit fraction.
    maximumDepositTierImprovement = 1, -- Maximum deposit-driven liquidity tier improvement.
    maximumRivalBenefitFraction = 0.50, -- Maximum rival V benefit / actual investor V benefit; Leon 2026-10-26.
    baseReserve = { -- Decision 33 (Leon 2026-11-02).
      enabled = true, -- Formula switch; false leaves the reserve unconfigured (bank suspended).
      capFloorMultiple = 3, -- Cap in U (scaled world-era credit floor) per living major.
      refillFloorMultiple = 0.15, -- Refill in U per living major per turn, clamped at cap.
      openingCashFraction = 1, -- Opening bank cash as a fraction of the first cap.
      fixedCap = false, -- Test/dev injection: a nonnegative gold cap replaces the formula.
      fixedRefill = false, -- Test/dev injection: nonnegative gold per turn replaces the formula.
    },
  },
  floors = {
    valueRatio = 0.80, -- Minimum V after all loan adjustments.
    nominalRate = 0, -- Minimum total nominal interest fraction.
  },
  arrears = {
    simpleRate = 0.05, -- Fee fraction per Standard turn on unpaid base, never on fees; per game turn = this / turn scale (decision 34).
    firstFeeDelayTurns = 1, -- Game turns before a new lot's first fee (means "next turn"; not speed-scaled); provisional (Claude default).
    lotOrder = "OLDEST_DUE_TURN_THEN_LOAN_ID", -- Payment order across lots; provisional (Claude default).
    componentOrder = {"FEES", "OVERDUE_INTEREST", "OVERDUE_PRINCIPAL"}, -- Order within a lot; provisional (Claude default).
    missPerPartlyUnpaidInstallment = 1, -- Misses counted per partly unpaid installment; provisional (Claude default).
    missDowngradeFloor = "C", -- Miss downgrades stop at this rating; provisional (Claude default).
    warningTurns = 7, -- Consecutive arrears Standard turns before warning; WBL_MATH.ArrearsClocks scales (decision 34).
    defaultTurns = 10, -- Consecutive arrears Standard turns before default; scaled like warningTurns (decision 34).
    stage2StartTurn = 11, -- Standard default-turn index at which stage 2 begins (stage 1 = this - 1 Standard turns, scaled; decision 34).
  },
  penalties = {
    stage1 = {
      garnishPercent = 50, -- Fixed across tiers; percent of positive net GPT, capped at treasury and payable debt; the only collection while in default (decision 34).
      amenities = -1, -- Amenities per city.
      productionPercent = -5, -- Percent production per city.
      sciencePercent = -5, -- Percent science per player.
      loyalty = 0, -- Loyalty per city per turn.
      favor = 0, -- Favor per turn, capped at available Favor.
      tradePercent = -10, -- Percent own international trade route yields.
    },
    stage2 = {
      garnishPercent = 75, -- Fixed across tiers; percent of positive net GPT, capped at treasury and payable debt; the only collection while in default (decision 34).
      amenities = -3, -- Amenities per city.
      productionPercent = -15, -- Percent production per city.
      sciencePercent = -15, -- Percent science per player.
      loyalty = -5, -- Loyalty per city per turn.
      favor = -5, -- Favor per turn, capped at available Favor.
      tradePercent = -25, -- Percent own international trade route yields.
    },
  },
  relief = {
    restructureFavorCost = 50, -- Favor, or all available Favor if less.
    restructureTermTurns = 30, -- Replacement loan payment duration in Standard turns.
    debtReliefFraction = 0.50, -- Fraction of eligible debt and arrears forgiven.
    debtReliefTurns = 15, -- Milestone deadline in Standard turns.
    maxRestructuresPerLineage = 1, -- Uses per original loan lineage.
    maxDebtReliefPerGame = 1, -- Uses per borrower per game.
    restructureGraceTurns = 0, -- Replacement loan grace in Standard turns; decision 31.
    restructureAppliesRatingAndScar = true, -- Replacement V includes the one-grade drop and any scar. Decision 33.
    debtReliefIncludesFutureInterest = true, -- Relief scales not-yet-due interest too; provisional (Claude default).
  },
  disasterRecovery = {
    valueRatio = {
      DEVELOPED = 1.10, -- Recovery repayment present value per gold borrowed; Leon 2026-10-27.
      DEVELOPING = 0.90, -- Recovery repayment present value per gold borrowed; Leon 2026-10-27.
      UNDERDEVELOPED = 0.80, -- Recovery repayment present value per gold borrowed; Leon 2026-10-27.
    },
    claimWindowTurns = 15, -- Claim duration in Standard turns from the authoritative qualifying event turn; S5 unverified.
  },
  grants = {
    gptMultiple = 3, -- Grant gold divided by current net GPT, before era minimum.
    eraMinimums = false, -- Per-era table form unused; eraMinimumFloorMultiple applies.
    eraMinimumFloorMultiple = 0.5, -- Grant minimum in U; grant = max(gptMultiple x net GPT, this x U). Decision 33.
    maxPerEra = 1, -- Development grant claims per borrower per era.
    infrastructureLimitMultiplier = 1.50, -- Multiple of normal credit limit.
  },
  -- Investor values. Decisions 29-32 apply eligible capital through investors.eligibility.
  investors = {
    depositTerms = {20, 30}, -- Deposit durations in Standard turns.
    depositReturns = {0.05, 0.08}, -- Total return fractions for matching terms; S3 placeholders.
    earlyWithdrawalFraction = 0.90, -- Principal returned on early withdrawal.
    favorShareStep = 0.10, -- Share fraction per base Favor unit.
    favorPerShareStep = 1, -- Favor per share step per turn.
    favorCap = 5, -- Base shareholder Favor per turn.
    aidGoldStep = 100, -- Other-civ actual loan disbursement gold per shared Favor unit.
    aidFavorCap = 3, -- Aid-credit Favor per investor per turn.
    presidentShareThreshold = 0.25, -- Minimum share fraction to be President.
    presidentFavor = 2, -- Extra Favor per President turn.
    presidentMerchantPoints = 2, -- Great Merchant points per President turn; S9 gated.
    presidentEnvoyTurns = 20, -- Standard President turns per envoy; S9 gated.
    presidentEraScore = 1, -- Era Score per qualifying era.
    presidentEraTurns = 10, -- Standard President turns required in that era.
    freezeShareThreshold = 0.40, -- Combined qualifying allied share fraction.
    presidentFreezeTargets = 1, -- Concurrent President solo-freeze targets; provisional (Claude default).
    eligibility = { -- Decision 29 capital ladder; U = scaled world-era credit floor.
      entryFloorMultiple = 0.5, -- Minimum E in U for any investor reward.
      favorStepFloorMultiple = 0.5, -- E in U per base Favor point, capped by favorCap.
      preferredHalfFloorMultiple = 1, -- Minimum post-loan E in U for the half discount.
      preferredFullFloorMultiple = 2, -- Minimum post-loan E in U for the full discount.
      preferredHalfValueAdjustment = -0.05, -- Locked own-loan V fraction at the half step.
      preferredFullValueAdjustment = -0.10, -- Locked own-loan V fraction at the full step.
      liquidityExemptionFloorMultiple = 1, -- Minimum post-loan E in U for liquidity V exemption.
      creditExtensionLimitFraction = 0.5, -- Extension = min(this x normal limit, E).
      presidentFloorMultiple = 2, -- Minimum E in U to be President.
      presidentConfirmTurns = 3, -- Consecutive Standard turns at the minimum; loss immediate.
      coalitionMemberFloorMultiple = 0.5, -- Minimum E in U per freeze coalition member.
      coalitionFloorMultiple = 3, -- Minimum combined coalition E in U.
      aidCapPerFloor = 1, -- Aid Favor cap per U of E, capped by aidFavorCap.
      subsidyMemoryTurns = 30, -- Standard turns forgiveness, relief and grants count as exposure.
      eraChangeGraceTurns = 10, -- Standard turns the previous era's U stays in force.
    },
  },
  ai = {
    lowTreasuryGptMultiple = 3, -- Borrow only below this multiple of positive net GPT.
    loanGptMultiple = 5, -- Requested principal divided by positive net GPT.
    maxLoans = 2, -- Maximum concurrent AI loans.
    termStandardTurns = 20, -- AI loan term in Standard turns; provisional (Claude default), middle term.
  },
  state = {
    schema = 1, -- Persisted state schema version.
    propertyKey = "WBL_STATE", -- Game property key holding the encoded state.
    ledgerRetentionTurns = 10, -- Game turns of individual ledger movements kept; totals kept always. Provisional (Claude default).
    stringCodecWhenUnverified = false, -- WBL_State: when features.statePersistenceVerified is false, true stores the state as a deterministic string instead of a table. Off by default (decision 33 attempts the table form live).
    checksumModulus = 4294967291, -- WBL_State.Checksum: largest prime below 2^32; keeps hash arithmetic exact in double precision.
    checksumMultipliers = {31, 131}, -- WBL_State.Checksum: two independent polynomial hash multipliers (small primes).
  },
  -- WP3 reducer constants (WBL_Reducer).
  reducer = {
    startingRating = "B", -- Spec 2.7: credit rating of a newly observed major.
    unknownDifficultyFallback = "DIFFICULTY_PRINCE", -- tiers.difficultyFactor row for an unresolved difficulty type; provisional (Claude default).
    percentUnit = 100, -- Percent per whole: garnish fraction = garnishPercent / this.
    restructureMinimumPriceRating = "C", -- A D-rated restructure is priced no cheaper than this rating; orchestrator default.
    recoveredRating = "C", -- Decision 19: rating D returns to this once all arrears and bank debt are settled.
  },
  -- WP4 engine adapter constants (WBL_Snapshot / WBL_Effects): engine identities, not tuning.
  adapters = {
    costMultiplierPercent = 100, -- GameSpeeds.CostMultiplier unit (percent); speedScale = CostMultiplier / this.
    excludedPlayerIDs = {62, 63}, -- Free Cities (62) and Barbarians (63) player IDs; never bank majors (playbook).
    notificationFallbackType = "USER_DEFINED_1", -- NotificationTypes member used when NOTIFICATION_WBL_* is missing.
  },
  -- WP5 gameplay entry (WBL_Bank): logging switches only, no tuning.
  bank = {
    phaseLogging = true, -- Print one "[WBL PHASE]" line per reducer phase each turn; on for the early dev build.
  },
  spikes = {
    goldDelta = 10, -- Gold change in S1 fixture.
    goldSafetyReserve = 0, -- Minimum treasury after S1 debit.
    aiGrant = 300, -- Gold granted in S8 candidate fixture.
    comparisonGold = {100, 300, 1000}, -- Gold amounts for S3 proposals.
    dealTurns = 30, -- Deal duration in S3 proposals; actual engine duration must be logged.
    dealGPTMin = 1, -- Minimum proposed GPT in S3 search.
    dealGPTMax = 100, -- Maximum proposed GPT in S3 search.
    dealQueryTimeoutSeconds = 8, -- Seconds allowed for one nonbinding S3 inspection response.
    dealRunTimeoutSeconds = 120, -- Seconds allowed for the complete serialized S3 inspection matrix.
    minAttitudeSamples = 3, -- Requested attitude samples; report incomplete if absent.
    favorDelta = 1, -- Favor change in S4 fixture.
    eraScoreDelta = 1, -- Era Score change in S4 fixture.
    merchantPointsDelta = 1, -- Great Merchant points change in S9 fixture.
    envoyDelta = 1, -- Envoy change in S9 fixture.
    observationTurns = 2, -- Early S8 observation checkpoint; not sufficient to prove causation.
    populationDelta = 1, -- Positive population increase in the disposable S6 fixture.
    milestoneObservationTurns = 1, -- Synced boundary observations before S6 fixture recheck.
    logEveryTurns = 1, -- Growth log interval in turns.
    difficultyLogEveryTurns = 10, -- S12 score log interval in turns.
    standardAutoplayTurns = 100, -- Minimum Standard S11 observation turns.
    onlineAutoplayTurns = 40, -- Proposed shorter Online S11 observation turns.
    epsilon = 0.000001, -- Numerical comparison tolerance for spike observations.
    -- WP9a telemetry spikes.
    treasuryTimingTurns = 3, -- S1: turns of per-hook treasury sampling after Run All Spikes (turns).
    -- WP9b S13 bank dry run.
    dryRunTurns = 3, -- S13: turns after the Bank Dry Run button turn that also run the in-memory bank pipeline (turns).
  },
  -- Decision 33: attempt* flags gate live calls (true = call the pcall'd candidate API, log and
  -- record failure). *Verified flags record evidence status only and never gate an attempt.
  features = {
    attemptAIBorrowing = true, -- Decision 2 rule-based AI loans; human-only fallback if S8 fails.
    attemptFavorWrite = true, -- Investor/President Favor grants and restructure/penalty Favor debits.
    attemptEraScoreWrite = true, -- President Era Score grant.
    attemptEnvoyWrite = true, -- President envoy grant.
    attemptMerchantPoints = true, -- President Great Merchant points.
    attemptPenaltyEffects = true, -- Non-garnish default penalty modifiers.
    recordFailedEffects = true, -- Failed attempted rewards are kept in players[i].unpaid and shown.
    aiBorrowingVerified = false, -- S8 evidence status.
    disasterRecoveryVerified = false, -- S5 Congress qualification and disaster identity remain unverified.
    merchantPointsVerified = false, -- S9 evidence status.
    envoyVerified = false, -- Legacy S9 evidence flag; superseded by envoyWriteVerified.
    goldAdapterVerified = false, -- S1 evidence status; gold is core, checked by the startup probe.
    penaltyEffectsVerified = false, -- S4 evidence status.
    favorWriteVerified = false, -- S4 evidence status.
    eraScoreWriteVerified = false, -- S4 evidence status.
    envoyWriteVerified = false, -- S9 evidence status.
    districtMilestoneVerified = false, -- S6 gate: district targets offered only when true.
    notificationsVerified = false, -- Evidence status; sending is pcall'd and logged regardless.
    statePersistenceVerified = false, -- S10 gate: false selects the string codec fallback.
    recoveryPredicateVerified = false, -- S5 gate: recovery entitlements never registered while false (decisions 15-16).
  },
  precision = {
    shareStepTolerance = 0.000000000001, -- Dimensionless machine-boundary tolerance, not a gameplay benefit.
    balanceTolerance = 0.0001, -- Gold/Favor difference treated as equal in expectedBefore checks; provisional (Claude default).
  },
}
