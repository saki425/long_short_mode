import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/app_navigation_controller.dart';
import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../services/app_ui_settings.dart';
import '../services/execution/auto_spot_grid_execution_service.dart';

class StrategyPage extends StatefulWidget {
  const StrategyPage({super.key});

  @override
  State<StrategyPage> createState() => _StrategyPageState();
}

String _baseAssetForSymbol(String symbol) {
  final normalized = symbol.toUpperCase();
  if (normalized.endsWith('USDT')) {
    return normalized.substring(0, normalized.length - 4);
  }
  return normalized;
}

String _displaySymbol(String symbol) {
  final normalized = symbol.toUpperCase();
  if (normalized.endsWith('USDT')) {
    return '${normalized.substring(0, normalized.length - 4)}/USDT';
  }
  return normalized;
}

class _StrategyPageState extends State<StrategyPage> {
  late final AutoSpotGridExecutionService _liveGrid;
  String _liveMessage = '';

  @override
  void initState() {
    super.initState();
    _liveGrid = Get.find<AutoSpotGridExecutionService>();
  }

  Future<void> _createLiveStrategy({required String executionMode}) async {
    final active = Get.find<SymbolWorkspaceController>().activeSymbol.value;
    if (active == null) {
      setState(() => _liveMessage = '请先添加并选择交易币对。');
      return;
    }
    final isFuturesGrid =
        executionMode == LiveSpotGridEditableConfig.futuresGridHedge;
    final center = Decimal.tryParse(active.lastTickerPrice ?? '') ??
        Decimal.fromInt(60000);
    final config = LiveSpotGridEditableConfig.defaults(
      centerPrice: center,
      symbol: active.symbol,
      name: isFuturesGrid
          ? '${active.symbol} LIVE Futures Long Grid'
          : '${active.symbol} LIVE Spot Grid',
      spotCapital: await _liveGrid.capitalLimit(symbol: active.symbol),
      executionMode: executionMode,
    );
    if (!mounted) return;
    final edited = await showDialog<LiveSpotGridEditableConfig>(
      context: context,
      builder: (context) => _LiveStrategyEditDialog(config: config),
    );
    if (edited == null) return;
    final id = await _liveGrid.createStrategyFromConfig(edited);
    final modeText = edited.isFuturesGridHedge ? '合约网格策略' : 'LIVE 现货网格策略';
    setState(() => _liveMessage = '已创建 $modeText: $id');
  }

  Future<void> _preflight(Strategy strategy) async {
    final result = await _liveGrid.preflight(strategy.id);
    setState(
      () => _liveMessage =
          result.ok ? '启动前检查通过。' : '启动前检查失败:\n${_issuesText(result.issues)}',
    );
  }

  Future<void> _dryRun(Strategy strategy) async {
    final report = await _liveGrid.dryRun(strategy.id);
    setState(() => _liveMessage = report.toDisplayText());
  }

  Future<void> _editLiveStrategy(Strategy strategy) async {
    final config = await _liveGrid.loadEditableConfig(strategy.id);
    if (config == null || !mounted) return;
    final edited = await showDialog<LiveSpotGridEditableConfig>(
      context: context,
      builder: (context) => _LiveStrategyEditDialog(config: config),
    );
    if (edited == null) return;
    var leverageSaved = false;
    var shortHedgeSaved = false;
    try {
      if (edited.enableFutureHedgeGrid || edited.isFuturesGridHedge) {
        await _liveGrid.updateShortHedgeSettings(
          strategy.id,
          multiplier: edited.shortHedgeMultiplier,
          spreadLevels: edited.shortHedgeSpreadLevels,
        );
        shortHedgeSaved = true;
      }
      if (edited.isFuturesGridHedge) {
        await _liveGrid.updateFuturesLeverage(
          strategy.id,
          edited.futuresLeverage,
        );
        leverageSaved = true;
      }
      await _liveGrid.updateEditableConfig(strategy.id, edited);
      final saved = await _liveGrid.loadEditableConfig(strategy.id);
      final leverageText = saved?.isFuturesGridHedge == true
          ? ' 合约杠杆: ${saved?.futuresLeverage ?? edited.futuresLeverage}x。'
          : '';
      final longEntryTriggerText = saved?.isFuturesGridHedge == true
          ? ' 开多提前触发: ${saved?.longEntryTriggerDistanceUsdt ?? edited.longEntryTriggerDistanceUsdt} USDT。'
          : '';
      final shortHedgeText = saved?.enableFutureHedgeGrid == true ||
              saved?.isFuturesGridHedge == true
          ? ' SHORT对冲: ${saved?.shortHedgeMultiplier ?? edited.shortHedgeMultiplier}x / 均摊${saved?.shortHedgeSpreadLevels ?? edited.shortHedgeSpreadLevels}层。'
          : '';
      setState(
        () => _liveMessage =
            '策略配置已保存，并已重新生成本地网格计划。$leverageText$longEntryTriggerText$shortHedgeText',
      );
    } catch (error) {
      final savedParts = [
        if (shortHedgeSaved) 'SHORT对冲参数已保存',
        if (leverageSaved) '合约杠杆已保存',
      ];
      final prefix = savedParts.isEmpty
          ? '策略配置保存失败'
          : '${savedParts.join('，')}，其它策略配置保存失败';
      setState(() => _liveMessage = '$prefix：$error');
    }
  }

  Future<void> _editMaxOpenOrders(Strategy strategy) async {
    final config = await _liveGrid.loadEditableConfig(strategy.id);
    if (config == null || !mounted) return;
    final maxOpenOrders = await showDialog<int>(
      context: context,
      builder: (context) => _MaxOpenOrdersDialog(config: config),
    );
    if (maxOpenOrders == null) return;
    try {
      await _liveGrid.updateMaxOpenOrders(strategy.id, maxOpenOrders);
      setState(() => _liveMessage = '最大活动挂单数已更新为 $maxOpenOrders。');
    } catch (error) {
      setState(() => _liveMessage = '最大活动挂单数保存失败：$error');
    }
  }

  Future<void> _editFuturesLeverage(Strategy strategy) async {
    final config = await _liveGrid.loadEditableConfig(strategy.id);
    if (config == null || !mounted) return;
    final leverage = await showDialog<int>(
      context: context,
      builder: (context) => _FuturesLeverageDialog(config: config),
    );
    if (leverage == null) return;
    try {
      await _liveGrid.updateFuturesLeverage(strategy.id, leverage);
      final saved = await _liveGrid.loadEditableConfig(strategy.id);
      setState(
        () => _liveMessage =
            '合约杠杆倍数已保存为 ${saved?.futuresLeverage ?? leverage.clamp(1, 125)}x。',
      );
    } catch (error) {
      setState(() => _liveMessage = '合约杠杆倍数保存失败：$error');
    }
  }

  Future<void> _editShortHedgeSettings(Strategy strategy) async {
    final config = await _liveGrid.loadEditableConfig(strategy.id);
    if (config == null || !mounted) return;
    final settings = await showDialog<_ShortHedgeSettingsResult>(
      context: context,
      builder: (context) => _ShortHedgeSettingsDialog(config: config),
    );
    if (settings == null) return;
    try {
      await _liveGrid.updateShortHedgeSettings(
        strategy.id,
        multiplier: settings.multiplier,
        spreadLevels: settings.spreadLevels,
      );
      final saved = await _liveGrid.loadEditableConfig(strategy.id);
      setState(
        () => _liveMessage =
            'SHORT 对冲参数已保存：${saved?.shortHedgeMultiplier ?? settings.multiplier}x / 均摊 ${saved?.shortHedgeSpreadLevels ?? settings.spreadLevels} 层。',
      );
    } catch (error) {
      setState(() => _liveMessage = 'SHORT 对冲参数保存失败：$error');
    }
  }

  Future<void> _copyLiveStrategy(Strategy strategy) async {
    try {
      final id = await _liveGrid.copyStrategy(strategy.id);
      setState(() => _liveMessage = '已复制为新策略: $id');
    } catch (error) {
      setState(() => _liveMessage = '复制策略失败：$error');
    }
  }

