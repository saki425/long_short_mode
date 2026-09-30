import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/symbol_workspace_controller.dart';
import '../services/execution/auto_spot_grid_execution_service.dart';
import '../services/market_data/market_data_coordinator.dart';
import '../services/market_data/market_tick.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final workspace = Get.find<SymbolWorkspaceController>();
    final market = Get.find<MarketDataCoordinator>();
    final liveGrid = Get.find<AutoSpotGridExecutionService>();

    return Scaffold(
      appBar: AppBar(title: const Text('总览')),
      body: Obx(() {
        final active = workspace.activeSymbol.value;
        if (active == null) {
          return const Center(child: Text('请先添加交易币对'));
        }

        return StreamBuilder<MarketTick>(
          key: ValueKey('dashboard-market-${active.symbol}'),
          stream: market.uiMarketStream,
          initialData: market.currentMarketTick,
          builder: (context, marketSnapshot) {
            final tick = marketSnapshot.data;
            final spot = tick?.symbol == active.symbol ? tick?.spot : null;
            final futures =
                tick?.symbol == active.symbol ? tick?.futures : null;

            return StreamBuilder(
              key: ValueKey('dashboard-strategy-${active.symbol}'),
              stream: liveGrid.watchActiveStrategy(symbol: active.symbol),
              builder: (context, strategySnapshot) {
                final strategy = strategySnapshot.data;
                return GridView.count(
                  padding: const EdgeInsets.all(16),
                  crossAxisCount: 4,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 2.4,
                  children: [
                    _MetricCard('当前币对', active.displayName),
                    _MetricCard('现货中间价', spot?.midPrice.toString() ?? '-'),
                    _MetricCard('现货Bid', spot?.bidPrice.toString() ?? '-'),
                    _MetricCard('现货Ask', spot?.askPrice.toString() ?? '-'),
                    _MetricCard('买卖价差', spot?.spread.toString() ?? '-'),
                    _MetricCard('价差百分比', spot?.spreadPercent.toString() ?? '-'),
                    _MetricCard('永续标记价格', futures?.markPrice.toString() ?? '-'),
                    _MetricCard('指数价格', futures?.indexPrice.toString() ?? '-'),
                    _MetricCard('现货/标记价差', tick?.basis?.toString() ?? '-'),
                    _MetricCard('资金费率', futures?.fundingRate.toString() ?? '-'),
                    _MetricCard(
                      '下一资金费时间',
                      futures?.nextFundingTime.toLocal().toString() ?? '-',
                    ),
                    _MetricCard('策略状态', strategy?.status ?? '无策略'),
                    _MetricCard(
                      '策略现货${active.baseAsset}',
                      strategy?.strategySpotBtc ?? '0',
                    ),
                    _MetricCard('当前空单${active.baseAsset}', '0'),
                    _MetricCard('目标空单${active.baseAsset}', '0'),
                    const _MetricCard('净敞口USDT', '-'),
                    const _MetricCard('网格已实现利润', '0'),
                    const _MetricCard('合约浮动盈亏', '0'),
                    const _MetricCard('组合总盈亏', '0'),
                    const _MetricCard('总权益', '0'),
                    const _MetricCard('现货手续费', '0'),
                    const _MetricCard('账户/行情连接', 'BINANCE LIVE'),
                  ],
                );
              },
            );
          },
        );
      }),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            Text(
              value,
              style: Theme.of(context).textTheme.titleLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
