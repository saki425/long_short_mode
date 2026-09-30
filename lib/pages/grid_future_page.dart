import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../services/execution/auto_spot_grid_execution_service.dart';
import '../services/execution/future_grid_engine.dart';
import '../services/market_data/market_data_coordinator.dart';

enum _ShortFutureLifecycleFilter {
  all,
  waitingOpen,
  submitted,
  open,
  closing,
  completed,
  error,
}

class _ShortFutureLifecycleStats {
  const _ShortFutureLifecycleStats({
    required this.total,
    required this.waitingOpen,
    required this.submitted,
    required this.open,
    required this.closing,
    required this.completed,
    required this.error,
  });

  final int total;
  final int waitingOpen;
  final int submitted;
  final int open;
  final int closing;
  final int completed;
  final int error;
}

class GridFuturePage extends StatefulWidget {
  const GridFuturePage({super.key});

  @override
  State<GridFuturePage> createState() => _GridFuturePageState();
}

class _GridFuturePageState extends State<GridFuturePage> {
  static final Map<String, Timer> _liveHedgeTimers = {};

  bool _showNonHedgeLayers = false;
  bool _liveHedgeListening = false;
  String? _loadedLiveHedgeSymbol;
  bool _restoringLiveHedgeSetting = false;
  final Set<String> _ensuredShortLayerStrategies = {};

