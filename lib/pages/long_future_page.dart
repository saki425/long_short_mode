import 'dart:async';

import 'package:flutter/material.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../services/binance/auth/binance_request_exception.dart';
import '../services/execution/auto_spot_grid_execution_service.dart';

enum _LongFutureLifecycleFilter {
  all,
  waitingBuy,
  open,
  waitingSell,
  sellSubmitting,
  completed,
  error,
}

class _LongFutureLifecycleStats {
  const _LongFutureLifecycleStats({
    required this.total,
    required this.waitingBuy,
    required this.open,
    required this.waitingSell,
    required this.sellSubmitting,
    required this.completed,
    required this.error,
  });

  final int total;
  final int waitingBuy;
  final int open;
  final int waitingSell;
  final int sellSubmitting;
  final int completed;
  final int error;
}

class LongFuturePage extends StatelessWidget {
  const LongFuturePage({super.key});

  @override
  Widget build(BuildContext context) {
    final workspace = Get.find<SymbolWorkspaceController>();
    final liveGrid = Get.find<AutoSpotGridExecutionService>();
    return Obx(() {
      final active = workspace.activeSymbol.value;
      if (active == null) {
        return const Center(child: Text('请先添加交易币对。'));
      }
      return StreamBuilder<Strategy?>(
        stream: liveGrid.watchActiveFuturesGridStrategy(symbol: active.symbol),
        builder: (context, strategySnapshot) {
          final strategy = strategySnapshot.data;
          return Scaffold(
            appBar: AppBar(title: const Text('当前策略完整网格生命周期')),
            body: strategy == null
                ? Center(
                    child: Text(
                      '当前 ${active.displayName} 还没有 LIVE 合约 LONG 网格策略。\n'
                      '请在 Strategy 页面创建“合约 LONG 网格 + SHORT 对冲”策略。',
                      textAlign: TextAlign.center,
                    ),
                  )
                : _LongFutureBody(strategy: strategy, liveGrid: liveGrid),
          );
        },
      );
    });
  }
}

class _LongFutureBody extends StatefulWidget {
  const _LongFutureBody({required this.strategy, required this.liveGrid});

  final Strategy strategy;
  final AutoSpotGridExecutionService liveGrid;

  @override
  State<_LongFutureBody> createState() => _LongFutureBodyState();
}

class _LongFutureBodyState extends State<_LongFutureBody> {
  static final Map<String, StreamSubscription<dynamic>>
      _autoListenWsSubscriptions = {};
  static final Map<String, StreamSubscription<dynamic>>
      _autoListenPriceSubscriptions = {};
  static final Map<String, DateTime> _autoListenLastPriceSyncAt = {};
  static final Map<String, DateTime> _autoListenLastRestSyncAt = {};
  static final Map<String, DateTime> _autoListenRateLimitUntil = {};
  static final Set<String> _autoListenScheduledStarts = {};
  static Future<void> _autoListenStartQueue = Future.value();
  static DateTime _autoListenLastStartedAt =
      DateTime.fromMillisecondsSinceEpoch(0);

  static const _autoListenFullRestInterval = Duration(minutes: 2);
  static const _autoListenRateLimitCooldown = Duration(minutes: 2);
  static const _autoListenPriceSyncInterval = Duration(seconds: 1);
  static const _autoListenStartStaggerInterval = Duration(seconds: 12);

