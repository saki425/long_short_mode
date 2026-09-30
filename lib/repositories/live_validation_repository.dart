import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../models/live_validation.dart';

class LiveValidationRepository {
  LiveValidationRepository(this.db);

  final AppDatabase db;

  List<LiveValidationStageConfig> get stages => LiveValidationStageConfig.defaults;

  List<PreflightCheckItem> buildPreflightChecklist() {
    return const [
      PreflightCheckItem(id: 'verify_sub_accounts', label: '验证两个子账户API', required: true),
      PreflightCheckItem(id: 'withdraw_disabled', label: '确认API没有提币权限', required: true),
      PreflightCheckItem(id: 'real_balances', label: '查询两个账户真实余额', required: true),
      PreflightCheckItem(id: 'spot_open_orders', label: '查询现货所有BTCUSDT挂单', required: true),
      PreflightCheckItem(id: 'futures_positions', label: '查询合约所有BTCUSDT仓位', required: true),
      PreflightCheckItem(id: 'no_unknown_long', label: '确认不存在未知多仓', required: true),
      PreflightCheckItem(id: 'no_external_short', label: '确认不存在非本策略空仓', required: true),
      PreflightCheckItem(id: 'exchange_rules', label: '获取现货和合约交易规则', required: true),
      PreflightCheckItem(id: 'min_notional', label: '检查每格金额满足最小下单金额', required: true),
      PreflightCheckItem(id: 'sqlite_writable', label: '测试SQLite数据库可写', required: true),
      PreflightCheckItem(id: 'emergency_stop', label: '测试紧急停止逻辑', required: true),
      PreflightCheckItem(id: 'loss_confirmation', label: '显示预计最大损失并要求用户确认', required: true),
    ];
  }

