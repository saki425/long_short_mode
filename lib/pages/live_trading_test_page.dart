import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/live_trading_test_controller.dart';
import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../services/app_ui_settings.dart';

class LiveTradingTestPage extends StatelessWidget {
  const LiveTradingTestPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<LiveTradingTestController>();
    final workspace = Get.find<SymbolWorkspaceController>();
    return Obx(() {
      final active = workspace.activeSymbol.value;
      final symbol = active?.symbol ?? controller.activeSymbol;
      return StreamBuilder<bool>(
        stream: AppUiSettings.watchHideSpotUiForSymbol(
          Get.find<AppDatabase>(),
          symbol: symbol,
        ),
        initialData: false,
        builder: (context, snapshot) {
          final hideSpot = snapshot.data ?? false;
          return DefaultTabController(
            key: ValueKey('live-trading-test-$symbol-hide-spot-$hideSpot'),
            length: hideSpot ? 1 : 2,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('交易测试'),
                actions: [
                  TextButton.icon(
                    onPressed:
                        () =>
                            hideSpot
                                ? controller.connectFuturesForSymbol(symbol)
                                : controller.connectForSymbol(symbol),
                    icon: const Icon(Icons.link),
                    label: const Text('连接'),
                  ),
                  TextButton.icon(
                    onPressed:
                        () =>
                            hideSpot
                                ? controller.refreshFuturesForSymbol(symbol)
                                : controller.refreshForSymbol(symbol),
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新'),
                  ),
                  TextButton.icon(
                    onPressed: controller.exportOrders,
                    icon: const Icon(Icons.download),
                    label: const Text('导出'),
                  ),
                ],
              ),
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TabBar(
                    labelColor: Colors.black87,
                    unselectedLabelColor: Colors.black54,
                    indicatorColor: const Color(0xFF3F51B5),
                    tabs: [
                      if (!hideSpot) const Tab(text: '现货下单测试'),
                      const Tab(text: '合约下单测试'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        if (!hideSpot)
                          _SpotTestTab(
                            controller: controller,
                            symbol: symbol,
                            displayName: active?.displayName ?? symbol,
                            baseAsset: active?.baseAsset ?? symbol,
                          ),
                        _FuturesTestTab(controller: controller, symbol: symbol),
                      ],
                    ),
                  ),
                  _Diagnostics(controller: controller),
                ],
              ),
            ),
          );
        },
      );
    });
  }
}

class _SpotTestTab extends StatelessWidget {
  const _SpotTestTab({
    required this.controller,
    required this.symbol,
    required this.displayName,
    required this.baseAsset,
  });

