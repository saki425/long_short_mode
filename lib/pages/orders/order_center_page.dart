import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../../controllers/app_navigation_controller.dart';
import '../../controllers/order_center_controller.dart';
import '../../controllers/symbol_workspace_controller.dart';
import '../../database/app_database.dart';
import '../../models/order_filters.dart';
import '../../services/execution/auto_spot_grid_execution_service.dart';
import 'order_detail_page.dart';

class OrderCenterPage extends StatelessWidget {
  const OrderCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<OrderCenterController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('订单中心'),
        actions: [
          TextButton.icon(
            onPressed: controller.exportCurrentOrders,
            icon: const Icon(Icons.download),
            label: const Text('导出CSV'),
          ),
        ],
      ),
      body: Obx(
        () => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ActiveSymbolBanner(
              workspace: Get.find<SymbolWorkspaceController>(),
            ),
            _CompactOrderSummary(controller: controller),
            if (controller.statusBucket.value == OrderStatusBucket.unfinished)
              _UnfinishedToolbar(controller: controller),
            _CollapsedFiltersAndStats(controller: controller),
            if (controller.exportedPath.value.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Text(
                  '已导出: ${controller.exportedPath.value}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (controller.operationMessage.value.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: SelectableText(controller.operationMessage.value),
              ),
            Expanded(child: _OrderContent(controller: controller)),
          ],
        ),
      ),
    );
  }
}

class _CompactOrderSummary extends StatelessWidget {
  const _CompactOrderSummary({required this.controller});

  final OrderCenterController controller;

  @override
  Widget build(BuildContext context) {
    final stats = controller.statistics.value;
    final unfinished = controller.unfinishedStatistics.value;
    final items = [
      _StatItem('计划', stats?.plannedOrderCount.toString() ?? '-'),
      _StatItem('已提交', stats?.submittedOrderCount.toString() ?? '-'),
      _StatItem('挂单', stats?.openOrderCount.toString() ?? '-'),
      _StatItem('完成', stats?.completedOrderCount.toString() ?? '-'),
      _StatItem('撤销', stats?.cancelledOrderCount.toString() ?? '-'),
      _StatItem('失败', stats?.failedOrderCount.toString() ?? '-'),
      _StatItem('现货成交额', stats?.spotTurnover.toString() ?? '-'),
      _StatItem('合约成交额', stats?.futuresTurnover.toString() ?? '-'),
      if (controller.statusBucket.value == OrderStatusBucket.unfinished) ...[
        _StatItem('本地计划', unfinished?.localPlanCount.toString() ?? '-'),
        _StatItem('提交中', unfinished?.submittingCount.toString() ?? '-'),
        _StatItem('Binance挂单', unfinished?.binanceOpenCount.toString() ?? '-'),
        _StatItem('部分成交', unfinished?.partiallyFilledCount.toString() ?? '-'),
        _StatItem('状态未知', unfinished?.unknownCount.toString() ?? '-'),
        _StatItem('等待恢复', unfinished?.pendingRecoveryCount.toString() ?? '-'),
        _StatItem(
          '等待反向',
          unfinished?.pendingReplacementCount.toString() ?? '-',
        ),
        _StatItem('涉及策略', unfinished?.strategyCount.toString() ?? '-'),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final item in items)
            Chip(
              visualDensity: VisualDensity.compact,
              label: Text('${item.label}: ${item.value}'),
            ),
        ],
      ),
    );
  }
}

class _CollapsedFiltersAndStats extends StatelessWidget {
  const _CollapsedFiltersAndStats({required this.controller});

  final OrderCenterController controller;

