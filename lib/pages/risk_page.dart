import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../database/app_database.dart';
import '../strategy/paper/paper_trading_service.dart';

class RiskPage extends StatelessWidget {
  const RiskPage({super.key});

  @override
  Widget build(BuildContext context) {
    final paper = Get.find<PaperTradingService>();
    return Scaffold(
      appBar: AppBar(title: const Text('风险事件')),
      body: StreamBuilder<Strategy?>(
        stream: paper.watchActiveStrategy(),
        builder: (context, strategySnapshot) {
          final strategy = strategySnapshot.data;
          if (strategy == null) {
            return const Center(child: Text('尚未创建Paper策略'));
          }
          return StreamBuilder<List<RiskEvent>>(
            stream: paper.watchRiskEvents(strategy.id),
            builder: (context, snapshot) {
              final rows = snapshot.data ?? const [];
              if (rows.isEmpty) {
                return const Center(child: Text('暂无风险事件'));
              }
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('时间')),
                    DataColumn(label: Text('类型')),
                    DataColumn(label: Text('级别')),
                    DataColumn(label: Text('消息')),
                    DataColumn(label: Text('当前值')),
                    DataColumn(label: Text('限制')),
                    DataColumn(label: Text('动作')),
                  ],
                  rows: [
                    for (final row in rows)
                      DataRow(cells: [
                        DataCell(Text(row.createdAt.toLocal().toString())),
                        DataCell(Text(row.type)),
                        DataCell(Text(row.level)),
                        DataCell(Text(row.message)),
                        DataCell(Text(row.currentValue ?? '-')),
                        DataCell(Text(row.limitValue ?? '-')),
                        DataCell(Text(row.actionTaken ?? '-')),
                      ]),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
