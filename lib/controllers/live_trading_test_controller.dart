import 'dart:async';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../models/order_filters.dart';
import '../repositories/order_repository.dart';
import '../services/execution/live_exchange_execution_service.dart';
import '../services/execution/live_trading_gate_service.dart';
import '../services/export/csv_export_service.dart';
import '../services/market_data/market_data_coordinator.dart';
import '../services/security/secure_key_storage.dart';
import 'symbol_workspace_controller.dart';

class LiveTradingTestController extends GetxController {
  LiveTradingTestController({
    required this.executionService,
    required this.orderRepository,
    required this.secureKeyStorage,
    required this.csvExportService,
    required this.marketDataCoordinator,
    required this.liveTradingGateService,
  });

  final LiveExchangeExecutionService executionService;
  final OrderRepository orderRepository;
  final SecureKeyStorage secureKeyStorage;
  final CsvExportService csvExportService;
  final MarketDataCoordinator marketDataCoordinator;
  final LiveTradingGateService liveTradingGateService;
  late final SymbolWorkspaceController _symbolWorkspaceController =
      Get.find<SymbolWorkspaceController>();

  final status = Rxn<LiveExecutionState>();
  final liveDisplay = Rxn<ApiKeyDisplay>();
  final message = ''.obs;
  final selectedRange = todayRange(DateTime.now()).obs;
  final marketType = MarketTypeFilter.all.obs;
  final sideFilter = 'ALL'.obs;
  final exportPath = ''.obs;
  final diagnostics = ''.obs;
  final spotTestOrderPassed = false.obs;
  final futuresSignaturePassed = false.obs;
  final manualSpotOrderLimit = Decimal.fromInt(5).obs;
  final manualSpotDailyLimit = Decimal.fromInt(20).obs;
  final manualFuturesOrderLimit = Decimal.fromInt(5).obs;
  final manualFuturesShortLimit = Decimal.fromInt(10).obs;
  final futuresManualSymbolText = ''.obs;
  final spotSelectedSide = 'BUY'.obs;
  final spotSelectedOrderType = 'LIMIT'.obs;
  final spotLimitQtyController = TextEditingController(text: '0.00008');
  final spotLimitPriceController = TextEditingController(text: '60000');
  final spotMarketQuoteController = TextEditingController(text: '5');
  final spotClientOrderIdController = TextEditingController();
  final futuresQtyController = TextEditingController(text: '0.00008');
  final futuresPriceController = TextEditingController(text: '60000');
  final futuresManualSymbolController = TextEditingController();
  final futuresClientOrderIdController = TextEditingController();
  final liveConfirmController = TextEditingController(text: '我确认当前使用正式账户和真实资金');
  final liveEnableController = TextEditingController(
    text: 'ENABLE LIVE TRADING',
  );
  StreamSubscription<LiveExecutionState>? _stateSub;

  String get activeSymbol =>
      _symbolWorkspaceController.activeSymbol.value?.symbol ?? 'BTCUSDT';

  String get activeDisplayName =>
      _symbolWorkspaceController.activeSymbol.value?.displayName ??
      _formatSymbol(activeSymbol);

  String get activeBaseAsset =>
      _symbolWorkspaceController.activeSymbol.value?.baseAsset ??
      _baseAssetForSymbol(activeSymbol);

  @override
  void onInit() {
    super.onInit();
    _stateSub = executionService.stateStream.listen((event) {
      status.value = event;
    });
    ever<bool>(liveTradingGateService.liveTradingEnabled, (enabled) {
      final current = status.value;
      if (current != null) {
        status.value = LiveExecutionState(
          spotRestStatus: current.spotRestStatus,
          spotWsStatus: current.spotWsStatus,
          futuresRestStatus: current.futuresRestStatus,
          futuresWsStatus: current.futuresWsStatus,
          writesBlocked: current.writesBlocked,
          liveTradingEnabled: enabled,
          lastError: current.lastError,
          restCooldownUntil: current.restCooldownUntil,
          restCooldownReason: current.restCooldownReason,
        );
      }
    });
    _loadDisplay();
    _loadRiskSettings();
    ever(_symbolWorkspaceController.activeSymbol, (_) {
      resetSpotTestOrder();
      futuresSignaturePassed.value = false;
      futuresManualSymbolController.text = activeSymbol;
      futuresManualSymbolText.value = activeSymbol;
      _loadRiskSettings();
    });
    futuresManualSymbolController.text = activeSymbol;
    futuresManualSymbolText.value = activeSymbol;
    connect();
  }

