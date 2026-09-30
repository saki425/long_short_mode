import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../services/app_ui_settings.dart';

class FilledOrdersPage extends StatelessWidget {
  const FilledOrdersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final db = Get.find<AppDatabase>();
    final workspace = Get.find<SymbolWorkspaceController>();
    return Scaffold(
      appBar: AppBar(title: const Text('成交记录')),
      body: Obx(() {
        final active = workspace.activeSymbol.value;
        if (active == null) {
          return const Center(child: Text('请先添加交易币对。'));
        }
        return FutureBuilder<_FilledOrderScope>(
          future: _loadScope(db, active.symbol),
          builder: (context, scopeSnapshot) {
            final scope = scopeSnapshot.data;
            if (scope == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return StreamBuilder<List<ExchangeHistoricalOrder>>(
              stream: _watchFilledOrders(db, scope),
              builder: (context, orderSnapshot) {
                final orders =
                    orderSnapshot.data ?? const <ExchangeHistoricalOrder>[];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Chip(label: Text('币对: ${active.displayName}')),
                          const Chip(label: Text('范围: 最近7天')),
                          Chip(label: Text('已成交: ${orders.length}')),
                          if (scope.hideSpot) const Chip(label: Text('现货已隐藏')),
                        ],
                      ),
                    ),
                    Expanded(
                      child:
                          orderSnapshot.connectionState ==
                                  ConnectionState.waiting
                              ? const Center(child: CircularProgressIndicator())
                              : orders.isEmpty
                              ? Center(
                                child: Text(
                                  '${active.displayName} 最近7天没有 Binance 已成交订单。',
                                ),
                              )
                              : _FilledOrdersTable(orders: orders),
                    ),
                  ],
                );
              },
            );
          },
        );
      }),
    );
  }

  Future<_FilledOrderScope> _loadScope(AppDatabase db, String symbol) async {
    final normalized = symbol.toUpperCase();
    final hideSpot = await AppUiSettings.hideSpotUiForSymbol(
      db,
      symbol: normalized,
    );
    final binding =
        await (db.select(db.symbolAccountBindings)
              ..where(
                (tbl) =>
                    tbl.symbol.equals(normalized) &
                    tbl.environment.equals('live'),
              )
              ..limit(1))
            .getSingleOrNull();
    return _FilledOrderScope(
      symbol: normalized,
      hideSpot: hideSpot,
      spotKeyProfileId: binding?.spotKeyProfileId?.trim(),
      futuresKeyProfileId: binding?.futuresKeyProfileId?.trim(),
    );
  }

  Stream<List<ExchangeHistoricalOrder>> _watchFilledOrders(
    AppDatabase db,
    _FilledOrderScope scope,
  ) {
    final start = DateTime.now().toUtc().subtract(const Duration(days: 7));
    final query =
        db.select(db.exchangeHistoricalOrders)
          ..where(
            (tbl) =>
                tbl.environment.equals('live') &
                tbl.symbol.equals(scope.symbol) &
                tbl.status.equals('FILLED') &
                tbl.updatedAt.isBiggerOrEqualValue(start) &
                (scope.hideSpot
                    ? tbl.marketType.equals('usdtFutures')
                    : const Constant(true)),
          )
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)]);
    return query.watch().map(scope.filterRows);
  }
}

class _FilledOrdersTable extends StatelessWidget {
  const _FilledOrdersTable({required this.orders});

  final List<ExchangeHistoricalOrder> orders;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('成交时间')),
            DataColumn(label: Text('市场')),
            DataColumn(label: Text('方向')),
            DataColumn(label: Text('持仓方向')),
            DataColumn(label: Text('类型')),
            DataColumn(label: Text('价格')),
            DataColumn(label: Text('均价')),
            DataColumn(label: Text('成交数量')),
            DataColumn(label: Text('成交额')),
            DataColumn(label: Text('Binance订单ID')),
            DataColumn(label: Text('Client ID')),
            DataColumn(label: Text('账户')),
          ],
          rows: [
            for (final order in orders)
              DataRow(
                cells: [
                  DataCell(Text(_formatTime(order.updatedAt))),
                  DataCell(Text(_marketLabel(order.marketType))),
                  DataCell(Text(order.side)),
                  DataCell(Text(order.positionSide ?? '-')),
                  DataCell(Text(order.orderType)),
                  DataCell(Text(order.price)),
                  DataCell(Text(order.averagePrice ?? '-')),
                  DataCell(Text(order.executedQuantity)),
                  DataCell(Text(order.quoteQuantity ?? '-')),
                  DataCell(Text(order.exchangeOrderId)),
                  DataCell(
                    SizedBox(
                      width: 260,
                      child: Text(
                        order.clientOrderId,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  DataCell(Text(_shortProfile(order.keyProfileId))),
                ],
              ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime value) {
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(value.toLocal());
  }

  String _marketLabel(String marketType) {
    return marketType == 'usdtFutures' ? '合约' : '现货';
  }

  String _shortProfile(String value) {
    if (value.length <= 8) return value;
    return '${value.substring(0, 4)}...${value.substring(value.length - 4)}';
  }
}

class _FilledOrderScope {
  const _FilledOrderScope({
    required this.symbol,
    required this.hideSpot,
    required this.spotKeyProfileId,
    required this.futuresKeyProfileId,
  });

  final String symbol;
  final bool hideSpot;
  final String? spotKeyProfileId;
  final String? futuresKeyProfileId;

  List<ExchangeHistoricalOrder> filterRows(List<ExchangeHistoricalOrder> rows) {
    return rows.where(_matchesProfile).toList(growable: false);
  }

  bool _matchesProfile(ExchangeHistoricalOrder row) {
    if (row.marketType == 'spot') {
      if (hideSpot) return false;
      return _matchesKey(row.keyProfileId, spotKeyProfileId);
    }
    if (row.marketType == 'usdtFutures') {
      return _matchesKey(row.keyProfileId, futuresKeyProfileId);
    }
    return false;
  }

  bool _matchesKey(String rowKey, String? boundKey) {
    final value = boundKey?.trim();
    if (value == null || value.isEmpty) {
      return true;
    }
    return rowKey == value;
  }
}