  @override
  Widget build(BuildContext context) {
    const dateOptions = {
      '今天': '今天',
      '昨天': '昨天',
      '最近7天': '最近7天',
      '最近30天': '最近30天',
      '本月': '本月',
      '上月': '上月',
    };
    final marketOptions = <MarketTypeFilter, String>{
      MarketTypeFilter.all: '全部',
      MarketTypeFilter.spot: '现货',
      MarketTypeFilter.usdtFutures: '合约',
    };
    const sideOptions = {'ALL': '全部', 'BUY': '买入', 'SELL': '卖出'};
    final statusOptions = <OrderStatusBucket, String>{
      OrderStatusBucket.all: '全部',
      OrderStatusBucket.unfinished: '未完成',
      OrderStatusBucket.completed: '已完成',
      OrderStatusBucket.cancelled: '已撤销',
      OrderStatusBucket.failed: '失败',
    };
    final unfinishedOptions = <UnfinishedOrderFilter, String>{
      UnfinishedOrderFilter.all: '全部未完成',
      UnfinishedOrderFilter.localPlan: '本地计划',
      UnfinishedOrderFilter.submitting: '提交中',
      UnfinishedOrderFilter.open: '挂单中',
      UnfinishedOrderFilter.partiallyFilled: '部分成交',
      UnfinishedOrderFilter.unknown: '状态未知',
      UnfinishedOrderFilter.pendingRecovery: '等待恢复',
      UnfinishedOrderFilter.pendingReplacement: '等待反向订单',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _FilterDropdown<String>(
            label: '日期',
            value: controller.selectedRange.value.label,
            items: dateOptions,
            width: 150,
            onChanged: controller.setPresetRange,
          ),
          _FilterDropdown<MarketTypeFilter>(
            label: '市场',
            value: controller.marketType.value,
            items: marketOptions,
            width: 130,
            onChanged: controller.setMarketType,
          ),
          _FilterDropdown<String>(
            label: '方向',
            value: controller.sideFilter.value,
            items: sideOptions,
            width: 130,
            onChanged: controller.setSideFilter,
          ),
          SizedBox(
            width: 260,
            child: TextField(
              decoration: const InputDecoration(
                labelText: '关键词',
                hintText: '订单ID / Client ID / 用途 / 网格',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: controller.setKeyword,
            ),
          ),
          _FilterDropdown<OrderStatusBucket>(
            label: '状态1',
            value: controller.statusBucket.value,
            items: statusOptions,
            width: 150,
            onChanged: controller.setStatusBucket,
          ),
          if (controller.statusBucket.value == OrderStatusBucket.unfinished)
            _FilterDropdown<UnfinishedOrderFilter>(
              label: '状态2',
              value: controller.unfinishedFilter.value,
              items: unfinishedOptions,
              width: 190,
              onChanged: controller.setUnfinishedFilter,
            ),
        ],
      ),
    );
  }
}

class _ActiveSymbolBanner extends StatelessWidget {
  const _ActiveSymbolBanner({required this.workspace});

  final SymbolWorkspaceController workspace;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final active = workspace.activeSymbol.value;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Text(
          active == null
              ? '当前币对：未选择'
              : '当前币对：${active.displayName} / ${active.symbol}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
      );
    });
  }
}

class _FilterDropdown<T> extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width = 160,
  });

  final String label;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (final entry in items.entries)
            DropdownMenuItem<T>(
              value: entry.key,
              child: Text(entry.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (value) {
          if (value != null) {
            onChanged(value);
          }
        },
      ),
    );
  }
}

class _UnfinishedToolbar extends StatelessWidget {
  const _UnfinishedToolbar({required this.controller});

  final OrderCenterController controller;