  String get manualFuturesSymbol {
    final raw =
        (futuresManualSymbolText.value.isEmpty
                ? futuresManualSymbolController.text
                : futuresManualSymbolText.value)
            .trim()
            .toUpperCase();
    return raw.isEmpty ? activeSymbol : raw;
  }

  Future<void> _loadRiskSettings({String? symbol}) async {
    final targetSymbol = (symbol ?? activeSymbol).toUpperCase();
    manualSpotOrderLimit.value = await executionService.manualSpotOrderLimit(
      symbol: targetSymbol,
    );
    manualSpotDailyLimit.value = await executionService.manualSpotDailyLimit(
      symbol: targetSymbol,
    );
    manualFuturesOrderLimit.value = await executionService
        .manualFuturesOrderLimit(symbol: targetSymbol);
    manualFuturesShortLimit.value = await executionService
        .manualFuturesShortLimit(symbol: targetSymbol);
  }

  Future<void> _loadFuturesRiskSettings({String? symbol}) async {
    final targetSymbol = (symbol ?? activeSymbol).toUpperCase();
    manualFuturesOrderLimit.value = await executionService
        .manualFuturesOrderLimit(symbol: targetSymbol);
    manualFuturesShortLimit.value = await executionService
        .manualFuturesShortLimit(symbol: targetSymbol);
  }

  Future<void> _loadDisplay() async {
    liveDisplay.value = await secureKeyStorage.loadDisplay();
  }

  @override
  void onClose() {
    _stateSub?.cancel();
    spotLimitQtyController.dispose();
    spotLimitPriceController.dispose();
    spotMarketQuoteController.dispose();
    futuresQtyController.dispose();
    futuresPriceController.dispose();
    futuresManualSymbolController.dispose();
    spotClientOrderIdController.dispose();
    futuresClientOrderIdController.dispose();
    liveConfirmController.dispose();
    liveEnableController.dispose();
    super.onClose();
  }

  Future<void> connect() async {
    return connectForSymbol(activeSymbol);
  }

  Future<void> connectForSymbol(String symbol) async {
    try {
      message.value = '';
      await executionService.connect(symbol: symbol);
      await _loadRiskSettings(symbol: symbol);
      await _loadDisplay();
      message.value = '$symbol LIVE 已连接。';
    } catch (error) {
      message.value = '连接失败：$error';
    }
  }

  Future<void> connectFuturesForSymbol(String symbol) async {
    final targetSymbol = symbol.toUpperCase();
    try {
      message.value = '';
      await executionService.connectFuturesForSymbol(targetSymbol);
      await _loadFuturesRiskSettings(symbol: targetSymbol);
      await _loadDisplay();
      message.value = '$targetSymbol Futures 已连接。';
    } catch (error) {
      message.value = '合约连接失败：$error';
    }
  }

  Future<void> disconnect() async {
    await executionService.disconnect();
    message.value = 'LIVE 已断开。';
  }

  @override
  Future<void> refresh() async {
    return refreshForSymbol(activeSymbol);
  }

  Future<void> refreshForSymbol(String symbol) async {
    await Future.wait([
      executionService.refreshSpotSnapshotForSymbol(symbol),
      executionService.refreshFuturesSnapshotForSymbol(symbol),
      _loadRiskSettings(symbol: symbol),
    ]);
    await _loadDisplay();
    message.value = '已刷新 $symbol LIVE 快照。';
  }

  Future<void> refreshFuturesForSymbol(String symbol) async {
    final targetSymbol = symbol.toUpperCase();
    try {
      await Future.wait([
        executionService.refreshFuturesSnapshotForSymbol(targetSymbol),
        _loadFuturesRiskSettings(symbol: targetSymbol),
      ]);
      await _loadDisplay();
      message.value = '已刷新 $targetSymbol Futures 快照。';
    } catch (error) {
      message.value = '刷新 $targetSymbol Futures 失败：$error';
    }
  }