  @override
  Widget build(BuildContext context) {
    final workspace = Get.find<SymbolWorkspaceController>();
    final db = Get.find<AppDatabase>();
    final liveGrid = Get.find<AutoSpotGridExecutionService>();
    final futureGrid = Get.find<FutureGridEngine>();
    return Obx(() {
      final active = workspace.activeSymbol.value;
      if (active == null) {
        return const Center(child: Text('请先添加交易币对。'));
      }
      return StreamBuilder<Strategy?>(
        stream: liveGrid.watchActiveFuturesGridStrategy(symbol: active.symbol),
        builder: (context, futuresStrategySnapshot) {
          return StreamBuilder<Strategy?>(
            stream: liveGrid.watchActiveStrategy(symbol: active.symbol),
            builder: (context, spotStrategySnapshot) {
              final strategy =
                  futuresStrategySnapshot.data ?? spotStrategySnapshot.data;
              final usingFuturesGrid = futuresStrategySnapshot.data != null;
              if (strategy != null &&
                  _ensuredShortLayerStrategies.add(strategy.id)) {
                unawaited(futureGrid.ensureForStrategy(strategy.id));
              }
              if (strategy != null && strategy.symbol == active.symbol) {
                unawaited(
                  _restoreLiveHedgeListening(
                    db: db,
                    liveGrid: liveGrid,
                    futureGrid: futureGrid,
                    strategy: strategy,
                  ),
                );
              }
              return Scaffold(
                appBar: AppBar(
                  title: Text('${active.displayName} Short Future'),
                  actions: [
                    if (strategy != null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Chip(
                            label: Text(
                              usingFuturesGrid ? '合约策略 SHORT' : '现货策略 SHORT',
                            ),
                          ),
                        ),
                      ),
                    if (strategy != null)
                      StreamBuilder<List<FuturesPosition>>(
                        stream: _watchFuturesPositions(db, strategy.symbol),
                        builder: (context, snapshot) {
                          final shortQty = _openShortQuantity(
                            snapshot.data ?? const <FuturesPosition>[],
                          );
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: RichText(
                                text: TextSpan(
                                  style: DefaultTextStyle.of(context).style,
                                  children: [
                                    TextSpan(text: '${strategy.symbol} 空单总量: '),
                                    TextSpan(
                                      text: shortQty,
                                      style: TextStyle(
                                        color: Colors.green.shade700,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    Tooltip(
                      message: '连接 Binance Futures 并监听真实空单数量',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('真实对冲监听'),
                          Switch(
                            value: _liveHedgeListening,
                            thumbColor: _switchThumbColor,
                            trackColor: _switchTrackColor,
                            onChanged:
                                strategy == null
                                    ? null
                                    : (value) => unawaited(
                                      _setLiveHedgeListening(
                                        enabled: value,
                                        db: db,
                                        liveGrid: liveGrid,
                                        futureGrid: futureGrid,
                                        strategy: strategy,
                                      ),
                                    ),
                          ),
                        ],
                      ),
                    ),
                    Tooltip(
                      message: '显示不需要对冲的层级',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('全部层级'),
                          Switch(
                            value: _showNonHedgeLayers,
                            thumbColor: _switchThumbColor,
                            trackColor: _switchTrackColor,
                            onChanged:
                                (value) =>
                                    setState(() => _showNonHedgeLayers = value),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新价格层记录',
                      onPressed:
                          strategy == null
                              ? null
                              : () => unawaited(
                                _refresh(
                                  liveGrid: liveGrid,
                                  futureGrid: futureGrid,
                                  strategy: strategy,
                                ),
                              ),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                body: () {
                  if (strategy == null) {
                    return Center(
                      child: Text(
                        '当前 ${active.displayName} 还没有可显示的 SHORT 对冲价格层策略。\n'
                        '请先在 Strategy 页面创建现货网格或合约 LONG 网格策略。',
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  if (strategy.symbol != active.symbol) {
                    return Center(
                      child: Text(
                        '当前页面币对与策略币对不一致，已阻止加载。\n'
                        'activeSymbol=${active.symbol}, strategy.symbol=${strategy.symbol}',
                        style: const TextStyle(color: Colors.red),
                      ),
                    );
                  }
                  return _GridFutureBody(
                    strategy: strategy,
                    liveGrid: liveGrid,
                    futureGrid: futureGrid,
                    showNonHedgeLayers: _showNonHedgeLayers,
                  );
                }(),
              );
            },
          );
        },
      );
    });
  }

  Stream<List<FuturesPosition>> _watchFuturesPositions(
    AppDatabase db,
    String symbol,
  ) {
    return (db.select(db.futuresPositions)
      ..where((tbl) => tbl.symbol.equals(symbol.toUpperCase()))).watch();
  }

  Future<void> _refresh({
    required AutoSpotGridExecutionService liveGrid,
    required FutureGridEngine futureGrid,
    required Strategy strategy,
  }) async {
    await liveGrid.liveExecution.refreshFuturesSnapshotForSymbol(
      strategy.symbol,
      includeHistory: false,
    );
    await futureGrid.ensureForStrategy(strategy.id);
  }

  Future<void> _restoreLiveHedgeListening({
    required AppDatabase db,
    required AutoSpotGridExecutionService liveGrid,
    required FutureGridEngine futureGrid,
    required Strategy strategy,
  }) async {
    final symbol = strategy.symbol.toUpperCase();
    if (_restoringLiveHedgeSetting || _loadedLiveHedgeSymbol == symbol) {
      return;
    }
    _restoringLiveHedgeSetting = true;
    try {
      final row =
          await (db.select(db.appSettings)..where(
            (tbl) => tbl.key.equals(_liveHedgeListeningKey(symbol)),
          )).getSingleOrNull();
      final enabled = row?.value == 'true';
      if (!mounted) return;
      setState(() {
        _loadedLiveHedgeSymbol = symbol;
        _liveHedgeListening = enabled;
      });
      if (enabled) {
        _startLiveHedgeTimer(
          liveGrid: liveGrid,
          futureGrid: futureGrid,
          strategy: strategy,
        );
      } else {
        _stopLiveHedgeTimer(symbol);
      }
    } finally {
      _restoringLiveHedgeSetting = false;
    }
  }

  Future<void> _setLiveHedgeListening({
    required bool enabled,
    required AppDatabase db,
    required AutoSpotGridExecutionService liveGrid,
    required FutureGridEngine futureGrid,
    required Strategy strategy,
  }) async {
    final symbol = strategy.symbol.toUpperCase();
    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: _liveHedgeListeningKey(symbol),
            value: enabled ? 'true' : 'false',
            updatedAt: DateTime.now().toUtc(),
          ),
        );
    if (!mounted) return;
    setState(() {
      _loadedLiveHedgeSymbol = symbol;
      _liveHedgeListening = enabled;
    });
    if (!enabled) {
      _stopLiveHedgeTimer(symbol);
      return;
    }
    _startLiveHedgeTimer(
      liveGrid: liveGrid,
      futureGrid: futureGrid,
      strategy: strategy,
    );
  }

  void _startLiveHedgeTimer({
    required AutoSpotGridExecutionService liveGrid,
    required FutureGridEngine futureGrid,
    required Strategy strategy,
  }) {
    final symbol = strategy.symbol.toUpperCase();
    unawaited(
      liveGrid.liveExecution
          .startFuturesUserDataStream(
            symbol: symbol,
            consumerKey: _liveHedgeListeningKey(symbol),
          )
          .catchError((_) {}),
    );
    unawaited(
      _refresh(liveGrid: liveGrid, futureGrid: futureGrid, strategy: strategy),
    );
    if (_liveHedgeTimers[symbol]?.isActive == true) {
      return;
    }
    _liveHedgeTimers[symbol] = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(
        liveGrid.liveExecution
            .refreshFuturesSnapshotForSymbol(symbol, includeHistory: false)
            .catchError((_) {}),
      );
    });
  }

  void _stopLiveHedgeTimer(String symbol) {
    final normalizedSymbol = symbol.toUpperCase();
    _liveHedgeTimers.remove(normalizedSymbol)?.cancel();
    final liveGrid = Get.find<AutoSpotGridExecutionService>();
    unawaited(
      liveGrid.liveExecution.stopFuturesUserDataStream(
        consumerKey: _liveHedgeListeningKey(normalizedSymbol),
      ),
    );
  }

  String _liveHedgeListeningKey(String symbol) {
    return 'gridFutureLiveHedgeListening.${symbol.toUpperCase()}';
  }

  String _openShortQuantity(List<FuturesPosition> rows) {
    var quantity = 0.0;
    for (final row in rows) {
      final amount = double.tryParse(row.positionAmount) ?? 0;
      if (row.positionSide == 'SHORT') {
        quantity += amount.abs();
      } else if (row.positionSide == 'BOTH' && amount < 0) {
        quantity += amount.abs();
      }
    }
    return quantity.toStringAsFixed(8);
  }

  WidgetStateProperty<Color?> get _switchThumbColor {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return Colors.white;
      }
      return null;
    });
  }

  WidgetStateProperty<Color?> get _switchTrackColor {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return Colors.white.withValues(alpha: 0.35);
      }
      return null;
    });
  }
}

class _GridFutureBody extends StatefulWidget {
  const _GridFutureBody({
    required this.strategy,
    required this.liveGrid,
    required this.futureGrid,
    required this.showNonHedgeLayers,
  });

