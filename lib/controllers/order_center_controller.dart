import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import 'symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../models/order_filters.dart';
import '../repositories/order_repository.dart';
import '../services/export/csv_export_service.dart';
import '../repositories/basic_repositories.dart';
import '../services/execution/auto_spot_grid_execution_service.dart';
import '../services/execution/live_exchange_execution_service.dart';

class OrderCenterController extends GetxController {
  OrderCenterController({
    required this.orderRepository,
    required this.csvExportService,
    required this.liveExecutionService,
    required this.autoSpotGridService,
    required this.logRepository,
  });

  final OrderRepository orderRepository;
  final CsvExportService csvExportService;
  final LiveExchangeExecutionService liveExecutionService;
  final AutoSpotGridExecutionService autoSpotGridService;
  final LogRepository logRepository;

  final selectedRange = todayRange(DateTime.now()).obs;
  final marketType = MarketTypeFilter.all.obs;
  final statusBucket = OrderStatusBucket.unfinished.obs;
  final unfinishedFilter = UnfinishedOrderFilter.all.obs;
  final sideFilter = 'ALL'.obs;
  final keyword = ''.obs;
  final allOrders = <Order>[].obs;
  final completedOrders = <Order>[].obs;
  final cancelledOrders = <Order>[].obs;
  final failedOrders = <Order>[].obs;
  final statistics = Rxn<OrderStatistics>();
  final unfinishedStatistics = Rxn<UnfinishedOrderStatistics>();
  final unfinishedReport = Rxn<UnfinishedOrderProcessReport>();
  final selectedOrderIds = <String>{}.obs;
  final operationMessage = ''.obs;
  final isLoadingHistory = false.obs;
  final currentPage = 0.obs;
  final exportedPath = ''.obs;
  final pageSize = 50;
  Worker? _symbolWorker;

  String? get _activeSymbol {
    if (!Get.isRegistered<SymbolWorkspaceController>()) {
      return null;
    }
    return Get.find<SymbolWorkspaceController>().activeSymbol.value?.symbol;
  }

  Stream<List<Order>> get openOrdersStream {
    final range = selectedRange.value.toUtcHalfOpenRange();
    return orderRepository.watchOpenOrders(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      symbol: _activeSymbol,
      marketType: marketType.value,
    );
  }

  Stream<List<Order>> get allOrdersStream {
    final range = selectedRange.value.toUtcHalfOpenRange();
    return orderRepository.watchAllOrders(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      symbol: _activeSymbol,
      marketType: marketType.value,
    );
  }

  Stream<List<Order>> get unfinishedOrdersStream {
    final range = selectedRange.value.toUtcHalfOpenRange();
    return orderRepository.watchUnfinishedOrders(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      filter: unfinishedFilter.value,
      symbol: _activeSymbol,
      marketType: marketType.value,
    );
  }

  Stream<List<Order>> get plannedOrdersStream {
    final range = selectedRange.value.toUtcHalfOpenRange();
    return orderRepository.watchPlannedOrders(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      symbol: _activeSymbol,
      marketType: marketType.value,
    );
  }

  @override
  void onInit() {
    super.onInit();
    if (Get.isRegistered<SymbolWorkspaceController>()) {
      _symbolWorker = ever(Get.find<SymbolWorkspaceController>().activeSymbol, (
        _,
      ) {
        selectedOrderIds.clear();
        refreshData();
      });
    }
    refreshData();
  }

  @override
  void onClose() {
    _symbolWorker?.dispose();
    super.onClose();
  }

  Future<void> refreshData() async {
    await Future.wait([
      loadHistory(resetPage: true),
      loadStatistics(),
      loadUnfinishedStatistics(),
    ]);
  }

  Future<void> loadStatistics() async {
    final range = selectedRange.value.toUtcHalfOpenRange();
    statistics.value = await orderRepository.getOrderStatistics(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      symbol: _activeSymbol,
    );
  }