  Future<void> validateSpotTestOrder({
    required String side,
    required bool market,
    String? symbol,
  }) async {
    try {
      liveTradingGateService.markActivity();
      final qty = Decimal.parse(spotLimitQtyController.text.trim());
      final price = Decimal.parse(spotLimitPriceController.text.trim());
      final quote = Decimal.parse(spotMarketQuoteController.text.trim());
      final type = market ? 'MARKET' : 'LIMIT';
      final targetSymbol = symbol ?? activeSymbol;
      final marketPreview =
          market
              ? _spotMarketPreview(side: side, quantity: qty, quote: quote)
              : null;
      final notional =
          marketPreview?.notional ??
          _spotEstimatedNotional(
            side: side,
            type: type,
            quantity: qty,
            price: price,
            quote: quote,
          );
      _validateSpotMinNotional(notional);
      await executionService.placeSpotTestOrder(
        symbol: targetSymbol,
        side: side,
        type: type,
        quantity:
            market && side == 'SELL'
                ? marketPreview?.quantity
                : (market ? null : qty),
        price: market ? null : price,
        quoteOrderQty:
            market && side == 'BUY' ? marketPreview?.quoteOrderQty : null,
      );
      spotTestOrderPassed.value = true;
      diagnostics.value =
          'Spot Test Order OK\nsymbol: $targetSymbol\nsignature: ok\ntrade permission: ok\nside: $side\ntype: $type\nestimatedNotional: $notional\nformattedPrice: ${market ? '-' : price}\nformattedQuantity: ${marketPreview?.quantity ?? (market ? '-' : qty)}\nquoteOrderQty: ${marketPreview?.quoteOrderQty ?? '-'}${marketPreview?.adjusted == true ? '\nriskAdjustment: capped to ${manualSpotOrderLimit.value} USDT max notional' : ''}';
      message.value = 'Spot Test Order 已验证。';
    } catch (error) {
      spotTestOrderPassed.value = false;
      diagnostics.value = 'Spot Test Order failed\n$error';
      message.value = 'Spot Test Order 失败：$error';
    }
  }

  Future<void> validateSelectedSpotTestOrder({String? symbol}) {
    return validateSpotTestOrder(
      side: spotSelectedSide.value,
      market: spotSelectedOrderType.value == 'MARKET',
      symbol: symbol,
    );
  }

  Future<void> submitSelectedSpotOrder(BuildContext context, {String? symbol}) {
    final side = spotSelectedSide.value;
    if (spotSelectedOrderType.value == 'MARKET') {
      return placeSpotMarketOrder(context, side: side, symbol: symbol);
    }
    return placeSpotLimitOrder(context, side: side, symbol: symbol);
  }

  void setSpotSide(String side) {
    spotSelectedSide.value = side;
    resetSpotTestOrder();
  }

  void setSpotOrderType(String type) {
    spotSelectedOrderType.value = type;
    resetSpotTestOrder();
  }

  void resetSpotTestOrder() {
    spotTestOrderPassed.value = false;
  }

  Future<void> testFuturesSignature({String? symbol}) async {
    try {
      liveTradingGateService.markActivity();
      final targetSymbol = symbol ?? activeSymbol;
      await executionService.testFuturesSignature(symbol: targetSymbol);
      await _loadRiskSettings(symbol: targetSymbol);
      futuresSignaturePassed.value = true;
      diagnostics.value =
          'Futures signature test OK\nsymbol: $targetSymbol\nsigned account snapshot query succeeded.';
      message.value = '$targetSymbol 合约签名测试通过。';
    } catch (error) {
      futuresSignaturePassed.value = false;
      diagnostics.value = 'Futures signature test failed\n$error';
      message.value = '合约签名测试失败：$error';
    }
  }

  Future<void> placeSpotLimitOrder(
    BuildContext context, {
    required String side,
    String? symbol,
  }) async {
    try {
      liveTradingGateService.markActivity();
      if (!spotTestOrderPassed.value) {
        throw StateError('请先完成 Spot Test Order。');
      }
      final qty = Decimal.parse(spotLimitQtyController.text.trim());
      final price = Decimal.parse(spotLimitPriceController.text.trim());
      final targetSymbol = symbol ?? activeSymbol;
      _validateSpotMinNotional(price * qty);
      await _confirmAndExecute(
        context: context,
        title: '现货限价订单确认',
        requireInput: false,
        summary: [
          _line('账户', '现货正式账户'),
          _line('市场', '$targetSymbol Spot'),
          _line('方向', side),
          _line('类型', 'LIMIT'),
          _line('价格', price.toString()),
          _line('数量', qty.toString()),
          _line('预计金额', (price * qty).toString()),
          _line('是否真实资金', '是'),
        ],
        onConfirm: () async {
          await executionService.placeSpotLimitOrder(
            symbol: targetSymbol,
            side: side,
            quantity: qty,
            price: price,
          );
        },
        onTest:
            () => validateSpotTestOrder(
              side: side,
              market: false,
              symbol: targetSymbol,
            ),
      );
      message.value = 'Spot 限价单已提交。';
    } catch (error) {
      message.value = 'Spot 限价下单失败：$error';
    }
  }