  final LiveTradingTestController controller;
  final String symbol;
  final String displayName;
  final String baseAsset;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final enabled =
          controller.liveTradingGateService.liveTradingEnabled.value;
      final canTrade = enabled && controller.spotTestOrderPassed.value;
      final selectedSide = controller.spotSelectedSide.value;
      final selectedType = controller.spotSelectedOrderType.value;
      final minNotional = controller.executionService.spotRules?.minNotional;
      final spotOrderLimit = controller.manualSpotOrderLimit.value;
      final spotDailyLimit = controller.manualSpotDailyLimit.value;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '$displayName 现货下单测试',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '单笔现货订单金额不得超过 $spotOrderLimit USDT；每日累计测试成交不得超过 $spotDailyLimit USDT。',
                ),
                if (minNotional != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Binance 最小名义金额: $minNotional USDT'),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('方向'),
                    ChoiceChip(
                      label: const Text('买入 BUY'),
                      selected: selectedSide == 'BUY',
                      onSelected: (_) => controller.setSpotSide('BUY'),
                    ),
                    ChoiceChip(
                      label: const Text('卖出 SELL'),
                      selected: selectedSide == 'SELL',
                      onSelected: (_) => controller.setSpotSide('SELL'),
                    ),
                    const SizedBox(width: 12),
                    const Text('类型'),
                    ChoiceChip(
                      label: const Text('限价 LIMIT'),
                      selected: selectedType == 'LIMIT',
                      onSelected: (_) => controller.setSpotOrderType('LIMIT'),
                    ),
                    ChoiceChip(
                      label: const Text('市价 MARKET'),
                      selected: selectedType == 'MARKET',
                      onSelected: (_) => controller.setSpotOrderType('MARKET'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _TextField(
                        controller: controller.spotLimitQtyController,
                        label: '数量',
                        onChanged: (_) => controller.resetSpotTestOrder(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TextField(
                        controller: controller.spotLimitPriceController,
                        label: '限价价格',
                        enabled: selectedType == 'LIMIT',
                        onChanged: (_) => controller.resetSpotTestOrder(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TextField(
                        controller: controller.spotMarketQuoteController,
                        label: '市价买入USDT',
                        enabled:
                            selectedType == 'MARKET' && selectedSide == 'BUY',
                        onChanged: (_) => controller.resetSpotTestOrder(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed:
                          () => controller.validateSelectedSpotTestOrder(
                            symbol: symbol,
                          ),
                      child: Text('Test Order: $selectedType $selectedSide'),
                    ),
                    OutlinedButton(
                      onPressed:
                          canTrade
                              ? () => controller.submitSelectedSpotOrder(
                                context,
                                symbol: symbol,
                              )
                              : null,
                      child: Text('提交真实订单: $selectedType $selectedSide'),
                    ),
                  ],
                ),
                const Divider(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _TextField(
                        controller: controller.spotClientOrderIdController,
                        label: 'Spot Client Order ID',
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed:
                          () => controller.querySpotOrder(symbol: symbol),
                      child: const Text('查询订单'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed:
                          enabled
                              ? () => controller.cancelOrder(
                                controller.spotClientOrderIdController.text
                                    .trim(),
                                futures: false,
                                symbol: symbol,
                              )
                              : null,
                      child: const Text('撤销订单'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                      ),
                      onPressed:
                          enabled
                              ? () => controller.cancelAllSpotOpenOrders(
                                context,
                                symbol: symbol,
                                displayName: displayName,
                                baseAsset: baseAsset,
                              )
                              : null,
                      icon: const Icon(Icons.cancel),
                      label: Text('撤销 $displayName 现货挂单'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _FuturesTestTab extends StatelessWidget {
  const _FuturesTestTab({required this.controller, required this.symbol});

  final LiveTradingTestController controller;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final enabled =
          controller.liveTradingGateService.liveTradingEnabled.value;
      final canTrade = enabled && controller.futuresSignaturePassed.value;
      final orderLimit = controller.manualFuturesOrderLimit.value;
      final shortLimit = controller.manualFuturesShortLimit.value;
      final targetSymbol = controller.manualFuturesSymbol;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '$targetSymbol U本位永续下单测试',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '只允许 SELL 开空；BUY reduceOnly=true 平空；SELL reduceOnly=true 平多。非 Reduce Only BUY 禁止。单笔不超过 $orderLimit USDT，最大空单名义价值 $shortLimit USDT。',
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _TextField(
                        controller: controller.futuresManualSymbolController,
                        label: '手动 Symbol',
                        onChanged: (value) {
                          controller.futuresManualSymbolText.value = value;
                          controller.futuresSignaturePassed.value = false;
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () {
                        final manual = controller.manualFuturesSymbol;
                        controller.connectFuturesForSymbol(manual);
                      },
                      icon: const Icon(Icons.link),
                      label: const Text('连接/加载'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed:
                          () => controller.refreshFuturesForSymbol(
                            controller.manualFuturesSymbol,
                          ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('刷新该 Symbol'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '当前页面币对：$symbol；实际合约测试使用：$targetSymbol。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _TextField(
                        controller: controller.futuresQtyController,
                        label: '数量',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TextField(
                        controller: controller.futuresPriceController,
                        label: '限价价格',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed:
                          () => controller.testFuturesSignature(
                            symbol: controller.manualFuturesSymbol,
                          ),
                      child: const Text('测试合约签名'),
                    ),
                    OutlinedButton(
                      onPressed:
                          canTrade
                              ? () => controller.placeFuturesMarketOrder(
                                context,
                                side: 'SELL',
                                reduceOnly: false,
                                symbol: controller.manualFuturesSymbol,
                              )
                              : null,
                      child: const Text('开小额空单'),
                    ),
                    OutlinedButton(
                      onPressed:
                          () => controller.refreshFuturesForSymbol(
                            controller.manualFuturesSymbol,
                          ),
                      child: const Text('查询仓位'),
                    ),
                    OutlinedButton(
                      onPressed:
                          canTrade
                              ? () => controller.placeFuturesMarketOrder(
                                context,
                                side: 'BUY',
                                reduceOnly: true,
                                symbol: controller.manualFuturesSymbol,
                              )
                              : null,
                      child: const Text('Reduce Only 平空'),
                    ),
                    OutlinedButton(
                      onPressed:
                          canTrade
                              ? () => controller.placeFuturesMarketOrder(
                                context,
                                side: 'SELL',
                                reduceOnly: true,
                                symbol: controller.manualFuturesSymbol,
                              )
                              : null,
                      child: const Text('Reduce Only 平多'),
                    ),
                  ],
                ),
                const Divider(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _TextField(
                        controller: controller.futuresClientOrderIdController,
                        label: 'Futures Client Order ID',
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed:
                          () => controller.queryFuturesOrder(
                            symbol: controller.manualFuturesSymbol,
                          ),
                      child: const Text('查询订单'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed:
                          enabled
                              ? () => controller.cancelOrder(
                                controller.futuresClientOrderIdController.text
                                    .trim(),
                                futures: true,
                                symbol: controller.manualFuturesSymbol,
                              )
                              : null,
                      child: const Text('撤销订单'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _Diagnostics extends StatelessWidget {
  const _Diagnostics({required this.controller});

  final LiveTradingTestController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Container(
        height: 92,
        padding: const EdgeInsets.all(8),
        color: Colors.grey.shade100,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                controller.diagnostics.value.isEmpty
                    ? (controller.message.value.isEmpty
                        ? '暂无诊断信息'
                        : controller.message.value)
                    : controller.diagnostics.value,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.label,
    this.enabled = true,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: onChanged,
    );
  }
}