  Future<void> loadUnfinishedStatistics() async {
    final range = selectedRange.value.toUtcHalfOpenRange();
    unfinishedStatistics.value = await orderRepository
        .getUnfinishedOrderStatistics(
          start: range.startInclusiveUtc,
          end: range.endExclusiveUtc,
          symbol: _activeSymbol,
          marketType: marketType.value,
        );
  }

  Future<void> loadHistory({bool resetPage = false}) async {
    if (resetPage) {
      currentPage.value = 0;
    }
    isLoadingHistory.value = true;
    final range = selectedRange.value.toUtcHalfOpenRange();
    final offset = currentPage.value * pageSize;
    try {
      allOrders.value = await orderRepository.getAllOrders(
        start: range.startInclusiveUtc,
        end: range.endExclusiveUtc,
        symbol: _activeSymbol,
        marketType: marketType.value,
        limit: pageSize,
        offset: offset,
      );
      completedOrders.value = await orderRepository.getCompletedOrders(
        start: range.startInclusiveUtc,
        end: range.endExclusiveUtc,
        symbol: _activeSymbol,
        marketType: marketType.value,
        limit: pageSize,
        offset: offset,
      );
      cancelledOrders.value = await orderRepository.getCancelledOrders(
        start: range.startInclusiveUtc,
        end: range.endExclusiveUtc,
        symbol: _activeSymbol,
        marketType: marketType.value,
        limit: pageSize,
        offset: offset,
      );
      failedOrders.value = await orderRepository.getFailedOrders(
        start: range.startInclusiveUtc,
        end: range.endExclusiveUtc,
        symbol: _activeSymbol,
        marketType: marketType.value,
        limit: pageSize,
        offset: offset,
      );
    } finally {
      isLoadingHistory.value = false;
    }
  }

  void setPresetRange(String label) {
    final now = DateTime.now();
    switch (label) {
      case '今天':
        selectedRange.value = todayRange(now);
        break;
      case '昨天':
        selectedRange.value = yesterdayRange(now);
        break;
      case '最近7天':
        selectedRange.value = lastDaysRange(now, 7, '最近7天');
        break;
      case '最近30天':
        selectedRange.value = lastDaysRange(now, 30, '最近30天');
        break;
      case '本月':
        selectedRange.value = thisMonthRange(now);
        break;
      case '上月':
        selectedRange.value = previousMonthRange(now);
        break;
    }
    refreshData();
  }

  void setMarketType(MarketTypeFilter value) {
    marketType.value = value;
    refreshData();
  }

  void setStatusBucket(OrderStatusBucket value) {
    statusBucket.value = value;
    selectedOrderIds.clear();
    loadHistory(resetPage: true);
  }

  void setUnfinishedFilter(UnfinishedOrderFilter value) {
    unfinishedFilter.value = value;
    selectedOrderIds.clear();
    loadUnfinishedStatistics();
  }

  void setSideFilter(String value) {
    sideFilter.value = value;
  }

  void setKeyword(String value) {
    keyword.value = value.trim();
  }

  Future<void> nextPage() async {
    currentPage.value += 1;
    await loadHistory();
  }

  Future<void> previousPage() async {
    if (currentPage.value == 0) {
      return;
    }
    currentPage.value -= 1;
    await loadHistory();
  }

  Future<OrderDetails?> loadDetails(String orderId) {
    return orderRepository.getOrderDetails(orderId);
  }

  bool isSelected(String orderId) => selectedOrderIds.contains(orderId);

  void toggleSelection(String orderId, bool selected) {
    final copy = {...selectedOrderIds};
    if (selected) {
      copy.add(orderId);
    } else {
      copy.remove(orderId);
    }
    selectedOrderIds.assignAll(copy);
  }

  void clearSelection() {
    selectedOrderIds.clear();
  }

  Future<void> buildUnfinishedReport() async {
    final range = selectedRange.value.toUtcHalfOpenRange();
    unfinishedReport.value = await orderRepository.buildUnfinishedOrderReport(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      symbol: _activeSymbol,
      marketType: marketType.value,
    );
    await loadUnfinishedStatistics();
  }