  @override
  Widget build(BuildContext context) {
    final selectedCount = controller.selectedOrderIds.length;
    final report = controller.unfinishedReport.value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: controller.buildUnfinishedReport,
                icon: const Icon(Icons.manage_search),
                label: const Text('处理未完成订单'),
              ),
              FilledButton.icon(
                onPressed:
                    () => _runAction(
                      context,
                      title: '扫描并修复未完成订单',
                      message:
                          '将刷新正式现货 REST 快照，并对涉及的 LIVE 网格策略执行 REST 对账。不会自动删除订单或跳过安全检查。',
                      action: controller.scanAndRepairUnfinishedOrders,
                    ),
                icon: const Icon(Icons.healing),
                label: const Text('扫描并修复'),
              ),
              OutlinedButton.icon(
                onPressed:
                    selectedCount == 0
                        ? null
                        : () => _showBulkSafetyDialog(context, selectedCount),
                icon: const Icon(Icons.fact_check),
                label: Text('批量操作 ($selectedCount)'),
              ),
              if (selectedCount > 0)
                TextButton(
                  onPressed: controller.clearSelection,
                  child: const Text('清除选择'),
                ),
            ],
          ),
          if (report != null) ...[
            const SizedBox(height: 8),
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: SelectableText(
                  '未完成处理报告 ${DateFormat('yyyy-MM-dd HH:mm:ss').format(report.generatedAt.toLocal())}\n'
                  '本地未完成=${report.localUnfinishedCount}, Binance挂单态=${report.binanceLikeOpenCount}, '
                  '提交超时=${report.submittingTimeoutCount}, unknown=${report.unknownCount}, '
                  '等待反向=${report.pendingReplacementCount}\n'
                  '${report.notes.join('\n')}',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showBulkSafetyDialog(BuildContext context, int selectedCount) {
    showDialog<void>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('批量操作安全确认'),
            content: SelectableText(
              '已选择 $selectedCount 笔订单。\n\n'
              '批量撤单只会处理状态为 new / partiallyFilled 且属于本程序的 LIVE 订单。'
              'unknown、planned、pendingReplacement 不会被直接删除或重试。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
              OutlinedButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await _runAction(
                    context,
                    title: '批量查询订单',
                    message: '将逐笔按 clientOrderId 查询 Binance 并更新本地状态。',
                    action: controller.batchQuerySelected,
                  );
                },
                child: const Text('批量查询'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await _runAction(
                    context,
                    title: '批量撤销真实订单',
                    message:
                        '将撤销所选订单中属于本程序、状态为 new / partiallyFilled 的 LIVE 订单。该操作会发送正式 Binance 撤单请求。',
                    action: controller.batchCancelSelected,
                  );
                },
                child: const Text('批量撤单'),
              ),
            ],
          ),
    );
  }

  Future<void> _runAction(
    BuildContext context, {
    required String title,
    required String message,
    required Future<void> Function() action,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
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
    if (confirmed != true) return;
    try {
      await action();
      messenger.showSnackBar(
        SnackBar(content: Text(controller.operationMessage.value)),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('操作失败：$error')));
    }
  }
}

class _StatItem {
  const _StatItem(this.label, this.value);

  final String label;
  final String value;
}

class _OrderContent extends StatelessWidget {
  const _OrderContent({required this.controller});

  final OrderCenterController controller;

  @override
  Widget build(BuildContext context) {
    switch (controller.statusBucket.value) {
      case OrderStatusBucket.all:
        return StreamBuilder<List<Order>>(
          stream: controller.allOrdersStream,
          builder:
              (context, snapshot) => _OrderTable(
                orders: snapshot.data ?? const [],
                bucket: OrderStatusBucket.all,
                controller: controller,
              ),
        );
      case OrderStatusBucket.unfinished:
        return StreamBuilder<List<Order>>(
          stream: controller.unfinishedOrdersStream,
          builder:
              (context, snapshot) => _OrderTable(
                orders: snapshot.data ?? const [],
                bucket: OrderStatusBucket.unfinished,
                controller: controller,
              ),
        );
      case OrderStatusBucket.completed:
        return _PagedOrderList(
          orders: controller.completedOrders,
          controller: controller,
          bucket: OrderStatusBucket.completed,
        );
      case OrderStatusBucket.cancelled:
        return _PagedOrderList(
          orders: controller.cancelledOrders,
          controller: controller,
          bucket: OrderStatusBucket.cancelled,
        );
      case OrderStatusBucket.failed:
        return _PagedOrderList(
          orders: controller.failedOrders,
          controller: controller,
          bucket: OrderStatusBucket.failed,
        );
    }
  }
}

class _PagedOrderList extends StatelessWidget {
  const _PagedOrderList({
    required this.orders,
    required this.controller,
    required this.bucket,
  });

