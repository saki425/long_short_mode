import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../services/pnl/completed_grid_cycle_service.dart';
import '../services/pnl/strategy_performance_service.dart';

class PnlPage extends StatelessWidget {
  const PnlPage({super.key});

  @override
  Widget build(BuildContext context) {
    final performance = Get.find<StrategyPerformanceService>();
    return Scaffold(
      appBar: AppBar(title: const Text('盈亏分析')),
      body: Obx(() {
        final active = Get.find<SymbolWorkspaceController>().activeSymbol.value;
        final symbol = active?.symbol;
        if (active == null || symbol == null) {
          return const Center(child: Text('请先添加交易币对'));
        }
        return StreamBuilder(
          key: ValueKey('pnl-$symbol'),
          stream: performance.watchCurrentStrategy(symbol: symbol),
          builder: (context, strategySnapshot) {
            final strategy = strategySnapshot.data;
            if (strategy == null) {
              return Center(child: Text('当前 ${active.displayName} 还没有策略'));
            }
            if (strategy.symbol != symbol) {
              return Center(
                child: Text(
                  '当前页面币对与策略币对不一致，已阻止加载。\nactiveSymbol=$symbol strategy.symbol=${strategy.symbol}',
                  style: const TextStyle(color: Colors.red),
                ),
              );
            }
            return FutureBuilder<StrategyPerformanceStats>(
              future: performance.calculate(strategy.id),
              builder: (context, snapshot) {
                final stats = snapshot.data;
                if (stats == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return RefreshIndicator(
                  onRefresh: () async {
                    (context as Element).markNeedsBuild();
                  },
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text('当前币对：${active.displayName}'),
                      const SizedBox(height: 8),
                      _StrategyRecordsCard(
                        symbol: symbol,
                        performance: performance,
                        onChanged: () => (context as Element).markNeedsBuild(),
                      ),
                      const SizedBox(height: 12),
                      _SummaryHeader(stats: stats),
                      const SizedBox(height: 12),
                      _PeriodCards(stats: stats),
                      const SizedBox(height: 12),
                      _BreakdownCard(stats: stats),
                      const SizedBox(height: 12),
                      if (stats.completedGridCycles == 0) ...[
                        _NoCompletedCycleNotice(stats: stats),
                        const SizedBox(height: 12),
                      ],
                      _AnnualizedCard(stats: stats),
                      const SizedBox(height: 12),
                      _RebuildCyclesCard(
                        strategyId: strategy.id,
                        onRebuilt: () => (context as Element).markNeedsBuild(),
                      ),
                      const SizedBox(height: 12),
                      _MetricTable(stats: stats),
                    ],
                  ),
                );
              },
            );
          },
        );
      }),
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.stats});

  final StrategyPerformanceStats stats;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${stats.strategy.name} / ${stats.strategy.symbol}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _MetricCard('策略总投入资金', '${_money(stats.initialCapital)} USDT'),
                _MetricCard('当前总净值', '${_money(stats.currentNetWorth)} USDT'),
                _MetricCard('当前净收益', '${_money(stats.netPnl)} USDT'),
                _MetricCard('实际收益率', _percent(stats.returnRate)),
                _MetricCard('策略运行天数', _number(stats.runningDays)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StrategyRecordsCard extends StatefulWidget {
  const _StrategyRecordsCard({
    required this.symbol,
    required this.performance,
    required this.onChanged,
  });

  final String symbol;
  final StrategyPerformanceService performance;
  final VoidCallback onChanged;

  @override
  State<_StrategyRecordsCard> createState() => _StrategyRecordsCardState();
}

class _StrategyRecordsCardState extends State<_StrategyRecordsCard> {
  String? _message;
  String? _deletingId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<StrategyPerformanceStats>>(
      future: widget.performance.calculateStrategies(symbol: widget.symbol),
      builder: (context, snapshot) {
        final records = snapshot.data ?? const <StrategyPerformanceStats>[];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('策略记录', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_message != null) ...[
                  Text(_message!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 8),
                ],
                if (snapshot.connectionState == ConnectionState.waiting)
                  const LinearProgressIndicator()
                else if (records.isEmpty)
                  const Text('当前币对还没有策略记录。')
                else
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('策略')),
                        DataColumn(label: Text('状态')),
                        DataColumn(label: Text('运行天数')),
                        DataColumn(label: Text('循环次数')),
                        DataColumn(label: Text('收益')),
                        DataColumn(label: Text('收益率')),
                        DataColumn(label: Text('操作')),
                      ],
                      rows: [
                        for (final stats in records)
                          DataRow(
                            cells: [
                              DataCell(
                                SizedBox(
                                  width: 260,
                                  child: Text(
                                    stats.strategy.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              DataCell(Text(stats.strategy.status)),
                              DataCell(Text(_number(stats.runningDays))),
                              DataCell(
                                Text(stats.completedGridCycles.toString()),
                              ),
                              DataCell(Text('${_money(stats.netPnl)} USDT')),
                              DataCell(Text(_percent(stats.returnRate))),
                              DataCell(
                                TextButton.icon(
                                  onPressed: _deletingId == stats.strategy.id
                                      ? null
                                      : () => _confirmDelete(stats.strategy),
                                  icon: const Icon(Icons.delete_outline),
                                  label: const Text('删除'),
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

  Future<void> _confirmDelete(Strategy strategy) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除策略记录'),
        content: Text('确认删除 ${strategy.name} 的展示记录？订单、成交和审计记录会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    setState(() {
      _deletingId = strategy.id;
      _message = null;
    });
    try {
      await widget.performance.archiveStrategyRecord(strategy.id);
      widget.onChanged();
    } catch (error) {
      setState(() => _message = '删除失败: $error');
    } finally {
      if (mounted) {
        setState(() => _deletingId = null);
      }
    }
  }
}

class _PeriodCards extends StatelessWidget {
  const _PeriodCards({required this.stats});

  final StrategyPerformanceStats stats;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final period in stats.periods)
          _MetricCard(
            period.label,
            '${_money(period.pnl)} USDT / ${_percent(period.returnRate)}',
          ),
      ],
    );
  }
}

class _AnnualizedCard extends StatelessWidget {
  const _AnnualizedCard({required this.stats});

  final StrategyPerformanceStats stats;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: stats.sampleInsufficient ? Colors.orange.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('年化收益率', style: Theme.of(context).textTheme.titleMedium),
            if (stats.sampleInsufficient)
              const Padding(
                padding: EdgeInsets.only(top: 6, bottom: 6),
                child: Text('运行时间少于7天：样本不足，仅供参考。'),
              ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _MetricCard(
                  '已实现年化',
                  stats.completedGridCycles == 0
                      ? '暂无已完成循环'
                      : _percent(stats.realizedOnlyAnnualizedReturn),
                ),
                _MetricCard('包含未实现盈亏年化', _percent(stats.annualizedReturn)),
                _MetricCard('最大浮亏', '${_money(stats.maxFloatingLoss)} USDT'),
                _MetricCard('最大回撤', '${_money(stats.maxDrawdown)} USDT'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({required this.stats});

  final StrategyPerformanceStats stats;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('收益拆分', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _MetricCard(
                  '已实现网格收益',
                  '${_money(stats.spotGridRealizedPnl)} USDT',
                ),
                _MetricCard(
                  '未实现现货盈亏',
                  '${_money(stats.unrealizedSpotPnl)} USDT',
                ),
                _MetricCard('现货手续费', '${_money(stats.spotFees)} USDT'),
                _MetricCard(
                  '对冲已实现盈亏',
                  '${_money(stats.futuresRealizedPnl)} USDT',
                ),
                _MetricCard(
                  '对冲未实现盈亏',
                  '${_money(stats.futuresUnrealizedPnl)} USDT',
                ),
                _MetricCard('资金费率', '${_money(stats.fundingFee)} USDT'),
                _MetricCard('当前净收益', '${_money(stats.netPnl)} USDT'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NoCompletedCycleNotice extends StatelessWidget {
  const _NoCompletedCycleNotice({required this.stats});

  final StrategyPerformanceStats stats;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.blueGrey.shade50,
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          '当前还没有完成 BUY→SELL 闭环，因此已实现网格收益为 0。'
          '当前净收益主要来自未卖出 BTC 的市价波动和手续费。',
        ),
      ),
    );
  }
}

class _RebuildCyclesCard extends StatefulWidget {
  const _RebuildCyclesCard({required this.strategyId, required this.onRebuilt});

  final String strategyId;
  final VoidCallback onRebuilt;

  @override
  State<_RebuildCyclesCard> createState() => _RebuildCyclesCardState();
}

class _RebuildCyclesCardState extends State<_RebuildCyclesCard> {
  String _message = '';
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('完成循环修复', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _running ? null : _rebuild,
              icon: const Icon(Icons.build),
              label: const Text('重建已完成循环'),
            ),
            if (_message.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(_message),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _rebuild() async {
    setState(() {
      _running = true;
      _message = '正在重建已完成循环...';
    });
    try {
      final service = Get.find<CompletedGridCycleService>();
      final report = await service.rebuildForStrategy(widget.strategyId);
      setState(() => _message = report.toDisplayText());
      widget.onRebuilt();
    } catch (error) {
      setState(() => _message = '重建失败: $error');
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }
}

class _MetricTable extends StatelessWidget {
  const _MetricTable({required this.stats});

  final StrategyPerformanceStats stats;

  @override
  Widget build(BuildContext context) {
    final rows = [
      ('策略总投入资金', '${_money(stats.initialCapital)} USDT'),
      ('当前现货余额', '${_money(stats.currentSpotBalance)} USDT'),
      ('当前合约保证金', '${_money(stats.currentFuturesMargin)} USDT'),
      ('已完成网格循环次数', stats.completedGridCycles.toString()),
      ('已实现现货网格利润', '${_money(stats.spotGridRealizedPnl)} USDT'),
      ('未实现现货盈亏', '${_money(stats.unrealizedSpotPnl)} USDT'),
      ('合约对冲已实现盈亏', '${_money(stats.futuresRealizedPnl)} USDT'),
      ('合约未实现盈亏', '${_money(stats.futuresUnrealizedPnl)} USDT'),
      ('资金费率收入/支出', '${_money(stats.fundingFee)} USDT'),
      ('现货手续费', '${_money(stats.spotFees)} USDT'),
      ('合约手续费', '${_money(stats.futuresFees)} USDT'),
      ('当前总净值', '${_money(stats.currentNetWorth)} USDT'),
      ('策略运行天数', _number(stats.runningDays)),
      ('实际收益率', _percent(stats.returnRate)),
      ('年化收益率', _percent(stats.annualizedReturn)),
      ('净收益公式', '当前总净值 - 策略总投入资金'),
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
                cells: [
                  DataCell(Text(row.$1)),
                  DataCell(SelectableText(row.$2)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 230,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 6),
              SelectableText(
                value,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _money(Decimal value) => _number(value);

String _percent(Decimal rate) {
  final percent = rate * Decimal.fromInt(100);
  return '${_number(percent)}%';
}

String _number(Decimal value) {
  final fixed = value.toDouble().toStringAsFixed(3);
  return fixed
      .replaceFirst(RegExp(r'\.?0+$'), '')
      .replaceFirst(RegExp(r'^-0$'), '0');
}