  Future<void> scanAndRepairUnfinishedOrders() async {
    final startedAt = DateTime.now().toUtc();
    operationMessage.value = '正在扫描并修复未完成订单...';
    var correctedStatuses = 0;
    var discoveredFills = 0;
    var failedOrders = 0;
    var repairedLocalRejects = 0;
    try {
      final range = selectedRange.value.toUtcHalfOpenRange();
      final beforeReport = await orderRepository.buildUnfinishedOrderReport(
        start: range.startInclusiveUtc,
        end: range.endExclusiveUtc,
        symbol: _activeSymbol,
        marketType: marketType.value,
      );
      final beforeFillCount =
          await orderRepository.db.select(orderRepository.db.fills).get();
      final unfinished =
          await orderRepository
              .watchUnfinishedOrders(
                start: range.startInclusiveUtc,
                end: range.endExclusiveUtc,
                filter: UnfinishedOrderFilter.all,
                symbol: _activeSymbol,
                marketType: marketType.value,
              )
              .first;
      await liveExecutionService.refreshSpotSnapshot();
      final strategyIds =
          unfinished
              .where((order) => order.environment == 'live')
              .map((order) => order.strategyId)
              .toSet();
      for (final strategyId in strategyIds) {
        try {
          repairedLocalRejects += await autoSpotGridService
              .repairLocalRejectedGridSubmissions(strategyId);
          await autoSpotGridService.reconcile(strategyId);
        } catch (error) {
          failedOrders += 1;
          await _audit(
            level: 'error',
            module: 'ORDER_CENTER',
            message: 'REST reconcile failed for unfinished strategy',
            strategyId: strategyId,
            extra: {'error': error.toString()},
          );
        }
      }

      for (final order in unfinished) {
        if (order.environment != 'live') continue;
        try {
          final before =
              (await orderRepository.getOrderDetails(order.id))?.order;
          await queryOrder(order, silent: true);
          final after =
              (await orderRepository.getOrderDetails(order.id))?.order;
          if (before != null &&
              after != null &&
              before.status != after.status) {
            correctedStatuses += 1;
          }
        } catch (_) {
          failedOrders += 1;
        }
      }

      final afterFillCount =
          await orderRepository.db.select(orderRepository.db.fills).get();
      discoveredFills = afterFillCount.length - beforeFillCount.length;
      final report = await orderRepository.buildUnfinishedOrderReport(
        start: range.startInclusiveUtc,
        end: range.endExclusiveUtc,
        symbol: _activeSymbol,
        marketType: marketType.value,
      );
      unfinishedReport.value = UnfinishedOrderProcessReport(
        generatedAt: DateTime.now().toUtc(),
        localUnfinishedCount: report.localUnfinishedCount,
        binanceLikeOpenCount: report.binanceLikeOpenCount,
        statusMismatchCount: correctedStatuses,
        submittingTimeoutCount: report.submittingTimeoutCount,
        unknownCount: report.unknownCount,
        pendingReplacementCount: report.pendingReplacementCount,
        notes: [
          '扫描开始：${startedAt.toLocal()}',
          '扫描前未完成=${beforeReport.localUnfinishedCount}',
          '已修正状态数=$correctedStatuses',
          '已修复本地拒绝提交=$repairedLocalRejects',
          '新发现成交数=$discoveredFills',
          '无法自动处理订单数=$failedOrders',
          '已刷新正式现货 REST 快照。',
          '已对涉及的 LIVE 网格策略执行策略级 REST 对账。',
          '没有发送新下单请求；撤单仍需用户在订单行或批量操作中二次确认。',
        ],
      );
      operationMessage.value =
          '扫描完成：修正状态 $correctedStatuses，发现成交 $discoveredFills，失败 $failedOrders。';
      await _audit(
        level: 'info',
        module: 'ORDER_CENTER',
        message: 'scan and repair unfinished orders completed',
        extra: {
          'correctedStatuses': correctedStatuses,
          'discoveredFills': discoveredFills,
          'failedOrders': failedOrders,
        },
      );
      await refreshData();
    } catch (error) {
      operationMessage.value = '扫描失败：$error';
      await _audit(
        level: 'error',
        module: 'ORDER_CENTER',
        message: 'scan and repair unfinished orders failed',
        extra: {'error': error.toString()},
      );
      rethrow;
    }
  }