  final List<Order> orders;
  final OrderCenterController controller;
  final OrderStatusBucket bucket;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _OrderTable(
            orders: orders,
            bucket: bucket,
            controller: controller,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text('第 ${controller.currentPage.value + 1} 页'),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: controller.previousPage,
                child: const Text('上一页'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed:
                    orders.length < controller.pageSize
                        ? null
                        : controller.nextPage,
                child: const Text('下一页'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OrderTable extends StatefulWidget {
  const _OrderTable({
    required this.orders,
    required this.bucket,
    required this.controller,
  });

  final List<Order> orders;
  final OrderStatusBucket bucket;
  final OrderCenterController controller;

  @override
  State<_OrderTable> createState() => _OrderTableState();
}

class _OrderTableState extends State<_OrderTable> {
  int _sortColumnIndex = 15;
  bool _sortAscending = false;
  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();

  @override
  void dispose() {
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final orders = _filteredAndSortedOrders();
      if (orders.isEmpty) {
        return const Center(child: Text('当前条件下没有订单'));
      }
      return LayoutBuilder(
        builder: (context, constraints) {
          return Scrollbar(
            controller: _horizontalController,
            thumbVisibility: true,
            notificationPredicate: (notification) => notification.depth == 0,
            child: SingleChildScrollView(
              controller: _horizontalController,
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Scrollbar(
                  controller: _verticalController,
                  thumbVisibility: true,
                  notificationPredicate:
                      (notification) => notification.depth == 0,
                  child: SingleChildScrollView(
                    controller: _verticalController,
                    child: DataTable(
                      sortColumnIndex: _sortColumnIndex,
                      sortAscending: _sortAscending,
                      columnSpacing: 14,
                      horizontalMargin: 12,
                      headingRowHeight: 42,
                      dataRowMinHeight: 56,
                      dataRowMaxHeight: 76,
                      columns: [
                        const DataColumn(label: Text('选择')),
                        _column('状态', 1),
                        const DataColumn(label: Text('真实订单')),
                        _column('环境', 2),
                        _column('市场', 3),
                        _column('方向', 4),
                        _column('用途', 5),
                        const DataColumn(label: Text('策略 ID')),
                        const DataColumn(label: Text('网格编号')),
                        _column('价格', 6),
                        _column('原始数量', 7),
                        _column('已成交', 8),
                        const DataColumn(label: Text('剩余数量')),
                        const DataColumn(label: Text('成交比例')),
                        const DataColumn(label: Text('Binance Order ID')),
                        const DataColumn(label: Text('Client Order ID')),
                        _column('创建时间', 9),
                        _column('最后更新', 10),
                        const DataColumn(label: Text('最近错误')),
                        const DataColumn(label: Text('操作')),
                      ],
                      rows: [for (final order in orders) _row(context, order)],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    });
  }

  DataColumn _column(String label, int index) {
    return DataColumn(
      label: Text(label),
      onSort: (columnIndex, ascending) {
        setState(() {
          _sortColumnIndex = columnIndex;
          _sortAscending = ascending;
        });
      },
    );
  }

  DataRow _row(BuildContext context, Order order) {
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
    final remaining = _remainingQuantity(order);
    final fillPercent = _fillPercent(order);
    return DataRow(
      selected: widget.controller.isSelected(order.id),
      cells: [
        DataCell(
          Checkbox(
            value: widget.controller.isSelected(order.id),
            onChanged:
                (value) =>
                    widget.controller.toggleSelection(order.id, value == true),
          ),
        ),
        DataCell(_statusChip(order.status)),
        DataCell(_submissionChip(order)),
        DataCell(Text(order.environment.toUpperCase())),
        DataCell(Text(order.marketType == 'spot' ? '现货' : '合约')),
        DataCell(Text(order.side)),
        DataCell(_narrowText(order.purpose, width: 84)),
        DataCell(_narrowText(order.strategyId, width: 160)),
        DataCell(_narrowText(order.gridLevelId ?? '-', width: 180)),
        DataCell(Text(order.price ?? '-')),
        DataCell(Text(order.originalQuantity)),
        DataCell(Text(order.executedQuantity)),
        DataCell(Text(remaining)),
        DataCell(Text(fillPercent)),
        DataCell(_narrowText(order.exchangeOrderId ?? '-', width: 140)),
        DataCell(_narrowText(order.clientOrderId, width: 210)),
        DataCell(Text(dateFormat.format(order.createdAt.toLocal()))),
        DataCell(Text(dateFormat.format(order.updatedAt.toLocal()))),
        DataCell(_narrowText(order.errorMessage ?? '-', width: 180)),
        DataCell(
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              _actionButton(
                label: '详情',
                onPressed: () => _showUnfinishedDetails(context, order),
              ),
              if (widget.bucket == OrderStatusBucket.unfinished)
                ..._actionsForStatus(context, order),
            ],
          ),
        ),
      ],
      onSelectChanged: (_) => _showUnfinishedDetails(context, order),
    );
  }

  Widget _statusChip(String status) {
    final color = switch (status) {
      'unknown' => Colors.red,
      'pendingRecovery' || 'pendingReplacement' => Colors.orange,
      'new' || 'partiallyFilled' => Colors.blue,
      'planned' || 'created' => Colors.grey,
      _ => Colors.blueGrey,
    };
    return Tooltip(
      message: _statusLabel(status),
      child: Chip(
        label: Text(_statusLabel(status)),
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: color.shade200),
        backgroundColor: color.shade50,
      ),
    );
  }

  Widget _submissionChip(Order order) {
    if (order.exchangeOrderId == null || order.exchangeOrderId!.isEmpty) {
      return const Chip(
        label: Text('未提交'),
        visualDensity: VisualDensity.compact,
      );
    }
    return Chip(
      label: const Text('Binance 挂单'),
      visualDensity: VisualDensity.compact,
      backgroundColor: Colors.blue.shade50,
    );
  }

  List<Widget> _actionsForStatus(BuildContext context, Order order) {
    switch (order.status) {
      case 'planned':
        return [
          _disabledAction('编辑'),
          _disabledAction('启用'),
          _disabledAction('禁用'),
          _disabledAction('删除'),
          _disabledAction('提交'),
        ];
      case 'created':
      case 'submitting':
        return [
          _actionButton(
            label: '查询',
            onPressed: () => _confirmQuery(context, order),
          ),
          _actionButton(
            label: '对账',
            onPressed: () => _confirmReconcile(context, order.strategyId),
          ),
          _actionButton(
            label: '意图',
            onPressed: () => _showUnfinishedDetails(context, order),
          ),
        ];
      case 'new':
        return [
          _actionButton(
            label: '查询',
            onPressed: () => _confirmQuery(context, order),
          ),
          _actionButton(
            label: '撤销',
            onPressed: () => _confirmCancel(context, order),
          ),
          _actionButton(
            label: '对账',
            onPressed: () => _confirmReconcile(context, order.strategyId),
          ),
        ];
      case 'partiallyFilled':
        return [
          _actionButton(
            label: '查询',
            onPressed: () => _confirmQuery(context, order),
          ),
          _actionButton(
            label: '撤销剩余',
            onPressed: () => _confirmCancelPartial(context, order),
          ),
          _disabledAction('Fills'),
        ];
      case 'cancelling':
        return [
          _actionButton(
            label: '查询最终',
            onPressed: () => _confirmQuery(context, order),
          ),
          _actionButton(
            label: '对账',
            onPressed: () => _confirmReconcile(context, order.strategyId),
          ),
        ];
      case 'unknown':
        return [
          _actionButton(
            label: '按Client查',
            onPressed: () => _confirmQuery(context, order),
          ),
          _disabledAction('按Order查'),
          _disabledAction('近期成交'),
          _actionButton(
            label: '对账',
            onPressed: () => _confirmReconcile(context, order.strategyId),
          ),
        ];
      case 'pendingRecovery':
      case 'reconciling':
        return [
          _disabledAction('恢复报告'),
          _actionButton(
            label: '完整对账',
            onPressed: () => _confirmReconcile(context, order.strategyId),
          ),
          _disabledAction('确认处理'),
        ];
      case 'pendingReplacement':
        return [
          _disabledAction('父订单'),
          _disabledAction('创建反向'),
          _disabledAction('放弃'),
        ];
      default:
        return const [];
    }
  }

  Widget _disabledAction(String label) {
    return Tooltip(
      message: '该操作需要接入执行服务并完成二次确认，当前未在订单中心直接启用。',
      child: OutlinedButton(
        onPressed: null,
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: const Size(48, 30),
        ),
        child: Text(label),
      ),
    );
  }

  Future<void> _confirmQuery(BuildContext context, Order order) async {
    await _runOrderAction(
      context,
      title: '查询订单',
      message: '按 clientOrderId 查询 Binance 并更新本地状态。\n${order.clientOrderId}',
      action: () => widget.controller.queryOrder(order),
    );
  }

  Future<void> _confirmCancel(BuildContext context, Order order) async {
    await _runOrderAction(
      context,
      title: '撤销真实订单',
      message:
          '将发送正式 Binance 撤单请求。\n\n'
          'Client Order ID: ${order.clientOrderId}\n'
          '状态: ${order.status}\n'
          '已成交: ${order.executedQuantity}/${order.originalQuantity}',
      action: () => widget.controller.cancelOrder(order),
    );
  }

  Future<void> _confirmCancelPartial(BuildContext context, Order order) async {
    await _runOrderAction(
      context,
      title: '撤销部分成交订单剩余部分',
      message:
          '将撤销剩余挂单。撤销后是否生成部分成交反向订单，需要策略恢复流程判断 minQty / minNotional。\n\n'
          '原始数量: ${order.originalQuantity}\n'
          '已成交数量: ${order.executedQuantity}\n'
          '剩余数量: ${_remainingQuantity(order)}',
      action: () => widget.controller.cancelOrder(order),
    );
  }

  Future<void> _confirmReconcile(
    BuildContext context,
    String strategyId,
  ) async {
    await _runOrderAction(
      context,
      title: 'REST 对账策略',
      message: '将对策略 $strategyId 执行完整 REST 对账，不会自动删除历史记录。',
      action: () async {
        await widget.controller.reconcileStrategy(strategyId);
      },
    );
  }

  Future<void> _runOrderAction(
    BuildContext context, {
    required String title,
    required String message,
    required Future<void> Function() action,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
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
    if (confirmed != true) return;
    try {
      await action();
      messenger.showSnackBar(
        SnackBar(content: Text(widget.controller.operationMessage.value)),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('操作失败：$error')));
    }
  }

  void _showUnfinishedDetails(BuildContext context, Order order) {
    if (widget.bucket != OrderStatusBucket.unfinished) {
      Get.to(() => OrderDetailPage(orderId: order.id));
      return;
    }
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
    showDialog<void>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('未完成订单详情'),
            content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _detail('本地订单 ID', order.id),
                    _detail('策略 ID', order.strategyId),
                    _detail('网格 ID', order.gridLevelId ?? '-'),
                    _detail('Binance Order ID', order.exchangeOrderId ?? '-'),
                    _detail('Client Order ID', order.clientOrderId),
                    _detail('环境', order.environment),
                    _detail('市场', order.marketType),
                    _detail('方向', order.side),
                    _detail('类型', order.orderType),
                    _detail('价格', order.price ?? '-'),
                    _detail('原始数量', order.originalQuantity),
                    _detail('已成交数量', order.executedQuantity),
                    _detail('剩余数量', _remainingQuantity(order)),
                    _detail('成交均价', order.averagePrice ?? '-'),
                    _detail('手续费', '请在成交明细中查看'),
                    _detail('当前状态', _statusLabel(order.status)),
                    _detail('Binance 查询状态', '未在此面板直接查询'),
                    _detail('本地数据库状态', order.status),
                    _detail('最近账户 WS 事件', '未记录到订单表'),
                    _detail('最近 REST 查询时间', '请查看对账记录'),
                    _detail('父订单', order.parentOrderId ?? '-'),
                    _detail('配对订单', '当前数据库未建 pairedOrderId 字段'),
                    _detail(
                      '是否已经创建反向订单',
                      '请查看 parentOrderId / pendingReplacement',
                    ),
                    _detail('最近错误', order.errorMessage ?? '-'),
                    _detail(
                      '创建时间',
                      dateFormat.format(order.createdAt.toLocal()),
                    ),
                    _detail(
                      '更新时间',
                      dateFormat.format(order.updatedAt.toLocal()),
                    ),
                    const Divider(),
                    const Text(
                      '状态历史：当前数据库未建独立状态历史表；后续应写入 order_state_events 审计表。',
                    ),
                    if (order.environment == 'live' &&
                        order.source == 'autoSpotGrid') ...[
                      const Divider(),
                      const Text('旧 LIVE 网格联动'),
                      Text('所属旧策略：${order.strategyId}'),
                      const Text(
                        '可在此执行 REST 对账、安全停止；安全关闭必须满足无挂单、无未完成订单、无待补反向和资产已归属。',
                      ),
                      const SizedBox(height: 8),
                      FutureBuilder<LiveSpotGridConflict?>(
                        future: widget.controller.loadConflictDetails(
                          order.strategyId,
                        ),
                        builder: (context, snapshot) {
                          final conflict = snapshot.data;
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const LinearProgressIndicator();
                          }
                          if (conflict == null) {
                            return const Text('当前策略未被识别为冲突策略。');
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Binance挂单=${conflict.binanceActiveOrders}, '
                                '本地活动=${conflict.localActiveOrders}, '
                                'unknown=${conflict.unknownOrders}, '
                                'pendingRecovery=${conflict.pendingRecoveryOrders}, '
                                'strategyBtc=${conflict.strategyBtc}',
                              ),
                              const SizedBox(height: 8),
                              if (conflict.canMarkStopped)
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  color: Colors.green.shade50,
                                  child: const Text(
                                    '该策略可以安全标记为已停止。',
                                    style: TextStyle(color: Colors.green),
                                  ),
                                )
                              else
                                Text(
                                  '暂不能安全关闭：${conflict.blockingReasons.join('; ')}',
                                ),
                            ],
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
              if (order.environment == 'live' && order.source == 'autoSpotGrid')
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    Get.find<AppNavigationController>().selectPage(1);
                  },
                  child: const Text('打开策略'),
                ),
              if (order.environment == 'live' && order.source == 'autoSpotGrid')
                OutlinedButton(
                  onPressed: () async {
                    await widget.controller.reconcileStrategy(order.strategyId);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('对账该策略'),
                ),
              if (order.environment == 'live' && order.source == 'autoSpotGrid')
                OutlinedButton(
                  onPressed: () async {
                    await widget.controller.safeStopStrategy(order.strategyId);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('安全停止'),
                ),
              if (order.environment == 'live' && order.source == 'autoSpotGrid')
                FilledButton(
                  onPressed: () async {
                    await widget.controller.markStrategyStopped(
                      order.strategyId,
                    );
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('安全关闭策略'),
                ),
              TextButton(
                onPressed:
                    () => Get.to(() => OrderDetailPage(orderId: order.id)),
                child: const Text('打开完整详情'),
              ),
            ],
          ),
    );
  }

  Widget _detail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }

  Widget _narrowText(String value, {required double width}) {
    return SizedBox(
      width: width,
      child: Tooltip(
        message: value,
        child: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _actionButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(48, 30),
      ),
      child: Text(label),
    );
  }

  List<Order> _filteredAndSortedOrders() {
    final side = widget.controller.sideFilter.value;
    final keyword = widget.controller.keyword.value.toLowerCase();
    final filtered =
        widget.orders.where((order) {
          if (side != 'ALL' && order.side != side) {
            return false;
          }
          if (keyword.isEmpty) {
            return true;
          }
          final text =
              [
                order.id,
                order.clientOrderId,
                order.exchangeOrderId ?? '',
                order.purpose,
                order.symbol,
                order.gridLevelId ?? '',
              ].join(' ').toLowerCase();
          return text.contains(keyword);
        }).toList();
    filtered.sort((a, b) {
      final result = _compare(a, b);
      return _sortAscending ? result : -result;
    });
    return filtered;
  }

  int _compare(Order a, Order b) {
    switch (_sortColumnIndex) {
      case 1:
        return a.status.compareTo(b.status);
      case 2:
        return a.environment.compareTo(b.environment);
      case 3:
        return a.marketType.compareTo(b.marketType);
      case 4:
        return a.side.compareTo(b.side);
      case 5:
        return a.purpose.compareTo(b.purpose);
      case 6:
        return (a.price ?? '').compareTo(b.price ?? '');
      case 7:
        return a.originalQuantity.compareTo(b.originalQuantity);
      case 8:
        return a.executedQuantity.compareTo(b.executedQuantity);
      case 9:
        return a.createdAt.compareTo(b.createdAt);
      case 10:
        return a.updatedAt.compareTo(b.updatedAt);
      default:
        return a.createdAt.compareTo(b.createdAt);
    }
  }

  String _remainingQuantity(Order order) {
    final original = double.tryParse(order.originalQuantity) ?? 0;
    final executed = double.tryParse(order.executedQuantity) ?? 0;
    final remaining = original - executed;
    if (remaining <= 0) return '0';
    return remaining.toStringAsPrecision(8);
  }

  String _fillPercent(Order order) {
    final original = double.tryParse(order.originalQuantity) ?? 0;
    final executed = double.tryParse(order.executedQuantity) ?? 0;
    if (original <= 0) return '0%';
    final percent = (executed / original * 100).clamp(0, 100);
    return '${percent.toStringAsFixed(1)}%';
  }

  String _statusLabel(String status) {
    return switch (status) {
      'planned' => '本地计划',
      'created' => '下单意图',
      'submitting' => '提交中',
      'new' => '挂单中',
      'partiallyFilled' => '部分成交',
      'cancelling' => '撤单中',
      'unknown' => '状态未知',
      'pendingRecovery' => '等待恢复',
      'pendingReplacement' => '等待反向',
      'reconciling' => '对账中',
      'filled' => '已完成',
      'cancelled' => '已撤销',
      'rejected' => '已拒绝',
      'expired' => '已过期',
      _ => status,
    };
  }
}