  Future<void> placeSpotMarketOrder(
    BuildContext context, {
    required String side,
    String? symbol,
  }) async {
    try {
      liveTradingGateService.markActivity();
      if (!spotTestOrderPassed.value) {
        throw StateError('请先完成 Spot Test Order。');
      }
      final inputQty = Decimal.parse(spotLimitQtyController.text.trim());
      final inputQuote = Decimal.parse(spotMarketQuoteController.text.trim());
      final targetSymbol = symbol ?? activeSymbol;
      final preview = _spotMarketPreview(
        side: side,
        quantity: inputQty,
        quote: inputQuote,
      );
      _validateSpotMinNotional(preview.notional);
      await _confirmAndExecute(
        context: context,
        title: '现货市价订单确认',
        requireInput: true,
        testInputHint: 'CONFIRM',
        summary: [
          _line('账户', '现货正式账户'),
          _line('市场', '$targetSymbol Spot'),
          _line('方向', side),
          _line('类型', 'MARKET'),
          _line('输入数量', inputQty.toString()),
          _line('实际发送数量', preview.quantity?.toString() ?? '-'),
          _line('输入市价买入USDT', inputQuote.toString()),
          _line('实际发送USDT', preview.quoteOrderQty?.toString() ?? '-'),
          _line('预计金额', preview.notional.toString()),
          if (preview.adjusted)
            _line('风控调整', '已按单笔 ${manualSpotOrderLimit.value} USDT 上限自动封顶'),
          _line('是否真实资金', '是'),
        ],
        onConfirm: () async {
          await executionService.placeSpotMarketOrder(
            symbol: targetSymbol,
            side: side,
            quantity: preview.quantity,
            quoteOrderQty: preview.quoteOrderQty,
          );
        },
      );
      message.value = 'Spot 市价单已提交。';
    } catch (error) {
      message.value = 'Spot 市价下单失败：$error';
    }
  }

  Future<void> placeFuturesLimitOrder(
    BuildContext context, {
    required String side,
    required bool reduceOnly,
    String? symbol,
  }) async {
    try {
      liveTradingGateService.markActivity();
      if (!futuresSignaturePassed.value) {
        throw StateError('请先完成合约签名测试。');
      }
      final qty = Decimal.parse(futuresQtyController.text.trim());
      final price = Decimal.parse(futuresPriceController.text.trim());
      final targetSymbol = symbol ?? activeSymbol;
      await _confirmAndExecute(
        context: context,
        title: '合约订单确认',
        requireInput: false,
        summary: [
          _line('账户', '合约正式账户'),
          _line('市场', '$targetSymbol USDⓈ-M Futures'),
          _line('方向', side),
          _line('类型', 'LIMIT'),
          _line('Reduce Only', reduceOnly ? '是' : '否'),
          _line('价格', price.toString()),
          _line('数量', qty.toString()),
          _line('预计金额', (price * qty).toString()),
          _line('是否真实资金', '是'),
        ],
        onConfirm: () async {
          await executionService.placeFuturesLimitOrder(
            symbol: targetSymbol,
            side: side,
            quantity: qty,
            price: price,
            reduceOnly: reduceOnly,
          );
        },
      );
      message.value = '合约限价单已提交。';
    } catch (error) {
      message.value = '合约限价下单失败：$error';
    }
  }

