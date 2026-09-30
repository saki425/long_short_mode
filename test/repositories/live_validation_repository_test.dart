import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/database/app_database.dart';
import 'package:grid_hedge_trader/models/live_validation.dart';
import 'package:grid_hedge_trader/repositories/live_validation_repository.dart';

void main() {
  late AppDatabase db;
  late LiveValidationRepository repository;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repository = LiveValidationRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('stage 1 uses required 100 USDT live validation defaults', () {
    final stage = LiveValidationStageConfig.stage1;

    expect(stage.totalCapitalUsdt, Decimal.fromInt(100));
    expect(stage.spotGridCapitalUsdt, Decimal.fromInt(70));
    expect(stage.futuresMarginBudgetUsdt, Decimal.fromInt(25));
    expect(stage.reserveCapitalUsdt, Decimal.fromInt(5));
    expect(stage.gridSpacingPercent, Decimal.parse('1.2'));
    expect(stage.upperGridCount, 3);
    expect(stage.lowerGridCount, 3);
    expect(stage.hedgeRatio, Decimal.parse('0.8'));
    expect(stage.hedgeCheckGridFills, 2);
    expect(stage.maxPortfolioLossUsdt, Decimal.fromInt(5));
    expect(stage.maxDailyLossUsdt, Decimal.fromInt(3));
    expect(stage.maxNetExposureUsdt, Decimal.fromInt(15));
  });

  test('preflight checklist includes all required live validation gates', () {
    final checklist = repository.buildPreflightChecklist();

    expect(checklist, hasLength(12));
    expect(checklist.every((item) => item.required), isTrue);
    expect(checklist.map((item) => item.id), containsAll([
      'verify_sub_accounts',
      'withdraw_disabled',
      'real_balances',
      'spot_open_orders',
      'futures_positions',
      'no_unknown_long',
      'no_external_short',
      'exchange_rules',
      'min_notional',
      'sqlite_writable',
      'emergency_stop',
      'loss_confirmation',
    ]));
  });

  test('stage 2 requires stage 1 to run at least 7 days without severe exception', () async {
    final stats = _positiveStats();
    final denied = await repository.evaluateUnlock(
      targetStage: ValidationStage.stage2,
      now: DateTime.utc(2026, 7, 8),
      previousStageStartedAt: DateTime.utc(2026, 7, 2),
      previousStageStats: stats,
      hasSevereException: false,
      hasDuplicateOrders: false,
      hasNakedExposure: false,
      maxDrawdownLimit: Decimal.fromInt(5),
    );
    final allowed = await repository.evaluateUnlock(
      targetStage: ValidationStage.stage2,
      now: DateTime.utc(2026, 7, 9),
      previousStageStartedAt: DateTime.utc(2026, 7, 2),
      previousStageStats: stats,
      hasSevereException: false,
      hasDuplicateOrders: false,
      hasNakedExposure: false,
      maxDrawdownLimit: Decimal.fromInt(5),
    );

    expect(denied.allowed, isFalse);
    expect(denied.reasons.single, contains('7 天'));
    expect(allowed.allowed, isTrue);
  });

  test('stage 3 requires positive return bounded drawdown no duplicate order and no naked exposure', () async {
    final denied = await repository.evaluateUnlock(
      targetStage: ValidationStage.stage3,
      now: DateTime.utc(2026, 7, 20),
      previousStageStartedAt: DateTime.utc(2026, 7, 5),
      previousStageStats: _positiveStats(maxDrawdown: Decimal.fromInt(20)),
      hasSevereException: false,
      hasDuplicateOrders: true,
      hasNakedExposure: true,
      maxDrawdownLimit: Decimal.fromInt(10),
    );
    final allowed = await repository.evaluateUnlock(
      targetStage: ValidationStage.stage3,
      now: DateTime.utc(2026, 7, 20),
      previousStageStartedAt: DateTime.utc(2026, 7, 5),
      previousStageStats: _positiveStats(maxDrawdown: Decimal.fromInt(5)),
      hasSevereException: false,
      hasDuplicateOrders: false,
      hasNakedExposure: false,
      maxDrawdownLimit: Decimal.fromInt(10),
    );

    expect(denied.allowed, isFalse);
    expect(denied.reasons, containsAll(['阶段2最大回撤超过限制', '阶段2存在重复下单', '阶段2存在裸露仓位']));
    expect(allowed.allowed, isTrue);
  });

  test('sqlite writable preflight writes app setting', () async {
    expect(await repository.testSqliteWritable(), isTrue);
  });
}

ValidationStats _positiveStats({Decimal? maxDrawdown}) {
  return ValidationStats(
    beginEquity: Decimal.fromInt(300),
    endEquity: Decimal.fromInt(315),
    netDepositWithdrawal: Decimal.zero,
    spotGridProfit: Decimal.fromInt(10),
    spotUnrealizedPnl: Decimal.zero,
    futuresRealizedPnl: Decimal.fromInt(5),
    futuresUnrealizedPnl: Decimal.zero,
    spotFees: Decimal.fromInt(1),
    futuresFees: Decimal.fromInt(1),
    fundingFees: Decimal.zero,
    slippageEstimate: Decimal.zero,
    portfolioNetProfit: Decimal.fromInt(15),
    portfolioReturnPercent: Decimal.fromInt(5),
    maxDrawdown: maxDrawdown ?? Decimal.fromInt(3),
    maxNetExposure: Decimal.fromInt(10),
    completedGridCycles: 2,
    hedgeAdjustmentCount: 3,
    apiErrorCount: 0,
    websocketDisconnectCount: 0,
    databaseReconcileErrorCount: 0,
  );
}
