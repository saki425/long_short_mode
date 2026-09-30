import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../../controllers/order_center_controller.dart';
import '../../repositories/order_repository.dart';

class OrderDetailPage extends StatelessWidget {
  const OrderDetailPage({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<OrderCenterController>();
    return Scaffold(
      appBar: AppBar(title: const Text('订单详情')),
      body: FutureBuilder<OrderDetails?>(
        future: controller.loadDetails(orderId),
        builder: (context, snapshot) {
          final details = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (details == null) {
            return const Center(child: Text('订单不存在'));
          }
          final order = details.order;
          final df = DateFormat('yyyy-MM-dd HH:mm:ss');
          final rows = <_DetailRow>[
            _DetailRow('本地订单ID', order.id),
            _DetailRow('Client Order ID', order.clientOrderId),
            _DetailRow('币安订单ID', order.exchangeOrderId ?? '-'),
            _DetailRow('策略ID', order.strategyId),
            _DetailRow('交易对', order.symbol),
            _DetailRow('账户类型', order.accountType),
            _DetailRow('市场', order.marketType),
            _DetailRow('订单用途', order.purpose),
            _DetailRow('订单方向', order.side),
            _DetailRow('Reduce Only', order.reduceOnly ? '是' : '否'),
            _DetailRow('计划价格', order.price ?? '-'),
            _DetailRow('成交均价', order.averagePrice ?? '-'),
            _DetailRow('原始数量', order.originalQuantity),
            _DetailRow('成交数量', order.executedQuantity),
            _DetailRow('创建时间', df.format(order.createdAt.toLocal())),
            _DetailRow('提交时间', order.submittedAt == null ? '-' : df.format(order.submittedAt!.toLocal())),
            _DetailRow('完成时间', order.completedAt == null ? '-' : df.format(order.completedAt!.toLocal())),
            _DetailRow('关联网格', order.gridLevelId ?? '-'),
            _DetailRow('关联订单', order.parentOrderId ?? '-'),
            _DetailRow('错误信息', order.errorMessage ?? '-'),
          ];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 140, child: Text(row.label, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Expanded(child: SelectableText(row.value)),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              Text('部分成交记录', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (details.fills.isEmpty) const Text('暂无成交'),
              for (final fill in details.fills)
                Card(
                  child: ListTile(
                    title: Text('${fill.side} ${fill.quantity} @ ${fill.price}'),
                    subtitle: Text('成交额 ${fill.quoteQuantity} | 手续费 ${fill.commission} ${fill.commissionAsset} | ${df.format(fill.tradeTime.toLocal())}'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _DetailRow {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;
}