  Future<void> placeFuturesMarketOrder(
    BuildContext context, {
    required String side,
    required bool reduceOnly,
    String? symbol,
  }) async {
    try {
      liveTradingGateService.markActivity();
      if (!futuresSignaturePassed.value) {
        throw StateError('请先完成合约签名测试。');
      }
      final qty = Decimal.parse(futuresQtyController.text.trim());
      final targetSymbol = symbol ?? activeSymbol;
      final preview = _validateFuturesMarketOrder(
        side: side,
        quantity: qty,
        reduceOnly: reduceOnly,
        symbol: targetSymbol,
      );
      await _confirmAndExecute(
        context: context,
        title: '合约市价订单确认',
        requireInput: true,
        testInputHint: 'CONFIRM',
        summary: [
          _line('账户', '合约正式账户'),
          _line('市场', '$targetSymbol USDⓈ-M Futures'),
          _line('方向', side),
          _line('类型', 'MARKET'),
          _line('Reduce Only', reduceOnly ? '是' : '否'),
          _line('输入数量', qty.toString()),
          _line('格式化后数量', preview.formattedQuantity.toString()),
          _line('参考 Mark Price', preview.referencePrice.toString()),
          _line('预计名义金额', preview.notional.toString()),
          _line('最小数量 minQty', preview.minQty.toString()),
          _line('数量步进 stepSize', preview.stepSize.toString()),
          _line('最小名义金额 minNotional', preview.minNotional.toString()),
          _line('当前最小合法数量', preview.minimumLegalQuantity.toString()),
          _line('当前最小合法金额', preview.minimumLegalNotional.toString()),
          _line('是否真实资金', '是'),
        ],
        onConfirm: () async {
          await executionService.placeFuturesMarketOrder(
            symbol: targetSymbol,
            side: side,
            quantity: qty,
            reduceOnly: reduceOnly,
          );
        },
      );
      message.value = '合约市价单已提交。';
    } catch (error) {
      message.value = '合约市价下单失败：$error';
      diagnostics.value = 'Futures market order validation failed\n$error';
    }
  }

  Future<void> cancelOrder(
    String clientOrderId, {
    required bool futures,
    String? symbol,
  }) async {
    try {
      liveTradingGateService.markActivity();
      if (futures) {
        await executionService.cancelFuturesOrder(
          clientOrderId,
          symbol: symbol ?? activeSymbol,
        );
      } else {
        await executionService.cancelSpotOrder(clientOrderId);
      }
      message.value = '已撤销: $clientOrderId';
    } catch (error) {
      message.value = '撤单失败：$error';
    }
  }

  Future<void> cancelAllSpotOpenOrders(
    BuildContext context, {
    String? symbol,
    String? displayName,
    String? baseAsset,
  }) async {
    try {
      liveTradingGateService.markActivity();
      final targetSymbol = symbol ?? activeSymbol;
      final targetDisplayName = displayName ?? activeDisplayName;
      final targetBaseAsset = baseAsset ?? activeBaseAsset;
      await _confirmAndExecute(
        context: context,
        title: '撤销当前币对现货挂单确认',
        requireInput: true,
        testInputHint: 'CONFIRM',
        summary: [
          _line('账户', '现货正式账户'),
          _line('币对', targetDisplayName),
          _line('范围', '$targetSymbol 当前现货挂单'),
          _line('操作', '逐笔撤销 Binance 当前币对现货挂单'),
          _line('是否真实资金', '是'),
          _line('说明', '不会卖出 $targetBaseAsset，不会删除本地历史记录。'),
        ],
        onConfirm: () async {
          final report = await executionService.cancelAllSpotOpenOrders(
            symbol: targetSymbol,
          );
          diagnostics.value = report.toDisplayText();
          message.value =
              '现货挂单撤销完成：成功 ${report.cancelledOrders}，失败 ${report.failedOrders}。';
        },
      );
    } catch (error) {
      diagnostics.value = 'Cancel all spot open orders failed\n$error';
      message.value = '撤销全部现货挂单失败：$error';
    }
  }

  Future<void> querySpotOrder({String? symbol}) async {
    try {
      liveTradingGateService.markActivity();
      final clientOrderId = spotClientOrderIdController.text.trim();
      if (clientOrderId.isEmpty) {
        throw StateError('请输入 Spot Client Order ID');
      }
      await executionService.querySpotOrder(
        clientOrderId,
        symbol: symbol ?? activeSymbol,
      );
      message.value = '${symbol ?? activeSymbol} Spot 订单已同步: $clientOrderId';
    } catch (error) {
      message.value = 'Spot 查询失败：$error';
    }
  }

