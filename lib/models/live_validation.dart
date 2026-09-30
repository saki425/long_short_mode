import 'package:decimal/decimal.dart';

enum ValidationStage {
  stage1,
  stage2,
  stage3,
}

class LiveValidationStageConfig {
  const LiveValidationStageConfig({
    required this.stage,
    required this.name,
    required this.totalCapitalUsdt,
    required this.spotGridCapitalUsdt,
    required this.futuresMarginBudgetUsdt,
    required this.reserveCapitalUsdt,
    required this.gridSpacingPercent,
    required this.upperGridCount,
    required this.lowerGridCount,
    required this.hedgeRatio,
    required this.hedgeCheckGridFills,
    required this.maxPortfolioLossUsdt,
    required this.maxDailyLossUsdt,
    required this.maxNetExposureUsdt,
  });

  final ValidationStage stage;
  final String name;
  final Decimal totalCapitalUsdt;
  final Decimal spotGridCapitalUsdt;
  final Decimal futuresMarginBudgetUsdt;
  final Decimal reserveCapitalUsdt;
  final Decimal gridSpacingPercent;
  final int upperGridCount;
  final int lowerGridCount;
  final Decimal hedgeRatio;
  final int hedgeCheckGridFills;
  final Decimal maxPortfolioLossUsdt;
  final Decimal maxDailyLossUsdt;
  final Decimal maxNetExposureUsdt;

  int get totalGridCount => upperGridCount + lowerGridCount;

  Decimal get approximatePerGridUsdt {
    if (totalGridCount == 0) {
      return Decimal.zero;
    }
    return (spotGridCapitalUsdt / Decimal.fromInt(totalGridCount)).toDecimal(scaleOnInfinitePrecision: 8);
  }

  static final stage1 = LiveValidationStageConfig(
    stage: ValidationStage.stage1,
    name: '阶段1：100 USDT',
    totalCapitalUsdt: Decimal.fromInt(100),
    spotGridCapitalUsdt: Decimal.fromInt(70),
    futuresMarginBudgetUsdt: Decimal.fromInt(25),
    reserveCapitalUsdt: Decimal.fromInt(5),
    gridSpacingPercent: Decimal.parse('1.2'),
    upperGridCount: 3,
    lowerGridCount: 3,
    hedgeRatio: Decimal.parse('0.8'),
    hedgeCheckGridFills: 2,
    maxPortfolioLossUsdt: Decimal.fromInt(5),
    maxDailyLossUsdt: Decimal.fromInt(3),
    maxNetExposureUsdt: Decimal.fromInt(15),
  );

  static final stage2 = LiveValidationStageConfig(
    stage: ValidationStage.stage2,
    name: '阶段2：300 USDT',
    totalCapitalUsdt: Decimal.fromInt(300),
    spotGridCapitalUsdt: Decimal.fromInt(210),
    futuresMarginBudgetUsdt: Decimal.fromInt(75),
    reserveCapitalUsdt: Decimal.fromInt(15),
    gridSpacingPercent: Decimal.parse('1.1'),
    upperGridCount: 4,
    lowerGridCount: 4,
    hedgeRatio: Decimal.parse('0.9'),
    hedgeCheckGridFills: 2,
    maxPortfolioLossUsdt: Decimal.fromInt(15),
    maxDailyLossUsdt: Decimal.fromInt(9),
    maxNetExposureUsdt: Decimal.fromInt(45),
  );

  static final stage3 = LiveValidationStageConfig(
    stage: ValidationStage.stage3,
    name: '阶段3：1000 USDT',
    totalCapitalUsdt: Decimal.fromInt(1000),
    spotGridCapitalUsdt: Decimal.fromInt(700),
    futuresMarginBudgetUsdt: Decimal.fromInt(250),
    reserveCapitalUsdt: Decimal.fromInt(50),
    gridSpacingPercent: Decimal.fromInt(1),
    upperGridCount: 6,
    lowerGridCount: 6,
    hedgeRatio: Decimal.fromInt(1),
    hedgeCheckGridFills: 2,
    maxPortfolioLossUsdt: Decimal.fromInt(50),
    maxDailyLossUsdt: Decimal.fromInt(30),
    maxNetExposureUsdt: Decimal.fromInt(100),
  );

  static List<LiveValidationStageConfig> get defaults => [stage1, stage2, stage3];
}

class PreflightCheckItem {
  const PreflightCheckItem({
    required this.id,
    required this.label,
    required this.required,
    this.passed = false,
    this.message = '待检查',
  });

  final String id;
  final String label;
  final bool required;
  final bool passed;
  final String message;
}

class ValidationStats {
  const ValidationStats({
    required this.beginEquity,
    required this.endEquity,
    required this.netDepositWithdrawal,
    required this.spotGridProfit,
    required this.spotUnrealizedPnl,
    required this.futuresRealizedPnl,
    required this.futuresUnrealizedPnl,
    required this.spotFees,
    required this.futuresFees,
    required this.fundingFees,
    required this.slippageEstimate,
    required this.portfolioNetProfit,
    required this.portfolioReturnPercent,
    required this.maxDrawdown,
    required this.maxNetExposure,
    required this.completedGridCycles,
    required this.hedgeAdjustmentCount,
    required this.apiErrorCount,
    required this.websocketDisconnectCount,
    required this.databaseReconcileErrorCount,
  });

  final Decimal beginEquity;
  final Decimal endEquity;
  final Decimal netDepositWithdrawal;
  final Decimal spotGridProfit;
  final Decimal spotUnrealizedPnl;
  final Decimal futuresRealizedPnl;
  final Decimal futuresUnrealizedPnl;
  final Decimal spotFees;
  final Decimal futuresFees;
  final Decimal fundingFees;
  final Decimal slippageEstimate;
  final Decimal portfolioNetProfit;
  final Decimal portfolioReturnPercent;
  final Decimal maxDrawdown;
  final Decimal maxNetExposure;
  final int completedGridCycles;
  final int hedgeAdjustmentCount;
  final int apiErrorCount;
  final int websocketDisconnectCount;
  final int databaseReconcileErrorCount;
}

class StageUnlockResult {
  const StageUnlockResult({
    required this.allowed,
    required this.reasons,
  });

  final bool allowed;
  final List<String> reasons;
}