  Future<void> _deleteLiveStrategy(Strategy strategy) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除策略'),
        content: const Text('只允许删除没有订单记录的未运行策略。确认删除当前本地策略和网格计划？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _liveGrid.deleteStrategy(strategy.id);
      setState(() => _liveMessage = '策略已删除。');
    } catch (error) {
      setState(() => _liveMessage = '删除策略失败：$error');
    }
  }

  Future<void> _archiveCurrentStrategy(Strategy strategy) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('归档当前策略'),
        content: const Text(
          '归档后该策略会变成旧策略，订单、成交和审计记录保留；Grid 和 Grid Future 将不再显示该策略网格。归档前策略必须已停止或满足安全停止条件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认归档'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _liveGrid.archiveStoppedStrategy(strategy.id);
      setState(() => _liveMessage = '当前策略已归档为旧策略，历史订单和成交保留。');
    } catch (error) {
      setState(() => _liveMessage = '归档当前策略失败：$error');
    }
  }

  Future<void> _moveGridBand(Strategy strategy, {required bool up}) async {
    final directionText = up ? '上移' : '下移';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('网格$directionText一格'),
        content: Text(
          '将在当前策略内按网格宽度$directionText一格，不归档策略、不移动历史订单。'
          '如果即将移出区间的边缘网格存在订单、完成循环或未处理空单价格层，操作会被阻止。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('确认$directionText'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _liveGrid.moveGridBandOneStep(strategy.id, up: up);
      setState(() => _liveMessage = '网格已$directionText一格。');
    } catch (error) {
      setState(() => _liveMessage = '网格$directionText失败：$error');
    }
  }

  Future<void> _resetForFreshStart() async {
    final controller = TextEditingController();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重置测试环境'),
          content: SizedBox(
            width: 620,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '该操作会撤销当前现货子账户内本程序 LIVE 挂单，并归档本地所有 LIVE 现货网格策略。',
                ),
                const SizedBox(height: 8),
                const Text('不会删除历史订单和成交记录。'),
                const Text('不会卖出任何资产。'),
                const Text('如果任意撤单失败，本地策略不会被归档。'),
                const SizedBox(height: 12),
                const Text('请输入 RESET 确认：'),
                const SizedBox(height: 6),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'RESET',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade700,
              ),
              onPressed: () {
                Navigator.of(
                  context,
                ).pop(controller.text.trim() == 'RESET');
              },
              child: const Text('撤销订单并归档策略'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        setState(() => _liveMessage = '已取消重置测试环境。');
        return;
      }
      final report = await _liveGrid.resetForFreshStart();
      setState(() => _liveMessage = report.toDisplayText());
    } catch (error) {
      setState(() => _liveMessage = '重置测试环境失败：$error');
    } finally {
      controller.dispose();
    }
  }

  Future<void> _confirmBtcInventory(Strategy strategy) async {
    try {
      final baseAsset = _baseAssetForSymbol(strategy.symbol);
      final inventory = await _liveGrid.loadBtcInventory(strategy.id);
      if (!mounted) return;
      final result = await showDialog<(Decimal, Decimal)>(
        context: context,
        builder: (context) => _BtcInventoryDialog(
          inventory: inventory,
          baseAsset: baseAsset,
          defaultExternalAll: true,
        ),
      );
      if (result == null) return;
      await _liveGrid.confirmBtcInventory(
        strategyId: strategy.id,
        strategyBtc: result.$1,
        externalBtc: result.$2,
      );
      setState(
        () => _liveMessage =
            '$baseAsset 归属已确认：strategy$baseAsset=${result.$1}, external$baseAsset=${result.$2}',
      );
    } catch (error) {
      setState(() => _liveMessage = '确认资产归属失败：$error');
    }
  }

  Future<void> _showConflictStrategies(Strategy strategy) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<List<LiveSpotGridConflict>> load() =>
              _liveGrid.conflictingLiveStrategies(strategy.id);
          return AlertDialog(
            title: const Text('冲突策略处理'),
            content: SizedBox(
              width: 920,
              child: FutureBuilder<List<LiveSpotGridConflict>>(
                future: load(),
                builder: (context, snapshot) {
                  final conflicts = snapshot.data ?? const [];
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const SizedBox(
                      height: 120,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (conflicts.isEmpty) {
                    return const Text('没有发现冲突策略。');
                  }
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () async {
                            await _batchCleanConflicts(strategy.id);
                            if (context.mounted) setDialogState(() {});
                          },
                          icon: const Icon(Icons.cleaning_services),
                          label: const Text('检查并清理无活动订单的旧策略'),
                        ),
                        const SizedBox(height: 8),
                        for (final item in conflicts)
                          _ConflictStrategyCard(
                            item: item,
                            onOpen: () {
                              setState(
                                () =>
                                    _liveMessage = '冲突策略ID：${item.strategyId}',
                              );
                            },
                            onReconcile: () async {
                              await _liveGrid.reconcile(item.strategyId);
                              setDialogState(() {});
                            },
                            onOrders: () =>
                                _showStrategyOrders(item.strategyId),
                            onExchangeOrders: () => _showStrategyExchangeOrders(
                              item.strategyId,
                            ),
                            onFills: () => _showStrategyFills(item.strategyId),
                            onBtc: () => _showOldStrategyBtcDialog(
                              item.strategyId,
                            ),
                            onSafeStop: () async {
                              await _liveGrid.stop(item.strategyId);
                              setDialogState(() {});
                            },
                            onCancelExchangeOrders: () async {
                              await _liveGrid.cancelStrategyExchangeOpenOrders(
                                item.strategyId,
                              );
                              setDialogState(() {});
                            },
                            onMarkStopped: () async {
                              await _liveGrid.markStoppedAfterNoExchangeOrders(
                                item.strategyId,
                              );
                              setDialogState(() {});
                            },
                            onArchive: () async {
                              await _liveGrid.archiveStoppedStrategy(
                                item.strategyId,
                              );
                              setDialogState(() {});
                            },
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showStrategyOrders(String strategyId) async {
    final orders = await _liveGrid.strategyOrders(strategyId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('策略订单'),
        content: SizedBox(
          width: 820,
          child: SingleChildScrollView(
            child: SelectableText(
              orders.isEmpty
                  ? '没有本地订单。'
                  : orders
                      .map(
                        (o) =>
                            '${o.status} ${o.side} ${o.orderType} price=${o.price ?? '-'} qty=${o.originalQuantity} executed=${o.executedQuantity} client=${o.clientOrderId} exchange=${o.exchangeOrderId ?? '-'}',
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

  Future<void> _showStrategyExchangeOrders(String strategyId) async {
    await _liveGrid.liveExecution.refreshSpotSnapshot();
    final orders = await _liveGrid.strategyExchangeOpenOrders(strategyId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Binance 当前挂单'),
        content: SizedBox(
          width: 860,
          child: SingleChildScrollView(
            child: SelectableText(
              orders.isEmpty
                  ? 'Binance 当前没有本程序关联的当前策略现货挂单。'
                  : orders
                      .map(
                        (o) =>
                            '${o.status} ${o.side} ${o.orderType} price=${o.price} qty=${o.originalQuantity} executed=${o.executedQuantity} client=${o.clientOrderId} exchange=${o.exchangeOrderId}',
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

  Future<void> _showStrategyFills(String strategyId) async {
    final fills = await _liveGrid.strategyFills(strategyId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('策略成交'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: SelectableText(
              fills.isEmpty
                  ? '没有成交。'
                  : fills
                      .map(
                        (f) =>
                            '${f.tradeTime.toLocal()} ${f.side} price=${f.price} qty=${f.quantity} quote=${f.quoteQuantity} fee=${f.commission} ${f.commissionAsset}',
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

  Future<void> _showOldStrategyBtcDialog(String strategyId) async {
    final strategy = await (_liveGrid.db.select(_liveGrid.db.strategies)
          ..where((tbl) => tbl.id.equals(strategyId)))
        .getSingleOrNull();
    if (!mounted || strategy == null) return;
    final btc = Decimal.tryParse(strategy.strategySpotBtc) ?? Decimal.zero;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('旧策略资产处理'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText('strategyId: $strategyId'),
              Text('策略资产: $btc'),
              const SizedBox(height: 8),
              const Text('默认 E：暂不处理。strategyBtc 不为 0 时不能直接清理旧策略。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('E 暂不处理'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('A 保留为旧策略资产'),
          ),
          FilledButton(
            onPressed: btc <= Decimal.zero
                ? null
                : () async {
                    await _liveGrid.moveStrategyBtcToExternal(strategyId);
                    if (context.mounted) Navigator.of(context).pop();
                  },
            child: const Text('B 转为 externalBtc'),
          ),
          const OutlinedButton(onPressed: null, child: Text('C 转给新策略')),
          const OutlinedButton(onPressed: null, child: Text('D 卖出策略资产')),
        ],
      ),
    );
  }

  Future<void> _batchCleanConflicts(String currentStrategyId) async {
    final conflicts = await _liveGrid.conflictingLiveStrategies(
      currentStrategyId,
    );
    final safe = conflicts.where((item) => item.canMarkStopped).toList();
    if (!mounted) return;
    final selected = <String>{for (final item in safe) item.strategyId};
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('批量清理无活动订单的旧策略'),
          content: SizedBox(
            width: 760,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (safe.isEmpty)
                    const Text('没有满足安全条件的旧策略。')
                  else
                    for (final item in safe)
                      CheckboxListTile(
                        value: selected.contains(item.strategyId),
                        onChanged: (value) {
                          setDialogState(() {
                            if (value == true) {
                              selected.add(item.strategyId);
                            } else {
                              selected.remove(item.strategyId);
                            }
                          });
                        },
                        title: Text(item.strategyId),
                        subtitle: Text(
                          '状态=${item.status}, strategyBtc=${item.strategyBtc}, Binance挂单=${item.binanceActiveOrders}, 本地活动=${item.localActiveOrders}',
                        ),
                      ),
                  const Divider(),
                  const Text('不会删除历史订单和成交数据，只把勾选策略状态改为 stopped。'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () async {
                      for (final id in selected) {
                        await _liveGrid.markStoppedAfterNoExchangeOrders(id);
                      }
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
              child: const Text('确认批量标记 stopped'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _recoveryReport(Strategy strategy) async {
    try {
      final report = await _liveGrid.buildRecoveryReport(strategy.id);
      setState(() => _liveMessage = report.toDisplayText());
    } catch (error) {
      setState(() => _liveMessage = '恢复报告生成失败：${_friendlyStartError(error)}');
    }
  }

  Future<void> _reconcile(Strategy strategy) async {
    try {
      await _liveGrid.reconcile(strategy.id);
      setState(() => _liveMessage = 'REST 对账完成。');
    } catch (error) {
      setState(() => _liveMessage = 'REST 对账失败：${_friendlyStartError(error)}');
    }
  }

  Future<void> _runLiveAction(
    String successMessage,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      if (!mounted) return;
      setState(() => _liveMessage = successMessage);
    } catch (error) {
      if (!mounted) return;
      setState(() => _liveMessage = '操作失败：${_friendlyStartError(error)}');
    }
  }

  Future<void> _startLive(Strategy strategy) async {
    final baseAsset = _baseAssetForSymbol(strategy.symbol);
    final displaySymbol = _displaySymbol(strategy.symbol);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启动 LIVE 现货网格'),
        content: Text(
          '这会在正式币安现货账户自动提交 $displaySymbol 网格订单，并可能建立初始 $baseAsset 库存。确认继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认启动 LIVE 网格'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    final result = await _showStartProgress(strategy);
    setState(() => _liveMessage = result);
  }

  Future<void> _startFuturesLongGrid(Strategy strategy) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启动 LIVE 合约 LONG 网格'),
        content: Text(
          '这会在 Binance Futures 为 ${_displaySymbol(strategy.symbol)} 提交 LONG BUY 限价挂单。'
          '资金来自合约账户，SHORT 对冲仍按价格层成交触发。确认继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认启动合约网格'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final report = await _liveGrid.startFuturesLongGrid(strategy.id);
      if (!mounted) return;
      setState(() => _liveMessage = report.toDisplayText());
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _liveMessage = '合约 LONG 网格启动失败：${_friendlyStartError(error)}',
      );
    }
  }

  Future<void> _recoverFuturesLongGrid(Strategy strategy) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复并对账 LONG 网格'),
        content: Text(
          '这会刷新 Binance Futures 订单、挂单和仓位，并按交易所真实状态恢复 ${_displaySymbol(strategy.symbol)} 的 LONG 网格。'
          '如果没有仍需处理的异常，会把策略恢复为 running 并清空旧错误。确认继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认恢复并对账'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final report = await _liveGrid.recoverAndReconcileFuturesLongGrid(
        strategy.id,
      );
      if (!mounted) return;
      setState(() => _liveMessage = report.toDisplayText());
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _liveMessage = '恢复并对账 LONG 网格失败：${_friendlyStartError(error)}',
      );
    }
  }

  Future<String> _showStartProgress(Strategy strategy) async {
    final baseAsset = _baseAssetForSymbol(strategy.symbol);
    final steps = <String, String>{
      '正在校验账户': 'pending',
      '正在校验余额': 'pending',
      '正在计算初始 $baseAsset': 'pending',
      '正在提交初始 $baseAsset 买入': 'pending',
      '正在等待初始买入成交': 'pending',
      '正在提交下方 BUY 网格': 'pending',
      '正在提交上方 SELL 网格': 'pending',
      '正在确认 Binance 订单': 'pending',
      '正在执行 REST 对账': 'pending',
      '启动完成': 'pending',
    };
    var detail = '';
    var result = '启动流程已执行。';
    var issues = <LiveSpotGridPreflightIssue>[];
    Future<void> runStart(
      BuildContext dialogContext,
      StateSetter setDialogState,
    ) async {
      try {
        issues = [];
        await _liveGrid.startWithProgress(
          strategy.id,
          onStep: (update) {
            if (!dialogContext.mounted) return;
            setDialogState(() {
              steps[update.step] = update.status;
              detail = update.message ?? detail;
            });
          },
        );
        final report = await _liveGrid.buildRecoveryReport(strategy.id);
        result = 'LIVE 网格已启动\n'
            '当前活动挂单数：${report.localOpenOrders}\n'
            'strategy$baseAsset：${report.strategyBtc}\n'
            '启动时间：${DateTime.now().toLocal()}';
      } catch (error) {
        issues = await _liveGrid.preflightIssues(strategy.id);
        result = 'LIVE 网格启动失败\n'
            '失败信息：${_friendlyStartError(error)}\n'
            '如果已有部分订单提交，策略将进入对账/暂停状态，请执行恢复报告。';
        if (dialogContext.mounted) {
          setDialogState(
            () => detail = _issuesText(issues, fallback: '$error'),
          );
        }
      } finally {
        if (dialogContext.mounted) {
          setDialogState(() {});
        }
      }
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        var started = false;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            if (!started) {
              started = true;
              // The task needs the dialog context so it can check mounted before updating the dialog.
              // ignore: use_build_context_synchronously
              Future<void>(() => runStart(dialogContext, setDialogState));
            }
            final done = steps['启动完成'] == 'success' ||
                result.startsWith('LIVE 网格启动失败') ||
                steps.values.contains('failed');
            return AlertDialog(
              title: const Text('LIVE 网格启动步骤'),
              content: SizedBox(
                width: 760,
                height: MediaQuery.sizeOf(context).height * 0.72,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        for (final entry in steps.entries)
                          Chip(
                            label: Text('${entry.key}: ${entry.value}'),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: _startStepColor(entry.value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (detail.isNotEmpty) ...[
                              const Divider(),
                              SelectableText(detail),
                            ],
                            if (issues.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              for (final issue in issues)
                                _PreflightIssueTile(
                                  issue: issue,
                                  onAction: () async {
                                    await _handlePreflightIssueAction(
                                      strategy,
                                      issue,
                                    );
                                    final next = await _liveGrid
                                        .preflightIssues(strategy.id);
                                    if (dialogContext.mounted) {
                                      setDialogState(() {
                                        issues = next;
                                        detail = _issuesText(next);
                                      });
                                    }
                                  },
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: done
                      ? () async {
                          for (final key in steps.keys.toList()) {
                            steps[key] = 'pending';
                          }
                          result = '启动流程已执行。';
                          detail = '';
                          issues = [];
                          setDialogState(() {});
                          await runStart(dialogContext, setDialogState);
                        }
                      : null,
                  child: const Text('重新运行检查'),
                ),
                FilledButton(
                  onPressed:
                      done ? () => Navigator.of(dialogContext).pop() : null,
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
    return result;
  }

  Future<void> _handlePreflightIssueAction(
    Strategy strategy,
    LiveSpotGridPreflightIssue issue,
  ) async {
    switch (issue.type) {
      case LiveSpotGridPreflightIssueType.exchangeRules:
        await _liveGrid.reloadSpotRules();
      case LiveSpotGridPreflightIssueType.conflictingStrategy:
        await _showConflictStrategies(strategy);
      case LiveSpotGridPreflightIssueType.btcClassification:
        await _confirmBtcInventory(strategy);
      case LiveSpotGridPreflightIssueType.liveTrading:
        Get.find<AppNavigationController>().selectPage(6);
      case LiveSpotGridPreflightIssueType.spotRest:
      case LiveSpotGridPreflightIssueType.unknownOrders:
        await _liveGrid.reconcile(strategy.id);
      default:
        break;
    }
  }

  String _issuesText(
    List<LiveSpotGridPreflightIssue> issues, {
    String fallback = '',
  }) {
    if (issues.isEmpty) return fallback;
    return issues
        .map(
          (issue) =>
              '[${_issueStatusText(issue.status)}] ${issue.title}: ${issue.message}',
        )
        .join('\n');
  }

  String _issueStatusText(String status) {
    return switch (status) {
      'passed' => '通过',
      'failed' => '失败',
      'blocked' => '阻塞',
      _ => status,
    };
  }

  String _friendlyStartError(Object error) {
    if (error is MissingExchangeRulesException ||
        error is ConflictingLiveStrategyException ||
        error is UnclassifiedAssetException ||
        error is LiveTradingDisabledException) {
      return error.toString();
    }
    final text = error.toString();
    return text.startsWith('Bad state: ') ? text.substring(11) : text;
  }

  Color _startStepColor(String status) {
    return switch (status) {
      'success' => Colors.green.shade50,
      'failed' => Colors.red.shade50,
      'running' => Colors.blue.shade50,
      _ => Colors.grey.shade100,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('策略')),
      body: Obx(() {
        final active = Get.find<SymbolWorkspaceController>().activeSymbol.value;
        final symbol = active?.symbol;
        if (active == null || symbol == null) {
          return const Center(child: Text('请先添加交易币对'));
        }
        return StreamBuilder<bool>(
          stream: AppUiSettings.watchHideSpotUiForSymbol(
            Get.find<AppDatabase>(),
            symbol: symbol,
          ),
          initialData: false,
          builder: (context, hideSpotSnapshot) {
            final hideSpotUi = hideSpotSnapshot.data ?? false;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('当前币对：${active.displayName}'),
                const SizedBox(height: 8),
                if (!hideSpotUi) ...[
                  StreamBuilder<Strategy?>(
                    stream: _liveGrid.watchActiveStrategy(symbol: symbol),
                    builder: (context, snapshot) => _LiveSpotGridSection(
                      strategy: snapshot.data,
                      liveGrid: _liveGrid,
                      message: _liveMessage,
                      onCreateSpot: () => _createLiveStrategy(
                        executionMode:
                            LiveSpotGridEditableConfig.spotGridFuturesHedge,
                      ),
                      onEdit: snapshot.data == null
                          ? null
                          : () => _editLiveStrategy(snapshot.data!),
                      onEditMaxOpenOrders: snapshot.data == null
                          ? null
                          : () => _editMaxOpenOrders(snapshot.data!),
                      onCopy: snapshot.data == null
                          ? null
                          : () => _copyLiveStrategy(snapshot.data!),
                      onDelete: snapshot.data == null
                          ? null
                          : () => _deleteLiveStrategy(snapshot.data!),
                      onArchiveCurrent: snapshot.data == null
                          ? null
                          : () => _archiveCurrentStrategy(snapshot.data!),
                      onMoveUp: snapshot.data == null
                          ? null
                          : () => _moveGridBand(snapshot.data!, up: true),
                      onMoveDown: snapshot.data == null
                          ? null
                          : () => _moveGridBand(snapshot.data!, up: false),
                      onConfirmBtc: snapshot.data == null
                          ? null
                          : () => _confirmBtcInventory(snapshot.data!),
                      onPreflight: snapshot.data == null
                          ? null
                          : () => _preflight(snapshot.data!),
                      onDryRun: snapshot.data == null
                          ? null
                          : () => _dryRun(snapshot.data!),
                      onStart: snapshot.data == null
                          ? null
                          : () => _startLive(snapshot.data!),
                      onPauseKeep: snapshot.data == null
                          ? null
                          : () => _runLiveAction(
                                '已暂停：保留挂单。',
                                () => _liveGrid.pauseKeepOrders(
                                  snapshot.data!.id,
                                ),
                              ),
                      onPauseCancel: snapshot.data == null
                          ? null
                          : () => _runLiveAction(
                                '已暂停：已请求撤销策略挂单。',
                                () => _liveGrid.pauseCancelOrders(
                                  snapshot.data!.id,
                                ),
                              ),
                      onResume: snapshot.data == null
                          ? null
                          : () => _runLiveAction(
                                '已恢复策略。',
                                () => _liveGrid.resume(snapshot.data!.id),
                              ),
                      onStop: snapshot.data == null
                          ? null
                          : () => _runLiveAction(
                                '已停止策略。',
                                () => _liveGrid.stop(snapshot.data!.id),
                              ),
                      onReconcile: snapshot.data == null
                          ? null
                          : () => _reconcile(snapshot.data!),
                      onRecoveryReport: snapshot.data == null
                          ? null
                          : () => _recoveryReport(snapshot.data!),
                      onEmergency: snapshot.data == null
                          ? null
                          : () => _runLiveAction(
                                '紧急退出完成。',
                                () => _liveGrid.emergencyExit(
                                  snapshot.data!.id,
                                ),
                              ),
                      onResetFreshStart: _resetForFreshStart,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                StreamBuilder<Strategy?>(
                  stream: _liveGrid.watchActiveFuturesGridStrategy(
                    symbol: symbol,
                  ),
                  builder: (context, snapshot) => _LiveFuturesGridSection(
                    strategy: snapshot.data,
                    liveGrid: _liveGrid,
                    onCreateFutures: () => _createLiveStrategy(
                      executionMode:
                          LiveSpotGridEditableConfig.futuresGridHedge,
                    ),
                    onEdit: snapshot.data == null
                        ? null
                        : () => _editLiveStrategy(snapshot.data!),
                    onEditMaxOpenOrders: snapshot.data == null
                        ? null
                        : () => _editMaxOpenOrders(snapshot.data!),
                    onEditFuturesLeverage: snapshot.data == null
                        ? null
                        : () => _editFuturesLeverage(snapshot.data!),
                    onEditShortHedgeSettings: snapshot.data == null
                        ? null
                        : () => _editShortHedgeSettings(snapshot.data!),
                    onCopy: snapshot.data == null
                        ? null
                        : () => _copyLiveStrategy(snapshot.data!),
                    onDelete: snapshot.data == null
                        ? null
                        : () => _deleteLiveStrategy(snapshot.data!),
                    onArchiveCurrent: snapshot.data == null
                        ? null
                        : () => _archiveCurrentStrategy(snapshot.data!),
                    onMoveUp: snapshot.data == null
                        ? null
                        : () => _moveGridBand(snapshot.data!, up: true),
                    onMoveDown: snapshot.data == null
                        ? null
                        : () => _moveGridBand(snapshot.data!, up: false),
                    onStart: snapshot.data == null
                        ? null
                        : () => _startFuturesLongGrid(snapshot.data!),
                    onRecover: snapshot.data == null
                        ? null
                        : () => _recoverFuturesLongGrid(snapshot.data!),
                  ),
                ),
              ],
            );
          },
        );
      }),
    );
  }
}

class _LiveSpotGridSection extends StatelessWidget {
  const _LiveSpotGridSection({
    required this.strategy,
    required this.liveGrid,
    required this.message,
    required this.onCreateSpot,
    required this.onEdit,
    required this.onEditMaxOpenOrders,
    required this.onCopy,
    required this.onDelete,
    required this.onArchiveCurrent,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onConfirmBtc,
    required this.onPreflight,
    required this.onDryRun,
    required this.onStart,
    required this.onPauseKeep,
    required this.onPauseCancel,
    required this.onResume,
    required this.onStop,
    required this.onReconcile,
    required this.onRecoveryReport,
    required this.onEmergency,
    required this.onResetFreshStart,
  });

  final Strategy? strategy;
  final AutoSpotGridExecutionService liveGrid;
  final String message;
  final VoidCallback onCreateSpot;
  final VoidCallback? onEdit;
  final VoidCallback? onEditMaxOpenOrders;
  final VoidCallback? onCopy;
  final VoidCallback? onDelete;
  final VoidCallback? onArchiveCurrent;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onConfirmBtc;
  final VoidCallback? onPreflight;
  final VoidCallback? onDryRun;
  final VoidCallback? onStart;
  final VoidCallback? onPauseKeep;
  final VoidCallback? onPauseCancel;
  final VoidCallback? onResume;
  final VoidCallback? onStop;
  final VoidCallback? onReconcile;
  final VoidCallback? onRecoveryReport;
  final VoidCallback? onEmergency;
  final VoidCallback onResetFreshStart;

  @override
  Widget build(BuildContext context) {
    final strategy = this.strategy;
    final baseAsset =
        strategy == null ? '资产' : _baseAssetForSymbol(strategy.symbol);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'LIVE 自动现货网格执行器',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            FutureBuilder(
              future: Future.wait([
                liveGrid.capitalLimit(),
                liveGrid.orderLimit(),
              ]),
              builder: (context, snapshot) {
                final capitalLimit = snapshot.data?[0].toString() ?? '50';
                final orderLimit = snapshot.data?[1].toString() ?? '10';
                return Text(
                  '仅当前币对正式现货子账户；合约对冲按策略价格层成交触发。资金上限 $capitalLimit USDT，单笔上限 $orderLimit USDT，启动只提交下方 BUY，SELL 等同一网格 BUY 成交后创建，最大活动挂单按策略配置生效。',
                );
              },
            ),
            const SizedBox(height: 12),
            if (strategy != null)
              FutureBuilder<LiveSpotGridRuntimeSummary>(
                future: liveGrid.runtimeSummary(strategy.id),
                builder: (context, snapshot) {
                  final summary = snapshot.data;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _LiveStatusCard(strategy: strategy, summary: summary),
                      const SizedBox(height: 10),
                      _LiveHintBar(strategy: strategy, summary: summary),
                    ],
                  );
                },
              ),
            const SizedBox(height: 12),
            _ButtonGroup(
              title: '配置',
              children: [
                ElevatedButton.icon(
                  onPressed: onCreateSpot,
                  icon: const Icon(Icons.add),
                  label: const Text('创建现货策略'),
                ),
                OutlinedButton.icon(
                  onPressed: _canEdit(strategy) ? onEdit : null,
                  icon: const Icon(Icons.edit),
                  label: const Text('编辑策略'),
                ),
                OutlinedButton.icon(
                  onPressed: strategy == null ? null : onEditMaxOpenOrders,
                  icon: const Icon(Icons.tune),
                  label: const Text('修改最大挂单数'),
                ),
                OutlinedButton.icon(
                  onPressed: strategy == null ? null : onCopy,
                  icon: const Icon(Icons.copy),
                  label: const Text('复制策略'),
                ),
                OutlinedButton.icon(
                  onPressed: _canEdit(strategy) ? onDelete : null,
                  icon: const Icon(Icons.delete),
                  label: const Text('删除策略'),
                ),
                OutlinedButton.icon(
                  onPressed: strategy == null ? null : onArchiveCurrent,
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('归档当前策略'),
                ),
                OutlinedButton.icon(
                  onPressed: _canEdit(strategy) ? onMoveUp : null,
                  icon: const Icon(Icons.north),
                  label: const Text('网格上移一格'),
                ),
                OutlinedButton.icon(
                  onPressed: _canEdit(strategy) ? onMoveDown : null,
                  icon: const Icon(Icons.south),
                  label: const Text('网格下移一格'),
                ),
                OutlinedButton.icon(
                  onPressed: strategy == null ? null : onConfirmBtc,
                  icon: const Icon(Icons.inventory),
                  label: Text('确认 $baseAsset 归属'),
                ),
              ],
            ),
            _ButtonGroup(
              title: '启动',
              children: [
                OutlinedButton.icon(
                  onPressed: onPreflight,
                  icon: const Icon(Icons.fact_check),
                  label: const Text('启动前检查'),
                ),
                OutlinedButton.icon(
                  onPressed: onDryRun,
                  icon: const Icon(Icons.preview),
                  label: const Text('启动预演'),
                ),
                Tooltip(
                  message: _startTooltip(strategy),
                  child: ElevatedButton.icon(
                    onPressed: _canStart(strategy) ? onStart : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('启动 LIVE 网格'),
                  ),
                ),
              ],
            ),
            _ButtonGroup(
              title: '运行',
              children: [
                OutlinedButton.icon(
                  onPressed: _isRunningLike(strategy) ? onPauseKeep : null,
                  icon: const Icon(Icons.pause),
                  label: const Text('保留挂单暂停'),
                ),
                OutlinedButton.icon(
                  onPressed: _isRunningLike(strategy) ? onPauseCancel : null,
                  icon: const Icon(Icons.pause_circle),
                  label: const Text('撤销挂单暂停'),
                ),
                OutlinedButton.icon(
                  onPressed: _canResume(strategy) ? onResume : null,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('恢复'),
                ),
                OutlinedButton.icon(
                  onPressed: strategy == null ? null : onStop,
                  icon: const Icon(Icons.stop),
                  label: const Text('停止'),
                ),
              ],
            ),
            _ButtonGroup(
              title: '恢复与安全',
              children: [
                OutlinedButton.icon(
                  onPressed: onReconcile,
                  icon: const Icon(Icons.sync),
                  label: const Text('REST 对账'),
                ),
                OutlinedButton.icon(
                  onPressed: onRecoveryReport,
                  icon: const Icon(Icons.restore_page),
                  label: const Text('恢复报告'),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                  ),
                  onPressed: onEmergency,
                  icon: const Icon(Icons.emergency),
                  label: const Text('紧急退出'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade800,
                    side: BorderSide(color: Colors.red.shade300),
                  ),
                  onPressed: onResetFreshStart,
                  icon: const Icon(Icons.cleaning_services),
                  label: const Text('重置测试环境'),
                ),
              ],
            ),
            if (message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SelectableText(message),
              ),
            const SizedBox(height: 12),
            if (strategy == null)
              const Text('尚未创建 LIVE 现货网格策略。')
            else
              _StrategySummary(title: '当前 LIVE 现货网格', strategy: strategy),
          ],
        ),
      ),
    );
  }

  bool _canEdit(Strategy? strategy) {
    if (strategy == null) return false;
    return {'idle', 'stopped', 'error'}.contains(strategy.status);
  }

  bool _canStart(Strategy? strategy) {
    if (strategy == null) return false;
    return {
      'idle',
      'stopped',
      'previewReady',
      'error',
    }.contains(strategy.status);
  }

  bool _isRunningLike(Strategy? strategy) {
    if (strategy == null) return false;
    return {'running', 'starting'}.contains(strategy.status);
  }

  bool _canResume(Strategy? strategy) {
    if (strategy == null) return false;
    return {
      'pausedKeepOrders',
      'pausedCancelOrders',
      'paused',
    }.contains(strategy.status);
  }

  String _startTooltip(Strategy? strategy) {
    if (strategy == null) return '请先创建策略';
    if (!_canStart(strategy)) return '当前状态不允许启动。运行中修改参数必须先停止并复制新策略。';
    return '仍需满足启动前检查、启动预演、真实写操作、账户 REST/WS、行情和 SQLite 状态。';
  }
}

class _PreflightIssueTile extends StatelessWidget {
  const _PreflightIssueTile({required this.issue, required this.onAction});

  final LiveSpotGridPreflightIssue issue;
  final Future<void> Function() onAction;

  @override
  Widget build(BuildContext context) {
    final color = issue.status == 'failed'
        ? Colors.red.shade700
        : issue.status == 'blocked'
            ? Colors.orange.shade700
            : Colors.green.shade700;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '[${_statusText(issue.status)}] ${issue.title}',
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                if (issue.actionLabel != null)
                  OutlinedButton(
                    onPressed: () => unawaited(onAction()),
                    child: Text(issue.actionLabel!),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(issue.message),
            if (issue.details.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText(
                issue.details.entries
                    .map((entry) => '${entry.key}: ${entry.value ?? '-'}')
                    .join('\n'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _statusText(String status) {
    return switch (status) {
      'passed' => '通过',
      'failed' => '失败',
      'blocked' => '阻塞',
      _ => status,
    };
  }
}

class _ConflictStrategyCard extends StatelessWidget {
  const _ConflictStrategyCard({
    required this.item,
    required this.onOpen,
    required this.onReconcile,
    required this.onOrders,
    required this.onExchangeOrders,
    required this.onFills,
    required this.onBtc,
    required this.onSafeStop,
    required this.onCancelExchangeOrders,
    required this.onMarkStopped,
    required this.onArchive,
  });

  final LiveSpotGridConflict item;
  final VoidCallback onOpen;
  final Future<void> Function() onReconcile;
  final Future<void> Function() onOrders;
  final Future<void> Function() onExchangeOrders;
  final Future<void> Function() onFills;
  final Future<void> Function() onBtc;
  final Future<void> Function() onSafeStop;
  final Future<void> Function() onCancelExchangeOrders;
  final Future<void> Function() onMarkStopped;
  final Future<void> Function() onArchive;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText('strategyId: ${item.strategyId}'),
            Text('策略名称: ${item.name}'),
            Text('交易对: ${item.symbol}'),
            Wrap(
              spacing: 20,
              runSpacing: 6,
              children: [
                Text('当前状态: ${item.status}'),
                Text('创建时间: ${item.createdAt.toLocal()}'),
                Text('启动时间: ${item.startedAt?.toLocal() ?? '-'}'),
                Text('最后更新时间: ${item.updatedAt.toLocal()}'),
                Text('本地活动订单数: ${item.localActiveOrders}'),
                Text('Binance 活动订单数: ${item.binanceActiveOrders}'),
                Text('已完成订单数: ${item.completedOrders}'),
                Text('已撤销订单数: ${item.cancelledOrders}'),
                Text('unknown订单数: ${item.unknownOrders}'),
                Text('未处理fills: ${item.unprocessedFills}'),
                Text('pendingRecoveryOrder: ${item.pendingRecoveryOrders}'),
                Text('策略${item.baseAsset}: ${item.strategyBtc}'),
                Text('未分类${item.baseAsset}: ${item.unclassifiedBtc}'),
                Text('最后REST对账: ${item.lastReconcileAt?.toLocal() ?? '-'}'),
              ],
            ),
            Text('最近错误: ${item.lastError ?? '-'}'),
            if (item.isGhostCandidate)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '该策略可能是残留状态，可以安全标记为 stopped。',
                  style: TextStyle(
                    color: Colors.green.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (item.blockingReasons.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '不能标记 stopped：${item.blockingReasons.join('；')}',
                style: TextStyle(color: Colors.red.shade700),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(onPressed: onOpen, child: const Text('打开策略')),
                OutlinedButton(
                  onPressed: () => unawaited(onReconcile()),
                  child: const Text('执行 REST 对账'),
                ),
                OutlinedButton(
                  onPressed: () => unawaited(onOrders()),
                  child: const Text('查看订单'),
                ),
                OutlinedButton(
                  onPressed: () => unawaited(onExchangeOrders()),
                  child: const Text('查看 Binance 挂单'),
                ),
                OutlinedButton(
                  onPressed: () => unawaited(onFills()),
                  child: const Text('查看成交'),
                ),
                OutlinedButton(
                  onPressed: () => unawaited(onBtc()),
                  child: const Text('查看策略资产'),
                ),
                OutlinedButton(
                  onPressed: () => unawaited(onSafeStop()),
                  child: const Text('安全停止'),
                ),
                FilledButton.tonal(
                  onPressed: item.binanceActiveOrders == 0
                      ? null
                      : () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('撤销 Binance 挂单'),
                              content: Text(
                                '将撤销该旧策略关联的本程序现货挂单 ${item.binanceActiveOrders} 笔。'
                                '不会撤销非本程序订单。确认继续？',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(
                                    context,
                                  ).pop(false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  child: const Text('确认撤销'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await onCancelExchangeOrders();
                          }
                        },
                  child: const Text('撤销 Binance 挂单'),
                ),
                Tooltip(
                  message: item.canMarkStopped
                      ? '满足安全条件'
                      : item.blockingReasons.join('；'),
                  child: FilledButton(
                    onPressed: item.canMarkStopped
                        ? () => unawaited(onMarkStopped())
                        : null,
                    child: const Text('标记为已停止'),
                  ),
                ),
                OutlinedButton(
                  onPressed:
                      item.canMarkStopped ? () => unawaited(onArchive()) : null,
                  child: const Text('归档策略'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveFuturesGridSection extends StatelessWidget {
  const _LiveFuturesGridSection({
    required this.strategy,
    required this.liveGrid,
    required this.onCreateFutures,
    required this.onEdit,
    required this.onEditMaxOpenOrders,
    required this.onEditFuturesLeverage,
    required this.onEditShortHedgeSettings,
    required this.onCopy,
    required this.onDelete,
    required this.onArchiveCurrent,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onStart,
    required this.onRecover,
  });

  final Strategy? strategy;
  final AutoSpotGridExecutionService liveGrid;
  final VoidCallback onCreateFutures;
  final VoidCallback? onEdit;
  final VoidCallback? onEditMaxOpenOrders;
  final VoidCallback? onEditFuturesLeverage;
  final VoidCallback? onEditShortHedgeSettings;
  final VoidCallback? onCopy;
  final VoidCallback? onDelete;
  final VoidCallback? onArchiveCurrent;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onStart;
  final VoidCallback? onRecover;

  @override
  Widget build(BuildContext context) {
    final strategy = this.strategy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'LIVE 合约 LONG 网格策略',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              '合约模式使用 Futures Hedge Mode：LONG 侧跑网格，SHORT 侧按价格层成交触发对冲。启动时只提交当前价下方的 LONG BUY，平多和补单执行器仍按后续成交处理。',
            ),
            const SizedBox(height: 12),
            _ButtonGroup(
              title: '配置',
              children: [
                ElevatedButton.icon(
                  onPressed: onCreateFutures,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('创建合约策略'),
                ),
                OutlinedButton.icon(
                  onPressed: _canEdit(strategy) ? onEdit : null,
                  icon: const Icon(Icons.edit),
                  label: const Text('编辑合约策略'),
                ),
                OutlinedButton.icon(
                  onPressed: strategy == null ? null : onEditMaxOpenOrders,
                  icon: const Icon(Icons.tune),
                  label: const Text('修改最大挂单数'),
                ),
                OutlinedButton.icon(
                  onPressed: strategy == null ? null : onEditFuturesLeverage,
                  icon: const Icon(Icons.speed),
                  label: const Text('修改合约杠杆'),
                ),
                OutlinedButton.icon(
                  onPressed: strategy == null ? null : onEditShortHedgeSettings,
                  icon: const Icon(Icons.call_split),
                  label: const Text('修改SHORT对冲'),
                ),
                OutlinedButton.icon(
                  onPressed: strategy == null ? null : onCopy,
                  icon: const Icon(Icons.copy),
                  label: const Text('复制策略'),
                ),
                OutlinedButton.icon(
                  onPressed: _canEdit(strategy) ? onDelete : null,
                  icon: const Icon(Icons.delete),
                  label: const Text('删除策略'),
                ),
                OutlinedButton.icon(
                  onPressed: strategy == null ? null : onArchiveCurrent,
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('归档当前策略'),
                ),
                OutlinedButton.icon(
                  onPressed: _canEdit(strategy) ? onMoveUp : null,
                  icon: const Icon(Icons.north),
                  label: const Text('网格上移一格'),
                ),
                OutlinedButton.icon(
                  onPressed: _canEdit(strategy) ? onMoveDown : null,
                  icon: const Icon(Icons.south),
                  label: const Text('网格下移一格'),
                ),
              ],
            ),
            _ButtonGroup(
              title: '启动',
              children: [
                Tooltip(
                  message: _startTooltip(strategy),
                  child: ElevatedButton.icon(
                    onPressed: _canStart(strategy) ? onStart : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('启动 LONG 网格'),
                  ),
                ),
              ],
            ),
            FutureBuilder<LiveSpotGridEditableConfig?>(
              future: strategy == null
                  ? Future.value(null)
                  : liveGrid.loadEditableConfig(strategy.id),
              builder: (context, snapshot) {
                final config = snapshot.data;
                if (strategy == null) {
                  return const Text('尚未创建 LIVE 合约 LONG 网格策略。');
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Chip(
                          label: Text('杠杆: ${config?.futuresLeverage ?? 1}x'),
                        ),
                        Chip(
                          label: Text(
                            '价格源: ${config?.futuresPriceSource ?? LiveSpotGridEditableConfig.futuresMarkPrice}',
                          ),
                        ),
                        Chip(
                          label: Text(
                            '开多提前: ${config?.longEntryTriggerDistanceUsdt ?? AutoSpotGridExecutionService.defaultLongEntryTriggerDistanceUsdt} USDT',
                          ),
                        ),
                        Chip(
                          label: Text(
                            'SHORT对冲: ${config?.shortHedgeMultiplier ?? Decimal.parse('1.2')}x',
                          ),
                        ),
                        Chip(
                          label: Text(
                            '均摊层数: ${config?.shortHedgeSpreadLevels ?? 4}',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _FuturesLongRuntimeStatusCard(
                      strategy: strategy,
                      liveGrid: liveGrid,
                      onRecover: onRecover,
                    ),
                    const SizedBox(height: 8),
                    _StrategySummary(
                      title: '当前 LIVE 合约 LONG 网格',
                      strategy: strategy,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  bool _canEdit(Strategy? strategy) {
    if (strategy == null) return false;
    return {'idle', 'stopped', 'error'}.contains(strategy.status);
  }

  bool _canStart(Strategy? strategy) {
    if (strategy == null) return false;
    return {
      'idle',
      'previewReady',
      'stopped',
      'error',
      'starting',
    }.contains(strategy.status);
  }

  String _startTooltip(Strategy? strategy) {
    if (strategy == null) return '请先创建合约 LONG 网格策略';
    if (_canStart(strategy)) return '提交初始 LONG BUY 合约挂单';
    return '当前状态不能启动: ${strategy.status}';
  }
}

class _ButtonGroup extends StatelessWidget {
  const _ButtonGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: children),
        ],
      ),
    );
  }
}

class _FuturesLongRuntimeStatusCard extends StatelessWidget {
  const _FuturesLongRuntimeStatusCard({
    required this.strategy,
    required this.liveGrid,
    required this.onRecover,
  });

  final Strategy strategy;
  final AutoSpotGridExecutionService liveGrid;
  final VoidCallback? onRecover;

  @override
  Widget build(BuildContext context) {
    final db = Get.find<AppDatabase>();
    return StreamBuilder<List<GridLevel>>(
      stream: liveGrid.watchGridLevels(strategy.id),
      builder: (context, levelSnapshot) {
        return StreamBuilder<List<Order>>(
          stream: (db.select(db.orders)
                ..where(
                  (tbl) =>
                      tbl.strategyId.equals(strategy.id) &
                      tbl.source.equals(
                        AutoSpotGridExecutionService.futuresLongSource,
                      ),
                ))
              .watch(),
          builder: (context, orderSnapshot) {
            final summary = _FuturesLongRuntimeSummary.from(
              strategy: strategy,
              levels: levelSnapshot.data ?? const <GridLevel>[],
              orders: orderSnapshot.data ?? const <Order>[],
            );
            final color = summary.color;
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(summary.icon, color: color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'LONG Future 运行状态：${summary.statusText}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: onRecover,
                        icon: const Icon(Icons.sync),
                        label: const Text('恢复并对账 LONG 网格'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 24,
                    runSpacing: 8,
                    children: [
                      SizedBox(
                        width: 220,
                        child: Text('策略状态: ${strategy.status}'),
                      ),
                      SizedBox(
                        width: 220,
                        child: Text('活动 LONG 挂单: ${summary.activeOrders}'),
                      ),
                      SizedBox(
                        width: 220,
                        child: Text('等待开多层: ${summary.waitingBuyLevels}'),
                      ),
                      SizedBox(
                        width: 220,
                        child: Text('已开多待平多层: ${summary.openLongLevels}'),
                      ),
                      SizedBox(
                        width: 220,
                        child: Text('错误层: ${summary.errorLevels}'),
                      ),
                      SizedBox(
                        width: 220,
                        child: Text('最近错误: ${strategy.lastError ?? '-'}'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _FuturesLongRuntimeSummary {
  const _FuturesLongRuntimeSummary({
    required this.statusText,
    required this.activeOrders,
    required this.waitingBuyLevels,
    required this.openLongLevels,
    required this.errorLevels,
    required this.color,
    required this.icon,
  });

  final String statusText;
  final int activeOrders;
  final int waitingBuyLevels;
  final int openLongLevels;
  final int errorLevels;
  final Color color;
  final IconData icon;

  factory _FuturesLongRuntimeSummary.from({
    required Strategy strategy,
    required List<GridLevel> levels,
    required List<Order> orders,
  }) {
    final activeOrders = orders.where(_isActiveLongOrder).length;
    final waitingBuyLevels = levels.where(_isWaitingLongBuyLevel).length;
    final openLongLevels = levels.where(_isOpenLongLevel).length;
    final errorLevels = levels
        .where(
          (level) => {level.status, level.lifecycleStatus}.contains('error'),
        )
        .length;

    late final String statusText;
    late final Color color;
    late final IconData icon;
    if ({'starting', 'stopping', 'reconciling'}.contains(strategy.status)) {
      statusText = '处理中';
      color = Colors.orange.shade700;
      icon = Icons.sync;
    } else if (strategy.status == 'running' && activeOrders > 0) {
      statusText = '正在运行';
      color = Colors.green.shade700;
      icon = Icons.play_circle;
    } else if (strategy.status == 'running') {
      statusText = '运行中但没有活动 LONG 挂单';
      color = Colors.red.shade700;
      icon = Icons.warning_amber;
    } else if (strategy.status == 'error' || errorLevels > 0) {
      statusText = '错误';
      color = Colors.red.shade700;
      icon = Icons.error_outline;
    } else if (strategy.status == 'stopped') {
      statusText = '已停止';
      color = Colors.blueGrey;
      icon = Icons.stop_circle_outlined;
    } else if (strategy.status == 'idle' || strategy.status == 'previewReady') {
      statusText = '未启动';
      color = Colors.amber.shade700;
      icon = Icons.pause_circle_outline;
    } else {
      statusText = strategy.status;
      color = Colors.blueGrey;
      icon = Icons.info_outline;
    }
    return _FuturesLongRuntimeSummary(
      statusText: statusText,
      activeOrders: activeOrders,
      waitingBuyLevels: waitingBuyLevels,
      openLongLevels: openLongLevels,
      errorLevels: errorLevels,
      color: color,
      icon: icon,
    );
  }

  static bool _isActiveLongOrder(Order order) {
    return order.source == AutoSpotGridExecutionService.futuresLongSource &&
        {
          'created',
          'submitting',
          'new',
          'partiallyFilled',
          'cancelling',
          'unknown',
        }.contains(order.status);
  }

  static bool _isWaitingLongBuyLevel(GridLevel level) {
    if (level.activeOrderId != null && level.activeOrderId!.isNotEmpty) {
      return false;
    }
    return {'ready', 'waiting', 'waitingBuy'}.contains(level.status) ||
        {
          'waitingBuy',
          'planned',
          'ready',
        }.contains(level.lifecycleStatus ?? '');
  }

  static bool _isOpenLongLevel(GridLevel level) {
    final status = level.lifecycleStatus ?? level.status;
    return {
      'buyFilled',
      'sellSubmitting',
      'sellOpen',
      'sellPartiallyFilled',
    }.contains(status);
  }
}

class _LiveStatusCard extends StatelessWidget {
  const _LiveStatusCard({required this.strategy, required this.summary});

  final Strategy strategy;
  final LiveSpotGridRuntimeSummary? summary;

  @override
  Widget build(BuildContext context) {
    final submitted = summary?.exchangeSubmitted == true;
    final rows = [
      ('中文状态', summary?.statusText ?? strategy.status),
      ('英文原始状态', strategy.status),
      ('是否已向 Binance 提交订单', submitted ? '是' : '否'),
      ('当前活动挂单数', '${summary?.activeOpenOrders ?? '-'}'),
      ('等待提交订单数', '${summary?.waitingOrders ?? '-'}'),
      ('已完成订单数', '${summary?.completedOrders ?? '-'}'),
      ('最近状态变化时间', summary?.lastChangedAt?.toLocal().toString() ?? '-'),
      ('最近一次成功操作', summary?.lastSuccess ?? '-'),
      ('最近错误', summary?.lastError ?? strategy.lastError ?? '-'),
    ];
    final statusColor = switch (strategy.status) {
      'error' || 'circuitBreaker' || 'outOfRangeLower' => Colors.red,
      'outOfRangeUpper' || 'reconciling' || 'stopping' => Colors.orange,
      'running' || 'previewReady' => Colors.green,
      'paused' || 'pausedKeepOrders' || 'pausedCancelOrders' => Colors.blueGrey,
      'idle' || 'stopped' => Colors.amber,
      _ => submitted ? Colors.green : Colors.amber,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: statusColor.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: statusColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('策略运行状态', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              for (final row in rows)
                SizedBox(width: 320, child: Text('${row.$1}: ${row.$2}')),
            ],
          ),
        ],
      ),
    );
  }
}

class _LiveHintBar extends StatelessWidget {
  const _LiveHintBar({required this.strategy, required this.summary});

  final Strategy strategy;
  final LiveSpotGridRuntimeSummary? summary;

  @override
  Widget build(BuildContext context) {
    final baseAsset = _baseAssetForSymbol(strategy.symbol);
    late final Color color;
    late final String text;
    if (strategy.status == 'idle') {
      color = Colors.amber.shade700;
      text =
          '未启动：仅创建了本地策略和网格计划，尚未向 Binance 提交任何真实订单。请先执行启动前检查和启动预演，再开启真实写操作并启动 LIVE 网格。';
    } else if (strategy.status == 'running' &&
        (summary?.activeOpenOrders ?? 0) == 0) {
      color = Colors.red.shade700;
      text = '策略状态为运行中，但 Binance 没有活动挂单，请立即执行 REST 对账。';
    } else if (strategy.status == 'running') {
      color = Colors.green.shade700;
      text = '策略正在运行，当前 Binance 活动挂单 ${summary?.activeOpenOrders ?? 0} 笔。';
    } else if (strategy.strategySpotBtc == '0') {
      color = Colors.amber.shade700;
      text =
          '当前没有策略 $baseAsset，启动时需要先建立初始 $baseAsset 库存。初始 $baseAsset 买入成功后才会提交 SELL 网格。';
    } else {
      color = Colors.blueGrey;
      text = summary?.statusText ?? strategy.status;
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 5)),
        color: color.withValues(alpha: 0.08),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _MaxOpenOrdersDialog extends StatefulWidget {
  const _MaxOpenOrdersDialog({required this.config});

  final LiveSpotGridEditableConfig config;

  @override
  State<_MaxOpenOrdersDialog> createState() => _MaxOpenOrdersDialogState();
}

class _MaxOpenOrdersDialogState extends State<_MaxOpenOrdersDialog> {
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(
      text: widget.config.maxOpenOrders.toString(),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxRows = widget.config.gridIntervalCount + 1;
    return AlertDialog(
      title: const Text('修改最大活动挂单数'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '最大活动挂单数',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '该修改会立即影响后续挂单上限，不会重建网格，也不会修改已存在的 Binance 挂单。当前价格层数量：$maxRows。',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            final value = int.tryParse(controller.text.trim());
            Navigator.of(context).pop(value);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _FuturesLeverageDialog extends StatefulWidget {
  const _FuturesLeverageDialog({required this.config});

  final LiveSpotGridEditableConfig config;

  @override
  State<_FuturesLeverageDialog> createState() => _FuturesLeverageDialogState();
}

class _FuturesLeverageDialogState extends State<_FuturesLeverageDialog> {
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(
      text: widget.config.futuresLeverage.toString(),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改合约杠杆倍数'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '合约杠杆倍数 1-125',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            const Text('该修改只保存策略配置；启动 LONG 网格前会设置到 Binance Futures。'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            final value = int.tryParse(controller.text.trim());
            Navigator.of(context).pop(value?.clamp(1, 125));
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _ShortHedgeSettingsResult {
  const _ShortHedgeSettingsResult({
    required this.multiplier,
    required this.spreadLevels,
  });

  final Decimal multiplier;
  final int spreadLevels;
}

class _ShortHedgeSettingsDialog extends StatefulWidget {
  const _ShortHedgeSettingsDialog({required this.config});

  final LiveSpotGridEditableConfig config;

  @override
  State<_ShortHedgeSettingsDialog> createState() =>
      _ShortHedgeSettingsDialogState();
}

class _ShortHedgeSettingsDialogState extends State<_ShortHedgeSettingsDialog> {
  late final TextEditingController multiplier;
  late final TextEditingController spreadLevels;

  @override
  void initState() {
    super.initState();
    multiplier = TextEditingController(
      text: widget.config.shortHedgeMultiplier.toString(),
    );
    spreadLevels = TextEditingController(
      text: widget.config.shortHedgeSpreadLevels.toString(),
    );
  }

  @override
  void dispose() {
    multiplier.dispose();
    spreadLevels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改 SHORT 对冲参数'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: multiplier,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'SHORT 对冲倍数',
                helperText: '例如 1.2 表示目标空单为多单的 120%',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: spreadLevels,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '下方均摊层数',
                helperText: '把目标空单平均分到中间价下方多个网格',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () async {
            FocusScope.of(context).unfocus();
            final navigator = Navigator.of(context);
            await Future<void>.delayed(Duration.zero);
            final parsedMultiplier = Decimal.tryParse(multiplier.text.trim()) ??
                Decimal.parse('1.2');
            final parsedSpread = int.tryParse(spreadLevels.text.trim()) ?? 4;
            navigator.pop(
              _ShortHedgeSettingsResult(
                multiplier: parsedMultiplier <= Decimal.zero
                    ? Decimal.parse('1.2')
                    : parsedMultiplier,
                spreadLevels: parsedSpread <= 0 ? 4 : parsedSpread,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _LiveStrategyEditDialog extends StatefulWidget {
  const _LiveStrategyEditDialog({required this.config});

  final LiveSpotGridEditableConfig config;

  @override
  State<_LiveStrategyEditDialog> createState() =>
      _LiveStrategyEditDialogState();
}

class _LiveStrategyEditDialogState extends State<_LiveStrategyEditDialog> {
  late String executionMode;
  late final TextEditingController name;
  late final TextEditingController center;
  late final TextEditingController lower;
  late final TextEditingController upper;
  late final TextEditingController gridMode;
  late final TextEditingController intervalCount;
  late final TextEditingController buyCount;
  late final TextEditingController maxOpen;
  late final TextEditingController capital;
  late final TextEditingController initialRatio;
  late final TextEditingController singleAmount;
  late final TextEditingController maxLoss;
  late final TextEditingController dailyLoss;
  late final TextEditingController outOfRange;
  late final TextEditingController futureGridOffset;
  late final TextEditingController futuresLeverage;
  late final TextEditingController longEntryTriggerDistance;
  late final TextEditingController shortHedgeMultiplier;
  late final TextEditingController shortHedgeSpreadLevels;
  late String futuresPriceSource;
  late bool enableFutureHedgeGrid;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    executionMode = c.executionMode;
    name = TextEditingController(text: c.name);
    center = TextEditingController(text: c.centerPrice.toString());
    lower = TextEditingController(text: _lowerPercentFromPrices(c).toString());
    upper = TextEditingController(text: _upperPercentFromPrices(c).toString());
    gridMode = TextEditingController(text: c.gridMode);
    intervalCount = TextEditingController(text: c.gridIntervalCount.toString());
    buyCount = TextEditingController(text: c.initialBuyOrderCount.toString());
    maxOpen = TextEditingController(text: c.maxOpenOrders.toString());
    capital = TextEditingController(text: c.spotCapital.toString());
    initialRatio = TextEditingController(text: c.initialBtcRatio.toString());
    singleAmount = TextEditingController(text: c.singleGridAmount.toString());
    maxLoss = TextEditingController(text: c.maxLossUsdt.toString());
    dailyLoss = TextEditingController(text: c.dailyMaxLossUsdt.toString());
    outOfRange = TextEditingController(text: c.outOfRangeAction);
    futureGridOffset = TextEditingController(
      text: c.futureGridOffset.toString(),
    );
    futuresLeverage = TextEditingController(text: c.futuresLeverage.toString());
    longEntryTriggerDistance = TextEditingController(
      text: c.longEntryTriggerDistanceUsdt.toString(),
    );
    shortHedgeMultiplier = TextEditingController(
      text: c.shortHedgeMultiplier.toString(),
    );
    shortHedgeSpreadLevels = TextEditingController(
      text: c.shortHedgeSpreadLevels.toString(),
    );
    futuresPriceSource = c.futuresPriceSource;
    enableFutureHedgeGrid = c.enableFutureHedgeGrid;
  }

  @override
  void dispose() {
    for (final controller in [
      name,
      center,
      lower,
      upper,
      gridMode,
      intervalCount,
      buyCount,
      maxOpen,
      capital,
      initialRatio,
      singleAmount,
      maxLoss,
      dailyLoss,
      outOfRange,
      futureGridOffset,
      futuresLeverage,
      longEntryTriggerDistance,
      shortHedgeMultiplier,
      shortHedgeSpreadLevels,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        executionMode == LiveSpotGridEditableConfig.futuresGridHedge
            ? '编辑 LIVE 合约网格策略'
            : '编辑 LIVE 现货网格策略',
      ),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 360,
                child: DropdownButtonFormField<String>(
                  initialValue: executionMode,
                  decoration: const InputDecoration(
                    labelText: '策略类型',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: LiveSpotGridEditableConfig.spotGridFuturesHedge,
                      child: Text('现货网格 + 合约对冲'),
                    ),
                    DropdownMenuItem(
                      value: LiveSpotGridEditableConfig.futuresGridHedge,
                      child: Text('合约 LONG 网格 + SHORT 对冲'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      executionMode = value;
                      enableFutureHedgeGrid =
                          value == LiveSpotGridEditableConfig.futuresGridHedge
                              ? true
                              : enableFutureHedgeGrid;
                    });
                  },
                ),
              ),
              _field(name, '策略名称', 360),
              _field(center, '中心价格', 180),
              _field(lower, '下限百分比 %', 180),
              _field(upper, '上限百分比 %', 180),
              _field(gridMode, '网格模式 geometric/arithmetic', 220),
              _field(intervalCount, '网格间隔数量', 160),
              _field(buyCount, '启动提交BUY数量', 160),
              _field(maxOpen, '最大活动挂单数', 160),
              _field(capital, '总资金', 160),
              _field(initialRatio, '初始资产比例', 160),
              _field(
                singleAmount,
                executionMode == LiveSpotGridEditableConfig.futuresGridHedge
                    ? '单格保证金'
                    : '单格金额',
                160,
              ),
              _field(maxLoss, '最大亏损', 160),
              _field(dailyLoss, '单日最大亏损', 160),
              _field(outOfRange, '出区间处理方式', 220),
              if (executionMode == LiveSpotGridEditableConfig.futuresGridHedge)
                _integerField(futuresLeverage, '合约杠杆倍数 1-125', 180),
              if (executionMode == LiveSpotGridEditableConfig.futuresGridHedge)
                _field(longEntryTriggerDistance, '开多提前触发 USDT', 180),
              if (_showShortHedgeSettings)
                _field(shortHedgeMultiplier, 'SHORT 对冲倍数', 180),
              if (_showShortHedgeSettings)
                _integerField(
                  shortHedgeSpreadLevels,
                  '下方均摊层数',
                  180,
                  helperText: '把目标空单平均分到中间价下方层级',
                ),
              if (executionMode == LiveSpotGridEditableConfig.futuresGridHedge)
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<String>(
                    initialValue: futuresPriceSource,
                    decoration: const InputDecoration(
                      labelText: '合约价格来源',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: LiveSpotGridEditableConfig.futuresMarkPrice,
                        child: Text('Futures Mark Price'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => futuresPriceSource = value);
                      }
                    },
                  ),
                ),
              SizedBox(
                width: 720,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: enableFutureHedgeGrid,
                  title: const Text('SHORT 对冲价格层'),
                  subtitle: Text(
                    executionMode == LiveSpotGridEditableConfig.futuresGridHedge
                        ? '合约模式下 LONG 网格成交后，SHORT 侧按价格层对冲。'
                        : '现货模式下 Spot Grid 成交后，Future SHORT 侧按价格层对冲。',
                  ),
                  onChanged: (value) => setState(() {
                    enableFutureHedgeGrid = value;
                  }),
                ),
              ),
              const SizedBox(
                width: 260,
                child: Text('对冲方向: SHORT；合约网格方向: LONG'),
              ),
              _field(futureGridOffset, 'Grid Offset（默认 +1）', 180),
              const SizedBox(
                width: 720,
                child: Text(
                  '限制：现货模式使用 Spot 账户；合约模式必须使用 Binance Futures 双向持仓模式，LONG 侧跑网格，SHORT 侧跑对冲。',
                ),
              ),
              const SizedBox(
                width: 720,
                child: Text(
                  '固定生命周期：Grid 行创建后 BUY 价格、SELL 价格和数量保持不变；启动时只提交 BUY。SELL 必须等待同一行 BUY 完全成交后才会创建。',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () async {
            FocusScope.of(context).unfocus();
            final navigator = Navigator.of(context);
            await Future<void>.delayed(Duration.zero);
            navigator.pop(_buildConfig());
          },
          child: const Text('保存配置'),
        ),
      ],
    );
  }

  Widget _field(TextEditingController controller, String label, double width) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _integerField(
    TextEditingController controller,
    String label,
    double width, {
    String helperText = '启动前会设置到 Binance Futures',
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  LiveSpotGridEditableConfig _buildConfig() {
    Decimal decimal(TextEditingController c) =>
        Decimal.tryParse(c.text.trim()) ?? Decimal.zero;
    int integer(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;
    final centerPrice = decimal(center);
    final lowerPercent = decimal(lower);
    final upperPercent = decimal(upper);
    final hundred = Decimal.fromInt(100);
    final lowerRatio = (lowerPercent / hundred).toDecimal(
      scaleOnInfinitePrecision: 8,
    );
    final upperRatio = (upperPercent / hundred).toDecimal(
      scaleOnInfinitePrecision: 8,
    );
    final lowerPrice = centerPrice * (Decimal.fromInt(1) - lowerRatio);
    final upperPrice = centerPrice * (Decimal.fromInt(1) + upperRatio);
    return LiveSpotGridEditableConfig(
      name: name.text.trim().isEmpty
          ? '${widget.config.symbol} LIVE Spot Grid'
          : name.text.trim(),
      symbol: widget.config.symbol,
      executionMode: executionMode,
      centerPrice: centerPrice,
      lowerPrice: lowerPrice,
      upperPrice: upperPrice,
      gridMode:
          gridMode.text.trim().isEmpty ? 'geometric' : gridMode.text.trim(),
      gridIntervalCount: integer(intervalCount),
      initialBuyOrderCount: integer(buyCount),
      initialSellOrderCount: 0,
      maxOpenOrders: integer(maxOpen),
      spotCapital: decimal(capital),
      initialBtcRatio: decimal(initialRatio),
      singleGridAmount: decimal(singleAmount),
      maxLossUsdt: decimal(maxLoss),
      dailyMaxLossUsdt: decimal(dailyLoss),
      outOfRangeAction: outOfRange.text.trim().isEmpty
          ? 'pauseAndReview'
          : outOfRange.text.trim(),
      enableFutureHedgeGrid: enableFutureHedgeGrid,
      futureGridOffset:
          integer(futureGridOffset) <= 0 ? 1 : integer(futureGridOffset),
      futuresLeverage: integer(futuresLeverage).clamp(1, 125),
      futuresPriceSource: futuresPriceSource,
      longEntryTriggerDistanceUsdt:
          decimal(longEntryTriggerDistance) < Decimal.zero
              ? Decimal.zero
              : decimal(longEntryTriggerDistance),
      longEntryTriggerMode: widget.config.longEntryTriggerMode,
      longEntryPrehangLevels: widget.config.longEntryPrehangLevels,
      shortHedgeMultiplier: decimal(shortHedgeMultiplier) <= Decimal.zero
          ? Decimal.parse('1.2')
          : decimal(shortHedgeMultiplier),
      shortHedgeSpreadLevels: integer(shortHedgeSpreadLevels) <= 0
          ? 4
          : integer(shortHedgeSpreadLevels),
    );
  }

  bool get _showShortHedgeSettings {
    return enableFutureHedgeGrid ||
        executionMode == LiveSpotGridEditableConfig.futuresGridHedge;
  }

  Decimal _lowerPercentFromPrices(LiveSpotGridEditableConfig config) {
    if (config.centerPrice <= Decimal.zero) return Decimal.zero;
    final ratio =
        ((config.centerPrice - config.lowerPrice) / config.centerPrice)
            .toDecimal(scaleOnInfinitePrecision: 8);
    return ratio * Decimal.fromInt(100);
  }

  Decimal _upperPercentFromPrices(LiveSpotGridEditableConfig config) {
    if (config.centerPrice <= Decimal.zero) return Decimal.zero;
    final ratio =
        ((config.upperPrice - config.centerPrice) / config.centerPrice)
            .toDecimal(scaleOnInfinitePrecision: 8);
    return ratio * Decimal.fromInt(100);
  }
}

class _BtcInventoryDialog extends StatefulWidget {
  const _BtcInventoryDialog({
    required this.inventory,
    required this.baseAsset,
    required this.defaultExternalAll,
  });

  final LiveSpotBtcInventory inventory;
  final String baseAsset;
  final bool defaultExternalAll;

  @override
  State<_BtcInventoryDialog> createState() => _BtcInventoryDialogState();
}

class _BtcInventoryDialogState extends State<_BtcInventoryDialog> {
  late final TextEditingController strategyBtc;
  late final TextEditingController externalBtc;
  String error = '';

  @override
  void initState() {
    super.initState();
    final inventory = widget.inventory;
    strategyBtc = TextEditingController(
      text: widget.defaultExternalAll ? '0' : inventory.strategyBtc.toString(),
    );
    externalBtc = TextEditingController(
      text: widget.defaultExternalAll
          ? inventory.accountTotalBtc.toString()
          : inventory.externalBtc.toString(),
    );
  }

  @override
  void dispose() {
    strategyBtc.dispose();
    externalBtc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inventory = widget.inventory;
    final baseAsset = widget.baseAsset;
    return AlertDialog(
      title: Text('确认 $baseAsset 归属'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '程序不会自动把账户已有 $baseAsset 当成策略 $baseAsset。请明确指定归属，未分类 $baseAsset 必须为 0 才允许启动自动网格。',
            ),
            const SizedBox(height: 12),
            Text('账户 $baseAsset 总量: ${inventory.accountTotalBtc}'),
            Text('available$baseAsset: ${inventory.btcFree}'),
            Text('locked$baseAsset: ${inventory.btcLocked}'),
            Text('currentStrategy$baseAsset: ${inventory.strategyBtc}'),
            Text('otherStrategy$baseAsset: ${inventory.otherStrategyBtc}'),
            Text('external$baseAsset: ${inventory.externalBtc}'),
            Text('unclassified$baseAsset: ${inventory.unclassifiedBtc}'),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: strategyBtc,
                    decoration: InputDecoration(
                      labelText: '指定为策略 $baseAsset',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => _validate(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: externalBtc,
                    decoration: InputDecoration(
                      labelText: '指定为外部 $baseAsset',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => _validate(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () {
                    strategyBtc.text = '0';
                    externalBtc.text = inventory.accountTotalBtc.toString();
                    _validate();
                  },
                  child: Text('A 标记为个人外部$baseAsset'),
                ),
                OutlinedButton(
                  onPressed: () {
                    strategyBtc.selection = TextSelection(
                      baseOffset: 0,
                      extentOffset: strategyBtc.text.length,
                    );
                  },
                  child: Text('B 指定数量为当前策略$baseAsset'),
                ),
                OutlinedButton(
                  onPressed: () {
                    strategyBtc.text = inventory.accountTotalBtc.toString();
                    externalBtc.text = '0';
                    _validate();
                  },
                  child: Text('C 全部划为当前策略$baseAsset'),
                ),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('D 暂不处理，禁止启动'),
                ),
              ],
            ),
            if (error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(error, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _currentResult() == null
              ? null
              : () => Navigator.of(context).pop(_currentResult()),
          child: const Text('确认归属'),
        ),
      ],
    );
  }

  void _validate() {
    setState(() {
      _currentResult();
    });
  }

  (Decimal, Decimal)? _currentResult() {
    final strategy = Decimal.tryParse(strategyBtc.text.trim());
    final external = Decimal.tryParse(externalBtc.text.trim());
    if (strategy == null || external == null) {
      error = '请输入合法 ${widget.baseAsset} 数量。';
      return null;
    }
    if (strategy < Decimal.zero || external < Decimal.zero) {
      error = '${widget.baseAsset} 数量不能为负数。';
      return null;
    }
    final assigned = strategy + external;
    if (assigned > widget.inventory.accountTotalBtc) {
      error =
          '策略 ${widget.baseAsset} + 外部 ${widget.baseAsset} 不能超过账户 ${widget.baseAsset} 总量。';
      return null;
    }
    final remaining = widget.inventory.accountTotalBtc - assigned;
    if (remaining > Decimal.zero) {
      error =
          '仍有 $remaining ${widget.baseAsset} 未分类。请全部归为策略或外部 ${widget.baseAsset}。';
      return null;
    }
    error = '';
    return (strategy, external);
  }
}

class _StrategySummary extends StatelessWidget {
  const _StrategySummary({required this.title, required this.strategy});

  final String title;
  final Strategy strategy;

  @override
  Widget build(BuildContext context) {
    final baseAsset = _baseAssetForSymbol(strategy.symbol);
    final rows = [
      ('策略ID', strategy.id),
      ('环境', strategy.environment),
      ('状态', strategy.status),
      ('交易对', strategy.symbol),
      ('中心价格', strategy.centerPrice),
      ('下限/上限', '${strategy.lowerPrice} / ${strategy.upperPrice}'),
      ('价格区间数量 gridIntervalCount', strategy.gridCount.toString()),
      ('价格节点数量 gridLevelCount', (strategy.gridCount + 1).toString()),
      ('网格模式', strategy.gridMode),
      ('现货资金', strategy.spotCapital),
      ('策略现货$baseAsset', strategy.strategySpotBtc),
      ('最大亏损', strategy.maxLossUsdt),
      ('最后错误', strategy.lastError ?? '-'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 160,
                  child: Text(
                    row.$1,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(child: SelectableText(row.$2)),
              ],
            ),
          ),
      ],
    );
  }
}
