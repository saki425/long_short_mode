import 'package:flutter/material.dart';
import 'package:decimal/decimal.dart';
import 'package:get/get.dart';

import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../models/live_validation.dart';
import '../models/order_filters.dart';
import '../repositories/live_validation_repository.dart';
import '../services/app_ui_settings.dart';

class ValidationStatsPage extends StatefulWidget {
  const ValidationStatsPage({super.key});

  @override
  State<ValidationStatsPage> createState() => _ValidationStatsPageState();
}

class _ValidationStatsPageState extends State<ValidationStatsPage> {
  late final LiveValidationRepository _repository;
  late final AppDatabase _db;
  LocalDateRange _range = todayRange(DateTime.now());

  @override
  void initState() {
    super.initState();
    _repository = Get.find<LiveValidationRepository>();
    _db = Get.find<AppDatabase>();
  }

  @override
  Widget build(BuildContext context) {
    final utcRange = _range.toUtcHalfOpenRange();
    return Scaffold(
      appBar: AppBar(title: const Text('验证统计')),
      body: FutureBuilder<ValidationStats>(
        future: _repository.getStats(
          start: utcRange.startInclusiveUtc,
          end: utcRange.endExclusiveUtc,
        ),
        builder: (context, snapshot) {
          final stats = snapshot.data;
          return Obx(() {
            final symbol =
                Get.find<SymbolWorkspaceController>()
                    .activeSymbol
                    .value
                    ?.symbol;
            return StreamBuilder<bool>(
              stream: AppUiSettings.watchHideSpotUiForSymbol(
                _db,
                symbol: symbol,
              ),
              initialData: false,
              builder: (context, uiSnapshot) {
                final hideSpotUi = uiSnapshot.data ?? false;
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _DateSelector(
                      selected: _range.label,
                      onSelected: (range) => setState(() => _range = range),
                    ),
                    const SizedBox(height: 12),
                    _StageCards(
                      stages: _repository.stages,
                      hideSpotUi: hideSpotUi,
                    ),
                    const SizedBox(height: 16),
                    _PreflightCard(
                      items: _repository.buildPreflightChecklist(),
                      hideSpotUi: hideSpotUi,
                    ),
                    const SizedBox(height: 16),
                    if (stats == null)
                      const LinearProgressIndicator()
                    else
                      _StatsTable(stats: stats, hideSpotUi: hideSpotUi),
                    const SizedBox(height: 16),
                    _UnlockRulesCard(stats: stats),
                  ],
                );
              },
            );
          });
        },
      ),
    );
  }
}

class _DateSelector extends StatelessWidget {
  const _DateSelector({required this.selected, required this.onSelected});

  final String selected;
  final ValueChanged<LocalDateRange> onSelected;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final ranges = [
      todayRange(now),
      yesterdayRange(now),
      lastDaysRange(now, 7, '最近7天'),
      lastDaysRange(now, 30, '最近30天'),
      thisMonthRange(now),
      previousMonthRange(now),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('日期范围'),
        for (final range in ranges)
          ChoiceChip(
            label: Text(range.label),
            selected: selected == range.label,
            onSelected: (_) => onSelected(range),
          ),
      ],
    );
  }
}

class _StageCards extends StatelessWidget {
  const _StageCards({required this.stages, required this.hideSpotUi});