  bool _starting = false;
  bool _autoListening = false;
  bool _autoSyncRunning = false;
  bool _autoSyncPending = false;
  bool _restoringAutoListening = false;
  String? _loadedAutoListeningStrategyId;
  late Future<LiveSpotGridEditableConfig?> _configFuture;
  _LongFutureLifecycleFilter _filter = _LongFutureLifecycleFilter.all;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _configFuture = widget.liveGrid.loadEditableConfig(widget.strategy.id);
    unawaited(_restoreAutoListening());
  }

  @override
  void didUpdateWidget(covariant _LongFutureBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.strategy.id != widget.strategy.id) {
      _loadedAutoListeningStrategyId = null;
      _configFuture = widget.liveGrid.loadEditableConfig(widget.strategy.id);
      unawaited(_restoreAutoListening());
    }
  }

  @override
  void dispose() {
    _disposeAutoListeningRuntime(widget.strategy.id);
    unawaited(
      widget.liveGrid.liveExecution.stopFuturesUserDataStream(
        consumerKey: _autoListeningKey(widget.strategy.id),
      ),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LiveSpotGridEditableConfig?>(
      future: _configFuture,
      builder: (context, configSnapshot) {
        final config = configSnapshot.data;
        return StreamBuilder<List<Order>>(
          stream: _watchFuturesLongOrders(widget.strategy.id),
          builder: (context, orderSnapshot) {
            final ordersById = {
              for (final order in orderSnapshot.data ?? const <Order>[])
                order.id: order,
            };
            final ordersByGrid = _ordersByGrid(
              orderSnapshot.data ?? const <Order>[],
            );
            return StreamBuilder<List<GridLevel>>(
              stream: widget.liveGrid.watchGridLevels(widget.strategy.id),
              builder: (context, gridSnapshot) {
                final levels = [...(gridSnapshot.data ?? const <GridLevel>[])]
                  ..sort((a, b) => _levelPrice(b).compareTo(_levelPrice(a)));
                final stats = _longFutureStats(
                  levels: levels,
                  ordersById: ordersById,
                  ordersByGrid: ordersByGrid,
                );
                final filteredLevels = levels
                    .where(
                      (level) => _matchesLongFutureFilter(
                        level: level,
                        ordersById: ordersById,
                        ordersByGrid: ordersByGrid,
                      ),
                    )
                    .toList();
                final completedLongCycles = levels.fold<int>(
                  0,
                  (sum, level) => sum + level.cycleNumber,
                );
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _longFutureHeader(
                        context: context,
                        stats: stats,
                        completedLongCycles: completedLongCycles,
                        config: config,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'LONG 网格价格层',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: _canStart(widget.strategy) && !_starting
                                ? _startFuturesLongGrid
                                : null,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('启动 LONG 网格'),
                          ),
                          OutlinedButton.icon(
                            onPressed: !_starting
                                ? _stopFuturesLongGridCancelOpenOrders
                                : null,
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('停止并撤销未成交 LONG'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: !_starting
                                ? () => _closeFuturesPosition('LONG')
                                : null,
                            icon: const Icon(Icons.south_east),
                            label: const Text('一键平仓多单'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: !_starting
                                ? () => _closeFuturesPosition('SHORT')
                                : null,
                            icon: const Icon(Icons.north_east),
                            label: const Text('一键平仓空单'),
                          ),
                          OutlinedButton.icon(
                            onPressed: !_starting
                                ? () => setState(() => _message = '')
                                : null,
                            icon: const Icon(Icons.clear),
                            label: const Text('清空提示'),
                          ),
                          OutlinedButton.icon(
                            onPressed: !_starting ? _resetErrorLayers : null,
                            icon: const Icon(Icons.refresh),
                            label: const Text('清理失败层'),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                !_starting ? _repairReleasedLongLayers : null,
                            icon: const Icon(Icons.build_circle_outlined),
                            label: const Text('修复释放层'),
                          ),
                          OutlinedButton.icon(
                            onPressed: !_starting
                                ? () => _reconcileFuturesLongGrid(
                                      includeHistory: false,
                                    )
                                : null,
                            icon: const Icon(Icons.sync),
                            label: const Text('轻量对账'),
                          ),
                          OutlinedButton.icon(
                            onPressed: !_starting
                                ? () => _reconcileFuturesLongGrid(
                                      includeHistory: true,
                                    )
                                : null,
                            icon: const Icon(Icons.fact_check_outlined),
                            label: const Text('完整对账'),
                          ),
                          Tooltip(
                            message: '定时刷新 Binance Futures 并执行 LONG 对账',
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('自动监听'),
                                Switch(
                                  value: _autoListening,
                                  onChanged: (value) =>
                                      unawaited(_setAutoListening(value)),
                                ),
                              ],
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: !_starting && config != null
                                ? () => _configureLongEntry(config)
                                : null,
                            icon: const Icon(Icons.tune),
                            label: const Text('LONG 触发配置'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (levels.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: Text('尚未生成 LONG 网格价格层。')),
                        )
                      else if (filteredLevels.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: Text('当前筛选条件下没有 LONG 网格价格层。')),
                        )
                      else
                        _longGridTable(
                          context: context,
                          levels: filteredLevels,
                          leverage: config?.futuresLeverage ?? 1,
                          ordersById: ordersById,
                          ordersByGrid: ordersByGrid,
                        ),
                      const SizedBox(height: 24),
                      _binanceFuturesOpenOrdersSection(),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _binanceFuturesOpenOrdersSection() {
    return StreamBuilder<List<ExchangeOpenOrder>>(
      stream: _watchBinanceFuturesOpenOrders(widget.strategy.symbol),
      builder: (context, snapshot) {
        final orders = snapshot.data ?? const <ExchangeOpenOrder>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Binance Futures 当前挂单',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _starting ? null : _refreshBinanceOpenOrders,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新当前挂单'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (orders.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('当前 symbol 没有 Binance Futures 挂单。'),
              )
            else
              _HorizontalScrollArea(
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('方向')),
                    DataColumn(label: Text('持仓方向')),
                    DataColumn(label: Text('类型')),
                    DataColumn(label: Text('限价')),
                    DataColumn(label: Text('原始数量')),
                    DataColumn(label: Text('已成交')),
                    DataColumn(label: Text('剩余')),
                    DataColumn(label: Text('状态')),
                    DataColumn(label: Text('ReduceOnly')),
                    DataColumn(label: Text('Binance Order ID')),
                    DataColumn(label: Text('Client Order ID')),
                    DataColumn(label: Text('更新时间')),
                    DataColumn(label: Text('同步时间')),
                  ],
                  rows: [
                    for (final order in orders)
                      DataRow(
                        cells: [
                          DataCell(Text(order.side)),
                          DataCell(Text(order.positionSide ?? '-')),
                          DataCell(Text(order.orderType)),
                          DataCell(Text(order.price)),
                          DataCell(Text(order.originalQuantity)),
                          DataCell(Text(order.executedQuantity)),
                          DataCell(
                            Text(
                              _remainingQuantity(
                                order.originalQuantity,
                                order.executedQuantity,
                              ),
                            ),
                          ),
                          DataCell(Text(order.status)),
                          DataCell(Text(order.reduceOnly == true ? '是' : '否')),
                          DataCell(Text(order.exchangeOrderId)),
                          DataCell(_narrow(order.clientOrderId)),
                          DataCell(Text(_df.format(order.updatedAt.toLocal()))),
                          DataCell(Text(_df.format(order.syncedAt.toLocal()))),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _longFutureHeader({
    required BuildContext context,
    required _LongFutureLifecycleStats stats,
    required int completedLongCycles,
    required LiveSpotGridEditableConfig? config,
  }) {
    final filters = {
      _LongFutureLifecycleFilter.all: '全部',
      _LongFutureLifecycleFilter.waitingBuy: '等待/提交开多',
      _LongFutureLifecycleFilter.open: 'Binance挂单',
      _LongFutureLifecycleFilter.waitingSell: '已开多待平多',
      _LongFutureLifecycleFilter.sellSubmitting: '平多中',
      _LongFutureLifecycleFilter.completed: '已完成循环',
      _LongFutureLifecycleFilter.error: '异常',
    };
    final cards = [
      ('网格总数', stats.total),
      ('等待开多', stats.waitingBuy),
      ('Binance挂单', stats.open),
      ('已开多待平多', stats.waitingSell),
      ('平多中', stats.sellSubmitting),
      ('已完成循环', completedLongCycles),
      ('异常', stats.error),
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
              '当前策略：${widget.strategy.name} / ${widget.strategy.status}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            FilledButton.icon(
              onPressed: _starting
                  ? null
                  : () => _reconcileFuturesLongGrid(includeHistory: false),
              icon: const Icon(Icons.sync),
              label: const Text('轻量对账'),
            ),
            OutlinedButton.icon(
              onPressed: _starting
                  ? null
                  : () => _reconcileFuturesLongGrid(includeHistory: true),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('完整对账'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            Chip(label: Text('Symbol: ${widget.strategy.symbol}')),
            const Chip(label: Text('模式: 合约 LONG 网格')),
            Chip(label: Text('杠杆: ${config?.futuresLeverage ?? 1}x')),
            Chip(
              label: Text(
                '价格源: ${config?.futuresPriceSource ?? LiveSpotGridEditableConfig.futuresMarkPrice}',
              ),
            ),
            Chip(
              label: Text(
                '开多模式: ${_longEntryModeText(config?.longEntryTriggerMode)}',
              ),
            ),
            Chip(
              label: Text(
                '提前距离: ${config?.longEntryTriggerDistanceUsdt ?? AutoSpotGridExecutionService.defaultLongEntryTriggerDistanceUsdt} USDT',
              ),
            ),
            Chip(
              label: Text(
                '预挂层数: ${config?.longEntryPrehangLevels ?? LiveSpotGridEditableConfig.defaultLongEntryPrehangLevels}',
              ),
            ),
            Chip(
              label: Text('最大活动挂单: ${config?.maxOpenOrders ?? 4}'),
            ),
            const Chip(label: Text('持仓模式要求: Hedge Mode')),
          ],
        ),
        if (_message.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_message, maxLines: 4, overflow: TextOverflow.ellipsis),
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
                  width: 132,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.$1),
                        const SizedBox(height: 6),
                        Text(
                          item.$2.toString(),
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
                selected: _filter == entry.key,
                onSelected: (_) => setState(() => _filter = entry.key),
              ),
          ],
        ),
      ],
    );
  }

  String _longEntryModeText(String? mode) {
    return mode == LiveSpotGridEditableConfig.longEntryTriggerModePrehang
        ? '预挂多层'
        : '接近价格触发';
  }

  Future<void> _configureLongEntry(
    LiveSpotGridEditableConfig config,
  ) async {
    var mode = config.longEntryTriggerMode;
    final distanceController = TextEditingController(
      text: config.longEntryTriggerDistanceUsdt.toString(),
    );
    final prehangController = TextEditingController(
      text: config.longEntryPrehangLevels.toString(),
    );
    final maxOrdersController = TextEditingController(
      text: config.maxOpenOrders.toString(),
    );
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('LONG 下单触发配置'),
              content: SizedBox(
                width: 430,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: mode,
                        decoration: const InputDecoration(
                          labelText: 'LONG 下单触发模式',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: LiveSpotGridEditableConfig
                                .longEntryTriggerModeNearPrice,
                            child: Text('接近价格触发'),
                          ),
                          DropdownMenuItem(
                            value: LiveSpotGridEditableConfig
                                .longEntryTriggerModePrehang,
                            child: Text('预挂多层'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => mode = value);
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: distanceController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: '提前触发距离 USDT',
                          helperText: '接近价格触发模式生效；预挂多层模式忽略该值。',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: prehangController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '预挂层数',
                          helperText: '预挂模式下维护的初始/动态 BUY 层数。',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: maxOrdersController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '最大活动挂单数',
                          helperText: '所有 LONG 活动订单的硬上限。',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '预挂多层只会提交 buyPrice 不高于当前 Mark Price 的订单，不会挂高于当前价的 BUY。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop({
                      'mode': mode,
                      'distance': distanceController.text,
                      'prehangLevels': prehangController.text,
                      'maxOrders': maxOrdersController.text,
                    });
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    distanceController.dispose();
    prehangController.dispose();
    maxOrdersController.dispose();
    if (result == null || !mounted) {
      return;
    }
    final distance = Decimal.tryParse('${result['distance']}');
    final prehangLevels = int.tryParse('${result['prehangLevels']}');
    final maxOrders = int.tryParse('${result['maxOrders']}');
    if (distance == null || prehangLevels == null || maxOrders == null) {
      setState(() => _message = 'LONG 触发配置保存失败：请输入合法数字。');
      return;
    }
    try {
      await widget.liveGrid.updateFuturesLongTriggerSettings(
        widget.strategy.id,
        triggerMode: '${result['mode']}',
        triggerDistanceUsdt: distance,
        prehangLevels: prehangLevels,
        maxOpenOrders: maxOrders,
      );
      if (!mounted) return;
      setState(() {
        _configFuture = widget.liveGrid.loadEditableConfig(widget.strategy.id);
        _message = 'LONG 触发配置已保存。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'LONG 触发配置保存失败: $error');
      }
    }
  }

  Stream<List<Order>> _watchFuturesLongOrders(String strategyId) {
    final db = Get.find<AppDatabase>();
    return (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source
                    .equals(AutoSpotGridExecutionService.futuresLongSource),
          ))
        .watch();
  }

  Stream<List<ExchangeOpenOrder>> _watchBinanceFuturesOpenOrders(
    String symbol,
  ) {
    final db = Get.find<AppDatabase>();
    return (db.select(db.exchangeOpenOrders)
          ..where(
            (tbl) =>
                tbl.accountType.equals('futuresSubAccount') &
                tbl.marketType.equals('usdtFutures') &
                tbl.environment.equals('live') &
                tbl.symbol.equals(symbol.toUpperCase()),
          )
          ..orderBy([
            (tbl) => OrderingTerm(
                  expression: tbl.updatedAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .watch();
  }

  Map<String, List<Order>> _ordersByGrid(List<Order> orders) {
    final result = <String, List<Order>>{};
    for (final order in orders) {
      final gridId = order.gridLevelId;
      if (gridId == null || gridId.isEmpty) {
        continue;
      }
      result.putIfAbsent(gridId, () => <Order>[]).add(order);
    }
    for (final orders in result.values) {
      orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return result;
  }

  _LongFutureLifecycleStats _longFutureStats({
    required List<GridLevel> levels,
    required Map<String, Order> ordersById,
    required Map<String, List<Order>> ordersByGrid,
  }) {
    var waitingBuy = 0;
    var open = 0;
    var waitingSell = 0;
    var sellSubmitting = 0;
    var completed = 0;
    var error = 0;
    for (final level in levels) {
      final currentOrder = _currentOrder(level, ordersById, ordersByGrid);
      if (_isWaitingBuyCycle(level, currentOrder)) waitingBuy += 1;
      if (_isBinanceOpenCycle(level, currentOrder)) open += 1;
      if (_isWaitingSellCycle(level, currentOrder)) waitingSell += 1;
      if (_isSellSubmittingCycle(level, currentOrder)) sellSubmitting += 1;
      if (_isCompletedCycle(level, currentOrder)) completed += 1;
      if (_isErrorCycle(level, currentOrder)) error += 1;
    }
    return _LongFutureLifecycleStats(
      total: levels.length,
      waitingBuy: waitingBuy,
      open: open,
      waitingSell: waitingSell,
      sellSubmitting: sellSubmitting,
      completed: completed,
      error: error,
    );
  }

  bool _matchesLongFutureFilter({
    required GridLevel level,
    required Map<String, Order> ordersById,
    required Map<String, List<Order>> ordersByGrid,
  }) {
    final currentOrder = _currentOrder(level, ordersById, ordersByGrid);
    return switch (_filter) {
      _LongFutureLifecycleFilter.all => true,
      _LongFutureLifecycleFilter.waitingBuy => _isWaitingBuyCycle(
          level,
          currentOrder,
        ),
      _LongFutureLifecycleFilter.open => _isBinanceOpenCycle(
          level,
          currentOrder,
        ),
      _LongFutureLifecycleFilter.waitingSell => _isWaitingSellCycle(
          level,
          currentOrder,
        ),
      _LongFutureLifecycleFilter.sellSubmitting => _isSellSubmittingCycle(
          level,
          currentOrder,
        ),
      _LongFutureLifecycleFilter.completed => _isCompletedCycle(
          level,
          currentOrder,
        ),
      _LongFutureLifecycleFilter.error => _isErrorCycle(level, currentOrder),
    };
  }

  bool _isWaitingBuyCycle(GridLevel level, Order? currentOrder) {
    final status = level.lifecycleStatus ?? level.status;
    return {
          'waitingBuy',
          'planned',
          'ready',
          'buySubmitting',
        }.contains(status) ||
        (currentOrder?.side == 'BUY' &&
            {'created', 'submitting'}.contains(currentOrder?.status));
  }

  bool _isBinanceOpenCycle(GridLevel level, Order? currentOrder) {
    final status = level.lifecycleStatus ?? level.status;
    return {
          'buyOpen',
          'buyPartiallyFilled',
          'sellOpen',
          'sellPartiallyFilled',
        }.contains(status) ||
        {'new', 'partiallyFilled'}.contains(currentOrder?.status);
  }

  bool _isWaitingSellCycle(GridLevel level, Order? currentOrder) {
    final status = level.lifecycleStatus ?? level.status;
    return status == 'buyFilled';
  }

  bool _isSellSubmittingCycle(GridLevel level, Order? currentOrder) {
    final status = level.lifecycleStatus ?? level.status;
    return status == 'sellSubmitting' ||
        (currentOrder?.side == 'SELL' &&
            {'created', 'submitting'}.contains(currentOrder?.status));
  }

  bool _isCompletedCycle(GridLevel level, Order? currentOrder) {
    final status = level.lifecycleStatus ?? level.status;
    return status == 'sellFilled' ||
        status == 'cycleCompleted' ||
        (currentOrder?.side == 'SELL' && currentOrder?.status == 'filled');
  }

  bool _isErrorCycle(GridLevel level, Order? currentOrder) {
    final status = level.lifecycleStatus ?? level.status;
    return status == 'error' ||
        {
          'failed',
          'unknown',
          'rejected',
          'expired',
        }.contains(currentOrder?.status);
  }

  Widget _longGridTable({
    required BuildContext context,
    required List<GridLevel> levels,
    required int leverage,
    required Map<String, Order> ordersById,
    required Map<String, List<Order>> ordersByGrid,
  }) {
    const columns = [
      ('网格编号', 72.0),
      ('当前方向', 96.0),
      ('循环次数', 80.0),
      ('BUY价格', 96.0),
      ('SELL价格', 96.0),
      ('计划数量', 96.0),
      ('计划名义金额', 116.0),
      ('预计保证金', 110.0),
      ('杠杆', 64.0),
      ('周期状态', 180.0),
      ('当前订单ID', 150.0),
      ('Client Order ID', 160.0),
      ('父订单ID', 140.0),
      ('配对订单ID', 140.0),
      ('已成交数量', 104.0),
      ('成交均价', 96.0),
      ('成交时间', 150.0),
      ('反向单', 80.0),
      ('是否需要补单', 104.0),
      ('最近错误', 180.0),
      ('更新时间', 150.0),
      ('操作', 430.0),
    ];
    final totalWidth = columns.fold<double>(
      0,
      (sum, column) => sum + column.$2,
    );
    return _HorizontalScrollArea(
      child: SizedBox(
        width: totalWidth,
        child: Column(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(color: Theme.of(context).canvasColor),
              child: Row(
                children: [
                  for (final column in columns)
                    _tableHeaderCell(column.$1, width: column.$2),
                ],
              ),
            ),
            const Divider(height: 1),
            for (final level in levels)
              _longGridRowView(
                context: context,
                level: level,
                leverage: leverage,
                ordersById: ordersById,
                ordersByGrid: ordersByGrid,
                widths: [for (final column in columns) column.$2],
              ),
          ],
        ),
      ),
    );
  }

  Widget _longGridRowView({
    required BuildContext context,
    required GridLevel level,
    required int leverage,
    required Map<String, Order> ordersById,
    required Map<String, List<Order>> ordersByGrid,
    required List<double> widths,
  }) {
    final currentOrder = _currentOrder(level, ordersById, ordersByGrid);
    final levelOrders = ordersByGrid[level.id] ?? const <Order>[];
    final recentSellOrder = _recentOrder(
      level,
      ordersById,
      ordersByGrid,
      side: 'SELL',
    );
    final showSellCycleInfo = _showSellCycleInfo(level, currentOrder);
    final displayedSellOrder = showSellCycleInfo ? recentSellOrder : null;
    final displayedSellOrderId = showSellCycleInfo
        ? (recentSellOrder?.id ?? level.lastSellOrderId)
        : '-';
    final currentSide = _currentSide(level, currentOrder);
    final needsReplacement = _needsLongReplacement(level, currentOrder);
    final error = _orderError(level, currentOrder);
    final updatedAt = _latestUpdatedAt(level, currentOrder);
    final hasBlockingOrder = levelOrders.any(_isBlockingOrder);
    final canSubmitBuy = _canSubmitLongBuy(level, hasBlockingOrder) ||
        (!hasBlockingOrder && _releasedLongBuyCanResubmit(levelOrders)) ||
        _staleLongBuyStateCanResubmit(
          level: level,
          currentOrder: currentOrder,
          hasBlockingOrder: hasBlockingOrder,
        );
    final canSubmitSell = needsReplacement && !hasBlockingOrder;
    final cells = <Widget>[
      Text(level.gridIndex.toString()),
      Text(currentSide),
      Text(_buyCycleNumber(level, currentOrder, currentSide)),
      Text(level.buyPrice ?? level.price),
      Text(level.sellPrice ?? '-'),
      Text(level.plannedQuantity),
      Text(level.plannedQuoteAmount),
      Text(_estimatedMargin(level, leverage)),
      Text('${leverage}x'),
      _cycleStatusCell(level, currentOrder),
      _narrow(currentOrder?.id ?? level.activeOrderId ?? '-'),
      _narrow(currentOrder?.clientOrderId ?? '-'),
      _narrow(currentOrder?.parentOrderId ?? '-'),
      _narrow(displayedSellOrderId ?? '-'),
      Text(currentOrder?.executedQuantity ?? '0'),
      Text(currentOrder?.averagePrice ?? '-'),
      Text(_filledAt(currentOrder)),
      Text(displayedSellOrder?.status ?? '-'),
      Text(needsReplacement ? '是' : '否'),
      _narrow(error),
      Text(_df.format(updatedAt.toLocal())),
      _levelActions(
        context: context,
        level: level,
        canSubmitBuy: canSubmitBuy,
        canSubmitSell: canSubmitSell,
        needsReplacement: needsReplacement,
        hasActiveOrder: hasBlockingOrder,
      ),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: error == '-' ? null : Colors.orange.shade50,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i += 1)
            _tableCell(width: widths[i], child: cells[i]),
        ],
      ),
    );
  }

  Widget _tableHeaderCell(String text, {required double width}) {
    return SizedBox(
      width: width,
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  Widget _tableCell({required double width, required Widget child}) {
    return SizedBox(
      width: width,
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(alignment: Alignment.centerLeft, child: child),
      ),
    );
  }

  bool _showSellCycleInfo(GridLevel level, Order? currentOrder) {
    final status = level.lifecycleStatus ?? level.status;
    if ({
      'buyFilled',
      'sellSubmitting',
      'sellOpen',
      'sellPartiallyFilled',
      'sellFilled',
      'cycleCompleted',
    }.contains(status)) {
      return true;
    }
    return currentOrder?.side == 'SELL';
  }

  Widget _levelActions({
    required BuildContext context,
    required GridLevel level,
    required bool canSubmitBuy,
    required bool canSubmitSell,
    required bool needsReplacement,
    required bool hasActiveOrder,
  }) {
    final actions = <Widget>[];
    if (canSubmitBuy) {
      actions.add(
        FilledButton(
          onPressed: _starting ? null : () => _confirmSubmitLongBuy(level),
          child: const Text('挂单'),
        ),
      );
    } else if (canSubmitSell) {
      actions.add(
        FilledButton.tonal(
          onPressed: _starting ? null : () => _confirmSubmitLongSell(level),
          child: const Text('补平多'),
        ),
      );
    } else {
      final label = hasActiveOrder
          ? '已有活动单'
          : needsReplacement
              ? '等待处理'
              : '不可操作';
      actions.add(
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 88),
          child: Text(label, overflow: TextOverflow.ellipsis),
        ),
      );
    }
    actions.add(
      OutlinedButton(
        onPressed: _starting ? null : () => _repairLongGridLevel(level),
        child: const Text('修复'),
      ),
    );
    actions.add(
      OutlinedButton(
        onPressed: _starting ? null : () => _confirmRenewLongGridLevel(level),
        child: const Text('Renew'),
      ),
    );
    actions.add(
      OutlinedButton(
        onPressed: _starting ? null : () => _confirmCloseLongGridLevel(level),
        child: const Text('平仓'),
      ),
    );
    actions.add(
      OutlinedButton(
        onPressed: _starting ? null : () => _confirmCancelLongGridLevel(level),
        child: const Text('撤单'),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          actions[i],
        ],
      ],
    );
  }

  Future<void> _repairLongGridLevel(GridLevel level) async {
    setState(() {
      _starting = true;
      _message = '正在修复价格层 ${level.gridIndex}...';
    });
    try {
      final repaired = await widget.liveGrid.repairFuturesLongGridLevel(
        level.id,
      );
      if (!mounted) return;
      final status = level.lifecycleStatus ?? level.status;
      setState(
        () => _message = repaired
            ? '价格层 ${level.gridIndex} 修复完成。'
            : status == 'buyFilled'
                ? '价格层 ${level.gridIndex} 已开多成交，当前不是本地残留修复场景；请点击该行“补平多”提交 reduceOnly 平多挂单。'
                : '价格层 ${level.gridIndex} 没有可修复的本地残留或仍存在真实活动单。',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '价格层 ${level.gridIndex} 修复失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _confirmRenewLongGridLevel(GridLevel level) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认 Renew 当前层'),
        content: SelectableText(
          '价格层: ${level.gridIndex}\n'
          '当前状态: ${level.lifecycleStatus ?? level.status}\n'
          'BUY价格: ${level.buyPrice ?? level.price}\n\n'
          'Renew 会把当前层释放为 LONG BUY / waitingBuy，并把该层旧 BUY 成交记录标记为不再参与生命周期计算。\n\n'
          'Renew 不会立即提交订单；后续价格 WebSocket 检测到价格进入配置范围时，会自动提交该层 LONG BUY。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认 Renew'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _starting = true;
      _message = '正在 Renew 价格层 ${level.gridIndex}...';
    });
    try {
      await widget.liveGrid.renewFuturesLongGridLevel(level.id);
      if (!mounted) return;
      setState(
        () => _message =
            '价格层 ${level.gridIndex} 已 Renew 为 LONG BUY，等待价格进入配置范围后自动挂单。',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '价格层 ${level.gridIndex} Renew 失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Order? _currentOrder(
    GridLevel level,
    Map<String, Order> ordersById,
    Map<String, List<Order>> ordersByGrid,
  ) {
    final activeOrderId = level.activeOrderId;
    if (activeOrderId != null && activeOrderId.isNotEmpty) {
      final active = ordersById[activeOrderId];
      if (active != null && !_isReleasedLocalGridOrder(active)) {
        return active;
      }
    }
    final status = level.lifecycleStatus ?? level.status;
    if (status == 'waitingBuy' || status == 'ready' || status == 'planned') {
      return null;
    }
    final lastBuyOrderId = level.lastBuyOrderId;
    if (lastBuyOrderId != null && lastBuyOrderId.isNotEmpty) {
      final lastBuy = ordersById[lastBuyOrderId];
      if (lastBuy != null && !_isReleasedLocalGridOrder(lastBuy)) {
        return lastBuy;
      }
    }
    final orders = ordersByGrid[level.id] ?? const <Order>[];
    for (final order in orders) {
      if (!_isReleasedLocalGridOrder(order)) {
        return order;
      }
    }
    return null;
  }

  Order? _recentOrder(
    GridLevel level,
    Map<String, Order> ordersById,
    Map<String, List<Order>> ordersByGrid, {
    required String side,
  }) {
    final knownId =
        side == 'BUY' ? level.lastBuyOrderId : level.lastSellOrderId;
    if (knownId != null && knownId.isNotEmpty) {
      final order = ordersById[knownId];
      if (order != null && !_isReleasedLocalGridOrder(order)) {
        return order;
      }
    }
    for (final order in ordersByGrid[level.id] ?? const <Order>[]) {
      if (order.side == side && !_isReleasedLocalGridOrder(order)) {
        return order;
      }
    }
    return null;
  }

  String _currentSide(GridLevel level, Order? currentOrder) {
    final status = level.lifecycleStatus ?? level.status;
    if (const {
      'buyFilled',
      'sellSubmitting',
      'sellOpen',
      'sellPartiallyFilled',
    }.contains(status)) {
      return 'LONG SELL';
    }
    if (currentOrder != null) {
      return currentOrder.side == 'BUY' ? 'LONG BUY' : 'LONG SELL';
    }
    if (status.contains('Sell') || status.contains('sell')) {
      return 'LONG SELL';
    }
    return 'LONG BUY';
  }

  String _buyCycleNumber(
    GridLevel level,
    Order? currentOrder,
    String currentSide,
  ) {
    if (currentOrder?.side == 'BUY' || currentSide.contains('BUY')) {
      return level.cycleNumber.toString();
    }
    return '-';
  }

  bool _needsLongReplacement(GridLevel level, Order? currentOrder) {
    final status = level.lifecycleStatus ?? level.status;
    return status == 'buyFilled';
  }

  bool _canSubmitLongBuy(GridLevel level, bool hasActiveOrder) {
    if (hasActiveOrder) {
      return false;
    }
    return {'ready', 'waiting', 'waitingBuy'}.contains(level.status) ||
        {
          'waitingBuy',
          'planned',
          'ready',
        }.contains(level.lifecycleStatus ?? '');
  }

  bool _staleLongBuyStateCanResubmit({
    required GridLevel level,
    required Order? currentOrder,
    required bool hasBlockingOrder,
  }) {
    if (hasBlockingOrder || currentOrder != null) {
      return false;
    }
    return {
      'buySubmitting',
      'buyOpen',
      'buyPartiallyFilled',
    }.contains(level.lifecycleStatus ?? level.status);
  }

  bool _isActiveOrder(Order order) {
    return {
      'created',
      'submitting',
      'new',
      'partiallyFilled',
      'cancelling',
      'unknown',
    }.contains(order.status);
  }

  bool _isBlockingOrder(Order order) {
    if (_isReleasedLocalGridOrder(order)) {
      return false;
    }
    if (_isLocalOnlyZeroFillFuturesLongGridSubmission(order)) {
      return false;
    }
    if (!_isActiveOrder(order)) {
      return false;
    }
    return true;
  }

  bool _isLocalOnlyZeroFillFuturesLongGridSubmission(Order order) {
    final exchangeOrderId = order.exchangeOrderId;
    return order.source == AutoSpotGridExecutionService.futuresLongSource &&
        order.marketType == 'usdtFutures' &&
        (order.purpose == 'futuresLongGridBuy' ||
            order.purpose == 'futuresLongGridSell') &&
        (exchangeOrderId == null || exchangeOrderId.isEmpty) &&
        _d(order.executedQuantity) == Decimal.zero &&
        {'created', 'submitting', 'failed', 'unknown'}.contains(order.status);
  }

  bool _isReleasedLocalGridOrder(Order order) {
    final error = order.errorMessage ?? '';
    if (order.source == AutoSpotGridExecutionService.futuresLongSource &&
        order.side == 'BUY' &&
        error.contains(
          AutoSpotGridExecutionService.noPositionReleasedFuturesLongBuyMessage,
        )) {
      return true;
    }
    if (order.status == 'filled' || _d(order.executedQuantity) > Decimal.zero) {
      return false;
    }
    return error.contains('已释放本地网格') || error.contains('无有效活动状态');
  }

  bool _releasedLongBuyCanResubmit(List<Order> orders) {
    return orders.any(
      (order) =>
          order.side == 'BUY' &&
          _isReleasedLocalGridOrder(order) &&
          _d(order.executedQuantity) == Decimal.zero,
    );
  }

  Decimal _d(String? value) {
    return Decimal.tryParse(value ?? '') ?? Decimal.zero;
  }

  DateTime _latestUpdatedAt(GridLevel level, Order? currentOrder) {
    final orderUpdatedAt = currentOrder?.updatedAt;
    if (orderUpdatedAt != null && orderUpdatedAt.isAfter(level.updatedAt)) {
      return orderUpdatedAt;
    }
    return level.updatedAt;
  }

  String _filledAt(Order? order) {
    if (order == null) {
      return '-';
    }
    final completedAt = order.completedAt;
    if (completedAt == null) {
      return '-';
    }
    return _df.format(completedAt.toLocal());
  }

  String _orderError(GridLevel level, Order? order) {
    if (order == null) {
      return '-';
    }
    if (_isReleasedLocalGridOrder(order)) {
      return '-';
    }
    final levelStatus = level.lifecycleStatus ?? level.status;
    if (levelStatus != 'error' &&
        !{'failed', 'unknown', 'rejected', 'expired'}.contains(order.status)) {
      return '-';
    }
    final message = order.errorMessage;
    if (message != null && message.isNotEmpty) {
      return message;
    }
    if ({'failed', 'unknown', 'rejected', 'expired'}.contains(order.status)) {
      return '订单状态: ${order.status}';
    }
    return '-';
  }

  Widget _narrow(String value) {
    if (value == '-') {
      return const Text('-');
    }
    return Tooltip(
      message: value,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: Text(value, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  String _estimatedMargin(GridLevel level, int leverage) {
    final notional = Decimal.tryParse(level.plannedQuoteAmount) ?? Decimal.zero;
    final safeLeverage = leverage <= 0 ? 1 : leverage;
    return (notional / Decimal.fromInt(safeLeverage))
        .toDecimal(scaleOnInfinitePrecision: 8)
        .toString();
  }

  String _remainingQuantity(String originalQuantity, String executedQuantity) {
    final original = Decimal.tryParse(originalQuantity) ?? Decimal.zero;
    final executed = Decimal.tryParse(executedQuantity) ?? Decimal.zero;
    final remaining = original - executed;
    return remaining < Decimal.zero ? '0' : remaining.toString();
  }

  Future<void> _restoreAutoListening() async {
    final strategyId = widget.strategy.id;
    if (_restoringAutoListening ||
        _loadedAutoListeningStrategyId == strategyId) {
      return;
    }
    _restoringAutoListening = true;
    try {
      final db = Get.find<AppDatabase>();
      final row = await (db.select(db.appSettings)
            ..where(
              (tbl) => tbl.key.equals(_autoListeningKey(strategyId)),
            ))
          .getSingleOrNull();
      final enabled = row?.value == 'true';
      if (!mounted) return;
      setState(() {
        _loadedAutoListeningStrategyId = strategyId;
        _autoListening = enabled;
      });
      if (enabled) {
        _startAutoListeningTimer(
          strategyId: strategyId,
          symbol: widget.strategy.symbol,
        );
      } else {
        _stopAutoListeningTimer(strategyId);
      }
    } finally {
      _restoringAutoListening = false;
    }
  }

  Future<void> _setAutoListening(bool enabled) async {
    final strategyId = widget.strategy.id;
    final db = Get.find<AppDatabase>();
    await db.into(db.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: _autoListeningKey(strategyId),
            value: enabled ? 'true' : 'false',
            updatedAt: DateTime.now().toUtc(),
          ),
        );
    if (!mounted) return;
    setState(() {
      _loadedAutoListeningStrategyId = strategyId;
      _autoListening = enabled;
      _message = enabled ? 'LONG 自动监听已开启。' : 'LONG 自动监听已关闭。';
    });
    if (enabled) {
      _startAutoListeningTimer(
        strategyId: strategyId,
        symbol: widget.strategy.symbol,
      );
    } else {
      _stopAutoListeningTimer(strategyId);
    }
  }

  void _startAutoListeningTimer({
    required String strategyId,
    required String symbol,
  }) {
    if (_autoListenScheduledStarts.contains(strategyId)) {
      return;
    }
    _autoListenScheduledStarts.add(strategyId);
    _autoListenStartQueue = _autoListenStartQueue.catchError((_) {}).then((
      _,
    ) async {
      final now = DateTime.now();
      final nextAllowed = _autoListenLastStartedAt.add(
        _autoListenStartStaggerInterval,
      );
      if (now.isBefore(nextAllowed)) {
        await Future.delayed(nextAllowed.difference(now));
      }
      if (!mounted || !_autoListening || widget.strategy.id != strategyId) {
        _autoListenScheduledStarts.remove(strategyId);
        return;
      }
      _autoListenLastStartedAt = DateTime.now();
      _startAutoListeningRuntime(strategyId: strategyId, symbol: symbol);
      _autoListenScheduledStarts.remove(strategyId);
    });
  }

  void _startAutoListeningRuntime({
    required String strategyId,
    required String symbol,
  }) {
    unawaited(
      widget.liveGrid.liveExecution
          .startFuturesUserDataStream(
            symbol: symbol,
            consumerKey: _autoListeningKey(strategyId),
          )
          .catchError((_) {}),
    );
    _startAutoListeningWsSubscription(strategyId: strategyId, symbol: symbol);
    _startAutoListeningPriceSubscription(
      strategyId: strategyId,
      symbol: symbol,
    );
  }

  void _stopAutoListeningTimer(String strategyId) {
    _disposeAutoListeningRuntime(strategyId);
    unawaited(
      widget.liveGrid.liveExecution.stopFuturesUserDataStream(
        consumerKey: _autoListeningKey(strategyId),
      ),
    );
  }

  void _disposeAutoListeningRuntime(String strategyId) {
    _autoListenWsSubscriptions.remove(strategyId)?.cancel();
    _autoListenPriceSubscriptions.remove(strategyId)?.cancel();
    _autoListenLastPriceSyncAt.remove(strategyId);
    _autoListenScheduledStarts.remove(strategyId);
  }

  void _startAutoListeningWsSubscription({
    required String strategyId,
    required String symbol,
  }) {
    if (_autoListenWsSubscriptions[strategyId] != null) {
      return;
    }
    final normalizedSymbol = symbol.toUpperCase();
    _autoListenWsSubscriptions[strategyId] =
        widget.liveGrid.liveExecution.futuresUserOrderUpdates
            .where(
      (event) =>
          event.strategyId == strategyId &&
          event.symbol == normalizedSymbol &&
          event.source == AutoSpotGridExecutionService.futuresLongSource &&
          event.status == 'filled',
    )
            .listen((event) {
      if (event.side == 'BUY') {
        final gridLevelId = event.gridLevelId;
        if (gridLevelId != null && gridLevelId.isNotEmpty) {
          unawaited(
            _submitLongSellAfterBuyFilled(
              gridLevelId,
              strategyId: strategyId,
            ),
          );
        } else {
          unawaited(
            _runAutoLongSync(
              strategyId: strategyId,
              symbol: symbol,
              refreshFirst: false,
              verifyAvailableQuantity: false,
            ),
          );
        }
        return;
      }
      if (event.side == 'SELL') {
        unawaited(_submitTriggeredLongBuy(strategyId));
      }
    });
  }

  Future<void> _submitLongSellAfterBuyFilled(
    String gridLevelId, {
    required String strategyId,
  }) async {
    if (_autoSyncRunning) {
      return;
    }
    _autoSyncRunning = true;
    try {
      await widget.liveGrid.submitFuturesLongCloseGridLevel(
        gridLevelId,
        verifyAvailableQuantity: false,
      );
      // In prehang mode this immediately replenishes the layer that was
      // consumed by the fill, subject to the current-price guard and the
      // configured active-order limit.
      final config = await widget.liveGrid.loadEditableConfig(strategyId);
      if (config?.longEntryTriggerMode ==
          LiveSpotGridEditableConfig.longEntryTriggerModePrehang) {
        await widget.liveGrid.submitTriggeredFuturesLongBuyOrders(strategyId);
      }
    } catch (error) {
      if (mounted && _autoListening) {
        setState(() => _message = 'LONG BUY 成交后提交平多失败: $error');
      }
    } finally {
      _autoSyncRunning = false;
    }
  }

  void _startAutoListeningPriceSubscription({
    required String strategyId,
    required String symbol,
  }) {
    if (_autoListenPriceSubscriptions[strategyId] != null) {
      return;
    }
    final normalizedSymbol = symbol.toUpperCase();
    _autoListenPriceSubscriptions[strategyId] = widget
        .liveGrid.marketData.futuresMarkPriceStream
        .where((event) => event.symbol.toUpperCase() == normalizedSymbol)
        .listen((_) {
      if (_autoSyncRunning) {
        return;
      }
      final now = DateTime.now();
      final last = _autoListenLastPriceSyncAt[strategyId];
      if (last != null && now.difference(last) < _autoListenPriceSyncInterval) {
        return;
      }
      _autoListenLastPriceSyncAt[strategyId] = now;
      unawaited(_submitTriggeredLongBuy(strategyId));
    });
  }

  Future<void> _submitTriggeredLongBuy(String strategyId) async {
    if (_autoSyncRunning) {
      return;
    }
    _autoSyncRunning = true;
    try {
      await widget.liveGrid.submitTriggeredFuturesLongBuyOrders(strategyId);
    } catch (error) {
      if (mounted && _autoListening && strategyId == widget.strategy.id) {
        setState(() => _message = 'LONG 价格触发挂单失败: $error');
      }
    } finally {
      _autoSyncRunning = false;
    }
  }

  Future<void> _runAutoLongSync({
    required String strategyId,
    required String symbol,
    bool refreshFirst = true,
    bool verifyAvailableQuantity = true,
    bool queueWhenBusy = true,
  }) async {
    if (_autoSyncRunning) {
      if (queueWhenBusy) {
        _autoSyncPending = true;
      }
      return;
    }
    _autoSyncRunning = true;
    var rateLimited = false;
    try {
      final now = DateTime.now();
      var shouldRefreshFirst = refreshFirst;
      final rateLimitUntil = _autoListenRateLimitUntil[strategyId];
      if (rateLimitUntil != null && now.isBefore(rateLimitUntil)) {
        shouldRefreshFirst = false;
      }
      final lastRestSyncAt = _autoListenLastRestSyncAt[strategyId];
      if (shouldRefreshFirst &&
          lastRestSyncAt != null &&
          now.difference(lastRestSyncAt) < _autoListenFullRestInterval) {
        shouldRefreshFirst = false;
      }
      if (refreshFirst) {
        if (shouldRefreshFirst) {
          await widget.liveGrid.liveExecution.refreshFuturesSnapshotForSymbol(
            symbol,
            includeHistory: false,
          );
          _autoListenLastRestSyncAt[strategyId] = DateTime.now();
        }
      }
      await widget.liveGrid.reconcileFuturesLongGrid(
        strategyId,
        autoSubmitClose: true,
        autoSubmitNextBuy: true,
        refreshFirst: false,
        verifyAvailableQuantity: verifyAvailableQuantity,
        validateMissingOpenOrders: shouldRefreshFirst,
      );
    } catch (error) {
      rateLimited = _isBinanceRateLimited(error);
      if (rateLimited) {
        _autoListenRateLimitUntil[strategyId] = DateTime.now().add(
          _autoListenRateLimitCooldown,
        );
      }
      if (mounted && _autoListening && strategyId == widget.strategy.id) {
        setState(
          () => _message = rateLimited
              ? 'LONG 自动监听触发 Binance 频率限制，已暂停 REST 对账 2 分钟，期间继续使用 WebSocket 轻量推进。'
              : 'LONG 自动监听同步失败: $error',
        );
      }
    } finally {
      _autoSyncRunning = false;
      if (_autoSyncPending &&
          _autoListening &&
          strategyId == widget.strategy.id) {
        _autoSyncPending = false;
        unawaited(
          _runAutoLongSync(
            strategyId: strategyId,
            symbol: symbol,
            refreshFirst: !rateLimited,
            verifyAvailableQuantity: !rateLimited,
          ),
        );
      }
    }
  }

  bool _isBinanceRateLimited(Object error) {
    return error is BinanceRequestException &&
        (error.type == BinanceRequestExceptionType.rateLimited ||
            error.statusCode == 429 ||
            error.binanceCode == -1003);
  }

  String _autoListeningKey(String strategyId) {
    return 'longFutureAutoListening.$strategyId';
  }

  String _localStatus(String status) {
    return switch (status) {
      'ready' => '计划',
      'waitingBuy' => '等待BUY',
      'buySubmitting' => '提交BUY',
      'buyOpen' => 'BUY挂单',
      'buyPartiallyFilled' => 'BUY部分成交',
      'buyFilled' => 'BUY已成交',
      'sellSubmitting' => '提交SELL',
      'sellOpen' => 'SELL挂单',
      'sellPartiallyFilled' => 'SELL部分成交',
      'sellFilled' => 'SELL已成交',
      'error' => '错误',
      _ => status,
    };
  }

  String _cycleStatus(String status) {
    return switch (status) {
      'waitingBuy' => '等待开多',
      'planned' => '计划',
      'ready' => '计划',
      'buySubmitting' => '提交开多',
      'buyOpen' => '开多挂单',
      'buyPartiallyFilled' => '开多部分成交',
      'buyFilled' => '已开多/等待平多',
      'sellSubmitting' => '提交平多',
      'sellOpen' => '平多挂单',
      'sellPartiallyFilled' => '平多部分成交',
      'sellFilled' => '本轮完成',
      'error' => '错误',
      _ => status,
    };
  }

  Widget _cycleStatusCell(GridLevel level, Order? currentOrder) {
    final cycleStatus = _cycleStatus(level.lifecycleStatus ?? level.status);
    final localStatus = _localStatus(level.status);
    final binanceStatus = _orderStatus(currentOrder?.status ?? 'notSubmitted');
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 240),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            cycleStatus,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            '本地: $localStatus / Binance: $binanceStatus',
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  String _orderStatus(String status) {
    return switch (status) {
      'notSubmitted' => '未提交',
      'created' => '本地计划',
      'submitting' => '提交中',
      'new' => 'Binance挂单',
      'partiallyFilled' => '部分成交',
      'filled' => '已成交',
      'cancelled' => '已撤销',
      'failed' => '失败',
      'unknown' => '状态未知',
      'rejected' => '已拒绝',
      'expired' => '已过期',
      _ => status,
    };
  }

  double _levelPrice(GridLevel level) {
    return double.tryParse(level.buyPrice ?? level.price) ?? 0;
  }

  bool _canStart(Strategy strategy) {
    return {
      'idle',
      'previewReady',
      'stopped',
      'error',
      'starting',
    }.contains(strategy.status);
  }

  Future<void> _confirmSubmitLongBuy(GridLevel level) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认 LONG 挂单'),
        content: SelectableText(
          '价格层: ${level.gridIndex}\n'
          '方向: BUY / LONG\n'
          '开多价格: ${level.buyPrice ?? level.price}\n'
          '平多价格: ${level.sellPrice ?? '-'}\n'
          '数量: ${level.plannedQuantity}\n\n'
          '提交前会检查该层没有活动订单、Futures 双向持仓模式和 Binance 交易规则。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认挂单'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _starting = true;
      _message = '正在提交价格层 ${level.gridIndex} LONG BUY...';
    });
    try {
      final orderId = await widget.liveGrid.submitWaitingFuturesLongGridLevel(
        level.id,
      );
      await widget.liveGrid.liveExecution.refreshFuturesSnapshotForSymbol(
        widget.strategy.symbol,
        includeHistory: false,
      );
      if (!mounted) return;
      setState(() => _message = 'LONG 挂单完成: $orderId');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = 'LONG 挂单失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _confirmSubmitLongSell(GridLevel level) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认补平多'),
        content: SelectableText(
          '价格层: ${level.gridIndex}\n'
          '方向: SELL / LONG\n'
          '平多价格: ${level.sellPrice ?? '-'}\n'
          '计划数量: ${level.plannedQuantity}\n\n'
          '这会提交当前价格层的 LONG SELL 限价平多单，不会处理其他价格层。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认补平多'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _starting = true;
      _message = '正在提交价格层 ${level.gridIndex} LONG SELL 平多...';
    });
    try {
      final orderId = await widget.liveGrid.submitFuturesLongCloseGridLevel(
        level.id,
      );
      await widget.liveGrid.liveExecution.refreshFuturesSnapshotForSymbol(
        widget.strategy.symbol,
        includeHistory: false,
      );
      if (!mounted) return;
      setState(() => _message = '补平多完成: $orderId');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '补平多失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _confirmCloseLongGridLevel(GridLevel level) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认当前层平仓'),
        content: SelectableText(
          '价格层: ${level.gridIndex}\n'
          '方向: SELL / LONG reduceOnly MARKET\n'
          '计划平仓数量: ${level.plannedQuantity}\n\n'
          '只平当前价格层对应的 LONG 多单数量。提交前会检查该层没有活动挂单，并按 Binance 当前可用 LONG 可平数量做上限。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认平仓当前层'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _starting = true;
      _message = '正在平仓价格层 ${level.gridIndex} 对应 LONG 多单...';
    });
    try {
      final orderId = await widget.liveGrid.closeFuturesLongGridLevelPosition(
        level.id,
      );
      await widget.liveGrid.liveExecution.refreshFuturesSnapshotForSymbol(
        widget.strategy.symbol,
        includeHistory: false,
      );
      if (!mounted) return;
      setState(() => _message = '价格层 ${level.gridIndex} 平仓已提交: $orderId');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '价格层 ${level.gridIndex} 平仓失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _confirmCancelLongGridLevel(GridLevel level) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认撤销当前层挂单'),
        content: SelectableText(
          '价格层: ${level.gridIndex}\n'
          '当前订单: ${level.activeOrderId ?? level.linkedOrderId ?? '-'}\n\n'
          '只撤销当前价格层的 Futures LONG 网格活动挂单。撤单完成后，该价格层会释放回等待提交/等待开多。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认撤单当前层'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _starting = true;
      _message = '正在撤销价格层 ${level.gridIndex} 活动挂单...';
    });
    try {
      final cancelled =
          await widget.liveGrid.cancelFuturesLongGridLevelOpenOrders(level.id);
      await widget.liveGrid.liveExecution.refreshFuturesSnapshotForSymbol(
        widget.strategy.symbol,
        includeHistory: false,
      );
      if (!mounted) return;
      setState(
        () => _message =
            '价格层 ${level.gridIndex} 撤单完成，已释放回等待提交/等待开多。撤销 $cancelled 单。',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '价格层 ${level.gridIndex} 撤单失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _repairReleasedLongLayers() async {
    setState(() {
      _starting = true;
      _message = '正在修复已释放的 LONG 网格层...';
    });
    try {
      final repaired = await widget.liveGrid
          .repairReleasedFuturesLongGridLevels(widget.strategy.id);
      if (!mounted) return;
      setState(() => _message = '修复释放层完成: $repaired 层。');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '修复释放层失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _startFuturesLongGrid() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启动 LONG 网格'),
        content: Text(
          '这会在 Binance Futures 为 ${widget.strategy.symbol} 提交 LONG BUY 限价挂单，'
          '使用合约账户资金，且要求真实资金开关已开启。确认继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认启动'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _starting = true;
      _message = '正在启动 LONG 网格...';
    });
    try {
      final report = await widget.liveGrid.startFuturesLongGrid(
        widget.strategy.id,
      );
      if (!mounted) return;
      setState(() => _message = report.toDisplayText());
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '启动 LONG 网格失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _resetErrorLayers() async {
    setState(() {
      _starting = true;
      _message = '正在清理失败 LONG 层...';
    });
    try {
      await widget.liveGrid.resetFuturesLongGridErrors(widget.strategy.id);
      await widget.liveGrid.liveExecution.refreshFuturesSnapshotForSymbol(
        widget.strategy.symbol,
        includeHistory: false,
      );
      if (!mounted) return;
      setState(() => _message = '失败 LONG 层已清理，可以重新启动。');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '清理失败 LONG 层失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _reconcileFuturesLongGrid({required bool includeHistory}) async {
    setState(() {
      _starting = true;
      _message = '';
    });
    try {
      final report = await widget.liveGrid.reconcileFuturesLongGrid(
        widget.strategy.id,
        autoSubmitClose: true,
        autoSubmitNextBuy: true,
        includeHistory: includeHistory,
      );
      if (!mounted) return;
      _showSnackBar(
        '${includeHistory ? '完整对账' : '轻量对账'}\n${report.toDisplayText()}',
      );
    } catch (error) {
      if (!mounted) return;
      _showSnackBar('LONG Futures Binance 对账失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _refreshBinanceOpenOrders() async {
    setState(() {
      _starting = true;
      _message = '';
    });
    try {
      await widget.liveGrid.liveExecution.refreshFuturesSnapshotForSymbol(
        widget.strategy.symbol,
        includeHistory: false,
      );
      await widget.liveGrid.reconcileFuturesLongGrid(
        widget.strategy.id,
        autoSubmitClose: true,
        autoSubmitNextBuy: true,
        refreshFirst: false,
        validateMissingOpenOrders: true,
      );
      if (!mounted) return;
      _showSnackBar('Binance Futures 当前挂单已刷新，并已同步和推进本地网格周期。');
    } catch (error) {
      if (!mounted) return;
      _showSnackBar('刷新 Binance Futures 当前挂单失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _stopFuturesLongGridCancelOpenOrders() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('停止并撤销未成交 LONG'),
        content: Text(
          '这会停止 ${widget.strategy.symbol} 当前合约 LONG 网格策略，并撤销本策略还没成交完的 LONG BUY 挂单。\n\n'
          '已经成交的 LONG 持仓不会市价平仓，SHORT 对冲也不会处理。确认继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认停止并撤单'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _starting = true;
      _message = '正在停止 LONG 网格并撤销未成交挂单...';
    });
    try {
      final report = await widget.liveGrid.stopFuturesLongGridCancelOpenOrders(
        widget.strategy.id,
      );
      if (!mounted) return;
      setState(() => _message = report.toDisplayText());
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '停止并撤销 LONG 挂单失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _closeFuturesPosition(String positionSide) async {
    final isLong = positionSide == 'LONG';
    final label = isLong ? '多单' : '空单';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('一键平仓$label'),
        content: Text(
          '这会对 ${widget.strategy.symbol} 当前 Futures $positionSide 持仓提交 reduceOnly 市价平仓单。\n\n'
          '这个操作不会撤销网格挂单，也不会改变另一侧持仓。确认继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('确认平仓$label'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _starting = true;
      _message = '正在提交 $positionSide reduceOnly 市价平仓...';
    });
    try {
      final report = isLong
          ? await widget.liveGrid.closeFuturesLongPosition(
              widget.strategy.id,
            )
          : await widget.liveGrid.closeFuturesShortPosition(
              widget.strategy.id,
            );
      if (!mounted) return;
      setState(() => _message = report.toDisplayText());
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '一键平仓$label失败: $error');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
      );
  }
}

class _HorizontalScrollArea extends StatefulWidget {
  const _HorizontalScrollArea({required this.child});

  final Widget child;

  @override
  State<_HorizontalScrollArea> createState() => _HorizontalScrollAreaState();
}

class _HorizontalScrollAreaState extends State<_HorizontalScrollArea> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      notificationPredicate: (notification) => notification.depth == 0,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        child: widget.child,
      ),
    );
  }
}

final _df = DateFormat('yyyy-MM-dd HH:mm:ss');