  Future<void> queryOrder(Order order, {bool silent = false}) async {
    try {
      if (order.marketType == 'spot') {
        await liveExecutionService.querySpotOrder(order.clientOrderId);
      } else if (order.marketType == 'usdtFutures') {
        await liveExecutionService.queryFuturesOrder(
          order.clientOrderId,
          symbol: order.symbol,
        );
      } else {
        throw StateError('不支持的市场类型 ${order.marketType}');
      }
      if (!silent) {
        operationMessage.value = '查询成功：${order.clientOrderId}';
      }
      await _audit(
        level: 'info',
        module: 'ORDER_CENTER',
        message: 'order queried',
        strategyId: order.strategyId,
        extra: {'orderId': order.id, 'clientOrderId': order.clientOrderId},
      );
      await refreshData();
    } catch (error) {
      if (!silent) {
        operationMessage.value = '查询失败：$error';
      }
      await _audit(
        level: 'error',
        module: 'ORDER_CENTER',
        message: 'order query failed',
        strategyId: order.strategyId,
        extra: {
          'orderId': order.id,
          'clientOrderId': order.clientOrderId,
          'error': error.toString(),
        },
      );
      rethrow;
    }
  }

  Future<void> cancelOrder(Order order) async {
    _assertAppOwned(order);
    if (!['new', 'partiallyFilled'].contains(order.status)) {
      throw StateError('当前状态 ${order.status} 不允许撤单。');
    }
    try {
      if (order.marketType == 'spot') {
        await liveExecutionService.cancelSpotOrder(order.clientOrderId);
      } else if (order.marketType == 'usdtFutures') {
        await liveExecutionService.cancelFuturesOrder(
          order.clientOrderId,
          symbol: order.symbol,
        );
      } else {
        throw StateError('不支持的市场类型 ${order.marketType}');
      }
      operationMessage.value = '撤单成功：${order.clientOrderId}';
      await _audit(
        level: 'warning',
        module: 'ORDER_CENTER',
        message: 'order cancelled from unfinished tab',
        strategyId: order.strategyId,
        extra: {'orderId': order.id, 'clientOrderId': order.clientOrderId},
      );
      await refreshData();
    } catch (error) {
      operationMessage.value = '撤单失败：$error';
      await _audit(
        level: 'error',
        module: 'ORDER_CENTER',
        message: 'order cancel failed',
        strategyId: order.strategyId,
        extra: {
          'orderId': order.id,
          'clientOrderId': order.clientOrderId,
          'error': error.toString(),
        },
      );
      rethrow;
    }
  }

  Future<LiveSpotGridRecoveryReport> reconcileStrategy(
    String strategyId,
  ) async {
    try {
      await autoSpotGridService.reconcile(strategyId);
      final report = await autoSpotGridService.buildRecoveryReport(strategyId);
      operationMessage.value =
          '策略对账完成：Binance挂单=${report.binanceOpenOrders}, 本地挂单=${report.localOpenOrders}, 缺失反向=${report.missingReverseOrders}';
      await _audit(
        level: 'info',
        module: 'ORDER_CENTER',
        message: 'strategy reconciled from unfinished tab',
        strategyId: strategyId,
      );
      await refreshData();
      return report;
    } catch (error) {
      operationMessage.value = '策略对账失败：$error';
      await _audit(
        level: 'error',
        module: 'ORDER_CENTER',
        message: 'strategy reconcile failed from unfinished tab',
        strategyId: strategyId,
        extra: {'error': error.toString()},
      );
      rethrow;
    }
  }

  Future<LiveSpotGridConflict?> loadConflictDetails(String strategyId) {
    return autoSpotGridService.conflictDetails(strategyId);
  }

