import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../services/execution/auto_spot_grid_execution_service.dart';
import '../services/execution/recovery_short_engine.dart';
import '../services/app_ui_settings.dart';
import '../services/market_data/market_data_coordinator.dart';
import '../services/market_data/market_tick.dart';

class ShortFutureRecoverPage extends StatelessWidget {
  const ShortFutureRecoverPage({super.key});

  @override
  Widget build(BuildContext context) {
    final workspace = Get.find<SymbolWorkspaceController>();
    final liveGrid = Get.find<AutoSpotGridExecutionService>();
    final recoveryEngine = Get.find<RecoveryShortEngine>();
    final marketData = Get.find<MarketDataCoordinator>();
    final db = Get.find<AppDatabase>();
    return Obx(() {
      final active = workspace.activeSymbol.value;
      if (active == null) {
        return const Center(child: Text('请先添加交易币对。'));
      }
      return StreamBuilder<Strategy?>(
        stream: liveGrid.watchActiveFuturesGridStrategy(symbol: active.symbol),
        builder: (context, snapshot) {
          final strategy = snapshot.data;
          return Scaffold(
            appBar: AppBar(
              title: Text('${active.displayName} Short Futures Recover'),
            ),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _HeaderCard(strategy: strategy),
                const SizedBox(height: 12),
                if (strategy == null)
                  const _EmptyState()
                else
                  FutureBuilder<LiveSpotGridEditableConfig?>(
                    future: liveGrid.loadEditableConfig(strategy.id),
                    builder: (context, configSnapshot) {
                      final config = configSnapshot.data;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _CurrentConfigCard(
                            strategy: strategy,
                            config: config,
                          ),
                          const SizedBox(height: 12),
                          _RecoveryExecutionSwitchCard(
                            db: db,
                            strategy: strategy,
                          ),
                          const SizedBox(height: 12),
                          _RiskSnapshotCard(
                            strategy: strategy,
                            engine: recoveryEngine,
                            marketData: marketData,
                          ),
                          const SizedBox(height: 12),
                          _RecoveryPreviewCard(
                            strategy: strategy,
                            config: config,
                          ),
                          const SizedBox(height: 12),
                          _RecoveryStateCard(
                            strategy: strategy,
                            engine: recoveryEngine,
                          ),
                          const SizedBox(height: 12),
                          const _ImplementationScopeCard(),
                        ],
                      );
                    },
                  ),
              ],
            ),
          );
        },
      );
    });
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.strategy});

  final Strategy? strategy;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recovery Short 独立模块',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              strategy == null
                  ? '当前 symbol 没有运行中的 LONG Futures 网格策略。'
                  : '当前策略：${strategy!.name} / ${strategy!.status}',
            ),
            const SizedBox(height: 8),
            const Text(
              '本页面用于后续承载底部 Recovery Short 分层保护，不修改现有 LONG Futures 买卖逻辑。',
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Text('请先在 Strategy 页面创建并启动当前币种的 LIVE 合约 LONG 网格。'),
      ),
    );
  }
}

class _CurrentConfigCard extends StatelessWidget {
  const _CurrentConfigCard({required this.strategy, required this.config});

  final Strategy strategy;
  final LiveSpotGridEditableConfig? config;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '当前 LONG 策略来源',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            _kv('Symbol', strategy.symbol),
            _kv('CenterPrice', strategy.centerPrice),
            _kv('UpperBound', strategy.upperPrice),
            _kv('LowerBound', strategy.lowerPrice),
            _kv('Grid Percent', '${strategy.gridSpacingPercent}%'),
            _kv('Grid Count', strategy.gridCount.toString()),
            _kv(
              'Long Qty Per Grid',
              config?.singleGridAmount.toString() ?? '-',
            ),
          ],
        ),
      ),
    );
  }
}

class _RecoveryExecutionSwitchCard extends StatelessWidget {
  const _RecoveryExecutionSwitchCard({
    required this.db,
    required this.strategy,
  });

