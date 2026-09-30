import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../services/app_ui_settings.dart';
import '../services/execution/auto_spot_grid_execution_service.dart';
import '../strategy/paper/paper_trading_service.dart';

enum _GridLifecycleFilter {
  all,
  waitingBuy,
  open,
  waitingSell,
  replacementFailed,
  completed,
  error,
}

class GridPage extends StatefulWidget {
  const GridPage({super.key});

  @override
  State<GridPage> createState() => _GridPageState();
}

class _GridPageState extends State<GridPage> {
  _GridLifecycleFilter _filter = _GridLifecycleFilter.all;
  final _expanded = <String>{};
  String _message = '';
  Timer? _syncTimer;
  bool _syncBusy = false;

  @override
  void initState() {
    super.initState();
    _syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_syncActiveGridStatus()),
    );
    unawaited(_syncActiveGridStatus());
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }

  Future<void> _syncActiveGridStatus() async {
    if (_syncBusy || !mounted) return;
    _syncBusy = true;
    try {
      final db = Get.find<AppDatabase>();
      final liveGrid = Get.find<AutoSpotGridExecutionService>();
      final symbol =
          Get.find<SymbolWorkspaceController>().activeSymbol.value?.symbol;
      if (symbol == null) return;
      if (await AppUiSettings.hideSpotUiForSymbol(db, symbol: symbol)) return;
      final strategy = await liveGrid.activeStrategy(symbol: symbol);
      if (strategy == null ||
          strategy.environment != AutoSpotGridExecutionService.environment) {
        return;
      }
      await liveGrid.syncGridStatus(strategy.id);
    } catch (_) {
      // 页面定时同步失败不打断用户操作，手动同步会显示具体错误。
    } finally {
      _syncBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final liveGrid = Get.find<AutoSpotGridExecutionService>();
    final paper = Get.find<PaperTradingService>();
    return Scaffold(
      appBar: AppBar(title: const Text('当前策略完整网格生命周期')),
      body: Obx(() {
        final active = Get.find<SymbolWorkspaceController>().activeSymbol.value;
        final symbol = active?.symbol;
        return StreamBuilder<bool>(
          stream: AppUiSettings.watchHideSpotUiForSymbol(
            Get.find<AppDatabase>(),
            symbol: symbol,
          ),
          initialData: false,
          builder: (context, hideSnapshot) {
            if (hideSnapshot.data ?? false) {
              return const Center(
                child: Text('现货网格页面已隐藏。请在 Strategy 页面查看合约 LONG 网格策略。'),
              );
            }
            if (active == null || symbol == null) {
              return const Center(child: Text('请先添加交易币对'));
            }
            return StreamBuilder<Strategy?>(
              key: ValueKey('live-grid-$symbol'),
              stream: liveGrid.watchActiveStrategy(symbol: symbol),
              builder: (context, liveSnapshot) {
                final liveStrategy = liveSnapshot.data;
                if (liveStrategy != null) {
                  if (liveStrategy.symbol != symbol) {
                    return Center(
                      child: Text(
                        '当前页面币对与策略币对不一致，已阻止加载。\nactiveSymbol=$symbol strategy.symbol=${liveStrategy.symbol}',
                        style: const TextStyle(color: Colors.red),
                      ),
                    );
                  }
                  return _LiveGridLifecycleView(
                    liveGrid: liveGrid,
                    strategy: liveStrategy,
                    filter: _filter,
                    expanded: _expanded,
                    message: _message,
                    onFilterChanged: (value) => setState(() => _filter = value),
                    onToggleExpanded: (id) {
                      setState(() {
                        if (!_expanded.add(id)) {
                          _expanded.remove(id);
                        }
                      });
                    },
                    onMessage: (value) => setState(() => _message = value),
                  );
                }
                return StreamBuilder<Strategy?>(
                  stream: paper.watchActiveStrategy(),
                  builder: (context, paperSnapshot) {
                    final paperStrategy = paperSnapshot.data;
                    if (paperStrategy == null ||
                        paperStrategy.symbol != symbol) {
                      return Center(
                        child: Text(
                          '当前 ${active.displayName} 还没有策略，请先创建 ${active.displayName} 策略。',
                        ),
                      );
                    }
                    return StreamBuilder<List<GridLevel>>(
                      stream: paper.watchGridLevels(paperStrategy.id),
                      builder: (context, snapshot) {
                        final levels = snapshot.data ?? const [];
                        return _PaperGridTable(
                          strategy: paperStrategy,
                          levels: levels,
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      }),
    );
  }
}

class _LiveGridLifecycleView extends StatelessWidget {
  const _LiveGridLifecycleView({
    required this.liveGrid,
    required this.strategy,
    required this.filter,
    required this.expanded,
    required this.message,
    required this.onFilterChanged,
    required this.onToggleExpanded,
    required this.onMessage,
  });

  final AutoSpotGridExecutionService liveGrid;
  final Strategy strategy;
  final _GridLifecycleFilter filter;
  final Set<String> expanded;
  final String message;
  final ValueChanged<_GridLifecycleFilter> onFilterChanged;
  final ValueChanged<String> onToggleExpanded;
  final ValueChanged<String> onMessage;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<GridLevel>>(
      stream: liveGrid.watchGridLevels(strategy.id),
      builder: (context, levelSnapshot) {
        return StreamBuilder<List<Order>>(
          stream: liveGrid.watchGridOrders(strategy.id),
          builder: (context, orderSnapshot) {
            final db = Get.find<AppDatabase>();
            return StreamBuilder<List<CompletedGridCycle>>(
              stream:
                  (db.select(db.completedGridCycles)..where(
                    (tbl) => tbl.strategyId.equals(strategy.id),
                  )).watch(),
              builder: (context, cycleSnapshot) {
                return StreamBuilder<List<ExchangeOpenOrder>>(
                  stream: liveGrid.watchLiveSpotGridExchangeOpenOrders(
                    symbol: strategy.symbol,
                  ),
                  builder: (context, exchangeSnapshot) {
                    final rows = _buildRows(
                      levels: levelSnapshot.data ?? const [],
                      orders: orderSnapshot.data ?? const [],
                    );
                    final filtered =
                        rows
                            .where((row) => _matchesFilter(row, filter))
                            .toList();
                    final stats = _GridLifecycleStats.fromRows(
                      rows,
                      completedCycles: cycleSnapshot.data?.length ?? 0,
                    );
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        return ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                minWidth: constraints.maxWidth - 32,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _Header(
                                    strategy: strategy,
                                    stats: stats,
                                    filter: filter,
                                    message: message,
                                    onFilterChanged: onFilterChanged,
                                    onSync:
                                        () => _runAction(
                                          context,
                                          title: '同步 Binance',
                                          message:
                                              '将查询当前策略 Binance 挂单、历史订单和成交，并检测缺失反向单。不会自动删除历史记录。',
                                          action: () async {
                                            await liveGrid.syncGridStatus(
                                              strategy.id,
                                            );
                                            onMessage(
                                              '同步完成：已刷新 Binance 订单、成交和网格生命周期。',
                                            );
                                          },
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  _LifecycleTable(
                                    rows: filtered,
                                    expanded: expanded,
                                    liveGrid: liveGrid,
                                    onToggleExpanded: onToggleExpanded,
                                    onMessage: onMessage,
                                  ),
                                  const SizedBox(height: 20),
                                  _ExchangeOpenOrdersTable(
                                    orders: exchangeSnapshot.data ?? const [],
                                    liveGrid: liveGrid,
                                    strategyId: strategy.id,
                                    onMessage: onMessage,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  bool _matchesFilter(_GridLifecycleRow row, _GridLifecycleFilter filter) {
    return switch (filter) {
      _GridLifecycleFilter.all => true,
      _GridLifecycleFilter.waitingBuy =>
        row.cycleStatus == 'waitingBuy' || row.cycleStatus == 'buySubmitting',
      _GridLifecycleFilter.open =>
        row.cycleStatus == 'buyOpen' ||
            row.cycleStatus == 'buyPartiallyFilled' ||
            row.cycleStatus == 'sellOpen' ||
            row.cycleStatus == 'sellPartiallyFilled',
      _GridLifecycleFilter.waitingSell =>
        row.cycleStatus == 'buyFilled' ||
            row.cycleStatus == 'sellSubmitting' ||
            row.cycleStatus == 'sellOpen' ||
            row.cycleStatus == 'sellPartiallyFilled' ||
            row.cycleStatus == 'replacementMissing',
      _GridLifecycleFilter.replacementFailed =>
        row.cycleStatus == 'replacementFailed',
      _GridLifecycleFilter.completed => row.cycleStatus == 'cycleCompleted',
      _GridLifecycleFilter.error => row.cycleStatus == 'error',
    };
  }

  List<_GridLifecycleRow> _buildRows({
    required List<GridLevel> levels,
    required List<Order> orders,
  }) {
    final inertFailedOrderIds =
        orders.where(_isInertFailedSubmission).map((order) => order.id).toSet();
    final ordersByGrid = <String, List<Order>>{};
    final childByParent = <String, Order>{};
    for (final order in orders) {
      if (inertFailedOrderIds.contains(order.id) ||
          (order.parentOrderId != null &&
              inertFailedOrderIds.contains(order.parentOrderId))) {
        continue;
      }
      if (order.gridLevelId != null) {
        ordersByGrid.putIfAbsent(order.gridLevelId!, () => []).add(order);
      }
      if (order.parentOrderId != null) {
        final existing = childByParent[order.parentOrderId!];
        if (existing == null || order.createdAt.isAfter(existing.createdAt)) {
          childByParent[order.parentOrderId!] = order;
        }
      }
    }
    for (final list in ordersByGrid.values) {
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return [
      for (final level in levels)
        _GridLifecycleRow.from(
          level: level,
          orders: ordersByGrid[level.id] ?? const [],
          childByParent: childByParent,
        ),
    ];
  }

  bool _isInertFailedSubmission(Order order) {
    if (!_isLocalOnlyZeroFillGridSubmission(order)) {
      return false;
    }
    return order.status == 'failed' ||
        (order.status == 'unknown' &&
            _isDefinitiveLocalRejectedSubmission(order));
  }

  bool _isDefinitiveLocalRejectedSubmission(Order order) {
    if (!_isLocalOnlyZeroFillGridSubmission(order)) {
      return false;
    }
    final message =
        '${order.errorCode ?? ''} ${order.errorMessage ?? ''}'.toLowerCase();
    if (message.trim().isEmpty) {
      return false;
    }
    return message.contains('-2010') ||
        message.contains('-2013') ||
        message.contains('-1013') ||
        message.contains('order does not exist') ||
        message.contains('insufficient balance') ||
        message.contains('requested action') ||
        message.contains('filter failure') ||
        message.contains('min_notional') ||
        message.contains('notional') ||
        message.contains('lot_size') ||
        message.contains('precision is over') ||
        message.contains('illegal characters');
  }

  bool _isLocalOnlyZeroFillGridSubmission(Order order) {
    final exchangeOrderId = order.exchangeOrderId;
    final purpose = order.purpose;
    return order.source == AutoSpotGridExecutionService.source &&
        order.marketType == 'spot' &&
        (purpose == 'gridBuy' || purpose == 'gridSell') &&
        (exchangeOrderId == null || exchangeOrderId.isEmpty) &&
        _decimal(order.executedQuantity) == Decimal.zero;
  }

  Future<void> _runAction(
    BuildContext context, {
    required String title,
    required String message,
    required Future<void> Function() action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(title),
            content: SelectableText(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认执行'),
              ),
            ],
          ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await action();
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('操作完成')));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('操作失败：$error')));
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.strategy,
    required this.stats,
    required this.filter,
    required this.message,
    required this.onFilterChanged,
    required this.onSync,
  });

  final Strategy strategy;
  final _GridLifecycleStats stats;
  final _GridLifecycleFilter filter;
  final String message;
  final ValueChanged<_GridLifecycleFilter> onFilterChanged;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final filters = {
      _GridLifecycleFilter.all: '全部',
      _GridLifecycleFilter.waitingBuy: '等待/提交BUY',
      _GridLifecycleFilter.open: 'Binance挂单',
      _GridLifecycleFilter.waitingSell: '已买入待卖出',
      _GridLifecycleFilter.replacementFailed: '补单失败',
      _GridLifecycleFilter.completed: '已完成循环',
      _GridLifecycleFilter.error: '异常',
    };
    final cards = [
      _Stat('网格总数', stats.total),
      _Stat('等待BUY', stats.planned),
      _Stat('Binance挂单', stats.open),
      _Stat('已买入待卖出', stats.waitingReplacement),
      _Stat('自动补单中', stats.replacementSubmitting),
      _Stat('补单失败', stats.replacementFailed),
      _Stat('已完成循环', stats.completed),
      _Stat('异常', stats.error),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '当前策略：${strategy.name} / ${strategy.status}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            FilledButton.icon(
              onPressed: onSync,
              icon: const Icon(Icons.sync),
              label: const Text('同步 Binance'),
            ),
          ],
        ),
        if (message.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText(message),
        ],
        const SizedBox(height: 10),
        SizedBox(
          height: 82,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cards.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final item = cards[index];
              return Card(
                child: SizedBox(
                  width: 120,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.label),
                        const SizedBox(height: 6),
                        Text(
                          item.value.toString(),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in filters.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: filter == entry.key,
                onSelected: (_) => onFilterChanged(entry.key),
              ),
          ],
        ),
      ],
    );
  }
}

class _LifecycleTable extends StatelessWidget {
  const _LifecycleTable({
    required this.rows,
    required this.expanded,
    required this.liveGrid,
    required this.onToggleExpanded,
    required this.onMessage,
  });

  final List<_GridLifecycleRow> rows;
  final Set<String> expanded;
  final AutoSpotGridExecutionService liveGrid;
  final ValueChanged<String> onToggleExpanded;
  final ValueChanged<String> onMessage;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Center(child: Text('当前条件下没有网格记录'));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 14,
        horizontalMargin: 10,
        columns: const [
          DataColumn(label: Text('展开')),
          DataColumn(label: Text('网格编号')),
          DataColumn(label: Text('当前方向')),
          DataColumn(label: Text('BUY价格')),
          DataColumn(label: Text('SELL价格')),
          DataColumn(label: Text('计划数量')),
          DataColumn(label: Text('计划金额')),
          DataColumn(label: Text('本地计划状态')),
          DataColumn(label: Text('生命周期状态')),
          DataColumn(label: Text('Binance订单状态')),
          DataColumn(label: Text('当前订单ID')),
          DataColumn(label: Text('Client Order ID')),
          DataColumn(label: Text('父订单ID')),
          DataColumn(label: Text('配对订单ID')),
          DataColumn(label: Text('已成交数量')),
          DataColumn(label: Text('成交均价')),
          DataColumn(label: Text('成交时间')),
          DataColumn(label: Text('反向单')),
          DataColumn(label: Text('是否需要补单')),
          DataColumn(label: Text('最近错误')),
          DataColumn(label: Text('更新时间')),
          DataColumn(label: Text('操作')),
        ],
        rows: [for (final row in rows) _row(context, row)],
      ),
    );
  }

  DataRow _row(BuildContext context, _GridLifecycleRow row) {
    final isExpanded = expanded.contains(row.id);
    return DataRow(
      color: WidgetStatePropertyAll(
        row.needsReplacement ? Colors.orange.shade50 : null,
      ),
      cells: [
        DataCell(
          IconButton(
            icon: Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
            onPressed: () => onToggleExpanded(row.id),
          ),
        ),
        DataCell(Text(row.level.gridIndex.toString())),
        DataCell(Text(row.currentSide)),
        DataCell(Text(row.buyPrice)),
        DataCell(Text(row.sellPrice)),
        DataCell(Text(row.level.plannedQuantity)),
        DataCell(Text(row.level.plannedQuoteAmount)),
        DataCell(Text(_localStatus(row.level.status))),
        DataCell(
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_cycleStatus(row.cycleStatus)),
              if (row.needsReplacement)
                FilledButton.tonal(
                  onPressed: () => _confirmReplacement(context, row),
                  child: Text('补${_replacementSideFor(row)}'),
                ),
            ],
          ),
        ),
        DataCell(
          Text(_orderStatus(row.currentOrder?.status ?? 'notSubmitted')),
        ),
        DataCell(_narrow(row.currentOrder?.id ?? '-')),
        DataCell(_narrow(row.currentOrder?.clientOrderId ?? '-')),
        DataCell(
          _narrow(
            row.parentOrder?.id ?? row.currentOrder?.parentOrderId ?? '-',
          ),
        ),
        DataCell(_narrow(row.replacementOrder?.id ?? '-')),
        DataCell(Text(row.currentOrder?.executedQuantity ?? '0')),
        DataCell(Text(row.currentOrder?.averagePrice ?? '-')),
        DataCell(
          Text(
            row.filledAt == null ? '-' : _df.format(row.filledAt!.toLocal()),
          ),
        ),
        DataCell(Text(row.replacementOrder?.status ?? '-')),
        DataCell(Text(row.needsReplacement ? '是' : '否')),
        DataCell(_narrow(row.currentOrder?.errorMessage ?? '-')),
        DataCell(Text(_df.format(row.updatedAt.toLocal()))),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Tooltip(
                  message:
                      row.canSubmitBuy
                          ? '点击后会再次检查同网格活动订单、本地同价订单和 Binance 同价挂单'
                          : '当前状态可能不能挂单；点击后仍会执行完整检查并显示原因',
                  child: FilledButton(
                    onPressed: () => _confirmSubmitBuy(context, row),
                    child: const Text('挂单'),
                  ),
                ),
              ),
              if (row.needsReplacement)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilledButton(
                    onPressed: () => _confirmReplacement(context, row),
                    child: Text('补${_replacementSideFor(row)}'),
                  ),
                ),
              OutlinedButton(
                onPressed: () => _showTimeline(context, row),
                child: const Text('时间线'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmSubmitBuy(
    BuildContext context,
    _GridLifecycleRow row,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('确认挂单到 Binance'),
            content: SizedBox(
              width: 560,
              child: SelectableText(
                '网格编号: ${row.level.gridIndex}\n'
                '方向: BUY\n'
                'BUY价格: ${row.buyPrice}\n'
                'SELL价格: ${row.sellPrice}\n'
                '计划数量: ${row.level.plannedQuantity}\n'
                '计划金额: ${row.level.plannedQuoteAmount}\n\n'
                '提交前会检查：\n'
                '1. 该网格没有活动订单；\n'
                '2. 本地没有同策略同方向同价格活动订单；\n'
                '3. Binance 当前没有同方向同价格挂单。',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认挂单到Binance'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      final orderId = await liveGrid.submitWaitingBuyGridLevel(row.level.id);
      onMessage('挂单完成：orderId=$orderId');
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('挂单完成：$orderId')));
    } catch (error) {
      onMessage('挂单失败：$error');
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('挂单失败：$error')));
    }
  }

  Future<void> _confirmReplacement(
    BuildContext context,
    _GridLifecycleRow row,
  ) async {
    final parent = row.currentOrder;
    if (parent == null) return;
    try {
      final preview = await liveGrid.previewReplacementOrder(parent.id);
      final hasExistingReplacement = preview.existingReplacementOrderId != null;
      final existingIsLocalOnly = preview.existingReplacementIsLocalOnly;
      final actionLabel =
          existingIsLocalOnly
              ? '提交本地反向单到Binance'
              : hasExistingReplacement
              ? '关联已有反向单'
              : '确认补单到Binance';
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text(actionLabel),
              content: SizedBox(
                width: 620,
                child: SingleChildScrollView(
                  child: SelectableText(
                    '父订单方向: ${preview.parentOrder.side}\n'
                    '父订单成交价: ${preview.parentOrder.averagePrice ?? preview.parentOrder.price ?? '-'}\n'
                    '父订单成交数量: ${preview.parentOrder.executedQuantity}\n'
                    '计划反向方向: ${preview.replacementSide}\n'
                    '计划反向价格: ${preview.replacementPrice}\n'
                    '计划反向数量: ${preview.replacementQuantity}\n'
                    '当前Bid/Ask: ${preview.currentBid} / ${preview.currentAsk}\n'
                    '预计金额: ${preview.notional}\n'
                    'minQty: ${preview.minQty}\n'
                    'minNotional: ${preview.minNotional}\n'
                    'tickSize: ${preview.tickSize}\n'
                    'stepSize: ${preview.stepSize}\n'
                    '已存在paired/replacement: ${preview.existingReplacementOrderId ?? '-'}\n'
                    '已有反向单类型: ${existingIsLocalOnly
                        ? '本地未提交'
                        : hasExistingReplacement
                        ? '已提交/可关联'
                        : '无'}\n'
                    '是否存在类似活动订单: ${preview.hasDuplicateActiveOrder ? '是' : '否'}\n'
                    '检查结果: ${preview.reason}',
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed:
                      (preview.canSubmit || hasExistingReplacement)
                          ? () => Navigator.of(context).pop(true)
                          : null,
                  child: Text(actionLabel),
                ),
              ],
            ),
      );
      if (confirmed != true) return;
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              existingIsLocalOnly
                  ? '正在提交本地反向单到 Binance...'
                  : hasExistingReplacement
                  ? '正在关联已有反向单...'
                  : '正在补单到 Binance...',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      final replacementId = await liveGrid.createReplacementForOrder(parent.id);
      await liveGrid.refreshGridLifecycle(row.level.strategyId);
      final resultMessage =
          existingIsLocalOnly
              ? '本地反向单已提交到 Binance：replacementOrderId=$replacementId'
              : hasExistingReplacement
              ? '已关联已有反向单：replacementOrderId=$replacementId'
              : '补单完成：replacementOrderId=$replacementId';
      onMessage(resultMessage);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(resultMessage)));
    } catch (error) {
      onMessage('补单失败：$error');
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('补单失败：$error')));
    }
  }

  void _showTimeline(BuildContext context, _GridLifecycleRow row) {
    showDialog<void>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('网格 ${row.level.gridIndex} 时间线'),
            content: SizedBox(
              width: 780,
              child: SingleChildScrollView(
                child: SelectableText(
                  row.timeline.isEmpty
                      ? '暂无订单历史'
                      : row.timeline
                          .map(
                            (order) =>
                                '${_df.format(order.createdAt.toLocal())} '
                                '${order.side} ${order.orderType} ${order.status} '
                                'price=${order.price ?? '-'} qty=${order.originalQuantity} '
                                'executed=${order.executedQuantity} parent=${order.parentOrderId ?? '-'} '
                                'client=${order.clientOrderId}',
                          )
                          .join('\n'),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
    );
  }

  Widget _narrow(String value) {
    return SizedBox(
      width: 150,
      child: Tooltip(
        message: value,
        child: Text(value, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _ExchangeOpenOrdersTable extends StatelessWidget {
  const _ExchangeOpenOrdersTable({
    required this.orders,
    required this.liveGrid,
    required this.strategyId,
    required this.onMessage,
  });

  final List<ExchangeOpenOrder> orders;
  final AutoSpotGridExecutionService liveGrid;
  final String strategyId;
  final ValueChanged<String> onMessage;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Binance 当前挂单', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (orders.isEmpty)
          const Text('当前币对没有本程序现货挂单')
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('方向')),
                DataColumn(label: Text('限价')),
                DataColumn(label: Text('数量')),
                DataColumn(label: Text('已成交')),
                DataColumn(label: Text('剩余')),
                DataColumn(label: Text('状态')),
                DataColumn(label: Text('Binance Order ID')),
                DataColumn(label: Text('Client Order ID')),
                DataColumn(label: Text('提交时间')),
                DataColumn(label: Text('操作')),
              ],
              rows: [
                for (final order in orders)
                  DataRow(
                    cells: [
                      DataCell(Text(order.side)),
                      DataCell(Text(order.price)),
                      DataCell(Text(order.originalQuantity)),
                      DataCell(Text(order.executedQuantity)),
                      DataCell(
                        Text(
                          _remaining(
                            order.originalQuantity,
                            order.executedQuantity,
                          ),
                        ),
                      ),
                      DataCell(Text(order.status)),
                      DataCell(Text(order.exchangeOrderId)),
                      DataCell(Text(order.clientOrderId)),
                      DataCell(Text(_df.format(order.createdAt.toLocal()))),
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            OutlinedButton(
                              onPressed: () async {
                                try {
                                  await liveGrid.liveExecution.querySpotOrder(
                                    order.clientOrderId,
                                  );
                                  await liveGrid.refreshGridLifecycle(
                                    strategyId,
                                  );
                                  onMessage('查询完成：${order.clientOrderId}');
                                } catch (error) {
                                  onMessage('查询失败：$error');
                                }
                              },
                              child: const Text('查询'),
                            ),
                            const SizedBox(width: 6),
                            OutlinedButton(
                              onPressed: () => _confirmCancel(context, order),
                              child: const Text('撤单'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _confirmCancel(
    BuildContext context,
    ExchangeOpenOrder order,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('撤销 Binance 挂单'),
            content: Text(
              '确认撤销 ${order.side} ${order.originalQuantity} @ ${order.price} ?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认撤单'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      await liveGrid.liveExecution.cancelSpotOrder(order.clientOrderId);
      await liveGrid.refreshGridLifecycle(strategyId);
      onMessage('撤单完成：${order.clientOrderId}');
    } catch (error) {
      onMessage('撤单失败：$error');
    }
  }
}

class _GridLifecycleRow {
  const _GridLifecycleRow({
    required this.id,
    required this.level,
    required this.buyPrice,
    required this.sellPrice,
    required this.currentOrder,
    required this.parentOrder,
    required this.replacementOrder,
    required this.timeline,
    required this.cycleStatus,
    required this.currentSide,
    required this.needsReplacement,
    required this.updatedAt,
    required this.filledAt,
  });

  final String id;
  final GridLevel level;
  final String buyPrice;
  final String sellPrice;
  final Order? currentOrder;
  final Order? parentOrder;
  final Order? replacementOrder;
  final List<Order> timeline;
  final String cycleStatus;
  final String currentSide;
  final bool needsReplacement;
  final DateTime updatedAt;
  final DateTime? filledAt;

  bool get canSubmitBuy {
    final order = currentOrder;
    final retryableFailedBuy =
        order != null &&
        order.side == 'BUY' &&
        {'cancelled', 'rejected', 'expired'}.contains(order.status) &&
        _decimal(order.executedQuantity) == Decimal.zero;
    return (order == null || retryableFailedBuy) &&
        (currentSide == 'BUY' || retryableFailedBuy) &&
        ({
              'waitingBuy',
              'planned',
              'ready',
              'waiting',
              'error',
            }.contains(cycleStatus) ||
            retryableFailedBuy);
  }

  factory _GridLifecycleRow.from({
    required GridLevel level,
    required List<Order> orders,
    required Map<String, Order> childByParent,
  }) {
    final current = _currentLifecycleOrder(orders);
    final parent =
        current?.parentOrderId == null
            ? null
            : orders
                .where((order) => order.id == current!.parentOrderId)
                .cast<Order?>()
                .firstOrNull;
    final candidateReplacement =
        current == null ? null : childByParent[current.id];
    final replacement =
        current != null &&
                candidateReplacement != null &&
                candidateReplacement.side != current.side &&
                candidateReplacement.createdAt.isAfter(current.createdAt)
            ? candidateReplacement
            : null;
    final missingReplacement =
        current != null &&
        ['filled', 'cancelled'].contains(current.status) &&
        _decimal(current.executedQuantity) > Decimal.zero &&
        replacement == null;
    final status = _deriveCycleStatus(
      level: level,
      current: current,
      replacement: replacement,
      missingReplacement: missingReplacement,
    );
    return _GridLifecycleRow(
      id: '${level.id}_${current?.id ?? 'planned'}',
      level: level,
      buyPrice: _fixedBuyPrice(level),
      sellPrice: _fixedSellPrice(level),
      currentOrder: current,
      parentOrder: parent,
      replacementOrder: replacement,
      timeline: orders.reversed.toList(),
      cycleStatus: status,
      currentSide: _currentSideFor(status, current),
      needsReplacement:
          status == 'buyFilled' ||
          status == 'sellFilled' ||
          status == 'replacementMissing' ||
          status == 'replacementFailed',
      updatedAt: current?.updatedAt ?? level.updatedAt,
      filledAt: current?.completedAt,
    );
  }

  static String _deriveCycleStatus({
    required GridLevel level,
    required Order? current,
    required Order? replacement,
    required bool missingReplacement,
  }) {
    if (current == null) {
      return level.status == 'ready' ? 'waitingBuy' : level.status;
    }
    if (current.side == 'BUY') {
      if (current.status == 'created' || current.status == 'submitting') {
        return 'buySubmitting';
      }
      if (current.status == 'new') return 'buyOpen';
      if (current.status == 'partiallyFilled') return 'buyPartiallyFilled';
      if (current.status == 'filled') {
        if (missingReplacement &&
            level.lifecycleStatus == 'replacementFailed') {
          return 'replacementFailed';
        }
        if (replacement == null) return 'buyFilled';
        if (replacement.side == 'SELL' &&
            (replacement.status == 'created' ||
                replacement.status == 'submitting')) {
          return 'sellSubmitting';
        }
        if (replacement.side == 'SELL' && replacement.status == 'new') {
          return 'sellOpen';
        }
        if (replacement.side == 'SELL' &&
            replacement.status == 'partiallyFilled') {
          return 'sellPartiallyFilled';
        }
        if (replacement.side == 'SELL' && replacement.status == 'filled') {
          return 'cycleCompleted';
        }
        return 'replacementFailed';
      }
    }
    if (current.side == 'SELL') {
      if (current.status == 'created' || current.status == 'submitting') {
        return 'sellSubmitting';
      }
      if (current.status == 'new') return 'sellOpen';
      if (current.status == 'partiallyFilled') return 'sellPartiallyFilled';
      if (current.status == 'filled') {
        if (missingReplacement &&
            level.lifecycleStatus == 'replacementFailed') {
          return 'replacementFailed';
        }
        if (replacement == null) return 'sellFilled';
        if (replacement.side == 'BUY' &&
            (replacement.status == 'created' ||
                replacement.status == 'submitting')) {
          return 'buySubmitting';
        }
        if (replacement.side == 'BUY' && replacement.status == 'new') {
          return 'buyOpen';
        }
        if (replacement.side == 'BUY' &&
            replacement.status == 'partiallyFilled') {
          return 'buyPartiallyFilled';
        }
        return 'replacementFailed';
      }
    }
    if (missingReplacement) return 'replacementMissing';
    if (current.status == 'unknown' || current.status == 'rejected') {
      return 'error';
    }
    return current.status;
  }
}

class _GridLifecycleStats {
  const _GridLifecycleStats({
    required this.total,
    required this.planned,
    required this.open,
    required this.waitingReplacement,
    required this.replacementSubmitting,
    required this.replacementFailed,
    required this.completed,
    required this.error,
  });

  final int total;
  final int planned;
  final int open;
  final int waitingReplacement;
  final int replacementSubmitting;
  final int replacementFailed;
  final int completed;
  final int error;

  factory _GridLifecycleStats.fromRows(
    List<_GridLifecycleRow> rows, {
    required int completedCycles,
  }) {
    return _GridLifecycleStats(
      total: rows.length,
      planned:
          rows
              .where(
                (row) =>
                    row.cycleStatus == 'waitingBuy' ||
                    row.cycleStatus == 'buySubmitting',
              )
              .length,
      open:
          rows
              .where(
                (row) => [
                  'buyOpen',
                  'buyPartiallyFilled',
                  'sellOpen',
                  'sellPartiallyFilled',
                ].contains(row.cycleStatus),
              )
              .length,
      waitingReplacement:
          rows
              .where(
                (row) =>
                    row.cycleStatus == 'buyFilled' ||
                    row.cycleStatus == 'sellSubmitting' ||
                    row.cycleStatus == 'sellOpen' ||
                    row.cycleStatus == 'sellPartiallyFilled' ||
                    row.cycleStatus == 'replacementMissing',
              )
              .length,
      replacementSubmitting:
          rows.where((row) => row.cycleStatus == 'sellSubmitting').length,
      replacementFailed:
          rows.where((row) => row.cycleStatus == 'replacementFailed').length,
      completed: completedCycles,
      error: rows.where((row) => row.cycleStatus == 'error').length,
    );
  }
}

class _Stat {
  const _Stat(this.label, this.value);
  final String label;
  final int value;
}

class _PaperGridTable extends StatelessWidget {
  const _PaperGridTable({required this.strategy, required this.levels});

  final Strategy strategy;
  final List<GridLevel> levels;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Paper 网格 - ${strategy.status}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('编号')),
              DataColumn(label: Text('价格')),
              DataColumn(label: Text('方向')),
              DataColumn(label: Text('数量')),
              DataColumn(label: Text('金额')),
              DataColumn(label: Text('状态')),
            ],
            rows: [
              for (final level in levels)
                DataRow(
                  cells: [
                    DataCell(Text(level.gridIndex.toString())),
                    DataCell(Text(level.price)),
                    DataCell(Text(level.plannedSide)),
                    DataCell(Text(level.plannedQuantity)),
                    DataCell(Text(level.plannedQuoteAmount)),
                    DataCell(Text(level.status)),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

final _df = DateFormat('yyyy-MM-dd HH:mm:ss');

Decimal _decimal(String value) => Decimal.tryParse(value) ?? Decimal.zero;

String _remaining(String original, String executed) {
  final value = _decimal(original) - _decimal(executed);
  return value <= Decimal.zero ? '0' : value.toString();
}

String _localStatus(String status) {
  return switch (status) {
    'waiting' => '等待生成计划',
    'ready' => '本地计划',
    'submitting' => '正在提交',
    'open' => '已提交',
    'filled' => '已成交',
    'cancelled' => '已撤销',
    'disabled' => '已禁用',
    _ => status,
  };
}

String _orderStatus(String status) {
  return switch (status) {
    'notSubmitted' => '未提交',
    'created' => '下单意图',
    'submitting' => '提交中',
    'new' => 'Binance挂单中',
    'partiallyFilled' => '部分成交',
    'filled' => '已成交',
    'cancelled' => '已撤销',
    'unknown' => '未知',
    _ => status,
  };
}

String _cycleStatus(String status) {
  return switch (status) {
    'waitingBuy' => '等待提交买单',
    'buySubmitting' => '正在提交买单',
    'buyOpen' => 'BUY挂单中',
    'buyPartiallyFilled' => 'BUY部分成交',
    'buyFilled' => 'BUY已成交，等待提交SELL',
    'sellSubmitting' => '正在提交卖单',
    'sellOpen' => 'SELL挂单中，等待卖出',
    'sellPartiallyFilled' => 'SELL部分成交',
    'sellFilled' => 'SELL已成交',
    'cycleCompleted' => '本轮完成',
    'replacementFailed' => '自动补单失败',
    'replacementMissing' => '检测到缺失反向单',
    'reconciling' => '正在对账',
    'paused' => '已暂停',
    'error' => '异常',
    _ => status,
  };
}

Order? _currentLifecycleOrder(List<Order> orders) {
  if (orders.isEmpty) {
    return null;
  }
  final active =
      orders
          .where(
            (order) => [
              'created',
              'submitting',
              'new',
              'partiallyFilled',
              'cancelling',
              'unknown',
            ].contains(order.status),
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  if (active.isNotEmpty) {
    return active.first;
  }
  final ordered = [...orders]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return ordered.first;
}

String _fixedBuyPrice(GridLevel level) {
  if (level.plannedSide == 'BUY') {
    return level.price;
  }
  return level.nextLowerPrice ?? '-';
}

String _fixedSellPrice(GridLevel level) {
  if (level.plannedSide == 'BUY') {
    return level.nextUpperPrice ?? '-';
  }
  return level.price;
}

String _currentSideFor(String status, Order? order) {
  if (order != null &&
      [
        'buySubmitting',
        'buyOpen',
        'buyPartiallyFilled',
        'sellSubmitting',
        'sellOpen',
        'sellPartiallyFilled',
      ].contains(status)) {
    return order.side;
  }
  if (status == 'waitingBuy' || status == 'cycleCompleted') {
    return 'BUY';
  }
  if (status == 'buyFilled' ||
      status == 'sellFilled' ||
      status == 'replacementMissing' ||
      status == 'replacementFailed') {
    if (order?.side == 'SELL' || status == 'sellFilled') {
      return 'BUY';
    }
    return 'SELL';
  }
  return order?.side ?? '-';
}

String _replacementSideFor(_GridLifecycleRow row) {
  final order = row.currentOrder;
  if (order?.side == 'BUY') {
    return 'SELL';
  }
  if (order?.side == 'SELL') {
    return 'BUY';
  }
  return row.currentSide == 'SELL' ? 'SELL' : 'BUY';
}