  Future<void> markStrategyStopped(String strategyId) async {
    try {
      await autoSpotGridService.markStoppedAfterNoExchangeOrders(strategyId);
      operationMessage.value = '策略已安全标记为 stopped：$strategyId';
      await _audit(
        level: 'warning',
        module: 'ORDER_CENTER',
        message: 'strategy marked stopped from unfinished tab',
        strategyId: strategyId,
      );
      await refreshData();
    } catch (error) {
      operationMessage.value = '安全关闭策略失败：$error';
      await _audit(
        level: 'error',
        module: 'ORDER_CENTER',
        message: 'strategy mark stopped failed from unfinished tab',
        strategyId: strategyId,
        extra: {'error': error.toString()},
      );
      rethrow;
    }
  }

  Future<void> safeStopStrategy(String strategyId) async {
    try {
      await autoSpotGridService.stop(strategyId);
      operationMessage.value = '安全停止流程完成：$strategyId';
      await _audit(
        level: 'warning',
        module: 'ORDER_CENTER',
        message: 'strategy safe stop executed from unfinished tab',
        strategyId: strategyId,
      );
      await refreshData();
    } catch (error) {
      operationMessage.value = '安全停止失败：$error';
      await _audit(
        level: 'error',
        module: 'ORDER_CENTER',
        message: 'strategy safe stop failed from unfinished tab',
        strategyId: strategyId,
        extra: {'error': error.toString()},
      );
      rethrow;
    }
  }

  Future<void> batchQuerySelected() async {
    final selected = await orderRepository.getOrdersByIds(selectedOrderIds);
    for (final order in selected) {
      await queryOrder(order, silent: true);
    }
    operationMessage.value = '批量查询完成：${selected.length} 笔。';
  }

  Future<void> batchCancelSelected() async {
    final selected =
        (await orderRepository.getOrdersByIds(selectedOrderIds))
            .where((order) => ['new', 'partiallyFilled'].contains(order.status))
            .toList();
    for (final order in selected) {
      await cancelOrder(order);
    }
    operationMessage.value = '批量撤单完成：${selected.length} 笔。';
  }

  Future<void> exportCurrentOrders() async {
    final range = selectedRange.value.toUtcHalfOpenRange();
    final completed = await orderRepository.getCompletedOrders(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      symbol: _activeSymbol,
      marketType: marketType.value,
      limit: 10000,
    );
    final cancelled = await orderRepository.getCancelledOrders(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      symbol: _activeSymbol,
      marketType: marketType.value,
      limit: 10000,
    );
    final failed = await orderRepository.getFailedOrders(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      symbol: _activeSymbol,
      marketType: marketType.value,
      limit: 10000,
    );
    final unfinished =
        await orderRepository
            .watchUnfinishedOrders(
              start: range.startInclusiveUtc,
              end: range.endExclusiveUtc,
              filter: UnfinishedOrderFilter.all,
              symbol: _activeSymbol,
              marketType: marketType.value,
            )
            .first;
    final csv = csvExportService.ordersToCsv([
      ...unfinished,
      ...completed,
      ...cancelled,
      ...failed,
    ]);
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final location = await getSaveLocation(
      suggestedName: 'grid_hedge_orders_$stamp.csv',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
    );
    if (location == null) {
      return;
    }
    final file = XFile.fromData(
      Uint8List.fromList(csv.codeUnits),
      mimeType: 'text/csv',
      name: 'grid_hedge_orders_$stamp.csv',
    );
    await file.saveTo(location.path);
    exportedPath.value = location.path;
  }

  void _assertAppOwned(Order order) {
    if (order.environment != 'live') {
      throw StateError('只允许处理 LIVE 订单。');
    }
    final appPrefixes = [
      'GH_LIVE_TEST_SPOT_',
      'GH_LIVE_TEST_FUTURES_',
      AutoSpotGridExecutionService.clientOrderPrefix,
    ];
    if (!appPrefixes.any(order.clientOrderId.startsWith)) {
      throw StateError('该订单不是本程序创建，禁止操作。');
    }
  }

  Future<void> _audit({
    required String level,
    required String module,
    required String message,
    String? strategyId,
    Map<String, Object?>? extra,
  }) {
    return logRepository.append(
      strategyId: strategyId,
      level: level,
      module: module,
      message: message,
      extraJson: extra == null ? null : jsonEncode(extra),
    );
  }
}