  final AppDatabase db;
  final Strategy strategy;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: AppUiSettings.watchShortRecoverEnabledForSymbol(
        db,
        symbol: strategy.symbol,
      ),
      initialData: false,
      builder: (context, snapshot) {
        final enabled = snapshot.data ?? false;
        return Card(
          child: SwitchListTile(
            value: enabled,
            title: const Text('启用 Recovery Short 自动执行'),
            subtitle: Text(
              enabled
                  ? '已开启：价格 WebSocket 触发时允许自动开空、平空和下边界减仓。'
                  : '已关闭：只展示状态和对账信息，不会自动提交 Recovery Short 订单。',
            ),
            onChanged: (value) async {
              await AppUiSettings.setShortRecoverEnabledForSymbol(
                db,
                symbol: strategy.symbol,
                value: value,
              );
              if (!context.mounted) {
                return;
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    value
                        ? '${strategy.symbol} Recovery Short 已开启'
                        : '${strategy.symbol} Recovery Short 已关闭',
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _RecoveryPreviewCard extends StatelessWidget {
  const _RecoveryPreviewCard({required this.strategy, required this.config});

  final Strategy strategy;
  final LiveSpotGridEditableConfig? config;

  @override
  Widget build(BuildContext context) {
    final center = Decimal.tryParse(strategy.centerPrice);
    final levels =
        center == null ? const <_RecoveryPreview>[] : _preview(center);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recovery Short 设计预览',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            _kv('模式', 'recovery_micro_short'),
            _kv('主格百分比', '1%'),
            _kv('保护起点', '-2.5%'),
            _kv('微格间距', '0.1%'),
            _kv('下边界', '-7%'),
            _kv('权重', '默认 10% x 10'),
            _kv('触发容差', '${_triggerTolerance(config)} USDT（复用开多提前触发）'),
            _kv('当前杠杆', '${config?.futuresLeverage ?? '-'}x'),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            const Text('预览价格层'),
            const SizedBox(height: 8),
            if (levels.isEmpty)
              const Text('CenterPrice 无法解析。')
            else
              Table(
                columnWidths: const {
                  0: FixedColumnWidth(64),
                  1: FixedColumnWidth(96),
                  2: FlexColumnWidth(),
                  3: FlexColumnWidth(),
                  4: FlexColumnWidth(),
                },
                children: [
                  const TableRow(
                    children: [
                      _TableHeader('档位'),
                      _TableHeader('百分比'),
                      _TableHeader('开空价'),
                      _TableHeader('开空触发'),
                      _TableHeader('平空触发'),
                    ],
                  ),
                  for (final item in levels)
                    TableRow(
                      children: [
                        _TableCell(item.index.toString()),
                        _TableCell('${item.percent}%'),
                        _TableCell(item.price.toString()),
                        _TableCell(item.entryTriggerPrice.toString()),
                        _TableCell(item.exitTriggerPrice.toString()),
                      ],
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  List<_RecoveryPreview> _preview(Decimal center) {
    final items = <_RecoveryPreview>[];
    final tolerance = _triggerTolerance(config);
    for (var i = 0; i < 10; i += 1) {
      final percent =
          Decimal.parse('-2.5') - Decimal.parse('0.1') * Decimal.fromInt(i);
      final percentRatio = (percent / Decimal.fromInt(100)).toDecimal(
        scaleOnInfinitePrecision: 12,
      );
      final multiplier = Decimal.fromInt(1) + percentRatio;
      final price = center * multiplier;
      items.add(
        _RecoveryPreview(
          i,
          percent,
          price,
          price + tolerance,
          price - tolerance,
        ),
      );
    }
    return items;
  }

  Decimal _triggerTolerance(LiveSpotGridEditableConfig? config) {
    return config?.longEntryTriggerDistanceUsdt ??
        AutoSpotGridExecutionService.defaultLongEntryTriggerDistanceUsdt;
  }
}

class _RiskSnapshotCard extends StatelessWidget {
  const _RiskSnapshotCard({
    required this.strategy,
    required this.engine,
    required this.marketData,
  });

  final Strategy strategy;
  final RecoveryShortEngine engine;
  final MarketDataCoordinator marketData;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, MarketTick>>(
      stream: marketData.allMarketTicksStream,
      initialData: marketData.currentMarketTicks,
      builder: (context, _) {
        return FutureBuilder<RecoveryShortRiskSnapshot?>(
          future: engine.loadRiskSnapshot(strategy.id),
          builder: (context, snapshot) {
            final risk = snapshot.data;
            if (risk == null) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('组合风险数据暂不可用。'),
                ),
              );
            }
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Long + Recovery Short 组合风险',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Chip(
                          label: Text(risk.protectionStatus),
                          backgroundColor: _statusColor(
                            risk.protectionStatus,
                          ).withValues(alpha: 0.16),
                          labelStyle: TextStyle(
                            color: _statusColor(risk.protectionStatus),
                            fontWeight: FontWeight.w600,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Mark: ${risk.currentMarkPrice?.toString() ?? '-'} / Symbol: ${risk.symbol}',
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _RiskTile(
                          label: 'Long 浮盈亏',
                          value: '${_fmt(risk.longUnrealizedPnl)} USDT',
                          color: _pnlColor(risk.longUnrealizedPnl),
                        ),
                        _RiskTile(
                          label: 'Short 浮盈亏',
                          value: '${_fmt(risk.shortUnrealizedPnl)} USDT',
                          color: _pnlColor(risk.shortUnrealizedPnl),
                        ),
                        _RiskTile(
                          label: '组合浮盈亏',
                          value: '${_fmt(risk.combinedUnrealizedPnl)} USDT',
                          color: _pnlColor(risk.combinedUnrealizedPnl),
                        ),
                        _RiskTile(
                          label: 'Long 数量',
                          value: _fmt(risk.longQuantity),
                        ),
                        _RiskTile(
                          label: 'Short 数量',
                          value: _fmt(risk.shortQuantity),
                        ),
                        _RiskTile(
                          label: 'Net Qty',
                          value: _fmt(risk.netQuantity),
                          color:
                              risk.netQuantity == Decimal.zero
                                  ? Colors.green.shade700
                                  : Colors.orange.shade800,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Short 已抵消 Long 浮亏：${_fmt(risk.offsetAmount)} USDT / ${_fmt(risk.offsetRatio)}%',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Long 均价 ${_fmt(risk.longAvgPrice)}，Short 均价 ${_fmt(risk.shortAvgPrice)}。',
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Color _pnlColor(Decimal value) {
    if (value > Decimal.zero) {
      return Colors.green.shade700;
    }
    if (value < Decimal.zero) {
      return Colors.red.shade700;
    }
    return Colors.grey.shade800;
  }

  Color _statusColor(String status) {
    switch (status) {
      case '有效抵消':
        return Colors.green.shade700;
      case '保护中':
        return Colors.orange.shade800;
      case '未生效':
        return Colors.red.shade700;
      default:
        return Colors.grey.shade800;
    }
  }
}

class _RiskTile extends StatelessWidget {
  const _RiskTile({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 172,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade700)),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImplementationScopeCard extends StatelessWidget {
  const _ImplementationScopeCard();

  @override
  Widget build(BuildContext context) {
    const items = [
      '不修改 LONG Futures 下单和生命周期。',
      'Recovery Short 使用独立状态机。',
      '每档按方向穿越触发，避免重复开空。',
      '开空后先跌 0.1%，再允许原价平空。',
      '平空后先涨 0.1%，再允许重新开仓。',
      '状态已持久化到 recovery_short_levels，支持程序重启恢复。',
      '下边界 -7% 时会尝试把 Recovery Short 超额部分减到 LONG 数量。',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '改造边界',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('- $item'),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecoveryStateCard extends StatelessWidget {
  const _RecoveryStateCard({required this.strategy, required this.engine});

  final Strategy strategy;
  final RecoveryShortEngine engine;

  @override
  Widget build(BuildContext context) {
    unawaited(engine.ensureForStrategy(strategy.id));
    return StreamBuilder<List<RecoveryShortLevel>>(
      stream: engine.watchLevels(strategy.id),
      builder: (context, snapshot) {
        final rows = snapshot.data ?? const <RecoveryShortLevel>[];
        final stats = _RecoveryUiStats.fromRows(rows);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text(
                      'Recovery Short 状态机',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.sync),
                      label: const Text('轻量对账 Recovery'),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final report = await engine.reconcileStrategy(
                          strategy.id,
                        );
                        messenger.showSnackBar(
                          SnackBar(content: Text(report.summary)),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _StatChip('总档位', stats.total.toString()),
                    _StatChip('READY', stats.ready.toString()),
                    _StatChip('OPEN', stats.open.toString()),
                    _StatChip('ARMED', stats.armedExit.toString()),
                    _StatChip('提交中', stats.submitting.toString()),
                    _StatChip('待重新激活', stats.closedWaitingRearm.toString()),
                    _StatChip('失败', stats.failed.toString()),
                  ],
                ),
                const SizedBox(height: 12),
                if (rows.isEmpty)
                  const Text('正在初始化 Recovery Short 档位。')
                else
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('档位')),
                        DataColumn(label: Text('百分比')),
                        DataColumn(label: Text('价格')),
                        DataColumn(label: Text('状态')),
                        DataColumn(label: Text('数量')),
                        DataColumn(label: Text('剩余')),
                        DataColumn(label: Text('可平')),
                        DataColumn(label: Text('可重新开')),
                        DataColumn(label: Text('轮次')),
                        DataColumn(label: Text('错误')),
                      ],
                      rows: [
                        for (final row in rows)
                          DataRow(
                            cells: [
                              DataCell(Text(row.partIndex.toString())),
                              DataCell(Text('${row.entryPercent}%')),
                              DataCell(Text(row.entryPrice)),
                              DataCell(Text(_statusText(row.status))),
                              DataCell(Text(row.quantity)),
                              DataCell(Text(row.remainingQuantity)),
                              DataCell(Text(row.armedForExit ? '是' : '否')),
                              DataCell(Text(row.armedForEntry ? '是' : '否')),
                              DataCell(Text(row.roundId.toString())),
                              DataCell(
                                SizedBox(
                                  width: 260,
                                  child: Text(
                                    row.lastError ?? '-',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _statusText(String status) {
    switch (status) {
      case RecoveryShortEngine.statusReadyToEnter:
        return '等待开空';
      case RecoveryShortEngine.statusEnterSubmitting:
        return '开空提交中';
      case RecoveryShortEngine.statusOpen:
        return '已开空';
      case RecoveryShortEngine.statusArmedExit:
        return '允许平空';
      case RecoveryShortEngine.statusExitSubmitting:
        return '平空提交中';
      case RecoveryShortEngine.statusClosedWaitingRearm:
        return '等待重新激活';
      case RecoveryShortEngine.statusFailed:
        return '失败';
      default:
        return status;
    }
  }
}

class _RecoveryUiStats {
  const _RecoveryUiStats({
    required this.total,
    required this.ready,
    required this.open,
    required this.armedExit,
    required this.submitting,
    required this.closedWaitingRearm,
    required this.failed,
  });

  factory _RecoveryUiStats.fromRows(List<RecoveryShortLevel> rows) {
    return _RecoveryUiStats(
      total: rows.length,
      ready:
          rows
              .where(
                (row) => row.status == RecoveryShortEngine.statusReadyToEnter,
              )
              .length,
      open:
          rows
              .where((row) => row.status == RecoveryShortEngine.statusOpen)
              .length,
      armedExit:
          rows
              .where((row) => row.status == RecoveryShortEngine.statusArmedExit)
              .length,
      submitting:
          rows
              .where(
                (row) =>
                    row.status == RecoveryShortEngine.statusEnterSubmitting ||
                    row.status == RecoveryShortEngine.statusExitSubmitting,
              )
              .length,
      closedWaitingRearm:
          rows
              .where(
                (row) =>
                    row.status == RecoveryShortEngine.statusClosedWaitingRearm,
              )
              .length,
      failed:
          rows
              .where((row) => row.status == RecoveryShortEngine.statusFailed)
              .length,
    );
  }

  final int total;
  final int ready;
  final int open;
  final int armedExit;
  final int submitting;
  final int closedWaitingRearm;
  final int failed;
}

class _StatChip extends StatelessWidget {
  const _StatChip(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text('$label $value'),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _RecoveryPreview {
  const _RecoveryPreview(
    this.index,
    this.percent,
    this.price,
    this.entryTriggerPrice,
    this.exitTriggerPrice,
  );

  final int index;
  final Decimal percent;
  final Decimal price;
  final Decimal entryTriggerPrice;
  final Decimal exitTriggerPrice;
}

class _TableHeader extends StatelessWidget {
  const _TableHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}

class _TableCell extends StatelessWidget {
  const _TableCell(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(text),
    );
  }
}

Widget _kv(String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        SizedBox(
          width: 150,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

String _fmt(Decimal value) {
  final text = value.toString();
  if (!text.contains('.')) {
    return text;
  }
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