  final Strategy strategy;
  final AutoSpotGridExecutionService liveGrid;
  final FutureGridEngine futureGrid;
  final bool showNonHedgeLayers;

  @override
  State<_GridFutureBody> createState() => _GridFutureBodyState();
}

class _GridFutureBodyState extends State<_GridFutureBody> {
  _ShortFutureLifecycleFilter _filter = _ShortFutureLifecycleFilter.all;
  bool _closingShort = false;
  String _message = '';

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<GridLevel>>(
      stream: widget.liveGrid.watchGridLevels(widget.strategy.id),
      builder: (context, spotSnapshot) {
        final spotLevels = spotSnapshot.data ?? const <GridLevel>[];
        return StreamBuilder<List<FutureGridOrder>>(
          stream: widget.futureGrid.watchFutureGridOrders(widget.strategy.id),
          builder: (context, futureSnapshot) {
            final futureRows = futureSnapshot.data ?? const <FutureGridOrder>[];
            return StreamBuilder<List<Order>>(
              stream: _watchLongExposureOrders(widget.strategy.id),
              builder: (context, orderSnapshot) {
                final exposureOrders = orderSnapshot.data ?? const <Order>[];
                return FutureBuilder<LiveSpotGridEditableConfig?>(
                  future: widget.liveGrid.loadEditableConfig(
                    widget.strategy.id,
                  ),
                  builder: (context, configSnapshot) {
                    final config = configSnapshot.data;
                    final leverage = config?.futuresLeverage ?? 1;
                    return FutureBuilder<FutureGridStage>(
                      future: widget.futureGrid.stageForStrategy(
                        widget.strategy.id,
                      ),
                      builder: (context, stageSnapshot) {
                        final stage =
                            stageSnapshot.data ??
                            const FutureGridStage(
                              title: '等待同步',
                              reason: '正在读取当前策略的现货网格和价格层对冲记录。',
                            );
                        final tailShort = _tailShort(futureRows);
                        final markPrice = _currentFuturesMarkPrice();
                        final tailLoss = _tailShortLoss(tailShort, markPrice);
                        final hedgeLayerIds = _shortHedgeLayerIds(
                          spotLevels,
                          config?.shortHedgeSpreadLevels ?? 4,
                        );
                        final rowsByGrid = {
                          for (final row in futureRows)
                            row.spotGridOrderId: row,
                        };
                        final visibleLevels =
                            widget.showNonHedgeLayers
                                ? spotLevels
                                : spotLevels
                                    .where(
                                      (level) =>
                                          hedgeLayerIds.contains(level.id),
                                    )
                                    .toList(growable: false);
                        final completedCycles = visibleLevels.fold<int>(
                          0,
                          (sum, level) => sum + level.cycleNumber,
                        );
                        final stats = _shortFutureStats(
                          levels: visibleLevels,
                          rowsByGrid: rowsByGrid,
                        );
                        return SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _shortFutureHeader(
                                context: context,
                                stats: stats,
                                completedCycles: completedCycles,
                                leverage: leverage,
                              ),
                              const SizedBox(height: 12),
                              _TailShortRiskBar(
                                tailShort: tailShort,
                                markPrice: markPrice,
                                tailLoss: tailLoss,
                                busy: _closingShort,
                                onCloseTail: _closeTailShort,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '价格层',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              _FutureGridTable(
                                levels: spotLevels,
                                rows: futureRows,
                                exposureOrders: exposureOrders,
                                centerPrice: widget.strategy.centerPrice,
                                currentPrice: markPrice,
                                shortHedgeMultiplier:
                                    config?.shortHedgeMultiplier ??
                                    Decimal.parse('1.2'),
                                shortHedgeSpreadLevels:
                                    config?.shortHedgeSpreadLevels ?? 4,
                                showNonHedgeLayers: widget.showNonHedgeLayers,
                                filter: _filter,
                              ),
                              const SizedBox(height: 20),
                              _binanceFuturesShortOpenOrdersSection(),
                              const SizedBox(height: 20),
                              Text(
                                '风险提示',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const Card(
                                child: Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Text(
                                    '空单只在 Spot BUY 成交后按价格层市价开仓，'
                                    '只在匹配价格层的 Spot SELL 成交后 reduceOnly 平仓。'
                                    '真实空单数量、平均开仓价、未实现盈亏和资金费率仍应以 Hedge/Futures 仓位同步结果核对。',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              _Header(strategy: widget.strategy),
                              const SizedBox(height: 12),
                              _StageCard(stage: stage),
                              const SizedBox(height: 12),
                              _HedgeRuleCard(strategy: widget.strategy),
                            ],
                          ),
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

  Widget _shortFutureHeader({
    required BuildContext context,
    required _ShortFutureLifecycleStats stats,
    required int completedCycles,
    required int leverage,
  }) {
    final filters = {
      _ShortFutureLifecycleFilter.all: '全部',
      _ShortFutureLifecycleFilter.waitingOpen: '等待/提交开空',
      _ShortFutureLifecycleFilter.submitted: 'Binance挂单',
      _ShortFutureLifecycleFilter.open: '已开空待平空',
      _ShortFutureLifecycleFilter.closing: '平空中',
      _ShortFutureLifecycleFilter.completed: '已完成循环',
      _ShortFutureLifecycleFilter.error: '异常',
    };
    final cards = [
      ('网格总数', stats.total),
      ('等待开空', stats.waitingOpen),
      ('Binance挂单', stats.submitted),
      ('已开空待平空', stats.open),
      ('平空中', stats.closing),
      ('已完成循环', completedCycles),
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
            FilledButton.tonalIcon(
              onPressed: _closingShort ? null : _closeFuturesShort,
              icon:
                  _closingShort
                      ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Icon(Icons.north_east),
              label: const Text('一键平仓空单'),
            ),
            OutlinedButton.icon(
              onPressed:
                  _closingShort ? null : () => setState(() => _message = ''),
              icon: const Icon(Icons.clear),
              label: const Text('清空提示'),
            ),
            OutlinedButton.icon(
              onPressed:
                  _closingShort
                      ? null
                      : () => _refreshBinanceOpenOrders(includeHistory: false),
              icon: const Icon(Icons.sync),
              label: const Text('轻量对账'),
            ),
            OutlinedButton.icon(
              onPressed:
                  _closingShort
                      ? null
                      : () => _refreshBinanceOpenOrders(includeHistory: true),
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
            const Chip(label: Text('模式: SHORT 价格层对冲')),
            Chip(label: Text('杠杆: ${leverage}x')),
            const Chip(label: Text('持仓模式要求: Hedge Mode')),
          ],
        ),
        if (_message.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText(_message),
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
                  width: 140,
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

  _ShortFutureLifecycleStats _shortFutureStats({
    required List<GridLevel> levels,
    required Map<String, FutureGridOrder> rowsByGrid,
  }) {
    var waitingOpen = 0;
    var submitted = 0;
    var open = 0;
    var closing = 0;
    var completed = 0;
    var error = 0;
    for (final level in levels) {
      switch (_shortFutureFilterFor(rowsByGrid[level.id])) {
        case _ShortFutureLifecycleFilter.waitingOpen:
          waitingOpen++;
        case _ShortFutureLifecycleFilter.submitted:
          submitted++;
        case _ShortFutureLifecycleFilter.open:
          open++;
        case _ShortFutureLifecycleFilter.closing:
          closing++;
        case _ShortFutureLifecycleFilter.completed:
          completed++;
        case _ShortFutureLifecycleFilter.error:
          error++;
        case _ShortFutureLifecycleFilter.all:
          break;
      }
    }
    return _ShortFutureLifecycleStats(
      total: levels.length,
      waitingOpen: waitingOpen,
      submitted: submitted,
      open: open,
      closing: closing,
      completed: completed,
      error: error,
    );
  }

  Set<String> _shortHedgeLayerIds(List<GridLevel> allLevels, int spreadLevels) {
    final requested = spreadLevels <= 0 ? 1 : spreadLevels;
    final sorted = allLevels
      .where((level) => _decimal(level.buyPrice ?? level.price) > 0)
      .toList(growable: false)..sort(
      (a, b) => _decimal(
        a.buyPrice ?? a.price,
      ).compareTo(_decimal(b.buyPrice ?? b.price)),
    );
    return sorted.take(requested).map((level) => level.id).toSet();
  }

  _ShortFutureLifecycleFilter _shortFutureFilterFor(FutureGridOrder? row) {
    switch (row?.status) {
      case 'WAIT_OPEN':
        return _ShortFutureLifecycleFilter.submitted;
      case 'OPEN':
        return _ShortFutureLifecycleFilter.open;
      case 'CLOSING':
      case 'CLOSE_SUBMITTED':
        return _ShortFutureLifecycleFilter.closing;
      case 'CLOSED':
        return _ShortFutureLifecycleFilter.completed;
      case 'FAILED':
        return _ShortFutureLifecycleFilter.error;
      case 'WAIT_TRIGGER':
      default:
        return _ShortFutureLifecycleFilter.waitingOpen;
    }
  }

  double _decimal(String value) => double.tryParse(value) ?? 0;

  Future<void> _closeFuturesShort() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('一键平仓空单'),
            content: Text(
              '这会对 ${widget.strategy.symbol} 当前 Futures SHORT 持仓提交 BUY reduceOnly 市价平仓单。\n\n'
              '这个操作不会撤销网格挂单，也不会处理 LONG 持仓。确认继续？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认平仓空单'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    setState(() {
      _closingShort = true;
      _message = '正在提交 SHORT reduceOnly 市价平仓...';
    });
    try {
      final report = await widget.liveGrid.closeFuturesShortPosition(
        widget.strategy.id,
      );
      if (!mounted) return;
      setState(() => _message = report.toDisplayText());
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '一键平仓空单失败: $error');
    } finally {
      if (mounted) {
        setState(() => _closingShort = false);
      }
    }
  }

  Future<void> _closeTailShort() async {
    final tail = _tailShort(
      await widget.futureGrid.futureGridOrders(widget.strategy.id),
    );
    if (tail == null) {
      setState(() => _message = '当前没有 OPEN 状态的 SHORT 尾单。');
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('一键市价平仓空单尾单'),
            content: Text(
              '这会只平当前最低价格 OPEN SHORT 层：\n\n'
              '价格层: ${tail.price}\n'
              '数量: ${tail.quantity}\n\n'
              '将提交 BUY reduceOnly 市价单。确认继续？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认平尾单'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    setState(() {
      _closingShort = true;
      _message = '正在市价平仓 SHORT 尾单...';
    });
    try {
      final closed = await widget.futureGrid.closeTailShort(widget.strategy.id);
      await widget.liveGrid.liveExecution.refreshFuturesSnapshotForSymbol(
        widget.strategy.symbol,
        includeHistory: false,
      );
      if (!mounted) return;
      setState(
        () => _message = 'SHORT 尾单已提交平仓：${closed.price} / ${closed.quantity}',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '平仓 SHORT 尾单失败: $error');
    } finally {
      if (mounted) {
        setState(() => _closingShort = false);
      }
    }
  }

  FutureGridOrder? _tailShort(List<FutureGridOrder> rows) {
    final openRows = rows
        .where(
          (row) =>
              row.side == 'SHORT' &&
              row.status == 'OPEN' &&
              _d(row.quantity) > Decimal.zero,
        )
        .toList(growable: false);
    if (openRows.isEmpty) {
      return null;
    }
    openRows.sort((a, b) => _d(a.price).compareTo(_d(b.price)));
    return openRows.first;
  }

  Decimal? _currentFuturesMarkPrice() {
    try {
      final market = Get.find<MarketDataCoordinator>();
      return market
              .latestFuturesMarkPriceFor(widget.strategy.symbol)
              ?.markPrice ??
          market.latestFuturesMarkPrice?.markPrice;
    } catch (_) {
      return null;
    }
  }

  Decimal? _tailShortLoss(FutureGridOrder? tail, Decimal? markPrice) {
    if (tail == null || markPrice == null) {
      return null;
    }
    final entry = _d(tail.price);
    final quantity = _d(tail.quantity);
    final loss = (markPrice - entry) * quantity;
    return loss > Decimal.zero ? loss : Decimal.zero;
  }

  Decimal _d(String value) => Decimal.tryParse(value) ?? Decimal.zero;

  Stream<List<Order>> _watchLongExposureOrders(String strategyId) {
    final db = Get.find<AppDatabase>();
    return (db.select(db.orders)..where(
      (tbl) =>
          tbl.strategyId.equals(strategyId) &
          tbl.source.isIn([
            'autoSpotGrid',
            AutoSpotGridExecutionService.futuresLongSource,
          ]) &
          tbl.purpose.isIn([
            'gridBuy',
            'gridSell',
            'futuresLongGridBuy',
            'futuresLongGridSell',
          ]) &
          tbl.status.isIn(['filled', 'cancelled']),
    )).watch();
  }

  Widget _binanceFuturesShortOpenOrdersSection() {
    return StreamBuilder<List<ExchangeOpenOrder>>(
      stream: _watchBinanceFuturesShortOpenOrders(widget.strategy.symbol),
      builder: (context, snapshot) {
        final orders = snapshot.data ?? const <ExchangeOpenOrder>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Binance Futures 当前 SHORT 挂单',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed:
                      _closingShort
                          ? null
                          : () =>
                              _refreshBinanceOpenOrders(includeHistory: false),
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新当前挂单'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (orders.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('当前 symbol 没有 Binance Futures SHORT 挂单。'),
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

  Stream<List<ExchangeOpenOrder>> _watchBinanceFuturesShortOpenOrders(
    String symbol,
  ) {
    final db = Get.find<AppDatabase>();
    return (db.select(db.exchangeOpenOrders)
          ..where(
            (tbl) =>
                tbl.accountType.equals('futuresSubAccount') &
                tbl.marketType.equals('usdtFutures') &
                tbl.environment.equals('live') &
                tbl.symbol.equals(symbol.toUpperCase()) &
                (tbl.positionSide.equals('SHORT') |
                    tbl.positionSide.equals('BOTH') |
                    tbl.positionSide.isNull()),
          )
          ..orderBy([
            (tbl) => OrderingTerm(
              expression: tbl.updatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  Future<void> _refreshBinanceOpenOrders({required bool includeHistory}) async {
    setState(() {
      _closingShort = true;
      _message = '';
    });
    try {
      final report = await widget.futureGrid.reconcileStrategy(
        widget.strategy.id,
        includeHistory: includeHistory,
      );
      if (!mounted) return;
      _showSnackBar(
        '${includeHistory ? '完整对账' : '轻量对账'}\n${report.toDisplayText()}',
      );
    } catch (error) {
      if (!mounted) return;
      _showSnackBar('刷新 Binance Futures 当前 SHORT 挂单失败: $error');
    } finally {
      if (mounted) {
        setState(() => _closingShort = false);
      }
    }
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

  String _remainingQuantity(String originalQuantity, String executedQuantity) {
    final original = Decimal.tryParse(originalQuantity) ?? Decimal.zero;
    final executed = Decimal.tryParse(executedQuantity) ?? Decimal.zero;
    final remaining = original - executed;
    return remaining < Decimal.zero ? '0' : remaining.toString();
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
      );
  }
}

class _TailShortRiskBar extends StatelessWidget {
  const _TailShortRiskBar({
    required this.tailShort,
    required this.markPrice,
    required this.tailLoss,
    required this.busy,
    required this.onCloseTail,
  });

  final FutureGridOrder? tailShort;
  final Decimal? markPrice;
  final Decimal? tailLoss;
  final bool busy;
  final VoidCallback onCloseTail;

  @override
  Widget build(BuildContext context) {
    final tail = tailShort;
    final lossText =
        tailLoss == null ? '-' : '${_formatDecimal(tailLoss!)} USDT';
    final detail =
        tail == null
            ? '当前没有 OPEN SHORT 尾单'
            : '尾单价格: ${tail.price} / 数量: ${tail.quantity} / Mark: ${markPrice?.toString() ?? '-'}';
    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '尾单当前亏损: $lossText',
              style: TextStyle(
                color: Colors.orange.shade900,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(detail),
            FilledButton.tonalIcon(
              onPressed: busy || tail == null ? null : onCloseTail,
              icon: const Icon(Icons.call_made),
              label: const Text('一键市价平仓空单尾单'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.strategy});

  final Strategy strategy;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前策略：${strategy.name}'),
            Text('策略ID：${strategy.id}'),
            Text('当前币对：${strategy.symbol}'),
            const Text('模式：现货网格 + 成交触发价格层对冲'),
          ],
        ),
      ),
    );
  }
}

class _StageCard extends StatelessWidget {
  const _StageCard({required this.stage});

  final FutureGridStage stage;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.blueGrey.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text('当前阶段：${stage.title}'), Text('原因：${stage.reason}')],
        ),
      ),
    );
  }
}

class _HedgeRuleCard extends StatelessWidget {
  const _HedgeRuleCard({required this.strategy});

  final Strategy strategy;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('对冲判断说明'),
            Text('中间价：${strategy.centerPrice}'),
            const Text('Spot BUY 成交且价格层属于最低分摊层时，才检查是否需要开空。'),
            const Text('最低分摊层数量由策略里的“下方均摊层数”控制。'),
            const Text('开空数量 = 当前 Binance 现货多单敞口 - 当前 Binance 空单总量。'),
            const Text('差值大于 0 时，使用 Futures 市价 SELL 增加空单，并记录到当前价格层。'),
            const Text('Spot SELL 成交时，只平匹配价格层的空单，使用 BUY reduceOnly。'),
          ],
        ),
      ),
    );
  }
}

class _FutureGridTable extends StatelessWidget {
  const _FutureGridTable({
    required this.levels,
    required this.rows,
    required this.exposureOrders,
    required this.centerPrice,
    required this.currentPrice,
    required this.shortHedgeMultiplier,
    required this.shortHedgeSpreadLevels,
    required this.showNonHedgeLayers,
    required this.filter,
  });

  final List<GridLevel> levels;
  final List<FutureGridOrder> rows;
  final List<Order> exposureOrders;
  final String centerPrice;
  final Decimal? currentPrice;
  final Decimal shortHedgeMultiplier;
  final int shortHedgeSpreadLevels;
  final bool showNonHedgeLayers;
  final _ShortFutureLifecycleFilter filter;

  @override
  Widget build(BuildContext context) {
    if (levels.isEmpty) {
      return const Text('当前策略没有价格层。');
    }
    final rowsByGrid = {for (final row in rows) row.spotGridOrderId: row};
    final hedgeLayerIds = _bottomHedgeLayerIds(levels);
    final spreadActivated = _spreadActivated(
      levels: levels,
      hedgeLayerIds: hedgeLayerIds,
      rowsByGrid: rowsByGrid,
    );
    final targetTotalShort =
        spreadActivated
            ? _openLongQuantity() * shortHedgeMultiplier
            : Decimal.zero;
    final ownLayerTargetTotal =
        spreadActivated
            ? _plannedLongQuantityForHedgeLayers(levels, hedgeLayerIds) *
                shortHedgeMultiplier
            : Decimal.zero;
    final openLayerShortQuantity = _openLayerShortQuantity();
    final spreadLevels = hedgeLayerIds.length;
    final layerSpreadTarget =
        spreadLevels <= 0
            ? Decimal.zero
            : (targetTotalShort / Decimal.fromInt(spreadLevels)).toDecimal(
              scaleOnInfinitePrecision: 12,
            );
    final totalRemaining =
        targetTotalShort + ownLayerTargetTotal - openLayerShortQuantity;
    final visibleLevels =
        showNonHedgeLayers
            ? levels
            : levels
                .where((level) => hedgeLayerIds.contains(level.id))
                .toList(growable: false);
    final filteredLevels = visibleLevels
        .where((level) => _matchesFilter(rowsByGrid[level.id], filter))
        .toList(growable: false);
    final sortedLevels = [...filteredLevels]..sort(
      (a, b) => _decimal(
        b.buyPrice ?? b.price,
      ).compareTo(_decimal(a.buyPrice ?? a.price)),
    );
    if (sortedLevels.isEmpty) {
      return const Text('当前筛选条件下没有 SHORT 价格层。');
    }
    return DataTable(
      columns: const [
        DataColumn(label: Text('价格层')),
        DataColumn(label: Text('spot 状态')),
        DataColumn(label: Text('是否处于需要对冲层级')),
        DataColumn(label: Text('future状态')),
        DataColumn(label: Text('已记录空单数量')),
        DataColumn(label: Text('分摊数量')),
        DataColumn(label: Text('当前层需对冲数量')),
        DataColumn(label: Text('仍需补开数量')),
        DataColumn(label: Text('关联 Spot Grid')),
      ],
      rows: [
        for (final level in sortedLevels)
          _layerRow(
            level: level,
            future: rowsByGrid[level.id],
            needsHedge: hedgeLayerIds.contains(level.id),
            layerSpreadTarget: layerSpreadTarget,
            totalRemaining: totalRemaining,
          ),
      ],
    );
  }

  bool _matchesFilter(
    FutureGridOrder? row,
    _ShortFutureLifecycleFilter filter,
  ) {
    if (filter == _ShortFutureLifecycleFilter.all) {
      return true;
    }
    return _shortFutureFilterFor(row) == filter;
  }

  _ShortFutureLifecycleFilter _shortFutureFilterFor(FutureGridOrder? row) {
    switch (row?.status) {
      case 'WAIT_OPEN':
        return _ShortFutureLifecycleFilter.submitted;
      case 'OPEN':
        return _ShortFutureLifecycleFilter.open;
      case 'CLOSING':
      case 'CLOSE_SUBMITTED':
        return _ShortFutureLifecycleFilter.closing;
      case 'CLOSED':
        return _ShortFutureLifecycleFilter.completed;
      case 'FAILED':
        return _ShortFutureLifecycleFilter.error;
      case 'WAIT_TRIGGER':
      default:
        return _ShortFutureLifecycleFilter.waitingOpen;
    }
  }

  DataRow _layerRow({
    required GridLevel level,
    required FutureGridOrder? future,
    required bool needsHedge,
    required Decimal layerSpreadTarget,
    required Decimal totalRemaining,
  }) {
    final priceText = level.buyPrice ?? level.price;
    final recordedShort =
        future?.status == 'OPEN' ? _d(future?.quantity ?? '0') : Decimal.zero;
    final layerLongTarget = _d(level.plannedQuantity) * shortHedgeMultiplier;
    final layerTarget =
        needsHedge ? layerSpreadTarget + layerLongTarget : Decimal.zero;
    final layerRemaining = layerTarget - recordedShort;
    final requiredHedge =
        !needsHedge
            ? Decimal.zero
            : _minPositive(layerRemaining, totalRemaining);
    return DataRow(
      cells: [
        DataCell(Text(priceText)),
        DataCell(Text(level.lifecycleStatus ?? level.status)),
        DataCell(Text(needsHedge ? '是' : '否')),
        DataCell(Text(future?.status ?? '-')),
        DataCell(Text(future?.quantity ?? '0')),
        DataCell(Text(needsHedge ? _formatQty(layerSpreadTarget) : '0')),
        DataCell(Text(_formatQty(layerTarget))),
        DataCell(Text(_formatQty(requiredHedge))),
        DataCell(Text(level.id)),
      ],
    );
  }

  Set<String> _bottomHedgeLayerIds(List<GridLevel> allLevels) {
    final requested = shortHedgeSpreadLevels <= 0 ? 1 : shortHedgeSpreadLevels;
    final sorted = allLevels
      .where((level) => _decimal(level.buyPrice ?? level.price) > 0)
      .toList(growable: false)..sort(
      (a, b) => _decimal(
        a.buyPrice ?? a.price,
      ).compareTo(_decimal(b.buyPrice ?? b.price)),
    );
    return sorted.take(requested).map((level) => level.id).toSet();
  }

  bool _spreadActivated({
    required List<GridLevel> levels,
    required Set<String> hedgeLayerIds,
    required Map<String, FutureGridOrder> rowsByGrid,
  }) {
    if (hedgeLayerIds.isEmpty) {
      return false;
    }
    final activeFuture = rowsByGrid.values.any(
      (row) =>
          hedgeLayerIds.contains(row.spotGridOrderId) &&
          row.side == 'SHORT' &&
          row.status != 'WAIT_TRIGGER' &&
          _d(row.quantity) > Decimal.zero,
    );
    if (activeFuture) {
      return true;
    }
    final activeLevel = levels.any((level) {
      if (!hedgeLayerIds.contains(level.id)) {
        return false;
      }
      final status = level.lifecycleStatus ?? level.status;
      return !{'waitingBuy', 'planned', 'ready'}.contains(status);
    });
    if (activeLevel) {
      return true;
    }
    final price = currentPrice;
    if (price == null || price <= Decimal.zero) {
      return false;
    }
    final firstSpreadPrice = levels
        .where((level) => hedgeLayerIds.contains(level.id))
        .map((level) => _d(level.buyPrice ?? level.price))
        .where((value) => value > Decimal.zero)
        .fold<Decimal?>(null, (max, value) {
          if (max == null || value > max) return value;
          return max;
        });
    return firstSpreadPrice != null && price <= firstSpreadPrice;
  }

  Decimal _openLongQuantity() {
    return _netLongQuantity(exposureOrders);
  }

  Decimal _plannedLongQuantityForHedgeLayers(
    List<GridLevel> allLevels,
    Set<String> hedgeGridIds,
  ) {
    var quantity = Decimal.zero;
    for (final level in allLevels) {
      if (hedgeGridIds.contains(level.id)) {
        quantity += _d(level.plannedQuantity);
      }
    }
    return quantity;
  }

  Decimal _netLongQuantity(List<Order> orders) {
    var quantity = Decimal.zero;
    for (final order in orders) {
      final executed = _d(order.executedQuantity);
      quantity += order.side == 'BUY' ? executed : -executed;
    }
    return quantity > Decimal.zero ? quantity : Decimal.zero;
  }

  Decimal _openLayerShortQuantity() {
    var quantity = Decimal.zero;
    for (final row in rows) {
      if (row.status == 'OPEN') {
        quantity += _d(row.quantity);
      }
    }
    return quantity;
  }

  Decimal _minPositive(Decimal a, Decimal b) {
    if (a <= Decimal.zero || b <= Decimal.zero) {
      return Decimal.zero;
    }
    return a < b ? a : b;
  }

  String _formatQty(Decimal value) {
    if (value <= Decimal.zero) {
      return '0';
    }
    return value.toString();
  }

  Decimal _d(String value) => Decimal.tryParse(value) ?? Decimal.zero;

  double _decimal(String value) => double.tryParse(value) ?? 0;
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

String _formatDecimal(Decimal value) {
  return value.toString();
}
