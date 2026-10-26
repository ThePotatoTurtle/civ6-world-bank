-- Canonical defaults. Calibration and unspecified production values are documented in TUNING.md.
-- The standalone dev mod receives an identical generated copy of this file.
WBL_CONFIG = {
  version = "0.0.0", -- Production semantic version; no playable release exists yet.
  devVersion = "0.0.0.2", -- Dev version targeting the production version above.
  growth = {
    standardDefault = 0.035, -- Growth fraction per Standard turn; proposed until S11.
    standardMin = 0.005, -- Minimum growth fraction per Standard turn; proposed until S11.
    standardMax = 0.06, -- Maximum growth fraction per Standard turn; proposed until S11.
    windowTurns = 20, -- Rolling window in Standard turns.
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
      valueRatio = 1.15, -- Repayment present value per gold borrowed; proposed S11.
      terms = {20, 30}, -- Payment durations in Standard turns.
      graceTurns = 0, -- Grace duration in Standard turns.
      milestoneForgiveness = 0.15, -- Fraction of remaining principal forgiven.
      penaltyStrength = 1.00, -- Fraction of base default penalty.
    },
    DEVELOPING = {
      valueRatio = 1.00, -- Repayment present value per gold borrowed; proposed S11.
      terms = {20, 30}, -- Payment durations in Standard turns.
      graceTurns = 3, -- Grace duration in Standard turns.
      milestoneForgiveness = 0.25, -- Fraction of remaining principal forgiven.
      penaltyStrength = 0.75, -- Fraction of base default penalty.
    },
    UNDERDEVELOPED = {
      valueRatio = 0.85, -- Repayment present value per gold borrowed; proposed S11.
      terms = {20, 30, 40}, -- Payment durations in Standard turns.
      graceTurns = 6, -- Grace duration in Standard turns.
      milestoneForgiveness = 0.35, -- Fraction of remaining principal forgiven.
      penaltyStrength = 0.50, -- Fraction of base default penalty.
    },
  },
  credit = {
    A = {limitMultiple = 12, valueAdjustment = -0.05}, -- GPT multiple and V fraction.
    B = {limitMultiple = 10, valueAdjustment = 0}, -- GPT multiple and V fraction.
    C = {limitMultiple = 6, valueAdjustment = 0.10}, -- GPT multiple and V fraction.
    D = {limitMultiple = 0, valueAdjustment = 0}, -- No new borrowing; restore C when all arrears clear.
    scarValueAdjustment = 0.10, -- V fraction added after leaving default.
    scarTurns = 30, -- Credit scar duration in Standard turns.
    missedPaymentsToDowngrade = 3, -- Missed installments on one loan.
    earlyRepayInterestFraction = 0.10, -- Fraction of remaining interest due on early repayment.
    eraMinimums = false, -- UNSPECIFIED: production credit era minimums await tuning.
  },
  liquidity = {
    normalThreshold = 1.00, -- Pool divided by base reserve cap.
    tightThreshold = 0.50, -- Pool divided by base reserve cap.
    strainedThreshold = 0.20, -- Pool divided by base reserve cap.
    normalValueAdjustment = 0, -- Non-investor V increase.
    tightValueAdjustment = 0.05, -- Non-investor V increase.
    strainedValueAdjustment = 0.10, -- Non-investor V increase.
    normalLimitMultiplier = 1.00, -- Non-investor credit limit fraction.
    tightLimitMultiplier = 0.80, -- Non-investor credit limit fraction.
    strainedLimitMultiplier = 0.50, -- Non-investor credit limit fraction.
    maximumDepositTierImprovement = 1, -- Maximum deposit-driven liquidity tier improvement.
    maximumRivalBenefitFraction = 0.50, -- Maximum rival V benefit / actual investor V benefit; Leon 2026-10-26.
    baseReserve = false, -- UNSPECIFIED: era/major-count refill and cap await tuning.
  },
  floors = {
    valueRatio = 0.80, -- Minimum V after all loan adjustments.
    nominalRate = 0, -- Minimum total nominal interest fraction.
  },
  arrears = {
    simpleRate = 0.05, -- Fee fraction per turn on unpaid base, never on fees.
    warningTurns = 7, -- Consecutive arrears turns before warning.
    defaultTurns = 10, -- Consecutive arrears turns before default.
    stage2StartTurn = 11, -- Default-turn index at which stage 2 begins.
  },
  penalties = {
    stage1 = {
      garnishPercent = 50, -- Percent of positive net GPT, capped at treasury and debt.
      amenities = -1, -- Amenities per city.
      productionPercent = -5, -- Percent production per city.
      sciencePercent = -5, -- Percent science per player.
      loyalty = 0, -- Loyalty per city per turn.
      favor = -1, -- Favor per turn, capped at available Favor.
      tradePercent = 0, -- Percent own international trade route yields.
    },
    stage2 = {
      garnishPercent = 75, -- Percent of positive net GPT, capped at treasury and debt.
      amenities = -2, -- Amenities per city.
      productionPercent = -10, -- Percent production per city.
      sciencePercent = -10, -- Percent science per player.
      loyalty = -2, -- Loyalty per city per turn.
      favor = -2, -- Favor per turn, capped at available Favor.
      tradePercent = -25, -- Percent own international trade route yields.
    },
  },
  relief = {
    restructureFavorCost = 50, -- Favor, or all available Favor if less.
    restructureTermTurns = 30, -- Replacement loan payment duration in Standard turns.
    debtReliefFraction = 0.50, -- Fraction of eligible debt and arrears forgiven.
    debtReliefTurns = 15, -- Milestone deadline in Standard turns.
    disasterPauseTurns = 5, -- Payment pause in Standard turns.
    disasterCooldownTurns = 30, -- Per-loan pause cooldown in Standard turns.
    maxRestructuresPerLineage = 1, -- Uses per original loan lineage.
    maxDebtReliefPerGame = 1, -- Uses per borrower per game.
  },
  grants = {
    gptMultiple = 3, -- Grant gold divided by current net GPT, before era minimum.
    eraMinimums = false, -- UNSPECIFIED: grant era minimums await tuning.
    maxPerEra = 1, -- Development grant claims per borrower per era.
    infrastructureLimitMultiplier = 1.50, -- Multiple of normal credit limit.
  },
  investors = {
    depositTerms = {20, 30}, -- Deposit durations in Standard turns.
    depositReturns = {0.05, 0.08}, -- Total return fractions for matching terms; S3 placeholders.
    earlyWithdrawalFraction = 0.90, -- Principal returned on early withdrawal.
    preferredValueAdjustment = -0.10, -- Own-loan V adjustment while an investor.
    preferredLimitMultiplier = 1.50, -- Own credit limit multiplier while an investor.
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
  },
  ai = {
    lowTreasuryGptMultiple = 3, -- Borrow only below this multiple of positive net GPT.
    loanGptMultiple = 5, -- Requested principal divided by positive net GPT.
    maxLoans = 2, -- Maximum concurrent AI loans.
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
  },
  features = {
    aiBorrowingVerified = false, -- S8 gameplay capability gate.
    disasterPauseVerified = false, -- S5 gameplay capability gate.
    merchantPointsVerified = false, -- S9 gameplay capability gate.
    envoyVerified = false, -- S9 gameplay capability gate.
  },
  precision = {
    shareStepTolerance = 0.000000000001, -- Dimensionless machine-boundary tolerance, not a gameplay benefit.
  },
}