  Future<bool> testSqliteWritable() async {
    const key = 'validation.sqliteWritable.lastCheckedAt';
    await db.into(db.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: key,
            value: DateTime.now().toUtc().toIso8601String(),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
    final row = await (db.select(db.appSettings)..where((tbl) => tbl.key.equals(key))).getSingleOrNull();
    return row != null;
  }

  Future<ValidationStats> getStats({
    required DateTime start,
    required DateTime end,
  }) async {
    final pnlRows = await (db.select(db.pnlSnapshots)
          ..where((tbl) => tbl.recordedAt.isBiggerOrEqualValue(start.toUtc()) & tbl.recordedAt.isSmallerThanValue(end.toUtc()))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.recordedAt)]))
        .get();
    final accountRows = await (db.select(db.accountSnapshots)
          ..where((tbl) => tbl.recordedAt.isBiggerOrEqualValue(start.toUtc()) & tbl.recordedAt.isSmallerThanValue(end.toUtc()))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.recordedAt)]))
        .get();
    final hedgeRows = await (db.select(db.hedgeAdjustments)
          ..where((tbl) => tbl.createdAt.isBiggerOrEqualValue(start.toUtc()) & tbl.createdAt.isSmallerThanValue(end.toUtc())))
        .get();
    final riskRows = await (db.select(db.riskEvents)
          ..where((tbl) => tbl.createdAt.isBiggerOrEqualValue(start.toUtc()) & tbl.createdAt.isSmallerThanValue(end.toUtc())))
        .get();

    final firstPnl = pnlRows.isEmpty ? null : pnlRows.first;
    final lastPnl = pnlRows.isEmpty ? null : pnlRows.last;
    final beginEquity = _decimal(firstPnl?.totalEquity ?? '0');
    final endEquity = _decimal(lastPnl?.totalEquity ?? '0');
    final spotGridProfit = _sum(pnlRows.map((row) => row.spotGridRealizedPnl));
    final futuresRealized = _sum(pnlRows.map((row) => row.futuresRealizedPnl));
    final spotFees = _sum(pnlRows.map((row) => row.spotFees));
    final futuresFees = _sum(pnlRows.map((row) => row.futuresFees));
    final fundingFees = _sum(pnlRows.map((row) => row.fundingFees));
    final spotUnrealized = _decimal(lastPnl?.spotUnrealizedPnl ?? '0');
    final futuresUnrealized = _decimal(lastPnl?.futuresUnrealizedPnl ?? '0');
    final maxNetExposure = accountRows.fold<Decimal>(
      Decimal.zero,
      (maxValue, row) {
        final exposure = _decimal(row.netExposureUsdt).abs();
        return exposure > maxValue ? exposure : maxValue;
      },
    );
    final maxDrawdown = _calculateMaxDrawdown(pnlRows.map((row) => _decimal(row.totalEquity)).toList());
    final netDeposits = Decimal.zero;
    final netProfit = endEquity - beginEquity - netDeposits;
    final returnPercent = beginEquity == Decimal.zero
        ? Decimal.zero
        : (netProfit / beginEquity).toDecimal(scaleOnInfinitePrecision: 8) * Decimal.fromInt(100);

    return ValidationStats(
      beginEquity: beginEquity,
      endEquity: endEquity,
      netDepositWithdrawal: netDeposits,
      spotGridProfit: spotGridProfit,
      spotUnrealizedPnl: spotUnrealized,
      futuresRealizedPnl: futuresRealized,
      futuresUnrealizedPnl: futuresUnrealized,
      spotFees: spotFees,
      futuresFees: futuresFees,
      fundingFees: fundingFees,
      slippageEstimate: Decimal.zero,
      portfolioNetProfit: netProfit,
      portfolioReturnPercent: returnPercent,
      maxDrawdown: maxDrawdown,
      maxNetExposure: maxNetExposure,
      completedGridCycles: 0,
      hedgeAdjustmentCount: hedgeRows.length,
      apiErrorCount: riskRows.where((row) => row.type == 'api').length,
      websocketDisconnectCount: riskRows.where((row) => row.type == 'websocket').length,
      databaseReconcileErrorCount: riskRows.where((row) => row.type == 'reconcile' || row.type == 'database').length,
    );
  }

  Future<StageUnlockResult> evaluateUnlock({
    required ValidationStage targetStage,
    required DateTime now,
    required DateTime? previousStageStartedAt,
    required ValidationStats previousStageStats,
    required bool hasSevereException,
    required bool hasDuplicateOrders,
    required bool hasNakedExposure,
    required Decimal maxDrawdownLimit,
  }) async {
    final reasons = <String>[];
    if (targetStage == ValidationStage.stage1) {
      return const StageUnlockResult(allowed: true, reasons: []);
    }
    if (previousStageStartedAt == null) {
      reasons.add('上一阶段尚未开始运行');
    }
    final requiredDays = targetStage == ValidationStage.stage2 ? 7 : 14;
    if (previousStageStartedAt != null && now.difference(previousStageStartedAt).inDays < requiredDays) {
      reasons.add('上一阶段连续运行未满 $requiredDays 天');
    }
    if (hasSevereException) {
      reasons.add('上一阶段存在严重异常');
    }
    if (targetStage == ValidationStage.stage3) {
      if (previousStageStats.portfolioNetProfit <= Decimal.zero) {
        reasons.add('阶段2组合净收益未为正');
      }
      if (previousStageStats.maxDrawdown > maxDrawdownLimit) {
        reasons.add('阶段2最大回撤超过限制');
      }
      if (hasDuplicateOrders) {
        reasons.add('阶段2存在重复下单');
      }
      if (hasNakedExposure) {
        reasons.add('阶段2存在裸露仓位');
      }
    }
    return StageUnlockResult(allowed: reasons.isEmpty, reasons: reasons);
  }

  Decimal _sum(Iterable<String> values) {
    return values.fold<Decimal>(Decimal.zero, (sum, value) => sum + _decimal(value));
  }

  Decimal _calculateMaxDrawdown(List<Decimal> equityCurve) {
    Decimal peak = Decimal.zero;
    Decimal maxDrawdown = Decimal.zero;
    for (final equity in equityCurve) {
      if (equity > peak) {
        peak = equity;
      }
      if (peak > Decimal.zero) {
        final drawdown = peak - equity;
        if (drawdown > maxDrawdown) {
          maxDrawdown = drawdown;
        }
      }
    }
    return maxDrawdown;
  }

  Decimal _decimal(String value) => Decimal.tryParse(value) ?? Decimal.zero;
}