  Future<void> queryFuturesOrder({String? symbol}) async {
    try {
      liveTradingGateService.markActivity();
      final clientOrderId = futuresClientOrderIdController.text.trim();
      if (clientOrderId.isEmpty) {
        throw StateError('请输入 Futures Client Order ID');
      }
      await executionService.queryFuturesOrder(
        clientOrderId,
        symbol: symbol ?? activeSymbol,
      );
      message.value = '${symbol ?? activeSymbol} Futures 订单已同步: $clientOrderId';
    } catch (error) {
      message.value = 'Futures 查询失败：$error';
    }
  }

  Future<void> enableLiveTrading() async {
    final first = liveConfirmController.text.trim();
    final second = liveEnableController.text.trim();
    if (first != '我确认当前使用正式账户和真实资金' || second != 'ENABLE LIVE TRADING') {
      message.value = '确认文字不匹配。';
      return;
    }
    liveTradingGateService.setEnabled(true);
    message.value = '真实写操作已开启。';
  }

  void disableLiveTrading() {
    liveTradingGateService.disable(reason: 'manual disable');
    message.value = '真实写操作已关闭。';
  }

  Future<void> emergencyExit({bool sellSpot = true}) async {
    try {
      await executionService.emergencyExit(sellSpot: sellSpot);
      liveTradingGateService.disable();
      message.value = '已执行 LIVE 紧急退出。';
    } catch (error) {
      message.value = '紧急退出失败：$error';
    }
  }

  Future<void> exportOrders() async {
    final range = selectedRange.value.toUtcHalfOpenRange();
    final completed = await orderRepository.getCompletedOrders(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      marketType: marketType.value,
      environment: OrderEnvironmentFilter.live,
      limit: 10000,
    );
    final cancelled = await orderRepository.getCancelledOrders(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      marketType: marketType.value,
      environment: OrderEnvironmentFilter.live,
      limit: 10000,
    );
    final failed = await orderRepository.getFailedOrders(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
      marketType: marketType.value,
      environment: OrderEnvironmentFilter.live,
      limit: 10000,
    );
    final csv = csvExportService.ordersToCsv([
      ...completed,
      ...cancelled,
      ...failed,
    ]);
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final location = await getSaveLocation(
      suggestedName: 'grid_hedge_live_orders_$stamp.csv',
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
      name: 'grid_hedge_live_orders_$stamp.csv',
    );
    await file.saveTo(location.path);
    exportPath.value = location.path;
  }