  final List<LiveValidationStageConfig> stages;
  final bool hideSpotUi;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final stage in stages)
          SizedBox(
            width: 300,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stage.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text('总资金: ${stage.totalCapitalUsdt} USDT'),
                    if (!hideSpotUi)
                      Text('现货网格: ${stage.spotGridCapitalUsdt} USDT'),
                    Text('合约保证金: ${stage.futuresMarginBudgetUsdt} USDT'),
                    Text('备用资金: ${stage.reserveCapitalUsdt} USDT'),
                    Text(
                      '上下网格: ${stage.upperGridCount}/${stage.lowerGridCount}',
                    ),
                    Text('网格间距: ${stage.gridSpacingPercent}%'),
                    Text('对冲比例: ${stage.hedgeRatio * Decimal.fromInt(100)}%'),
                    Text('组合最大亏损: ${stage.maxPortfolioLossUsdt} USDT'),
                    Text('单日最大亏损: ${stage.maxDailyLossUsdt} USDT'),
                    Text('最大净敞口: ${stage.maxNetExposureUsdt} USDT'),
                    Text('估算每格金额: ${stage.approximatePerGridUsdt} USDT'),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PreflightCard extends StatelessWidget {
  const _PreflightCard({required this.items, required this.hideSpotUi});

  final List<PreflightCheckItem> items;
  final bool hideSpotUi;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('实盘验证启动前检查', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final item in _displayItems())
              ListTile(
                dense: true,
                leading: Icon(
                  item.passed
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                ),
                title: Text(item.label),
                subtitle: Text(item.message),
              ),
          ],
        ),
      ),
    );
  }

  List<PreflightCheckItem> _displayItems() {
    if (!hideSpotUi) {
      return items;
    }
    return [
      for (final item in items)
        if (item.id != 'spot_open_orders')
          PreflightCheckItem(
            id: item.id,
            label: _futuresOnlyLabel(item),
            required: item.required,
            passed: item.passed,
            message: item.message,
          ),
    ];
  }

  String _futuresOnlyLabel(PreflightCheckItem item) {
    return switch (item.id) {
      'verify_sub_accounts' => '验证合约子账户 API',
      'real_balances' => '查询合约账户真实余额',
      'exchange_rules' => '获取合约交易规则',
      _ => item.label,
    };
  }
}

class _StatsTable extends StatelessWidget {
  const _StatsTable({required this.stats, required this.hideSpotUi});

  final ValidationStats stats;
  final bool hideSpotUi;

  @override
  Widget build(BuildContext context) {
    final rows = [
      _MetricRow('期初总资产', '${stats.beginEquity} USDT'),
      _MetricRow('期末总资产', '${stats.endEquity} USDT'),
      _MetricRow('净充值和净提现', '${stats.netDepositWithdrawal} USDT'),
      if (!hideSpotUi) _MetricRow('现货网格利润', '${stats.spotGridProfit} USDT'),
      if (!hideSpotUi) _MetricRow('现货浮动盈亏', '${stats.spotUnrealizedPnl} USDT'),
      _MetricRow('合约已实现盈亏', '${stats.futuresRealizedPnl} USDT'),
      _MetricRow('合约浮动盈亏', '${stats.futuresUnrealizedPnl} USDT'),
      if (!hideSpotUi) _MetricRow('现货手续费', '${stats.spotFees} USDT'),
      _MetricRow('合约手续费', '${stats.futuresFees} USDT'),
      _MetricRow('资金费率', '${stats.fundingFees} USDT'),
      _MetricRow('滑点估算', '${stats.slippageEstimate} USDT'),
      _MetricRow('组合净利润', '${stats.portfolioNetProfit} USDT'),
      _MetricRow('组合收益率', '${stats.portfolioReturnPercent}%'),
      _MetricRow('最大回撤', '${stats.maxDrawdown} USDT'),
      _MetricRow('最大净敞口', '${stats.maxNetExposure} USDT'),
      _MetricRow('完整网格循环次数', stats.completedGridCycles.toString()),
      _MetricRow('对冲调整次数', stats.hedgeAdjustmentCount.toString()),
      _MetricRow('API错误次数', stats.apiErrorCount.toString()),
      _MetricRow('WebSocket断线次数', stats.websocketDisconnectCount.toString()),
      _MetricRow('数据库对账异常次数', stats.databaseReconcileErrorCount.toString()),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: DataTable(
          columns: const [
            DataColumn(label: Text('指标')),
            DataColumn(label: Text('数值')),
          ],
          rows: [
            for (final row in rows)
              DataRow(
                cells: [DataCell(Text(row.label)), DataCell(Text(row.value))],
              ),
          ],
        ),
      ),
    );
  }
}

class _UnlockRulesCard extends StatelessWidget {
  const _UnlockRulesCard({required this.stats});

  final ValidationStats? stats;

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '阶段解锁机制',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            Text('阶段1连续运行至少7天且没有严重异常后，才允许手动解锁阶段2。'),
            Text('阶段2连续运行至少14天，并且组合净收益为正、最大回撤未超过限制、没有重复下单和裸露仓位后，才允许手动解锁阶段3。'),
            Text('程序不会自动增加资金，阶段切换必须由用户手动确认。'),
          ],
        ),
      ),
    );
  }
}

class _MetricRow {
  const _MetricRow(this.label, this.value);

  final String label;
  final String value;
}
