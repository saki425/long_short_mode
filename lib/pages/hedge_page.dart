import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../services/execution/auto_spot_grid_execution_service.dart';
import '../services/hedge/live_hedge_service.dart';

class HedgePage extends StatefulWidget {
  const HedgePage({super.key});

  @override
  State<HedgePage> createState() => _HedgePageState();
}

class _HedgePageState extends State<HedgePage> {
  String _message = '';
  bool _syncingFutures = false;

  @override
  Widget build(BuildContext context) {
    final liveGrid = Get.find<AutoSpotGridExecutionService>();
    final hedge = Get.find<LiveHedgeService>();
    return Scaffold(
      appBar: AppBar(title: const Text('动态对冲')),
      body: Obx(() {
        final active = Get.find<SymbolWorkspaceController>().activeSymbol.value;
        final symbol = active?.symbol;
        if (active == null || symbol == null) {
          return const Center(child: Text('请先添加交易币对'));
        }

        return StreamBuilder<Strategy?>(
          key: ValueKey('hedge-$symbol'),
          stream: liveGrid.watchActiveStrategy(symbol: symbol),
          builder: (context, strategySnapshot) {
            final strategy = strategySnapshot.data;
            if (strategy == null) {
              return Center(
                child: Text('当前 ${active.displayName} 尚未创建 LIVE 现货网格策略'),
              );
            }
            if (strategy.symbol != symbol) {
              return Center(
                child: Text(
                  '当前页面币对与策略币对不一致，已阻止加载。\nactiveSymbol=$symbol strategy.symbol=${strategy.symbol}',
                  style: const TextStyle(color: Colors.red),
                ),
              );
            }

            return StreamBuilder<List<FuturesPosition>>(
              stream: hedge.watchFuturesPositions(),
              builder: (context, _) {
                return StreamBuilder<FuturesAccountSnapshot?>(
                  stream: hedge.watchLatestFuturesAccountSnapshot(),
                  builder: (context, __) {
                    return FutureBuilder<LiveHedgeSnapshot>(
                      future: hedge.calculate(strategy.id),
                      builder: (context, snapshot) {
                        final data = snapshot.data;
                        if (data == null) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }

                        return ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            Text('当前币对：${active.displayName}'),
                            const SizedBox(height: 8),
                            _StatusCard(snapshot: data),
                            const SizedBox(height: 12),
                            _FuturesReadOnlyCard(snapshot: data),
                            const SizedBox(height: 12),
                            _HedgeStageCard(snapshot: data),
                            const SizedBox(height: 12),
                            _SettingsCard(
                              state: data.state,
                              onSave: (settings) async {
                                await hedge.updateSettings(
                                  strategyId: strategy.id,
                                  hedgeEnabled: settings.hedgeEnabled,
                                  hedgeDryRun: settings.hedgeDryRun,
                                  hedgeRatio: settings.hedgeRatio,
                                  maxHedgeQty: settings.maxHedgeQty,
                                  minAdjustQty: settings.minAdjustQty,
                                  minAdjustNotional: settings.minAdjustNotional,
                                  checkIntervalSeconds:
                                      settings.checkIntervalSeconds,
                                  allowAutoOpenShort:
                                      settings.allowAutoOpenShort,
                                  allowAutoCloseShort:
                                      settings.allowAutoCloseShort,
                                );
                                await hedge.calculate(strategy.id);
                                setState(() => _message = '对冲配置已保存并重新计算');
                              },
                            ),
                            const SizedBox(height: 12),
                            _ActionButtons(
                              syncingFutures: _syncingFutures,
                              message: _message,
                              strategyId: strategy.id,
                              hedge: hedge,
                              snapshot: data,
                              onSyncFutures: () async {
                                setState(() {
                                  _syncingFutures = true;
                                  _message = '正在同步真实 Futures 仓位...';
                                });
                                try {
                                  await hedge.syncFuturesPositionAndCalculate(
                                    strategy.id,
                                  );
                                  setState(
                                    () => _message = '已同步真实 Futures 仓位并重新计算',
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(() => _syncingFutures = false);
                                  }
                                }
                              },
                              onRecalculate: () async {
                                await hedge.calculate(strategy.id);
                                setState(() => _message = '已重新计算对冲');
                              },
                              onDryRun: () async {
                                await hedge.createDryRunAction(strategy.id);
                                setState(() => _message = '已记录 Dry Run 对冲动作');
                              },
                              onExecute: () async {
                                final confirmed = await _confirm(context, data);
                                if (confirmed != true) {
                                  return;
                                }
                                await hedge.executeSuggestedAction(strategy.id);
                                setState(() => _message = '已执行建议 Futures 对冲动作');
                              },
                              onStartAuto: () async {
                                final confirmed = await _confirmAutoStart(
                                  context,
                                  data,
                                );
                                if (confirmed != true) {
                                  return;
                                }
                                await hedge.startAutoExecution(strategy.id);
                                setState(() => _message = '已开启自动 Futures 对冲执行');
                              },
                              onStopAuto: () async {
                                await hedge.stopAutoExecution(strategy.id);
                                setState(() => _message = '已关闭自动 Futures 对冲执行');
                              },
                            ),
                            const SizedBox(height: 12),
                            _ExposureTable(exposures: data.gridExposures),
                            const SizedBox(height: 12),
                            StreamBuilder<List<HedgeAction>>(
                              stream: hedge.watchActions(strategy.id),
                              builder: (context, actionSnapshot) {
                                return _ActionsTable(
                                  actions: actionSnapshot.data ?? const [],
                                );
                              },
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
      }),
    );
  }

  Future<bool?> _confirm(BuildContext context, LiveHedgeSnapshot snapshot) {
    final result = snapshot.result;
    final dryRun = snapshot.state.hedgeDryRun;
    return showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(dryRun ? '记录 Dry Run 对冲动作' : '确认执行 Futures 对冲单'),
            content: SelectableText(
              '当前策略: ${snapshot.strategy.name}\n'
              '当前暴露 BTC: ${result.exposedSpotQty}\n'
              '当前空单: ${result.currentShortQty}\n'
              '目标空单: ${result.targetShortQty}\n'
              '需要调整数量: ${result.diffQty}\n'
              '本次动作: ${result.actionType.name}\n'
              '方向: ${result.side}\n'
              '数量: ${result.actionQty}\n'
              'reduceOnly: ${result.reduceOnly}\n'
              '预计名义金额: ${result.actionNotional}\n'
              'Dry Run: $dryRun\n\n'
              '${dryRun ? '当前只会记录 Dry Run，不会发送真实 Futures 订单。' : '确认后会发送真实 Binance Futures 订单。'}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(dryRun ? '确认记录 Dry Run' : '确认执行 Futures 对冲单'),
              ),
            ],
          ),
    );
  }

  Future<bool?> _confirmAutoStart(
    BuildContext context,
    LiveHedgeSnapshot snapshot,
  ) {
    final state = snapshot.state;
    final result = snapshot.result;
    return showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('确认开启自动 Futures 对冲执行'),
            content: SelectableText(
              '当前策略: ${snapshot.strategy.name}\n'
              'Dry Run: ${state.hedgeDryRun}\n'
              '允许自动开空: ${state.allowAutoOpenShort}\n'
              '允许自动平空: ${state.allowAutoCloseShort}\n'
              '检查间隔: ${state.checkIntervalSeconds} 秒\n'
              '当前暴露 BTC: ${result.exposedSpotQty}\n'
              '当前空单: ${result.currentShortQty}\n'
              '目标空单: ${result.targetShortQty}\n'
              '建议动作: ${result.actionType.name}\n\n'
              '开启后程序会按间隔自动重新计算并发送符合条件的 Futures 对冲单。'
              '必须确保真实写操作已开启，且 Futures 账户、杠杆和保证金模式符合要求。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认开启自动执行'),
              ),
            ],
          ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.snapshot});

  final LiveHedgeSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final state = snapshot.state;
    final result = snapshot.result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前对冲状态', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Metric('对冲开关', state.hedgeEnabled ? '开启' : '关闭'),
                _Metric('Dry Run', state.hedgeDryRun ? '是' : '否'),
                _Metric(
                  '对冲比例',
                  '${(Decimal.tryParse(state.hedgeRatio) ?? Decimal.zero) * Decimal.fromInt(100)}%',
                ),
                _Metric('策略暴露 BTC', result.exposedSpotQty.toString()),
                _Metric('当前价格', result.currentPrice.toString()),
                _Metric('策略中线', result.midPrice.toString()),
                _Metric('策略下限', result.lowerPrice.toString()),
                _Metric('riskScore', result.riskScore.toString()),
                _Metric(
                  '实际目标对冲比例',
                  '${result.effectiveHedgeRatio * Decimal.fromInt(100)}%',
                ),
                _Metric('当前合约空单', result.currentShortQty.toString()),
                _Metric('目标空单', result.targetShortQty.toString()),
                _Metric('需要调整数量', result.diffQty.toString()),
                _Metric('建议动作', result.actionType.name),
                _Metric('动作数量', result.actionQty.toString()),
                _Metric('原因', result.reason),
                _Metric(
                  '外部仓位',
                  snapshot.externalFuturesPosition ? '检测到' : '未检测到',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FuturesReadOnlyCard extends StatelessWidget {
  const _FuturesReadOnlyCard({required this.snapshot});

  final LiveHedgeSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final position = snapshot.futuresPosition;
    final account = snapshot.futuresAccountSnapshot;
    final positionAmount = position?.positionAmount ?? '0';
    final markPrice = position?.markPrice ?? account?.markPrice;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '真实 Futures 只读数据',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                const _Metric('同步来源', 'Binance Futures REST / 本地SQLite'),
                _Metric('仓位方向', position?.positionSide ?? '-'),
                _Metric('原始仓位数量', positionAmount.toString()),
                _Metric('当前真实空单', snapshot.result.currentShortQty.toString()),
                _Metric('目标空单', snapshot.result.targetShortQty.toString()),
                _Metric('差值', snapshot.result.diffQty.toString()),
                _Metric('开仓均价', position?.entryPrice.toString() ?? '-'),
                _Metric('Mark Price', markPrice ?? '-'),
                _Metric('未实现盈亏', position?.unrealizedPnl.toString() ?? '-'),
                _Metric('杠杆', position?.leverage ?? '-'),
                _Metric('保证金模式', position?.marginType ?? '-'),
                _Metric('钱包余额', account?.walletBalance ?? '-'),
                _Metric('可用余额', account?.availableBalance ?? '-'),
                _Metric('账户未实现盈亏', account?.totalUnrealizedPnl ?? '-'),
                _Metric(
                  '最近仓位更新时间',
                  position?.updatedAt.toLocal().toString() ?? '-',
                ),
                _Metric(
                  '最近账户同步时间',
                  account?.recordedAt.toLocal().toString() ?? '-',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '当前阶段只读取真实 Futures 仓位并做 Dry Run 校验，不会自动发送合约订单。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _HedgeStageCard extends StatelessWidget {
  const _HedgeStageCard({required this.snapshot});

  final LiveHedgeSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final result = snapshot.result;
    final color = _stageColor(result.hedgeStage.name);
    return Card(
      color: color.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前对冲阶段', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            _StageLine(
              '阶段',
              '${result.hedgeStageText}（${result.hedgeStage.name}）',
            ),
            _StageLine('原因', result.hedgeReasonText),
            _StageLine('下一步', result.hedgeNextActionText),
            const SizedBox(height: 8),
            Text(
              '订单决定是否需要对冲，价格决定对冲比例。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Color _stageColor(String stage) {
    return switch (stage) {
      'belowLowerStrongHedge' ||
      'deepBelowLowerEmergencyHedge' ||
      'blockedByRisk' ||
      'externalPositionDetected' ||
      'error' => Colors.red,
      'skipTooSmall' || 'syncRequired' => Colors.orange,
      'aboveMidNoHedge' || 'noExposure' => Colors.green,
      _ => Colors.blueGrey,
    };
  }
}

class _StageLine extends StatelessWidget {
  const _StageLine(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label：',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

class _HedgeSettings {
  const _HedgeSettings({
    required this.hedgeEnabled,
    required this.hedgeDryRun,
    required this.hedgeRatio,
    required this.maxHedgeQty,
    required this.minAdjustQty,
    required this.minAdjustNotional,
    required this.checkIntervalSeconds,
    required this.allowAutoOpenShort,
    required this.allowAutoCloseShort,
  });

  final bool hedgeEnabled;
  final bool hedgeDryRun;
  final Decimal hedgeRatio;
  final Decimal maxHedgeQty;
  final Decimal minAdjustQty;
  final Decimal minAdjustNotional;
  final int checkIntervalSeconds;
  final bool allowAutoOpenShort;
  final bool allowAutoCloseShort;
}

class _SettingsCard extends StatefulWidget {
  const _SettingsCard({required this.state, required this.onSave});

  final HedgeState state;
  final Future<void> Function(_HedgeSettings) onSave;

  @override
  State<_SettingsCard> createState() => _SettingsCardState();
}

class _SettingsCardState extends State<_SettingsCard> {
  late bool _enabled;
  late bool _dryRun;
  late bool _allowOpen;
  late bool _allowClose;
  late final TextEditingController _ratio;
  late final TextEditingController _maxQty;
  late final TextEditingController _minQty;
  late final TextEditingController _minNotional;
  late final TextEditingController _interval;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final state = widget.state;
    _enabled = state.hedgeEnabled;
    _dryRun = state.hedgeDryRun;
    _allowOpen = state.allowAutoOpenShort;
    _allowClose = state.allowAutoCloseShort;
    _ratio = TextEditingController(text: state.hedgeRatio);
    _maxQty = TextEditingController(text: state.maxHedgeQty);
    _minQty = TextEditingController(text: state.minAdjustQty);
    _minNotional = TextEditingController(text: state.minAdjustNotional);
    _interval = TextEditingController(
      text: state.checkIntervalSeconds.toString(),
    );
  }

  @override
  void dispose() {
    _ratio.dispose();
    _maxQty.dispose();
    _minQty.dispose();
    _minNotional.dispose();
    _interval.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.updatedAt == widget.state.updatedAt &&
        oldWidget.state.hedgeDryRun == widget.state.hedgeDryRun &&
        oldWidget.state.hedgeEnabled == widget.state.hedgeEnabled &&
        oldWidget.state.allowAutoOpenShort == widget.state.allowAutoOpenShort &&
        oldWidget.state.allowAutoCloseShort ==
            widget.state.allowAutoCloseShort) {
      return;
    }
    final state = widget.state;
    _enabled = state.hedgeEnabled;
    _dryRun = state.hedgeDryRun;
    _allowOpen = state.allowAutoOpenShort;
    _allowClose = state.allowAutoCloseShort;
    _ratio.text = state.hedgeRatio;
    _maxQty.text = state.maxHedgeQty;
    _minQty.text = state.minAdjustQty;
    _minNotional.text = state.minAdjustNotional;
    _interval.text = state.checkIntervalSeconds.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('对冲配置', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: const Text('启用合约对冲'),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
            SwitchListTile(
              title: const Text('Dry Run 只计算不下单'),
              subtitle: Text(
                _dryRun
                    ? '当前不会发送真实 Futures 订单，也不能开启自动执行。'
                    : '已关闭 Dry Run。手动/自动执行会进入真实 Futures 下单检查链路。',
              ),
              value: _dryRun,
              onChanged: (value) => setState(() => _dryRun = value),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FilledButton.icon(
                onPressed: _saving ? null : _toggleDryRunAndSave,
                icon: Icon(_dryRun ? Icons.lock_open : Icons.science),
                label: Text(_dryRun ? '关闭 Dry Run 并保存' : '开启 Dry Run 并保存'),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _field(_ratio, '对冲比例 0-1'),
                _field(_maxQty, '最大对冲数量'),
                _field(_minQty, '最小调整数量'),
                _field(_minNotional, '最小调整金额'),
                _field(_interval, '检查间隔秒'),
              ],
            ),
            SwitchListTile(
              title: const Text('允许自动开空'),
              subtitle: const Text('关闭 Dry Run 且开启自动执行后，才允许自动增加 SHORT。'),
              value: _allowOpen,
              onChanged: (value) => setState(() => _allowOpen = value),
            ),
            SwitchListTile(
              title: const Text('允许自动平空'),
              subtitle: const Text('关闭 Dry Run 且开启自动执行后，才允许 reduceOnly 自动平空。'),
              value: _allowClose,
              onChanged: (value) => setState(() => _allowClose = value),
            ),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon:
                  _saving
                      ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Icon(Icons.save),
              label: Text(_saving ? '保存中...' : '保存对冲配置'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(_currentSettings());
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _toggleDryRunAndSave() async {
    setState(() {
      _dryRun = !_dryRun;
      _saving = true;
    });
    try {
      await widget.onSave(_currentSettings());
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  _HedgeSettings _currentSettings() {
    return _HedgeSettings(
      hedgeEnabled: _enabled,
      hedgeDryRun: _dryRun,
      hedgeRatio: Decimal.tryParse(_ratio.text.trim()) ?? Decimal.parse('0.5'),
      maxHedgeQty:
          Decimal.tryParse(_maxQty.text.trim()) ?? Decimal.parse('0.01'),
      minAdjustQty:
          Decimal.tryParse(_minQty.text.trim()) ?? Decimal.parse('0.00001'),
      minAdjustNotional:
          Decimal.tryParse(_minNotional.text.trim()) ?? Decimal.fromInt(5),
      checkIntervalSeconds: int.tryParse(_interval.text.trim()) ?? 30,
      allowAutoOpenShort: _allowOpen,
      allowAutoCloseShort: _allowClose,
    );
  }

  Widget _field(TextEditingController controller, String label) {
    return SizedBox(
      width: 220,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _ActionButtons extends StatelessWidget {
  const _ActionButtons({
    required this.syncingFutures,
    required this.message,
    required this.strategyId,
    required this.hedge,
    required this.snapshot,
    required this.onSyncFutures,
    required this.onRecalculate,
    required this.onDryRun,
    required this.onExecute,
    required this.onStartAuto,
    required this.onStopAuto,
  });

  final bool syncingFutures;
  final String message;
  final String strategyId;
  final LiveHedgeService hedge;
  final LiveHedgeSnapshot snapshot;
  final VoidCallback onSyncFutures;
  final VoidCallback onRecalculate;
  final VoidCallback onDryRun;
  final VoidCallback onExecute;
  final VoidCallback onStartAuto;
  final VoidCallback onStopAuto;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Set<String>>(
      stream: hedge.watchAutoExecutionStrategies(),
      builder: (context, autoSnapshot) {
        final running =
            autoSnapshot.data?.contains(strategyId) ??
            hedge.isAutoExecutionRunning(strategyId);
        final canExecute = snapshot.result.canSubmit;
        final canStartAuto =
            snapshot.state.hedgeEnabled &&
            !snapshot.state.hedgeDryRun &&
            (snapshot.state.allowAutoOpenShort ||
                snapshot.state.allowAutoCloseShort) &&
            !running;
        final autoDisabledReason = _autoDisabledReason(running);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: syncingFutures ? null : onSyncFutures,
                      icon:
                          syncingFutures
                              ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : const Icon(Icons.sync),
                      label: const Text('同步 Futures 仓位'),
                    ),
                    ElevatedButton.icon(
                      onPressed: onRecalculate,
                      icon: const Icon(Icons.calculate),
                      label: const Text('重新计算对冲'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onDryRun,
                      icon: const Icon(Icons.science),
                      label: const Text('记录 Dry Run 动作'),
                    ),
                    FilledButton.icon(
                      onPressed: canExecute ? onExecute : null,
                      icon: const Icon(Icons.swap_horiz),
                      label: Text(
                        snapshot.state.hedgeDryRun
                            ? '手动执行建议动作（Dry Run）'
                            : '手动执行建议动作',
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: canStartAuto ? onStartAuto : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('开启自动执行'),
                    ),
                    OutlinedButton.icon(
                      onPressed: running ? onStopAuto : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('关闭自动执行'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '自动执行状态：${running ? '运行中' : '关闭'}。'
                  '${autoDisabledReason ?? '当前满足开启条件。'}',
                ),
                if (message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(message),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String? _autoDisabledReason(bool running) {
    if (running) {
      return '自动执行已经运行中。';
    }
    if (!snapshot.state.hedgeEnabled) {
      return '请先启用合约对冲。';
    }
    if (snapshot.state.hedgeDryRun) {
      return 'Dry Run 开启时禁止自动真实下单；如需自动执行，请关闭 Dry Run 并保存配置。';
    }
    if (!snapshot.state.allowAutoOpenShort &&
        !snapshot.state.allowAutoCloseShort) {
      return '请至少开启“允许自动开空”或“允许自动平空”。';
    }
    return null;
  }
}

class _ExposureTable extends StatelessWidget {
  const _ExposureTable({required this.exposures});

  final List exposures;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Grid ID')),
              DataColumn(label: Text('Cycle')),
              DataColumn(label: Text('阶段')),
              DataColumn(label: Text('BUY成交')),
              DataColumn(label: Text('SELL成交')),
              DataColumn(label: Text('暴露BTC')),
              DataColumn(label: Text('计入对冲')),
            ],
            rows: [
              for (final row in exposures)
                DataRow(
                  cells: [
                    DataCell(_wideCell(row.gridId.toString(), width: 520)),
                    DataCell(Text(row.cycleNumber.toString())),
                    DataCell(Text(row.phase.toString())),
                    DataCell(Text(row.buyFilledQty.toString())),
                    DataCell(Text(row.sellFilledQty.toString())),
                    DataCell(Text(row.exposedQty.toString())),
                    DataCell(Text(row.countsForHedge ? '是' : '否')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionsTable extends StatelessWidget {
  const _ActionsTable({required this.actions});

  final List<HedgeAction> actions;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('时间')),
              DataColumn(label: Text('动作')),
              DataColumn(label: Text('方向')),
              DataColumn(label: Text('数量')),
              DataColumn(label: Text('Dry Run')),
              DataColumn(label: Text('状态')),
              DataColumn(label: Text('Client Order ID')),
              DataColumn(label: Text('原因/错误')),
            ],
            rows: [
              for (final action in actions)
                DataRow(
                  cells: [
                    DataCell(Text(action.createdAt.toLocal().toString())),
                    DataCell(Text(action.actionType)),
                    DataCell(Text(action.side)),
                    DataCell(Text(action.quantity)),
                    DataCell(Text(action.dryRun ? '是' : '否')),
                    DataCell(Text(action.status)),
                    DataCell(_wideCell(action.clientOrderId ?? '-')),
                    DataCell(
                      _wideCell(
                        action.errorMessage ?? action.reason ?? '-',
                        width: 520,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _wideCell(String value, {double width = 220}) {
  return SizedBox(
    width: width,
    child: Tooltip(
      message: value,
      child: Text(value, softWrap: true, overflow: TextOverflow.visible),
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