  Future<void> _confirmAndExecute({
    required BuildContext context,
    required String title,
    required List<Widget> summary,
    required Future<void> Function() onConfirm,
    Future<void> Function()? onTest,
    required bool requireInput,
    String testInputHint = 'CONFIRM',
  }) async {
    final confirmController = TextEditingController();
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          var canConfirm = !requireInput;
          return StatefulBuilder(
            builder: (context, setState) {
              return AlertDialog(
                title: Text(title),
                content: SizedBox(
                  width: 560,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '所有正式订单都会影响真实资金。',
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ...summary,
                        if (requireInput) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: confirmController,
                            decoration: const InputDecoration(
                              labelText: '输入 CONFIRM',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (value) {
                              setState(() {
                                canConfirm = value.trim() == testInputHint;
                              });
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                actions: [
                  if (onTest != null)
                    TextButton(
                      onPressed: () async {
                        try {
                          await onTest();
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                        } catch (error) {
                          message.value = 'Spot Test Order 失败：$error';
                        }
                      },
                      child: const Text('测试下单'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed:
                        canConfirm
                            ? () async {
                              try {
                                await onConfirm();
                                if (dialogContext.mounted) {
                                  Navigator.of(dialogContext).pop();
                                }
                              } catch (error) {
                                message.value = '$title 失败：$error';
                                diagnostics.value = '$title failed\n$error';
                              }
                            }
                            : null,
                    child: const Text('确认发送真实订单'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      confirmController.dispose();
    }
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text('$label: $value'),
    );
  }

  Future<OrderDetails?> loadDetails(String orderId) {
    return orderRepository.getOrderDetails(orderId);
  }

  Decimal _spotEstimatedNotional({
    required String side,
    required String type,
    required Decimal quantity,
    required Decimal? price,
    required Decimal quote,
  }) {
    if (type == 'MARKET' && side == 'BUY') {
      return quote;
    }
    final reference =
        price ??
        (side == 'BUY'
            ? marketDataCoordinator.latestSpotTicker?.askPrice
            : marketDataCoordinator.latestSpotTicker?.bidPrice) ??
        Decimal.fromInt(60000);
    return reference * quantity;
  }

  void _validateSpotMinNotional(Decimal notional) {
    final minNotional = executionService.spotRules?.minNotional;
    if (minNotional != null &&
        minNotional > Decimal.zero &&
        notional < minNotional) {
      throw StateError(
        '订单金额 $notional USDT 低于 Binance 最小名义金额 $minNotional USDT。请提高价格、数量，或选择市价买入 ${manualSpotOrderLimit.value} USDT。',
      );
    }
  }

  _SpotMarketPreview _spotMarketPreview({
    required String side,
    required Decimal quantity,
    required Decimal quote,
  }) {
    final maxNotional = manualSpotOrderLimit.value;
    final rules = executionService.spotRules;
    final reference =
        (side == 'BUY'
            ? marketDataCoordinator.latestSpotTicker?.askPrice
            : marketDataCoordinator.latestSpotTicker?.bidPrice) ??
        Decimal.fromInt(60000);
    if (reference <= Decimal.zero) {
      throw StateError('缺少有效现货 Bid/Ask，不能估算市价单。');
    }
    if (rules != null && rules.minNotional > maxNotional) {
      throw StateError(
        'Binance 最小名义金额 ${rules.minNotional} USDT 高于当前现货单笔上限 $maxNotional USDT，禁止提交现货市价单。',
      );
    }
    if (side == 'BUY') {
      final cappedQuote = quote > maxNotional ? maxNotional : quote;
      return _SpotMarketPreview(
        quantity: null,
        quoteOrderQty: cappedQuote,
        notional: cappedQuote,
        adjusted: cappedQuote != quote,
      );
    }
    final inputNotional = quantity * reference;
    final cappedQuantity =
        inputNotional > maxNotional
            ? (maxNotional / reference).toDecimal(scaleOnInfinitePrecision: 12)
            : quantity;
    final finalQuantity =
        rules == null ? cappedQuantity : rules.quantizeQuantity(cappedQuantity);
    final finalNotional = finalQuantity * reference;
    if (finalQuantity <= Decimal.zero) {
      throw StateError('按 $maxNotional USDT 上限计算后的市价卖出数量为 0，不能提交。');
    }
    if (rules != null &&
        !rules.isAcceptableOrder(
          price: rules.quantizePrice(reference),
          quantity: finalQuantity,
        )) {
      throw StateError(
        '按 $maxNotional USDT 上限计算后的市价卖出数量 $finalQuantity 不满足 minQty/minNotional。',
      );
    }
    return _SpotMarketPreview(
      quantity: finalQuantity,
      quoteOrderQty: null,
      notional: finalNotional,
      adjusted: finalQuantity != quantity,
    );
  }

  _FuturesMarketPreview _validateFuturesMarketOrder({
    required String side,
    required Decimal quantity,
    required bool reduceOnly,
    required String symbol,
  }) {
    final rules = executionService.futuresRules;
    if (rules == null) {
      throw StateError('缺少合约交易规则，请先重新连接并等待 exchangeInfo 加载。');
    }
    final markPrice =
        marketDataCoordinator.latestFuturesMarkPriceFor(symbol)?.markPrice;
    if (markPrice == null || markPrice <= Decimal.zero) {
      throw StateError('缺少合约 Mark Price，不能估算市价单名义金额。');
    }
    if (side == 'BUY' && !reduceOnly) {
      throw StateError('禁止非 Reduce Only 的 BUY，防止建立净多仓。');
    }
    final referencePrice = rules.quantizePrice(markPrice);
    final formattedQuantity = rules.quantizeQuantity(quantity);
    final notional = referencePrice * formattedQuantity;
    final minQtyByNotional = _ceilToStep(
      (rules.minNotional / referencePrice).toDecimal(
        scaleOnInfinitePrecision: 18,
      ),
      rules.stepSize,
    );
    final minimumLegalQuantity =
        minQtyByNotional > rules.minQty ? minQtyByNotional : rules.minQty;
    final minimumLegalNotional = referencePrice * minimumLegalQuantity;
    final preview = _FuturesMarketPreview(
      referencePrice: referencePrice,
      formattedQuantity: formattedQuantity,
      notional: notional,
      minQty: rules.minQty,
      stepSize: rules.stepSize,
      minNotional: rules.minNotional,
      minimumLegalQuantity: minimumLegalQuantity,
      minimumLegalNotional: minimumLegalNotional,
    );
    diagnostics.value =
        'Futures market preview\n'
        'side=$side\n'
        'reduceOnly=$reduceOnly\n'
        'inputQty=$quantity\n'
        'formattedQty=$formattedQuantity\n'
        'referenceMarkPrice=$referencePrice\n'
        'notional=$notional\n'
        'minQty=${rules.minQty}\n'
        'stepSize=${rules.stepSize}\n'
        'minNotional=${rules.minNotional}\n'
        'minimumLegalQty=$minimumLegalQuantity\n'
        'minimumLegalNotional=$minimumLegalNotional';
    if (formattedQuantity <= Decimal.zero) {
      throw StateError(
        '输入数量 $quantity 按 stepSize=${rules.stepSize} 格式化后为 0。'
        '当前至少需要 $minimumLegalQuantity BTC，约 $minimumLegalNotional USDT。',
      );
    }
    if (!rules.isQuantityAcceptable(formattedQuantity)) {
      throw StateError(
        '格式化后数量 $formattedQuantity 不满足 minQty=${rules.minQty}。'
        '当前至少需要 $minimumLegalQuantity BTC，约 $minimumLegalNotional USDT。',
      );
    }
    if (!rules.isNotionalAcceptable(referencePrice, formattedQuantity)) {
      final message =
          '订单名义金额 $notional USDT 低于 Binance 合约最小名义金额 '
          '${rules.minNotional} USDT。当前至少需要 $minimumLegalQuantity BTC，'
          '约 $minimumLegalNotional USDT。';
      final orderLimit = manualFuturesOrderLimit.value;
      if (!reduceOnly && minimumLegalNotional > orderLimit) {
        throw StateError(
          '$message 当前合约开空单笔上限为 $orderLimit USDT，因此当前 $activeSymbol 合约规则下禁止小额开空。',
        );
      }
      throw StateError(message);
    }
    final orderLimit = manualFuturesOrderLimit.value;
    if (!reduceOnly && notional > orderLimit) {
      throw StateError('合约开空单笔名义金额 $notional USDT 超过 $orderLimit USDT 上限。');
    }
    if (!reduceOnly && minimumLegalNotional > orderLimit) {
      throw StateError(
        'Binance 当前最小合法合约订单约 $minimumLegalNotional USDT，'
        '高于当前 $orderLimit USDT 开空上限，禁止提交。',
      );
    }
    return preview;
  }

  Decimal _ceilToStep(Decimal value, Decimal step) {
    if (step == Decimal.zero) {
      return value;
    }
    return (value / step).toDecimal(scaleOnInfinitePrecision: 18).ceil() * step;
  }

  String _formatSymbol(String symbol) {
    final normalized = symbol.toUpperCase();
    if (normalized.endsWith('USDT') && normalized.length > 4) {
      return '${normalized.substring(0, normalized.length - 4)}/USDT';
    }
    return normalized;
  }

  String _baseAssetForSymbol(String symbol) {
    final normalized = symbol.toUpperCase();
    if (normalized.endsWith('USDT') && normalized.length > 4) {
      return normalized.substring(0, normalized.length - 4);
    }
    return normalized;
  }
}

class _SpotMarketPreview {
  const _SpotMarketPreview({
    required this.quantity,
    required this.quoteOrderQty,
    required this.notional,
    required this.adjusted,
  });

  final Decimal? quantity;
  final Decimal? quoteOrderQty;
  final Decimal notional;
  final bool adjusted;
}

class _FuturesMarketPreview {
  const _FuturesMarketPreview({
    required this.referencePrice,
    required this.formattedQuantity,
    required this.notional,
    required this.minQty,
    required this.stepSize,
    required this.minNotional,
    required this.minimumLegalQuantity,
    required this.minimumLegalNotional,
  });

  final Decimal referencePrice;
  final Decimal formattedQuantity;
  final Decimal notional;
  final Decimal minQty;
  final Decimal stepSize;
  final Decimal minNotional;
  final Decimal minimumLegalQuantity;
  final Decimal minimumLegalNotional;
}
