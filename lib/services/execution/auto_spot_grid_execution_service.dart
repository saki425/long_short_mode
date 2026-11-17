import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../models/paper_strategy_config.dart';
import '../../repositories/basic_repositories.dart';
import '../../services/app_ui_settings.dart';
import '../../services/binance/auth/binance_request_exception.dart';
import '../../services/market_data/market_data_coordinator.dart';
import '../../services/market_data/market_data_status.dart';
import '../../services/binance/trading/binance_symbol_rules.dart';
import '../../services/pnl/completed_grid_cycle_service.dart';
import '../../strategy/grid/grid_generator.dart';
import 'future_grid_engine.dart';
import 'live_exchange_execution_service.dart';
import 'live_trading_gate_service.dart';
import 'order_state_transition_validator.dart';

enum LiveSpotGridPreflightIssueType {
  marketData,
  spotRest,
  spotAccountWs,
  serverTime,
  exchangeRules,
  sqlite,
  conflictingStrategy,
  unknownOrders,
  btcClassification,
  usdtBalance,
  gridAndCapital,
  liveTrading,
}

class LiveSpotGridPreflightIssue {
  const LiveSpotGridPreflightIssue({
    required this.type,
    required this.title,
    required this.status,
    required this.message,
    this.actionLabel,
    this.details = const {},
  });

  final LiveSpotGridPreflightIssueType type;
  final String title;
  final String status;
  final String message;
  final String? actionLabel;
  final Map<String, Object?> details;

  bool get failed => status == 'failed';
}

class MissingExchangeRulesException implements Exception {
  const MissingExchangeRulesException(this.message);
  final String message;
  @override
  String toString() => 'MissingExchangeRulesException: $message';
}

class ConflictingLiveStrategyException implements Exception {
  const ConflictingLiveStrategyException(this.message);
  final String message;
  @override
  String toString() => 'ConflictingLiveStrategyException: $message';
}

class UnclassifiedAssetException implements Exception {
  const UnclassifiedAssetException(this.message);
  final String message;
  @override
  String toString() => 'UnclassifiedAssetException: $message';
}

class LiveTradingDisabledException implements Exception {
  const LiveTradingDisabledException(this.message);
  final String message;
  @override
  String toString() => 'LiveTradingDisabledException: $message';
}

class LiveSpotGridPreflightResult {
  const LiveSpotGridPreflightResult({
    required this.ok,
    required this.failures,
    this.issues = const [],
  });

  final bool ok;
  final List<String> failures;
  final List<LiveSpotGridPreflightIssue> issues;
}

class FuturesLongGridStartReport {
  const FuturesLongGridStartReport({
    required this.strategyId,
    required this.symbol,
    required this.submittedOrders,
    required this.activeOrders,
    required this.waitingOrders,
    required this.failures,
  });

  final String strategyId;
  final String symbol;
  final int submittedOrders;
  final int activeOrders;
  final int waitingOrders;
  final List<String> failures;

  bool get ok => failures.isEmpty;

  String toDisplayText() {
    final lines = [
      '合约 LONG 网格启动完成',
      'Symbol: $symbol',
      '本次提交 LONG BUY: $submittedOrders',
      '当前活动挂单: $activeOrders',
      '等待提交层级: $waitingOrders',
    ];
    if (failures.isNotEmpty) {
      lines.add('失败: ${failures.join('; ')}');
    }
    return lines.join('\n');
  }
}

class FuturesLongGridStopReport {
  const FuturesLongGridStopReport({
    required this.strategyId,
    required this.symbol,
    required this.cancelledOrders,
    required this.partialFilledOrders,
    required this.resetLevels,
    required this.failures,
  });

  final String strategyId;
  final String symbol;
  final int cancelledOrders;
  final int partialFilledOrders;
  final int resetLevels;
  final List<String> failures;

  bool get ok => failures.isEmpty;

  String toDisplayText() {
    final lines = [
      failures.isEmpty ? '合约 LONG 网格已停止' : '合约 LONG 网格停止未完成',
      'Symbol: $symbol',
      '已撤销未成交/未完全成交 LONG BUY 挂单: $cancelledOrders',
      '存在部分成交 LONG 层: $partialFilledOrders',
      '已恢复等待层级: $resetLevels',
    ];
    if (failures.isNotEmpty) {
      lines.add('失败: ${failures.join('; ')}');
    }
    return lines.join('\n');
  }
}

class FuturesPositionCloseReport {
  const FuturesPositionCloseReport({
    required this.strategyId,
    required this.symbol,
    required this.positionSide,
    required this.quantity,
    required this.orderId,
  });

  final String strategyId;
  final String symbol;
  final String positionSide;
  final Decimal quantity;
  final String? orderId;

  bool get submitted => orderId != null;

  String toDisplayText() {
    if (orderId == null) {
      return '$symbol 当前没有可平的 $positionSide 持仓。';
    }
    return [
      '$symbol $positionSide 一键平仓已提交',
      '数量: $quantity',
      '订单: $orderId',
    ].join('\n');
  }
}

class _FuturesLongReduceAvailability {
  const _FuturesLongReduceAvailability({
    required this.currentLong,
    required this.reservedReduceOnlySell,
    required this.available,
    required this.reduceOnlySellOrderCount,
  });

  final Decimal currentLong;
  final Decimal reservedReduceOnlySell;
  final Decimal available;
  final int reduceOnlySellOrderCount;

  String failureMessage({
    required Decimal requestedQuantity,
    required Decimal desiredQuantity,
  }) {
    final base = 'Binance 当前没有可用 LONG 可平数量。'
        '计划平多=$requestedQuantity，当前层需要=$desiredQuantity，'
        '当前LONG持仓=$currentLong，'
        '已被reduceOnly平多挂单占用=$reservedReduceOnlySell，'
        '可用可平=$available，'
        '占用挂单数=$reduceOnlySellOrderCount。';
    if (currentLong <= Decimal.zero) {
      return '$base 具体原因: Binance 当前没有 LONG 持仓，可能已经平仓或仓位未同步。';
    }
    if (reservedReduceOnlySell >= currentLong) {
      return '$base 具体原因: 当前 LONG 持仓已全部被已有 reduceOnly SELL 平多挂单占用。';
    }
    return '$base 具体原因: 可用可平数量不足，可能是持仓或挂单刚变化，请刷新 Binance 当前挂单并对账。';
  }
}

class FuturesLongGridReconcileReport {
  const FuturesLongGridReconcileReport({
    required this.strategyId,
    required this.symbol,
    required this.syncedOrders,
    required this.activeOrders,
    required this.completedOrders,
    required this.errorOrders,
    this.errorDetails = const [],
  });

  final String strategyId;
  final String symbol;
  final int syncedOrders;
  final int activeOrders;
  final int completedOrders;
  final int errorOrders;
  final List<String> errorDetails;

  String toDisplayText() {
    final lines = [
      'LONG Futures Binance 对账完成',
      'Symbol: $symbol',
      '已同步订单: $syncedOrders',
      '活动订单: $activeOrders',
      '已完成订单: $completedOrders',
      '异常订单: $errorOrders',
    ];
    if (errorDetails.isNotEmpty) {
      lines.add('异常明细:');
      lines.addAll(errorDetails.take(5).map((detail) => '- $detail'));
      if (errorDetails.length > 5) {
        lines.add('- 还有 ${errorDetails.length - 5} 笔异常订单未展示');
      }
    }
    return lines.join('\n');
  }
}

class FuturesLongGridRecoverReport {
  const FuturesLongGridRecoverReport({
    required this.strategyId,
    required this.symbol,
    required this.restored,
    required this.reconcileReport,
    required this.activeOrders,
    required this.waitingBuyLevels,
    required this.openLongLevels,
    required this.errorLevels,
    this.message,
  });

  final String strategyId;
  final String symbol;
  final bool restored;
  final FuturesLongGridReconcileReport reconcileReport;
  final int activeOrders;
  final int waitingBuyLevels;
  final int openLongLevels;
  final int errorLevels;
  final String? message;

  String toDisplayText() {
    final lines = [
      restored ? '恢复并对账 LONG 网格完成' : '恢复并对账 LONG 网格未完成',
      'Symbol: $symbol',
      '活动 LONG 挂单: $activeOrders',
      '等待开多层: $waitingBuyLevels',
      '已开多待平多层: $openLongLevels',
      '错误层: $errorLevels',
      '异常订单: ${reconcileReport.errorOrders}',
    ];
    if (message != null && message!.isNotEmpty) {
      lines.add('说明: $message');
    }
    if (reconcileReport.errorDetails.isNotEmpty) {
      lines.add('异常明细:');
      lines.addAll(
        reconcileReport.errorDetails.take(5).map((item) => '- $item'),
      );
    }
    return lines.join('\n');
  }
}

class LiveSpotGridEditableConfig {
  const LiveSpotGridEditableConfig({
    required this.name,
    required this.symbol,
    required this.executionMode,
    required this.centerPrice,
    required this.lowerPrice,
    required this.upperPrice,
    required this.gridMode,
    required this.gridIntervalCount,
    required this.initialBuyOrderCount,
    required this.initialSellOrderCount,
    required this.maxOpenOrders,
    required this.spotCapital,
    required this.initialBtcRatio,
    required this.singleGridAmount,
    required this.maxLossUsdt,
    required this.dailyMaxLossUsdt,
    required this.outOfRangeAction,
    required this.enableFutureHedgeGrid,
    required this.futureGridOffset,
    required this.futuresLeverage,
    required this.futuresPriceSource,
    required this.longEntryTriggerDistanceUsdt,
    this.longEntryTriggerMode = longEntryTriggerModeNearPrice,
    this.longEntryPrehangLevels = defaultLongEntryPrehangLevels,
    required this.shortHedgeMultiplier,
    required this.shortHedgeSpreadLevels,
  });

  static const spotGridFuturesHedge = 'spotGridFuturesHedge';
  static const futuresGridHedge = 'futuresGridHedge';
  static const futuresMarkPrice = 'futuresMarkPrice';
  static const longEntryTriggerModeNearPrice = 'nearPrice';
  static const longEntryTriggerModePrehang = 'prehang';
  static const defaultLongEntryPrehangLevels = 4;

  factory LiveSpotGridEditableConfig.defaults({
    required Decimal centerPrice,
    String symbol = 'BTCUSDT',
    String name = 'BTCUSDT LIVE Spot Grid',
    Decimal? spotCapital,
    String executionMode = spotGridFuturesHedge,
  }) {
    final spacing = Decimal.parse('0.012');
    return LiveSpotGridEditableConfig(
      name: name,
      symbol: symbol,
      executionMode: executionMode,
      centerPrice: centerPrice,
      lowerPrice:
          centerPrice * (Decimal.fromInt(1) - spacing * Decimal.fromInt(3)),
      upperPrice:
          centerPrice * (Decimal.fromInt(1) + spacing * Decimal.fromInt(3)),
      gridMode: 'geometric',
      gridIntervalCount: 6,
      initialBuyOrderCount:
          AutoSpotGridExecutionService.defaultInitialBuyOrderCount,
      initialSellOrderCount: 0,
      maxOpenOrders: AutoSpotGridExecutionService.defaultMaxOpenOrders,
      spotCapital: spotCapital ?? Decimal.fromInt(50),
      initialBtcRatio: Decimal.parse('0.5'),
      singleGridAmount: Decimal.parse('7.14285714'),
      maxLossUsdt: Decimal.fromInt(3),
      dailyMaxLossUsdt: Decimal.fromInt(2),
      outOfRangeAction: 'pauseAndReview',
      enableFutureHedgeGrid: executionMode == futuresGridHedge,
      futureGridOffset: 1,
      futuresLeverage: 1,
      futuresPriceSource: futuresMarkPrice,
      longEntryTriggerDistanceUsdt:
          AutoSpotGridExecutionService.defaultLongEntryTriggerDistanceUsdt,
      longEntryTriggerMode: longEntryTriggerModeNearPrice,
      longEntryPrehangLevels: defaultLongEntryPrehangLevels,
      shortHedgeMultiplier: Decimal.parse('1.2'),
      shortHedgeSpreadLevels: 4,
    );
  }

  factory LiveSpotGridEditableConfig.fromStrategy(Strategy strategy) {
    return LiveSpotGridEditableConfig(
      name: strategy.name,
      symbol: strategy.symbol,
      executionMode: spotGridFuturesHedge,
      centerPrice: _parseDecimal(strategy.centerPrice),
      lowerPrice: _parseDecimal(strategy.lowerPrice),
      upperPrice: _parseDecimal(strategy.upperPrice),
      gridMode: strategy.gridMode,
      gridIntervalCount: strategy.gridCount,
      initialBuyOrderCount:
          AutoSpotGridExecutionService.defaultInitialBuyOrderCount,
      initialSellOrderCount: 0,
      maxOpenOrders: AutoSpotGridExecutionService.defaultMaxOpenOrders,
      spotCapital: _parseDecimal(strategy.spotCapital),
      initialBtcRatio: Decimal.parse('0.5'),
      singleGridAmount: Decimal.parse('7.14285714'),
      maxLossUsdt: _parseDecimal(strategy.maxLossUsdt),
      dailyMaxLossUsdt: Decimal.fromInt(2),
      outOfRangeAction: 'pauseAndReview',
      enableFutureHedgeGrid: false,
      futureGridOffset: 1,
      futuresLeverage: 1,
      futuresPriceSource: futuresMarkPrice,
      longEntryTriggerDistanceUsdt:
          AutoSpotGridExecutionService.defaultLongEntryTriggerDistanceUsdt,
      longEntryTriggerMode: longEntryTriggerModeNearPrice,
      longEntryPrehangLevels: defaultLongEntryPrehangLevels,
      shortHedgeMultiplier: Decimal.parse('1.2'),
      shortHedgeSpreadLevels: 4,
    );
  }

  factory LiveSpotGridEditableConfig.fromJson(Map<String, dynamic> json) {
    return LiveSpotGridEditableConfig(
      name: '${json['name'] ?? 'BTCUSDT LIVE Spot Grid'}',
      symbol: '${json['symbol'] ?? 'BTCUSDT'}',
      executionMode: '${json['executionMode'] ?? spotGridFuturesHedge}',
      centerPrice: _parseDecimal('${json['centerPrice'] ?? '0'}'),
      lowerPrice: _parseDecimal('${json['lowerPrice'] ?? '0'}'),
      upperPrice: _parseDecimal('${json['upperPrice'] ?? '0'}'),
      gridMode: '${json['gridMode'] ?? 'geometric'}',
      gridIntervalCount:
          int.tryParse('${json['gridIntervalCount'] ?? '6'}') ?? 6,
      initialBuyOrderCount:
          int.tryParse('${json['initialBuyOrderCount'] ?? '2'}') ?? 2,
      initialSellOrderCount:
          int.tryParse('${json['initialSellOrderCount'] ?? '0'}') ?? 0,
      maxOpenOrders: int.tryParse('${json['maxOpenOrders'] ?? '4'}') ?? 4,
      spotCapital: _parseDecimal('${json['spotCapital'] ?? '50'}'),
      initialBtcRatio: _parseDecimal('${json['initialBtcRatio'] ?? '0.5'}'),
      singleGridAmount: _parseDecimal(
        '${json['singleGridAmount'] ?? '7.14285714'}',
      ),
      maxLossUsdt: _parseDecimal('${json['maxLossUsdt'] ?? '3'}'),
      dailyMaxLossUsdt: _parseDecimal('${json['dailyMaxLossUsdt'] ?? '2'}'),
      outOfRangeAction: '${json['outOfRangeAction'] ?? 'pauseAndReview'}',
      enableFutureHedgeGrid:
          '${json['enableFutureHedgeGrid'] ?? 'false'}' == 'true',
      futureGridOffset: int.tryParse('${json['futureGridOffset'] ?? '1'}') ?? 1,
      futuresLeverage: int.tryParse('${json['futuresLeverage'] ?? '1'}') ?? 1,
      futuresPriceSource: '${json['futuresPriceSource'] ?? futuresMarkPrice}',
      longEntryTriggerDistanceUsdt: _parseDecimal(
        '${json['longEntryTriggerDistanceUsdt'] ?? '1'}',
      ),
      longEntryTriggerMode:
          '${json['longEntryTriggerMode'] ?? longEntryTriggerModeNearPrice}' ==
                  longEntryTriggerModePrehang
              ? longEntryTriggerModePrehang
              : longEntryTriggerModeNearPrice,
      longEntryPrehangLevels: int.tryParse(
            '${json['longEntryPrehangLevels'] ?? defaultLongEntryPrehangLevels}',
          ) ??
          defaultLongEntryPrehangLevels,
      shortHedgeMultiplier: _parseDecimal(
        '${json['shortHedgeMultiplier'] ?? '1.2'}',
      ),
      shortHedgeSpreadLevels:
          int.tryParse('${json['shortHedgeSpreadLevels'] ?? '4'}') ?? 4,
    );
  }

  final String name;
  final String symbol;
  final String executionMode;
  final Decimal centerPrice;
  final Decimal lowerPrice;
  final Decimal upperPrice;
  final String gridMode;
  final int gridIntervalCount;
  final int initialBuyOrderCount;
  final int initialSellOrderCount;
  final int maxOpenOrders;
  final Decimal spotCapital;
  final Decimal initialBtcRatio;
  final Decimal singleGridAmount;
  final Decimal maxLossUsdt;
  final Decimal dailyMaxLossUsdt;
  final String outOfRangeAction;
  final bool enableFutureHedgeGrid;
  final int futureGridOffset;
  final int futuresLeverage;
  final String futuresPriceSource;
  final Decimal longEntryTriggerDistanceUsdt;
  final String longEntryTriggerMode;
  final int longEntryPrehangLevels;
  final Decimal shortHedgeMultiplier;
  final int shortHedgeSpreadLevels;

  bool get isFuturesGridHedge => executionMode == futuresGridHedge;

  LiveSpotGridEditableConfig copyWith({
    String? name,
    String? symbol,
    String? executionMode,
    Decimal? centerPrice,
    Decimal? lowerPrice,
    Decimal? upperPrice,
    String? gridMode,
    int? gridIntervalCount,
    int? initialBuyOrderCount,
    int? initialSellOrderCount,
    int? maxOpenOrders,
    Decimal? spotCapital,
    Decimal? initialBtcRatio,
    Decimal? singleGridAmount,
    Decimal? maxLossUsdt,
    Decimal? dailyMaxLossUsdt,
    String? outOfRangeAction,
    bool? enableFutureHedgeGrid,
    int? futureGridOffset,
    int? futuresLeverage,
    String? futuresPriceSource,
    Decimal? longEntryTriggerDistanceUsdt,
    String? longEntryTriggerMode,
    int? longEntryPrehangLevels,
    Decimal? shortHedgeMultiplier,
    int? shortHedgeSpreadLevels,
  }) {
    return LiveSpotGridEditableConfig(
      name: name ?? this.name,
      symbol: symbol ?? this.symbol,
      executionMode: executionMode ?? this.executionMode,
      centerPrice: centerPrice ?? this.centerPrice,
      lowerPrice: lowerPrice ?? this.lowerPrice,
      upperPrice: upperPrice ?? this.upperPrice,
      gridMode: gridMode ?? this.gridMode,
      gridIntervalCount: gridIntervalCount ?? this.gridIntervalCount,
      initialBuyOrderCount: initialBuyOrderCount ?? this.initialBuyOrderCount,
      initialSellOrderCount:
          initialSellOrderCount ?? this.initialSellOrderCount,
      maxOpenOrders: maxOpenOrders ?? this.maxOpenOrders,
      spotCapital: spotCapital ?? this.spotCapital,
      initialBtcRatio: initialBtcRatio ?? this.initialBtcRatio,
      singleGridAmount: singleGridAmount ?? this.singleGridAmount,
      maxLossUsdt: maxLossUsdt ?? this.maxLossUsdt,
      dailyMaxLossUsdt: dailyMaxLossUsdt ?? this.dailyMaxLossUsdt,
      outOfRangeAction: outOfRangeAction ?? this.outOfRangeAction,
      enableFutureHedgeGrid:
          enableFutureHedgeGrid ?? this.enableFutureHedgeGrid,
      futureGridOffset: futureGridOffset ?? this.futureGridOffset,
      futuresLeverage: futuresLeverage ?? this.futuresLeverage,
      futuresPriceSource: futuresPriceSource ?? this.futuresPriceSource,
      longEntryTriggerDistanceUsdt:
          longEntryTriggerDistanceUsdt ?? this.longEntryTriggerDistanceUsdt,
      longEntryTriggerMode: longEntryTriggerMode ?? this.longEntryTriggerMode,
      longEntryPrehangLevels:
          longEntryPrehangLevels ?? this.longEntryPrehangLevels,
      shortHedgeMultiplier: shortHedgeMultiplier ?? this.shortHedgeMultiplier,
      shortHedgeSpreadLevels:
          shortHedgeSpreadLevels ?? this.shortHedgeSpreadLevels,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'symbol': symbol,
        'executionMode': executionMode,
        'centerPrice': centerPrice.toString(),
        'lowerPrice': lowerPrice.toString(),
        'upperPrice': upperPrice.toString(),
        'gridMode': gridMode,
        'gridIntervalCount': gridIntervalCount,
        'initialBuyOrderCount': initialBuyOrderCount,
        'initialSellOrderCount': initialSellOrderCount,
        'maxOpenOrders': maxOpenOrders,
        'spotCapital': spotCapital.toString(),
        'initialBtcRatio': initialBtcRatio.toString(),
        'singleGridAmount': singleGridAmount.toString(),
        'maxLossUsdt': maxLossUsdt.toString(),
        'dailyMaxLossUsdt': dailyMaxLossUsdt.toString(),
        'outOfRangeAction': outOfRangeAction,
        'enableFutureHedgeGrid': enableFutureHedgeGrid.toString(),
        'futureGridOffset': futureGridOffset.toString(),
        'futuresLeverage': futuresLeverage.toString(),
        'futuresPriceSource': futuresPriceSource,
        'longEntryTriggerDistanceUsdt': longEntryTriggerDistanceUsdt.toString(),
        'longEntryTriggerMode': longEntryTriggerMode,
        'longEntryPrehangLevels': longEntryPrehangLevels,
        'shortHedgeMultiplier': shortHedgeMultiplier.toString(),
        'shortHedgeSpreadLevels': shortHedgeSpreadLevels.toString(),
      };

  PaperStrategyConfig toPaperConfig() {
    return PaperStrategyConfig(
      name: name,
      symbol: symbol,
      centerPrice: centerPrice,
      lowerPrice: lowerPrice,
      upperPrice: upperPrice,
      gridCount: gridIntervalCount,
      gridSpacingPercent: Decimal.parse('1.2'),
      gridMode: gridMode,
      spotCapital: spotCapital,
      futuresCapital: Decimal.zero,
      reserveCapital: Decimal.zero,
      hedgeRatio: Decimal.zero,
      maxLossUsdt: maxLossUsdt,
      maxExposureUsdt: Decimal.zero,
      feeRate: Decimal.parse('0.001'),
      fundingRatePerTick: Decimal.zero,
      minHedgeQuantity: Decimal.zero,
    );
  }
}

class LiveSpotGridRuntimeSummary {
  const LiveSpotGridRuntimeSummary({
    required this.statusText,
    required this.exchangeSubmitted,
    required this.activeOpenOrders,
    required this.waitingOrders,
    required this.completedOrders,
    required this.lastChangedAt,
    required this.lastSuccess,
    required this.lastError,
  });

  final String statusText;
  final bool exchangeSubmitted;
  final int activeOpenOrders;
  final int waitingOrders;
  final int completedOrders;
  final DateTime? lastChangedAt;
  final String lastSuccess;
  final String lastError;
}

class LiveSpotBtcInventory {
  const LiveSpotBtcInventory({
    required this.accountTotalBtc,
    required this.btcFree,
    required this.btcLocked,
    required this.strategyBtc,
    required this.otherStrategyBtc,
    required this.externalBtc,
    required this.unclassifiedBtc,
  });

  final Decimal accountTotalBtc;
  final Decimal btcFree;
  final Decimal btcLocked;
  final Decimal strategyBtc;
  final Decimal otherStrategyBtc;
  final Decimal externalBtc;
  final Decimal unclassifiedBtc;
}

String _baseAssetForSymbol(String symbol) {
  final normalized = symbol.toUpperCase();
  if (normalized.endsWith('USDT')) {
    return normalized.substring(0, normalized.length - 4);
  }
  return normalized;
}

const String _quoteAsset = 'USDT';

class LiveSpotGridConflict {
  const LiveSpotGridConflict({
    required this.strategyId,
    required this.name,
    required this.symbol,
    required this.baseAsset,
    required this.status,
    required this.createdAt,
    required this.startedAt,
    required this.updatedAt,
    required this.localActiveOrders,
    required this.binanceActiveOrders,
    required this.completedOrders,
    required this.cancelledOrders,
    required this.unknownOrders,
    required this.unprocessedFills,
    required this.pendingRecoveryOrders,
    required this.strategyBtc,
    required this.unclassifiedBtc,
    required this.lastReconcileAt,
    required this.lastError,
    required this.canMarkStopped,
    required this.safeToArchive,
    required this.isGhostCandidate,
    required this.blockingReasons,
  });

  final String strategyId;
  final String name;
  final String symbol;
  final String baseAsset;
  final String status;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime updatedAt;
  final int localActiveOrders;
  final int binanceActiveOrders;
  final int completedOrders;
  final int cancelledOrders;
  final int unknownOrders;
  final int unprocessedFills;
  final int pendingRecoveryOrders;
  final Decimal strategyBtc;
  final Decimal unclassifiedBtc;
  final DateTime? lastReconcileAt;
  final String? lastError;
  final bool canMarkStopped;
  final bool safeToArchive;
  final bool isGhostCandidate;
  final List<String> blockingReasons;
}

class LiveSpotGridStartStepUpdate {
  const LiveSpotGridStartStepUpdate(this.step, this.status, {this.message});

  final String step;
  final String status;
  final String? message;
}

class LiveSpotGridDryRunLevel {
  const LiveSpotGridDryRunLevel({
    required this.gridIndex,
    required this.side,
    required this.price,
    required this.quantity,
    required this.notional,
    required this.valid,
    required this.reason,
  });

  final int gridIndex;
  final String side;
  final Decimal price;
  final Decimal quantity;
  final Decimal notional;
  final bool valid;
  final String reason;
}

class LiveSpotGridDryRunReport {
  const LiveSpotGridDryRunReport({
    required this.symbol,
    required this.ok,
    required this.failures,
    required this.gridIntervalCount,
    required this.gridLevelCount,
    required this.initialActiveOrderCount,
    required this.maxOpenOrders,
    required this.initialBuyOrderCount,
    required this.initialSellOrderCount,
    required this.currentPrice,
    required this.lowerPrice,
    required this.upperPrice,
    required this.levels,
    required this.initialBtcRequired,
    required this.availableBtc,
    required this.availableUsdt,
    required this.estimatedFirstOrderCount,
    required this.estimatedReservedUsdt,
    required this.estimatedReservedBtc,
    required this.estimatedFeeUsdt,
    required this.exchangeOpenOrderCount,
    required this.unknownOpenOrderCount,
    required this.externalBtc,
    required this.unclassifiedBtc,
  });

  final String symbol;
  final bool ok;
  final List<String> failures;
  final int gridIntervalCount;
  final int gridLevelCount;
  final int initialActiveOrderCount;
  final int maxOpenOrders;
  final int initialBuyOrderCount;
  final int initialSellOrderCount;
  final Decimal currentPrice;
  final Decimal lowerPrice;
  final Decimal upperPrice;
  final List<LiveSpotGridDryRunLevel> levels;
  final Decimal initialBtcRequired;
  final Decimal availableBtc;
  final Decimal availableUsdt;
  final int estimatedFirstOrderCount;
  final Decimal estimatedReservedUsdt;
  final Decimal estimatedReservedBtc;
  final Decimal estimatedFeeUsdt;
  final int exchangeOpenOrderCount;
  final int unknownOpenOrderCount;
  final Decimal externalBtc;
  final Decimal unclassifiedBtc;

  String toDisplayText() {
    final baseAsset = _baseAssetForSymbol(symbol);
    final buffer = StringBuffer()
      ..writeln(ok ? '启动预演通过' : '启动预演失败')
      ..writeln('gridIntervalCount 价格区间数量: $gridIntervalCount')
      ..writeln('gridLevelCount 价格节点数量: $gridLevelCount')
      ..writeln(
        'initialActiveOrderCount 启动提交订单数量: $initialActiveOrderCount',
      )
      ..writeln('maxOpenOrders 最大活动挂单数量: $maxOpenOrders')
      ..writeln('首次 BUY 单数: $initialBuyOrderCount')
      ..writeln('启动直接提交 SELL 单数: 0（SELL 只在对应 BUY 成交后创建）')
      ..writeln('当前价格: $currentPrice')
      ..writeln('区间: $lowerPrice - $upperPrice')
      ..writeln('初始 $baseAsset 需要量: $initialBtcRequired')
      ..writeln('账户可用 $baseAsset: $availableBtc')
      ..writeln('账户可用 USDT: $availableUsdt')
      ..writeln('外部 $baseAsset: $externalBtc')
      ..writeln('未分类 $baseAsset: $unclassifiedBtc')
      ..writeln('预计首次挂单数量: $estimatedFirstOrderCount')
      ..writeln('预计占用 USDT: $estimatedReservedUsdt')
      ..writeln('预计占用 $baseAsset: $estimatedReservedBtc')
      ..writeln('预计手续费: $estimatedFeeUsdt USDT')
      ..writeln('交易所 $symbol 挂单: $exchangeOpenOrderCount')
      ..writeln('未知 $symbol 挂单: $unknownOpenOrderCount');
    if (failures.isNotEmpty) {
      buffer.writeln('失败项:');
      for (final failure in failures) {
        buffer.writeln('- $failure');
      }
    }
    buffer.writeln('网格明细:');
    for (final level in levels) {
      buffer.writeln(
        '#${level.gridIndex} ${level.side} price=${level.price} '
        'qty=${level.quantity} amount=${level.notional} '
        '${level.valid ? 'OK' : level.reason}',
      );
    }
    return buffer.toString();
  }
}

class LiveSpotGridRecoveryReport {
  const LiveSpotGridRecoveryReport({
    required this.symbol,
    required this.safeToResume,
    required this.binanceOpenOrders,
    required this.localOpenOrders,
    required this.newFills,
    required this.statusMismatches,
    required this.missingReverseOrders,
    required this.strategyBtc,
    required this.accountBtc,
    required this.messages,
  });

  final String symbol;
  final bool safeToResume;
  final int binanceOpenOrders;
  final int localOpenOrders;
  final int newFills;
  final int statusMismatches;
  final int missingReverseOrders;
  final Decimal strategyBtc;
  final Decimal accountBtc;
  final List<String> messages;

  String toDisplayText() {
    final baseAsset = _baseAssetForSymbol(symbol);
    final buffer = StringBuffer()
      ..writeln(safeToResume ? '恢复报告: 可安全恢复' : '恢复报告: 需要人工处理')
      ..writeln('Binance 挂单数量: $binanceOpenOrders')
      ..writeln('本地挂单数量: $localOpenOrders')
      ..writeln('新发现成交: $newFills')
      ..writeln('状态不一致订单: $statusMismatches')
      ..writeln('缺失反向订单: $missingReverseOrders')
      ..writeln('strategy$baseAsset: $strategyBtc')
      ..writeln('账户 $baseAsset: $accountBtc');
    for (final message in messages) {
      buffer.writeln('- $message');
    }
    return buffer.toString();
  }
}

class LiveSpotGridResetReport {
  const LiveSpotGridResetReport({
    required this.cancelledExchangeOrders,
    required this.failedExchangeCancels,
    required this.archivedStrategies,
    required this.disabledGridLevels,
  });

  final int cancelledExchangeOrders;
  final int failedExchangeCancels;
  final int archivedStrategies;
  final int disabledGridLevels;

  String toDisplayText() {
    final buffer = StringBuffer()
      ..writeln(failedExchangeCancels == 0 ? '重置测试环境完成' : '重置测试环境未完成')
      ..writeln('已撤销 Binance 现货挂单: $cancelledExchangeOrders')
      ..writeln('撤单失败: $failedExchangeCancels')
      ..writeln('已归档 LIVE 现货网格策略: $archivedStrategies')
      ..write('已禁用本地网格计划: $disabledGridLevels');
    if (failedExchangeCancels > 0) {
      buffer
        ..writeln()
        ..write('存在撤单失败，为避免隐藏真实挂单，本地策略没有归档。请先确认 Binance 挂单状态后重试。');
    }
    return buffer.toString();
  }
}

class LiveSpotGridReplacementPreview {
  const LiveSpotGridReplacementPreview({
    required this.parentOrder,
    required this.replacementSide,
    required this.replacementPrice,
    required this.replacementQuantity,
    required this.notional,
    required this.currentBid,
    required this.currentAsk,
    required this.minQty,
    required this.minNotional,
    required this.tickSize,
    required this.stepSize,
    required this.existingReplacementOrderId,
    required this.existingReplacementIsLocalOnly,
    required this.hasDuplicateActiveOrder,
    required this.canSubmit,
    required this.reason,
  });

  final Order parentOrder;
  final String replacementSide;
  final Decimal replacementPrice;
  final Decimal replacementQuantity;
  final Decimal notional;
  final Decimal currentBid;
  final Decimal currentAsk;
  final Decimal minQty;
  final Decimal minNotional;
  final Decimal tickSize;
  final Decimal stepSize;
  final String? existingReplacementOrderId;
  final bool existingReplacementIsLocalOnly;
  final bool hasDuplicateActiveOrder;
  final bool canSubmit;
  final String reason;
}

class AutoSpotGridExecutionService {
  AutoSpotGridExecutionService({
    required this.db,
    required this.liveExecution,
    required this.liveTradingGate,
    required this.marketData,
    required this.logRepository,
    FutureGridEngine? futureGridEngine,
    GridGenerator gridGenerator = const GridGenerator(),
  })  : _gridGenerator = gridGenerator,
        futureGridEngine = futureGridEngine ??
            FutureGridEngine(db: db, liveExecution: liveExecution);

  static const environment = 'LIVE_SPOT_GRID';
  static const futuresGridEnvironment = 'LIVE_FUTURES_GRID';
  static const source = 'autoSpotGrid';
  static const futuresLongSource = 'autoFuturesLongGrid';
  static const noPositionReleasedFuturesLongBuyMessage =
      'Binance 当前没有对应 LONG 持仓，已释放本地 BUY 成交记录，不再参与生命周期计算。';
  static const clientOrderPrefix = 'GH_LIVE_GRID_SPOT_';
  static const int defaultMaxOpenOrders = 4;
  static const int defaultInitialBuyOrderCount = 2;
  static const int defaultInitialSellOrderCount = 0;
  static const int maxOpenOrders = defaultMaxOpenOrders;
  static const int initialBuyOrderCount = defaultInitialBuyOrderCount;
  static const int initialSellOrderCount = defaultInitialSellOrderCount;
  static final Decimal defaultLongEntryTriggerDistanceUsdt = Decimal.fromInt(1);
  static const String capitalLimitSettingKey = 'autoSpotGridCapitalLimitUsdt';
  static const String orderLimitSettingKey =
      LiveExchangeExecutionService.autoSpotGridOrderLimitKey;
  static const _conflictingStatuses = [
    'running',
    'starting',
    'pausedKeepOrders',
    'pausedCancelOrders',
    'reconciling',
    'stopping',
  ];
  static const _needsResolutionStatuses = [
    ..._conflictingStatuses,
    'circuitBreaker',
    'error',
  ];

  final AppDatabase db;
  final LiveExchangeExecutionService liveExecution;
  final LiveTradingGateService liveTradingGate;
  final MarketDataCoordinator marketData;
  final LogRepository logRepository;
  final GridGenerator _gridGenerator;
  final FutureGridEngine futureGridEngine;
  final OrderStateTransitionValidator _transitionValidator =
      const OrderStateTransitionValidator();
  final Uuid _uuid = const Uuid();
  final Map<String, DateTime> _outOfRangeSince = {};
  final Map<String, String> _outOfRangeSide = {};

  Future<Decimal> capitalLimit({String? symbol}) =>
      _decimalSetting(capitalLimitSettingKey, Decimal.fromInt(50), symbol);

  Future<Decimal> orderLimit({String? symbol}) =>
      liveExecution.autoSpotGridOrderLimit(symbol: symbol);

  Future<Decimal> _decimalSetting(
    String key,
    Decimal defaultValue,
    String? symbol,
  ) async {
    final binding = symbol == null
        ? null
        : await (db.select(db.symbolAccountBindings)
              ..where(
                (tbl) =>
                    tbl.symbol.equals(symbol.toUpperCase()) &
                    tbl.environment.equals('live'),
              ))
            .getSingleOrNull();
    final raw = await AppUiSettings.readScopedSettingValue(
      db,
      key: key,
      symbol: symbol,
      keyProfileId: binding?.spotKeyProfileId ?? binding?.futuresKeyProfileId,
    );
    final value = raw == null ? null : Decimal.tryParse(raw);
    if (value == null || value <= Decimal.zero) {
      return defaultValue;
    }
    return value;
  }

  Stream<Strategy?> watchActiveStrategy({String? symbol}) {
    return (db.select(db.strategies)
          ..where(
            (tbl) =>
                tbl.environment.equals(environment) &
                (symbol == null
                    ? const Constant(true)
                    : tbl.symbol.equals(symbol)) &
                tbl.status.isNotIn(['archived', 'completed']),
          )
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
          ..limit(1))
        .watchSingleOrNull();
  }

  Future<Strategy?> activeStrategy({String? symbol}) {
    return (db.select(db.strategies)
          ..where(
            (tbl) =>
                tbl.environment.equals(environment) &
                (symbol == null
                    ? const Constant(true)
                    : tbl.symbol.equals(symbol)) &
                tbl.status.isNotIn(['archived', 'completed']),
          )
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  Stream<List<GridLevel>> watchGridLevels(String strategyId) {
    return (db.select(db.gridLevels)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.gridIndex)]))
        .watch();
  }

  Stream<List<Order>> watchGridOrders(String strategyId) {
    return (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) & tbl.source.equals(source),
          ))
        .watch();
  }

  Stream<Strategy?> watchActiveFuturesGridStrategy({String? symbol}) {
    return (db.select(db.strategies)
          ..where(
            (tbl) =>
                tbl.environment.equals(futuresGridEnvironment) &
                (symbol == null
                    ? const Constant(true)
                    : tbl.symbol.equals(symbol)) &
                tbl.status.isNotIn(['archived', 'completed']),
          )
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
          ..limit(1))
        .watchSingleOrNull();
  }

  Future<void> refreshGridLifecycle(String strategyId) async {
    await _markLocalRejectedGridSubmissionsFailed(strategyId);
    await _recomputeGridLifecycle(strategyId);
  }

  Future<int> repairLocalRejectedGridSubmissions(String strategyId) async {
    final repaired = await _markLocalRejectedGridSubmissionsFailed(strategyId);
    if (repaired > 0) {
      await _recomputeGridLifecycle(strategyId);
      await _recalculateStrategyBtc(strategyId);
    }
    return repaired;
  }

  Future<void> syncGridStatus(String strategyId) async {
    final strategy = await _strategy(strategyId);
    await liveExecution.refreshSpotSnapshotForSymbol(
      strategy?.symbol ?? 'BTCUSDT',
    );
    await _syncExchangeState(strategyId);
    await _markLocalRejectedGridSubmissionsFailed(strategyId);
    await _recomputeGridLifecycle(strategyId);
    await _recalculateStrategyBtc(strategyId);
    await _processFilledOrders(strategyId);
    await CompletedGridCycleService(db).rebuildForStrategy(strategyId);
    await _recomputeGridLifecycle(strategyId);
    await _recalculateStrategyBtc(strategyId);
    await _checkOutOfRange(strategyId);
  }

  Future<String> createDefaultStrategy({
    String symbol = 'BTCUSDT',
    String name = 'BTCUSDT LIVE Spot Grid',
    String executionMode = LiveSpotGridEditableConfig.spotGridFuturesHedge,
  }) async {
    final normalizedSymbol = symbol.toUpperCase();
    final isFutures =
        executionMode == LiveSpotGridEditableConfig.futuresGridHedge;
    if (isFutures) {
      try {
        await liveExecution.ensureFuturesRules(symbol: normalizedSymbol);
      } catch (_) {}
    } else {
      await liveExecution
          .ensureSpotRules(symbol: normalizedSymbol)
          .catchError((_) => null);
    }
    final tick = marketData.currentMarketTicks[normalizedSymbol];
    final center = isFutures
        ? tick?.futures?.markPrice ?? Decimal.fromInt(60000)
        : tick?.spot?.midPrice ?? Decimal.fromInt(60000);
    final editConfig = LiveSpotGridEditableConfig.defaults(
      centerPrice: center,
      name: name,
      symbol: normalizedSymbol,
      spotCapital: await capitalLimit(symbol: normalizedSymbol),
      executionMode: executionMode,
    );
    return createStrategyFromConfig(editConfig);
  }

  Future<String> createStrategyFromConfig(
    LiveSpotGridEditableConfig editConfig,
  ) async {
    final config = editConfig.toPaperConfig();
    final isFutures = editConfig.isFuturesGridHedge;
    final strategyId =
        '${isFutures ? 'live_futures_grid' : 'live_spot_grid'}_${_uuid.v4()}';
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await db.into(db.strategies).insert(
            StrategiesCompanion.insert(
              id: strategyId,
              name: config.name,
              symbol: config.symbol,
              environment: isFutures ? futuresGridEnvironment : environment,
              status: 'idle',
              createdAt: now,
              lowerPrice: _s(config.lowerPrice),
              upperPrice: _s(config.upperPrice),
              centerPrice: _s(config.centerPrice),
              gridCount: config.gridCount,
              gridSpacingPercent: _s(config.gridSpacingPercent),
              gridMode: config.gridMode,
              spotCapital: _s(config.spotCapital),
              futuresCapital: '0',
              reserveCapital: '0',
              hedgeRatio: '0',
              maxLossUsdt: _s(config.maxLossUsdt),
              maxExposureUsdt: '0',
              strategySpotBtc: const Value('0'),
              externalSpotBtc: const Value('0'),
              updatedAt: now,
            ),
          );
      await _insertGrid(
        strategyId,
        config,
        singleGridAmount: editConfig.singleGridAmount,
        enableFutureHedgeGrid: editConfig.enableFutureHedgeGrid,
        futureGridOffset: editConfig.futureGridOffset,
        useFuturesRules: isFutures,
        futuresLeverage: editConfig.futuresLeverage,
      );
      await _saveEditableConfig(strategyId, editConfig);
    });
    return strategyId;
  }

  Future<LiveSpotGridEditableConfig?> loadEditableConfig(
    String strategyId,
  ) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      return null;
    }
    final row = await (db.select(db.appSettings)
          ..where(
            (tbl) => tbl.key.equals(_configKey(strategyId)),
          ))
        .getSingleOrNull();
    if (row == null) {
      return LiveSpotGridEditableConfig.fromStrategy(strategy);
    }
    try {
      return LiveSpotGridEditableConfig.fromJson(
        Map<String, dynamic>.from(jsonDecode(row.value) as Map),
      );
    } catch (_) {
      return LiveSpotGridEditableConfig.fromStrategy(strategy);
    }
  }

  Future<void> updateEditableConfig(
    String strategyId,
    LiveSpotGridEditableConfig editConfig,
  ) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('策略不存在');
    }
    final orders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) & tbl.source.equals(source),
          ))
        .get();
    if (!_canEditStatus(strategy.status) || orders.isNotEmpty) {
      throw StateError('当前状态不允许编辑。请先停止策略并确认没有活动订单。');
    }
    if (!editConfig.isFuturesGridHedge) {
      final capitalLimitValue = await capitalLimit(symbol: strategy.symbol);
      if (editConfig.spotCapital > capitalLimitValue) {
        throw StateError('总资金不能超过 $capitalLimitValue USDT');
      }
      final orderLimitValue = await orderLimit(symbol: strategy.symbol);
      if (editConfig.singleGridAmount > orderLimitValue) {
        throw StateError('单格金额不能超过 $orderLimitValue USDT');
      }
    }
    _validateMaxOpenOrders(editConfig);
    final config = editConfig.toPaperConfig();
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(db.strategies)
            ..where((tbl) => tbl.id.equals(strategyId)))
          .write(
        StrategiesCompanion(
          name: Value(editConfig.name),
          environment: Value(
            editConfig.isFuturesGridHedge
                ? futuresGridEnvironment
                : environment,
          ),
          lowerPrice: Value(_s(editConfig.lowerPrice)),
          upperPrice: Value(_s(editConfig.upperPrice)),
          centerPrice: Value(_s(editConfig.centerPrice)),
          gridCount: Value(editConfig.gridIntervalCount),
          gridMode: Value(editConfig.gridMode),
          spotCapital: Value(_s(editConfig.spotCapital)),
          maxLossUsdt: Value(_s(editConfig.maxLossUsdt)),
          updatedAt: Value(now),
        ),
      );
      await (db.delete(db.gridLevels)
            ..where((tbl) => tbl.strategyId.equals(strategyId)))
          .go();
      await (db.delete(db.futureGridOrders)
            ..where((tbl) => tbl.strategyId.equals(strategyId)))
          .go();
      await _insertGrid(
        strategyId,
        config,
        singleGridAmount: editConfig.singleGridAmount,
        enableFutureHedgeGrid: editConfig.enableFutureHedgeGrid,
        futureGridOffset: editConfig.futureGridOffset,
        useFuturesRules: editConfig.isFuturesGridHedge,
        futuresLeverage: editConfig.futuresLeverage,
      );
      await _saveEditableConfig(strategyId, editConfig);
    });
  }

  Future<void> updateMaxOpenOrders(String strategyId, int maxOpenOrders) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('策略不存在');
    }
    final config = await loadEditableConfig(strategyId);
    if (config == null) {
      throw StateError('策略配置不存在');
    }
    final updated = config.copyWith(maxOpenOrders: maxOpenOrders);
    _validateMaxOpenOrders(updated);
    await db.transaction(() async {
      await _saveEditableConfig(strategyId, updated);
      await (db.update(db.strategies)
            ..where(
              (tbl) => tbl.id.equals(strategyId),
            ))
          .write(StrategiesCompanion(updatedAt: Value(DateTime.now().toUtc())));
    });
  }

  Future<void> updateFuturesLeverage(String strategyId, int leverage) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('策略不存在');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    final config = await loadEditableConfig(strategyId);
    if (config == null) {
      throw StateError('策略配置不存在');
    }
    final updated = config.copyWith(futuresLeverage: leverage.clamp(1, 125));
    await db.transaction(() async {
      await _saveEditableConfig(strategyId, updated);
      await (db.update(db.strategies)
            ..where(
              (tbl) => tbl.id.equals(strategyId),
            ))
          .write(StrategiesCompanion(updatedAt: Value(DateTime.now().toUtc())));
    });
  }

  Future<void> updateFuturesLongTriggerSettings(
    String strategyId, {
    required String triggerMode,
    required Decimal triggerDistanceUsdt,
    required int prehangLevels,
    required int maxOpenOrders,
  }) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('策略不存在');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    final config = await loadEditableConfig(strategyId);
    if (config == null) {
      throw StateError('策略配置不存在');
    }
    final normalizedMode =
        triggerMode == LiveSpotGridEditableConfig.longEntryTriggerModePrehang
            ? LiveSpotGridEditableConfig.longEntryTriggerModePrehang
            : LiveSpotGridEditableConfig.longEntryTriggerModeNearPrice;
    if (triggerDistanceUsdt < Decimal.zero) {
      throw StateError('提前触发距离不能小于 0');
    }
    if (prehangLevels <= 0) {
      throw StateError('预挂层数必须大于 0');
    }
    final updated = config.copyWith(
      longEntryTriggerMode: normalizedMode,
      longEntryTriggerDistanceUsdt: triggerDistanceUsdt,
      longEntryPrehangLevels: prehangLevels,
      maxOpenOrders: maxOpenOrders,
    );
    _validateMaxOpenOrders(updated);
    await db.transaction(() async {
      await _saveEditableConfig(strategyId, updated);
      await (db.update(db.strategies)
            ..where(
              (tbl) => tbl.id.equals(strategyId),
            ))
          .write(StrategiesCompanion(updatedAt: Value(DateTime.now().toUtc())));
    });
  }

  Future<void> updateShortHedgeSettings(
    String strategyId, {
    required Decimal multiplier,
    required int spreadLevels,
  }) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('策略不存在');
    }
    final config = await loadEditableConfig(strategyId);
    if (config == null) {
      throw StateError('策略配置不存在');
    }
    final normalizedMultiplier =
        multiplier <= Decimal.zero ? Decimal.parse('1.2') : multiplier;
    final normalizedSpreadLevels = spreadLevels <= 0 ? 4 : spreadLevels;
    final updated = config.copyWith(
      shortHedgeMultiplier: normalizedMultiplier,
      shortHedgeSpreadLevels: normalizedSpreadLevels,
    );
    await db.transaction(() async {
      await _saveEditableConfig(strategyId, updated);
      await (db.update(db.strategies)
            ..where(
              (tbl) => tbl.id.equals(strategyId),
            ))
          .write(StrategiesCompanion(updatedAt: Value(DateTime.now().toUtc())));
    });
  }

  Future<void> resetFuturesLongGridErrors(String strategyId) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('策略不存在');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    await _resetStaleFuturesLongSubmissions(strategyId);
    final hasActive = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(futuresLongSource) &
                tbl.status.isIn(['new', 'partiallyFilled', 'cancelling']),
          ))
        .get();
    if (hasActive.isEmpty) {
      await _setStatus(
        strategyId,
        'error',
        lastError: '已清理本地 LONG 启动失败层，可重试启动',
      );
    }
  }

  Future<void> moveGridBandOneStep(
    String strategyId, {
    required bool up,
  }) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('策略不存在');
    }
    if (!_canEditStatus(strategy.status)) {
      throw StateError('当前状态不允许移动网格。请先停止策略并处理边缘挂单/尾单。');
    }
    final levels = await (db.select(db.gridLevels)
          ..where((tbl) => tbl.strategyId.equals(strategyId)))
        .get();
    final priced = levels
        .where((level) => _gridBuyPrice(level) != null)
        .toList(growable: false);
    if (priced.length < 2) {
      throw StateError('网格层级不足，无法按网格宽度移动。');
    }
    final sorted = [...priced]
      ..sort((a, b) => _gridBuyPrice(a)!.compareTo(_gridBuyPrice(b)!));
    final gridStep = _gridBuyPrice(sorted[1])! - _gridBuyPrice(sorted[0])!;
    if (gridStep <= Decimal.zero) {
      throw StateError('网格宽度无效，无法移动。');
    }
    final leaving = up ? sorted.first : sorted.last;
    await _ensureMovableEdgeLevel(leaving);

    final anchor = up ? sorted.last : sorted.first;
    final direction = up ? Decimal.fromInt(1) : -Decimal.fromInt(1);
    final newBuy = _gridBuyPrice(anchor)! + gridStep * direction;
    final sellStep = _gridSellPrice(anchor) == null
        ? gridStep
        : _gridSellPrice(anchor)! - _gridBuyPrice(anchor)!;
    final newSell = newBuy + sellStep;
    final config = await loadEditableConfig(strategyId);
    if (config == null) {
      throw StateError('策略配置不存在');
    }
    final movedConfig = config.copyWith(
      lowerPrice: config.lowerPrice + gridStep * direction,
      upperPrice: config.upperPrice + gridStep * direction,
      centerPrice: config.centerPrice + gridStep * direction,
    );
    final isFutures = strategy.environment == futuresGridEnvironment;
    BinanceSymbolRules? rules;
    if (isFutures) {
      try {
        rules = await liveExecution.ensureFuturesRules(symbol: strategy.symbol);
      } catch (_) {
        rules = null;
      }
    } else {
      rules = liveExecution.spotRulesForSymbol(strategy.symbol);
    }
    final perGridNotional = isFutures
        ? movedConfig.singleGridAmount *
            Decimal.fromInt(movedConfig.futuresLeverage.clamp(1, 125))
        : movedConfig.singleGridAmount;
    final qty = rules?.quantizeQuantity(
          (perGridNotional / newBuy).toDecimal(scaleOnInfinitePrecision: 8),
        ) ??
        (perGridNotional / newBuy).toDecimal(scaleOnInfinitePrecision: 8);
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.delete(db.futureGridOrders)
            ..where(
              (tbl) =>
                  tbl.spotGridOrderId.equals(leaving.id) &
                  tbl.status.isIn(['WAIT_TRIGGER', 'WAIT_OPEN']),
            ))
          .go();
      await (db.delete(db.gridLevels)
            ..where((tbl) => tbl.id.equals(leaving.id)))
          .go();
      await db.into(db.gridLevels).insert(
            GridLevelsCompanion.insert(
              id: '${strategyId}_grid_move_${_uuid.v4()}',
              strategyId: strategyId,
              gridIndex: up ? sorted.length - 1 : 0,
              price: _s(newBuy),
              nextUpperPrice: Value(_s(newSell)),
              nextLowerPrice: const Value(null),
              plannedSide: 'BUY',
              plannedQuantity: _s(qty),
              plannedQuoteAmount: _s(newBuy * qty),
              status: 'ready',
              buyPrice: Value(_s(newBuy)),
              sellPrice: Value(_s(newSell)),
              lifecycleStatus: const Value('waitingBuy'),
              activeOrderId: const Value(null),
              lastBuyOrderId: const Value(null),
              lastSellOrderId: const Value(null),
              lastCompletedOrderId: const Value(null),
              cycleNumber: const Value(0),
              createdAt: now,
              updatedAt: now,
            ),
          );
      final refreshed = await (db.select(db.gridLevels)
            ..where((tbl) => tbl.strategyId.equals(strategyId)))
          .get();
      refreshed.sort((a, b) => _gridBuyPrice(a)!.compareTo(_gridBuyPrice(b)!));
      for (var i = 0; i < refreshed.length; i += 1) {
        await (db.update(db.gridLevels)
              ..where(
                (tbl) => tbl.id.equals(refreshed[i].id),
              ))
            .write(GridLevelsCompanion(gridIndex: Value(i)));
      }
      await (db.update(db.strategies)
            ..where((tbl) => tbl.id.equals(strategyId)))
          .write(
        StrategiesCompanion(
          lowerPrice: Value(_s(movedConfig.lowerPrice)),
          upperPrice: Value(_s(movedConfig.upperPrice)),
          centerPrice: Value(_s(movedConfig.centerPrice)),
          updatedAt: Value(now),
        ),
      );
      await _saveEditableConfig(strategyId, movedConfig);
    });
    if (movedConfig.enableFutureHedgeGrid) {
      await futureGridEngine.ensureForStrategy(strategyId);
    }
  }

  Future<void> _ensureMovableEdgeLevel(GridLevel level) async {
    final orders = await (db.select(db.orders)
          ..where((tbl) => tbl.gridLevelId.equals(level.id)))
        .get();
    if (orders.isNotEmpty) {
      throw StateError('边缘网格已有订单记录，不能直接移动。请先撤单、平尾单或归档旧策略。');
    }
    final cycles = await (db.select(db.completedGridCycles)
          ..where((tbl) => tbl.gridId.equals(level.id)))
        .get();
    if (cycles.isNotEmpty) {
      throw StateError('边缘网格已有完成循环，不能直接移动。请归档旧策略或保留历史层。');
    }
    final futures = await (db.select(db.futureGridOrders)
          ..where((tbl) => tbl.spotGridOrderId.equals(level.id)))
        .get();
    final blockingFutures = futures
        .where(
          (row) => row.status != 'WAIT_TRIGGER' && row.status != 'WAIT_OPEN',
        )
        .toList(growable: false);
    if (blockingFutures.isNotEmpty) {
      throw StateError('边缘网格存在未处理空单价格层，请先在 Binance reduceOnly 平仓或处理错误记录。');
    }
  }

  void _validateMaxOpenOrders(LiveSpotGridEditableConfig config) {
    if (config.maxOpenOrders <= 0) {
      throw StateError('最大活动挂单数必须大于 0');
    }
    final maxRows = config.gridIntervalCount + 1;
    if (config.maxOpenOrders > maxRows) {
      throw StateError('最大活动挂单数不能超过价格层数量 $maxRows');
    }
  }

  Future<String> copyStrategy(String strategyId) async {
    final config = await loadEditableConfig(strategyId);
    if (config == null) {
      throw StateError('策略不存在');
    }
    final copied = LiveSpotGridEditableConfig(
      name: '${config.name} Copy',
      symbol: config.symbol,
      executionMode: config.executionMode,
      centerPrice: config.centerPrice,
      lowerPrice: config.lowerPrice,
      upperPrice: config.upperPrice,
      gridMode: config.gridMode,
      gridIntervalCount: config.gridIntervalCount,
      initialBuyOrderCount: config.initialBuyOrderCount,
      initialSellOrderCount: config.initialSellOrderCount,
      maxOpenOrders: config.maxOpenOrders,
      spotCapital: config.spotCapital,
      initialBtcRatio: config.initialBtcRatio,
      singleGridAmount: config.singleGridAmount,
      maxLossUsdt: config.maxLossUsdt,
      dailyMaxLossUsdt: config.dailyMaxLossUsdt,
      outOfRangeAction: config.outOfRangeAction,
      enableFutureHedgeGrid: config.enableFutureHedgeGrid,
      futureGridOffset: config.futureGridOffset,
      futuresLeverage: config.futuresLeverage,
      futuresPriceSource: config.futuresPriceSource,
      longEntryTriggerDistanceUsdt: config.longEntryTriggerDistanceUsdt,
      longEntryTriggerMode: config.longEntryTriggerMode,
      longEntryPrehangLevels: config.longEntryPrehangLevels,
      shortHedgeMultiplier: config.shortHedgeMultiplier,
      shortHedgeSpreadLevels: config.shortHedgeSpreadLevels,
    );
    final newId =
        '${copied.isFuturesGridHedge ? 'live_futures_grid' : 'live_spot_grid'}_${_uuid.v4()}';
    final now = DateTime.now().toUtc();
    final paper = copied.toPaperConfig();
    await db.transaction(() async {
      await db.into(db.strategies).insert(
            StrategiesCompanion.insert(
              id: newId,
              name: copied.name,
              symbol: copied.symbol,
              environment: copied.isFuturesGridHedge
                  ? futuresGridEnvironment
                  : environment,
              status: 'idle',
              createdAt: now,
              lowerPrice: _s(copied.lowerPrice),
              upperPrice: _s(copied.upperPrice),
              centerPrice: _s(copied.centerPrice),
              gridCount: copied.gridIntervalCount,
              gridSpacingPercent: paper.gridSpacingPercent.toString(),
              gridMode: copied.gridMode,
              spotCapital: _s(copied.spotCapital),
              futuresCapital: '0',
              reserveCapital: '0',
              hedgeRatio: '0',
              maxLossUsdt: _s(copied.maxLossUsdt),
              maxExposureUsdt: '0',
              strategySpotBtc: const Value('0'),
              externalSpotBtc: const Value('0'),
              updatedAt: now,
            ),
          );
      await _insertGrid(
        newId,
        paper,
        singleGridAmount: copied.singleGridAmount,
        enableFutureHedgeGrid: copied.enableFutureHedgeGrid,
        futureGridOffset: copied.futureGridOffset,
        useFuturesRules: copied.isFuturesGridHedge,
      );
      await _saveEditableConfig(newId, copied);
    });
    return newId;
  }

  Future<void> deleteStrategy(String strategyId) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) return;
    if (!_canEditStatus(strategy.status)) {
      throw StateError('当前状态不允许删除策略');
    }
    final orders = await (db.select(db.orders)
          ..where((tbl) => tbl.strategyId.equals(strategyId)))
        .get();
    if (orders.isNotEmpty) {
      throw StateError('策略已有订单审计记录，不能删除。请保留历史或复制新策略。');
    }
    await db.transaction(() async {
      await (db.delete(db.gridLevels)
            ..where((tbl) => tbl.strategyId.equals(strategyId)))
          .go();
      await (db.delete(db.futureGridOrders)
            ..where((tbl) => tbl.strategyId.equals(strategyId)))
          .go();
      await (db.delete(db.appSettings)
            ..where((tbl) => tbl.key.equals(_configKey(strategyId))))
          .go();
      await (db.delete(db.strategies)
            ..where((tbl) => tbl.id.equals(strategyId)))
          .go();
    });
  }

  Future<LiveSpotGridRuntimeSummary> runtimeSummary(String strategyId) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('策略不存在');
    }
    final orders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) & tbl.source.equals(source),
          ))
        .get();
    final active = orders
        .where(
          (order) => [
            'created',
            'submitting',
            'new',
            'partiallyFilled',
          ].contains(order.status),
        )
        .length;
    final waiting = await (db.select(db.gridLevels)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.status.isIn(['waiting', 'ready']),
          ))
        .get();
    final completed = orders.where((order) => order.status == 'filled').length;
    final submitted = orders.any(
      (order) => order.exchangeOrderId != null || order.status != 'created',
    );
    return LiveSpotGridRuntimeSummary(
      statusText: statusText(strategy.status),
      exchangeSubmitted: submitted,
      activeOpenOrders: active,
      waitingOrders: waiting.length,
      completedOrders: completed,
      lastChangedAt: strategy.updatedAt,
      lastSuccess: _lastSuccessFor(strategy.status),
      lastError: strategy.lastError ?? '-',
    );
  }

  Future<LiveSpotBtcInventory> loadBtcInventory(String strategyId) async {
    final snapshot = await _latestSpotSnapshot();
    final strategy = await _strategy(strategyId);
    final symbol = strategy?.symbol ?? 'BTCUSDT';
    final baseAsset = _baseAssetForSymbol(symbol);
    final baseAssetRow = await _latestAccountAsset(baseAsset);
    final otherStrategies = await (db.select(db.strategies)
          ..where(
            (tbl) =>
                tbl.environment.equals(environment) &
                tbl.symbol.equals(symbol) &
                tbl.id.equals(strategyId).not(),
          ))
        .get();
    final otherStrategyBtc = otherStrategies.fold<Decimal>(
      Decimal.zero,
      (sum, row) => sum + _d(row.strategySpotBtc),
    );
    final accountTotal = baseAsset == 'BTC'
        ? (snapshot == null ? Decimal.zero : _d(snapshot.accountTotalBtc))
        : _assetTotal(baseAssetRow);
    final baseFree = baseAsset == 'BTC'
        ? (snapshot == null ? Decimal.zero : _d(snapshot.btcFree))
        : _assetFree(baseAssetRow);
    final baseLocked = baseAsset == 'BTC'
        ? (snapshot == null ? Decimal.zero : _d(snapshot.btcLocked))
        : _assetLocked(baseAssetRow);
    final unclassified = baseAsset == 'BTC'
        ? (snapshot == null ? Decimal.zero : _d(snapshot.unclassifiedBtc))
        : accountTotal -
            otherStrategyBtc -
            (strategy == null ? Decimal.zero : _d(strategy.strategySpotBtc)) -
            (strategy == null ? Decimal.zero : _d(strategy.externalSpotBtc));
    return LiveSpotBtcInventory(
      accountTotalBtc: accountTotal,
      btcFree: baseFree,
      btcLocked: baseLocked,
      strategyBtc:
          strategy == null ? Decimal.zero : _d(strategy.strategySpotBtc),
      otherStrategyBtc: otherStrategyBtc,
      externalBtc:
          strategy == null ? Decimal.zero : _d(strategy.externalSpotBtc),
      unclassifiedBtc:
          unclassified < Decimal.zero ? Decimal.zero : unclassified,
    );
  }

  Future<void> confirmBtcInventory({
    required String strategyId,
    required Decimal strategyBtc,
    required Decimal externalBtc,
  }) async {
    final snapshot = await _latestSpotSnapshot();
    final strategy = await _strategy(strategyId);
    final baseAsset = _baseAssetForSymbol(strategy?.symbol ?? 'BTCUSDT');
    final baseAssetRow = await _latestAccountAsset(baseAsset);
    if (snapshot == null && baseAssetRow == null) {
      throw StateError('缺少现货账户快照，请先刷新账户。');
    }
    if (strategyBtc < Decimal.zero || externalBtc < Decimal.zero) {
      throw StateError('$baseAsset 归属数量不能为负数。');
    }
    final total = baseAsset == 'BTC'
        ? _d(snapshot!.accountTotalBtc)
        : _assetTotal(baseAssetRow);
    final assigned = strategyBtc + externalBtc;
    if (assigned > total) {
      throw StateError(
        '策略 $baseAsset + 外部 $baseAsset 不能超过账户 $baseAsset 总量 $total。',
      );
    }
    final unclassified = total - assigned;
    final oldStrategy =
        strategy == null ? Decimal.zero : _d(strategy.strategySpotBtc);
    final oldExternal =
        strategy == null ? Decimal.zero : _d(strategy.externalSpotBtc);
    final oldUnclassified = baseAsset == 'BTC' && snapshot != null
        ? _d(snapshot.unclassifiedBtc)
        : total - oldStrategy - oldExternal;
    await db.transaction(() async {
      if (baseAsset == 'BTC' && snapshot != null) {
        await (db.update(db.spotAccountSnapshots)
              ..where((tbl) => tbl.id.equals(snapshot.id)))
            .write(
          SpotAccountSnapshotsCompanion(
            strategyTrackedBtc: Value(_s(strategyBtc)),
            externalBtc: Value(_s(externalBtc)),
            unclassifiedBtc: Value(_s(unclassified)),
          ),
        );
      }
      await (db.update(db.strategies)
            ..where((tbl) => tbl.id.equals(strategyId)))
          .write(
        StrategiesCompanion(
          strategySpotBtc: Value(_s(strategyBtc)),
          externalSpotBtc: Value(_s(externalBtc)),
          updatedAt: Value(DateTime.now().toUtc()),
          lastError: const Value(null),
        ),
      );
      final now = DateTime.now().toUtc();
      if (strategyBtc != oldStrategy) {
        await db.into(db.assetClassificationEvents).insert(
              AssetClassificationEventsCompanion.insert(
                id: _uuid.v4(),
                asset: baseAsset,
                quantity: _s(_abs(strategyBtc - oldStrategy)),
                fromClassification: 'unclassified',
                toClassification: 'strategyBtc',
                strategyId: Value(strategyId),
                reason: 'user confirmed BTC classification',
                confirmedAt: now,
              ),
            );
      }
      if (externalBtc != oldExternal || unclassified != oldUnclassified) {
        await db.into(db.assetClassificationEvents).insert(
              AssetClassificationEventsCompanion.insert(
                id: _uuid.v4(),
                asset: baseAsset,
                quantity: _s(_abs(externalBtc - oldExternal)),
                fromClassification: 'unclassified',
                toClassification: 'externalBtc',
                strategyId: Value(strategyId),
                reason: 'user confirmed BTC classification',
                confirmedAt: now,
              ),
            );
      }
    });
  }

  Future<List<LiveSpotGridConflict>> conflictingLiveStrategies(
    String strategyId,
  ) async {
    final currentStrategy = await _strategy(strategyId);
    final currentSymbol = currentStrategy?.symbol;
    final rows = await (db.select(db.strategies)
          ..where(
            (tbl) =>
                tbl.environment.equals(environment) &
                tbl.id.equals(strategyId).not() &
                (currentSymbol == null
                    ? const Constant(true)
                    : tbl.symbol.equals(currentSymbol)) &
                tbl.status.isIn(_needsResolutionStatuses),
          ))
        .get();
    final conflicts = <LiveSpotGridConflict>[];
    for (final row in rows) {
      final baseAsset = _baseAssetForSymbol(row.symbol);
      final inventory = await loadBtcInventory(row.id);
      final localActive = await (db.select(db.orders)
            ..where(
              (tbl) =>
                  tbl.strategyId.equals(row.id) &
                  tbl.status.isIn([
                    'created',
                    'submitting',
                    'new',
                    'partiallyFilled',
                    'cancelling',
                  ]),
            ))
          .get();
      final completed = await (db.select(db.orders)
            ..where(
              (tbl) =>
                  tbl.strategyId.equals(row.id) &
                  tbl.source.equals(source) &
                  tbl.status.equals('filled'),
            ))
          .get();
      final cancelled = await (db.select(db.orders)
            ..where(
              (tbl) =>
                  tbl.strategyId.equals(row.id) &
                  tbl.source.equals(source) &
                  tbl.status.equals('cancelled'),
            ))
          .get();
      final unknown = await (db.select(db.orders)
            ..where(
              (tbl) =>
                  tbl.strategyId.equals(row.id) &
                  tbl.source.equals(source) &
                  tbl.status.equals('unknown'),
            ))
          .get();
      final binanceActive = await (db.select(db.exchangeOpenOrders)
            ..where(
              (tbl) =>
                  tbl.environment.equals('live') &
                  tbl.marketType.equals('spot') &
                  tbl.symbol.equals(row.symbol) &
                  tbl.clientOrderId.like('$clientOrderPrefix%'),
            ))
          .get();
      final lastReconcile = await (db.select(db.reconciliationRuns)
            ..where((tbl) => tbl.summaryJson.like('%${row.id}%'))
            ..orderBy([(tbl) => OrderingTerm.desc(tbl.startedAt)])
            ..limit(1))
          .getSingleOrNull();
      final strategyBtc = _d(row.strategySpotBtc);
      final unclassifiedBtc = inventory.unclassifiedBtc;
      const unprocessedFills = 0;
      const pendingRecoveryOrders = 0;
      final blockingReasons = <String>[];
      if (binanceActive.isNotEmpty) {
        blockingReasons.add('Binance 关联活动挂单数=${binanceActive.length}');
      }
      if (localActive.isNotEmpty) {
        blockingReasons.add('本地活动订单数=${localActive.length}');
      }
      if (unknown.isNotEmpty) {
        blockingReasons.add('存在 unknown 订单=${unknown.length}');
      }
      if (unprocessedFills > 0) {
        blockingReasons.add('存在未处理 fills=$unprocessedFills');
      }
      if (pendingRecoveryOrders > 0) {
        blockingReasons.add('存在 pendingRecoveryOrder=$pendingRecoveryOrders');
      }
      if (strategyBtc > Decimal.zero) {
        blockingReasons.add('strategyBtc=$strategyBtc 尚未处理');
      }
      if (lastReconcile == null || lastReconcile.status != 'success') {
        blockingReasons.add('最近一次 REST 对账未成功');
      }
      final canMarkStopped = blockingReasons.isEmpty;
      final isGhostCandidate = [
            'running',
            'pausedKeepOrders',
            'pausedCancelOrders',
            'reconciling',
          ].contains(row.status) &&
          binanceActive.isEmpty &&
          localActive.isEmpty &&
          strategyBtc == Decimal.zero &&
          lastReconcile?.status == 'success';
      conflicts.add(
        LiveSpotGridConflict(
          strategyId: row.id,
          name: row.name,
          symbol: row.symbol,
          baseAsset: baseAsset,
          status: row.status,
          createdAt: row.createdAt,
          startedAt: row.startedAt,
          updatedAt: row.updatedAt,
          localActiveOrders: localActive.length,
          binanceActiveOrders: binanceActive.length,
          completedOrders: completed.length,
          cancelledOrders: cancelled.length,
          unknownOrders: unknown.length,
          unprocessedFills: unprocessedFills,
          pendingRecoveryOrders: pendingRecoveryOrders,
          strategyBtc: _d(row.strategySpotBtc),
          unclassifiedBtc: unclassifiedBtc,
          lastReconcileAt:
              lastReconcile?.completedAt ?? lastReconcile?.startedAt,
          lastError: row.lastError,
          canMarkStopped: canMarkStopped,
          safeToArchive: canMarkStopped && row.status == 'stopped',
          isGhostCandidate: isGhostCandidate,
          blockingReasons: blockingReasons,
        ),
      );
    }
    return conflicts;
  }

  Future<void> markStoppedAfterNoExchangeOrders(String strategyId) async {
    await reconcile(strategyId);
    final conflict = await conflictDetails(strategyId);
    if (conflict == null) {
      return;
    }
    if (!conflict.canMarkStopped) {
      throw StateError('不满足安全停止条件：${conflict.blockingReasons.join('; ')}');
    }
    await _setStatus(
      strategyId,
      'stopped',
      stoppedAt: DateTime.now().toUtc(),
      lastError: '用户确认 Binance 无关联挂单后标记 stopped',
    );
  }

  Future<LiveSpotGridConflict?> conflictDetails(String strategyId) async {
    final row = await _strategy(strategyId);
    if (row == null) return null;
    final temp = await conflictingLiveStrategies('__none__');
    for (final item in temp) {
      if (item.strategyId == strategyId) return item;
    }
    return null;
  }

  Future<void> archiveStoppedStrategy(String strategyId) async {
    final row = await _strategy(strategyId);
    if (row == null) return;
    final conflict = await conflictDetails(strategyId);
    if (conflict != null &&
        !conflict.canMarkStopped &&
        row.status != 'stopped') {
      throw StateError('归档前必须满足安全停止条件。');
    }
    if (row.status != 'stopped' && conflict == null) {
      throw StateError('只有 stopped 或满足安全条件的旧策略可以归档。');
    }
    await _setStatus(
      strategyId,
      'archived',
      stoppedAt: DateTime.now().toUtc(),
      lastError: '用户归档旧策略；历史订单和成交保留',
    );
  }

  Future<List<Order>> strategyOrders(String strategyId) {
    return (db.select(db.orders)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .get();
  }

  Future<List<ExchangeOpenOrder>> strategyExchangeOpenOrders(
    String strategyId,
  ) async {
    final localClientIds = (await (db.select(db.orders)
              ..where(
                (tbl) =>
                    tbl.strategyId.equals(strategyId) &
                    tbl.clientOrderId.like('$clientOrderPrefix%'),
              ))
            .get())
        .map((order) => order.clientOrderId)
        .toSet();
    final strategy = await (db.select(db.strategies)
          ..where((tbl) => tbl.id.equals(strategyId)))
        .getSingleOrNull();
    final symbol = strategy?.symbol ?? 'BTCUSDT';
    final exchange = await (db.select(db.exchangeOpenOrders)
          ..where(
            (tbl) =>
                tbl.environment.equals('live') &
                tbl.marketType.equals('spot') &
                tbl.symbol.equals(symbol) &
                tbl.clientOrderId.like('$clientOrderPrefix%'),
          ))
        .get();
    if (localClientIds.isEmpty) {
      return exchange;
    }
    return exchange
        .where((order) => localClientIds.contains(order.clientOrderId))
        .toList();
  }

  Future<void> cancelStrategyExchangeOpenOrders(String strategyId) async {
    final strategy = await _strategy(strategyId);
    await liveExecution.refreshSpotSnapshotForSymbol(
      strategy?.symbol ?? 'BTCUSDT',
    );
    final orders = await strategyExchangeOpenOrders(strategyId);
    for (final order in orders) {
      if (!order.clientOrderId.startsWith(clientOrderPrefix)) {
        continue;
      }
      await liveExecution.cancelSpotOrder(order.clientOrderId);
    }
    await reconcile(strategyId);
  }

  Future<LiveSpotGridResetReport> resetForFreshStart() async {
    await liveExecution.refreshSpotSnapshot();
    final exchangeOrders = await (db.select(db.exchangeOpenOrders)
          ..where(
            (tbl) =>
                tbl.environment.equals('live') &
                tbl.marketType.equals('spot') &
                tbl.symbol.equals('BTCUSDT'),
          ))
        .get();
    var cancelled = 0;
    var failed = 0;
    for (final order in exchangeOrders) {
      try {
        await liveExecution.cancelSpotOrder(order.clientOrderId);
        cancelled += 1;
      } catch (_) {
        failed += 1;
      }
    }

    await liveExecution.refreshSpotSnapshot();
    if (failed > 0) {
      return LiveSpotGridResetReport(
        cancelledExchangeOrders: cancelled,
        failedExchangeCancels: failed,
        archivedStrategies: 0,
        disabledGridLevels: 0,
      );
    }

    final strategies = await (db.select(db.strategies)
          ..where((tbl) => tbl.environment.equals(environment)))
        .get();
    final now = DateTime.now().toUtc();
    var disabledGridLevels = 0;
    await db.transaction(() async {
      for (final strategy in strategies) {
        final levels = await (db.select(db.gridLevels)
              ..where((tbl) => tbl.strategyId.equals(strategy.id)))
            .get();
        disabledGridLevels += levels.length;
        await (db.update(db.gridLevels)
              ..where((tbl) => tbl.strategyId.equals(strategy.id)))
            .write(
          GridLevelsCompanion(
            status: const Value('disabled'),
            lifecycleStatus: const Value('paused'),
            activeOrderId: const Value(null),
            updatedAt: Value(now),
          ),
        );
        await (db.update(db.strategies)
              ..where((tbl) => tbl.id.equals(strategy.id)))
            .write(
          StrategiesCompanion(
            status: const Value('archived'),
            stoppedAt: Value(now),
            updatedAt: Value(now),
            lastError: const Value('reset for fresh start'),
          ),
        );
      }
    });
    return LiveSpotGridResetReport(
      cancelledExchangeOrders: cancelled,
      failedExchangeCancels: failed,
      archivedStrategies: strategies.length,
      disabledGridLevels: disabledGridLevels,
    );
  }

  Stream<List<ExchangeOpenOrder>> watchLiveSpotGridExchangeOpenOrders({
    required String symbol,
  }) {
    final query = db.select(db.exchangeOpenOrders)
      ..where(
        (tbl) =>
            tbl.environment.equals('live') &
            tbl.marketType.equals('spot') &
            tbl.symbol.equals(symbol.toUpperCase()) &
            tbl.clientOrderId.like('$clientOrderPrefix%'),
      );
    query.orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]);
    return query.watch();
  }

  Future<LiveSpotGridReplacementPreview> previewReplacementOrder(
    String parentOrderId,
  ) async {
    final parent = await (db.select(db.orders)
          ..where((tbl) => tbl.id.equals(parentOrderId)))
        .getSingleOrNull();
    if (parent == null) {
      throw StateError('父订单不存在: $parentOrderId');
    }
    final grid = parent.gridLevelId == null
        ? null
        : await (db.select(db.gridLevels)
              ..where(
                (tbl) => tbl.id.equals(parent.gridLevelId!),
              ))
            .getSingleOrNull();
    if (grid == null) {
      throw StateError('父订单没有关联网格，无法补单。');
    }
    final replacementSide = parent.side == 'BUY' ? 'SELL' : 'BUY';
    final reversePrice =
        parent.side == 'BUY' ? _gridSellPrice(grid) : _gridBuyPrice(grid);
    if (reversePrice == null) {
      throw StateError('当前固定网格行缺少对应反向价格。');
    }
    final existing = await _findExistingReplacementOrder(
      parent: parent,
      grid: grid,
      replacementSide: replacementSide,
      replacementPrice: reversePrice,
    );
    final rules = liveExecution.spotRulesForSymbol(parent.symbol);
    final price =
        rules == null ? reversePrice : rules.quantizePrice(reversePrice);
    final quantity = await _replacementQuantityForOrder(
      parent,
      replacementSide: replacementSide,
      price: price,
      rules: rules,
    );
    final duplicate = await _hasActiveOrderForGrid(grid.id);
    final acceptable = rules == null
        ? quantity > Decimal.zero
        : rules.isAcceptableOrder(price: price, quantity: quantity);
    final existingIsLocalOnly =
        existing != null && _isLocalOnlyReplacementCandidate(existing);
    final ticker = marketData.latestSpotTicker;
    final reason = existingIsLocalOnly
        ? '已存在本地反向订单但未提交 Binance，确认后将按当前可用余额校正数量并沿用该 clientOrderId 提交。'
        : existing != null
            ? '已存在 Binance 反向订单，将直接关联，不会重复补单。'
            : duplicate
                ? '已存在同方向同价格活动订单，禁止重复补单。'
                : acceptable
                    ? '满足补单条件。'
                    : '数量或金额不满足 minQty/minNotional。';
    return LiveSpotGridReplacementPreview(
      parentOrder: parent,
      replacementSide: replacementSide,
      replacementPrice: price,
      replacementQuantity: quantity,
      notional: price * quantity,
      currentBid: ticker?.bidPrice ?? Decimal.zero,
      currentAsk: ticker?.askPrice ?? Decimal.zero,
      minQty: rules?.minQty ?? Decimal.zero,
      minNotional: rules?.minNotional ?? Decimal.zero,
      tickSize: rules?.tickSize ?? Decimal.zero,
      stepSize: rules?.stepSize ?? Decimal.zero,
      existingReplacementOrderId: existing?.id,
      existingReplacementIsLocalOnly: existingIsLocalOnly,
      hasDuplicateActiveOrder: duplicate,
      canSubmit:
          (existingIsLocalOnly || existing == null) && !duplicate && acceptable,
      reason: reason,
    );
  }

  Future<String> createReplacementForOrder(String parentOrderId) async {
    final parent = await (db.select(db.orders)
          ..where((tbl) => tbl.id.equals(parentOrderId)))
        .getSingleOrNull();
    if (parent == null) {
      throw StateError('父订单不存在: $parentOrderId');
    }
    await liveExecution.refreshSpotSnapshotForSymbol(parent.symbol);
    await _syncExchangeState(parent.strategyId);
    final refreshed = await (db.select(db.orders)
          ..where((tbl) => tbl.id.equals(parentOrderId)))
        .getSingleOrNull();
    if (refreshed == null) {
      throw StateError('父订单不存在: $parentOrderId');
    }
    final replacementId = await _createReplacementForFilledOrder(
      refreshed,
      manual: true,
    );
    await _recomputeGridLifecycle(refreshed.strategyId);
    return replacementId;
  }

  Future<List<Fill>> strategyFills(String strategyId) {
    return (db.select(db.fills)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.tradeTime)]))
        .get();
  }

  Future<void> moveStrategyBtcToExternal(String strategyId) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) return;
    final strategyBtc = _d(strategy.strategySpotBtc);
    if (strategyBtc <= Decimal.zero) return;
    final snapshot = await _latestSpotSnapshot();
    final oldExternal = _d(strategy.externalSpotBtc);
    await db.transaction(() async {
      await (db.update(db.strategies)
            ..where((tbl) => tbl.id.equals(strategyId)))
          .write(
        StrategiesCompanion(
          strategySpotBtc: const Value('0'),
          externalSpotBtc: Value(_s(oldExternal + strategyBtc)),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      if (snapshot != null) {
        await (db.update(db.spotAccountSnapshots)
              ..where((tbl) => tbl.id.equals(snapshot.id)))
            .write(
          SpotAccountSnapshotsCompanion(
            strategyTrackedBtc: const Value('0'),
            externalBtc: Value(_s(_d(snapshot.externalBtc) + strategyBtc)),
            unclassifiedBtc: Value(_s(_d(snapshot.unclassifiedBtc))),
          ),
        );
      }
      await db.into(db.assetClassificationEvents).insert(
            AssetClassificationEventsCompanion.insert(
              id: _uuid.v4(),
              asset: 'BTC',
              quantity: _s(strategyBtc),
              fromClassification: 'strategyBtc',
              toClassification: 'externalBtc',
              strategyId: Value(strategyId),
              reason: 'user moved old strategy BTC to external BTC',
              confirmedAt: DateTime.now().toUtc(),
            ),
          );
    });
  }

  Future<void> reloadSpotRules() async {
    await liveExecution.ensureSpotRules(force: true);
  }

  Future<LiveSpotGridPreflightResult> preflight(String strategyId) async {
    await _setStatus(strategyId, 'validating');
    final issues = await preflightIssues(strategyId);
    final failures = issues
        .where((issue) => issue.failed)
        .map((issue) => issue.message)
        .toList();
    if (failures.isEmpty) {
      await _setStatus(strategyId, 'previewReady');
    } else {
      await _setStatus(strategyId, 'idle', lastError: failures.join('; '));
    }
    return LiveSpotGridPreflightResult(
      ok: failures.isEmpty,
      failures: failures,
      issues: issues,
    );
  }

  Future<List<LiveSpotGridPreflightIssue>> preflightIssues(
    String strategyId,
  ) async {
    final issues = <LiveSpotGridPreflightIssue>[];
    var blocked = false;
    final strategy = await _strategy(strategyId);
    final symbol = strategy?.symbol ?? 'BTCUSDT';
    final baseAsset = _baseAssetForSymbol(symbol);

    void addIssue(LiveSpotGridPreflightIssue issue) {
      issues.add(issue);
      if (issue.failed) {
        blocked = true;
      }
    }

    LiveSpotGridPreflightIssue blockedIssue(
      LiveSpotGridPreflightIssueType type,
      String title,
    ) {
      return LiveSpotGridPreflightIssue(
        type: type,
        title: title,
        status: 'blocked',
        message: '前置检查失败，暂不执行该项。',
      );
    }

    final ticker = marketData.latestSpotTicker;
    addIssue(
      marketData.status.overallStatus == MarketConnectionStatus.ready &&
              ticker != null
          ? LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.marketData,
              title: '公共行情',
              status: 'passed',
              message: '$symbol 现货行情正常。',
            )
          : LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.marketData,
              title: '公共行情',
              status: 'failed',
              message: '公共行情未就绪',
              details: {
                'overallStatus': marketData.status.overallStatus.name,
                'spotTicker': ticker == null ? 'missing' : 'available',
              },
            ),
    );

    final snapshot = await _latestSpotSnapshot();
    addIssue(
      snapshot == null
          ? const LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.spotRest,
              title: '现货REST',
              status: 'failed',
              message: '缺少现货账户快照，请先连接或刷新账户。',
              actionLabel: 'REST对账',
            )
          : LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.spotRest,
              title: '现货REST',
              status: 'passed',
              message: '最近快照：${snapshot.recordedAt.toLocal()}',
            ),
    );

    addIssue(
      snapshot == null
          ? const LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.spotAccountWs,
              title: '现货账户WS',
              status: 'blocked',
              message: '现货REST未就绪，暂不判断账户WS。',
            )
          : const LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.spotAccountWs,
              title: '现货账户WS',
              status: 'passed',
              message: '账户事件状态由只读连接维护，当前已有账户快照。',
            ),
    );

    addIssue(
      blocked
          ? blockedIssue(LiveSpotGridPreflightIssueType.serverTime, '服务器时间')
          : const LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.serverTime,
              title: '服务器时间',
              status: 'passed',
              message: '签名请求会使用已校准时间服务。',
            ),
    );

    if (blocked) {
      addIssue(
        blockedIssue(LiveSpotGridPreflightIssueType.exchangeRules, '交易规则'),
      );
    } else {
      try {
        await liveExecution.ensureSpotRules(symbol: symbol);
      } catch (_) {
        // Diagnostics are read below.
      }
      final diagnostics = liveExecution.spotRulesDiagnostics;
      addIssue(
        liveExecution.spotRulesForSymbol(symbol) == null
            ? LiveSpotGridPreflightIssue(
                type: LiveSpotGridPreflightIssueType.exchangeRules,
                title: '交易规则',
                status: 'failed',
                message: '$symbol 正式现货交易规则未加载。',
                actionLabel: '加载交易规则',
                details: _rulesDetails(diagnostics),
              )
            : LiveSpotGridPreflightIssue(
                type: LiveSpotGridPreflightIssueType.exchangeRules,
                title: '交易规则',
                status: 'passed',
                message: diagnostics.usingCache
                    ? '已加载 $symbol 规则，当前使用缓存。'
                    : '已加载 $symbol 规则。',
                details: _rulesDetails(diagnostics),
              ),
      );
    }

    if (blocked) {
      addIssue(blockedIssue(LiveSpotGridPreflightIssueType.sqlite, 'SQLite'));
    } else {
      try {
        await db.into(db.appSettings).insertOnConflictUpdate(
              AppSettingsCompanion.insert(
                key: 'live_grid_preflight_write_test',
                value: DateTime.now().toUtc().toIso8601String(),
                updatedAt: DateTime.now().toUtc(),
              ),
            );
        addIssue(
          const LiveSpotGridPreflightIssue(
            type: LiveSpotGridPreflightIssueType.sqlite,
            title: 'SQLite',
            status: 'passed',
            message: '本地数据库可写。',
          ),
        );
      } catch (error) {
        addIssue(
          LiveSpotGridPreflightIssue(
            type: LiveSpotGridPreflightIssueType.sqlite,
            title: 'SQLite',
            status: 'failed',
            message: '本地数据库写入失败：$error',
          ),
        );
      }
    }

    final conflicts = await conflictingLiveStrategies(strategyId);
    final blockingConflicts = conflicts
        .where(
          (item) =>
              _conflictingStatuses.contains(item.status) ||
              !item.canMarkStopped,
        )
        .toList();
    final safeResidualConflicts =
        conflicts.where((item) => !blockingConflicts.contains(item)).toList();
    addIssue(
      blockingConflicts.isEmpty
          ? const LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.conflictingStrategy,
              title: '冲突策略',
              status: 'passed',
              message: '没有阻止启动的活跃 LIVE 现货网格。',
            )
          : LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.conflictingStrategy,
              title: '冲突策略',
              status: 'failed',
              message: '找到 ${blockingConflicts.length} 条需要处理的旧 LIVE 现货网格。'
                  '${safeResidualConflicts.isEmpty ? '' : ' 另有 ${safeResidualConflicts.length} 条可安全清理的残留策略。'}',
              actionLabel: '查看冲突策略',
              details: {
                'strategies': blockingConflicts
                    .map(
                      (item) => {
                        'strategyId': item.strategyId,
                        'symbol': item.symbol,
                        'status': item.status,
                        'createdAt': item.createdAt.toIso8601String(),
                        'startedAt': item.startedAt?.toIso8601String(),
                        'localActiveOrders': item.localActiveOrders,
                        'binanceActiveOrders': item.binanceActiveOrders,
                        'strategy${item.baseAsset}':
                            item.strategyBtc.toString(),
                        'lastReconcileAt':
                            item.lastReconcileAt?.toIso8601String(),
                        'blockingReasons': item.blockingReasons,
                      },
                    )
                    .toList(),
                if (safeResidualConflicts.isNotEmpty)
                  'safeResidualStrategies': safeResidualConflicts
                      .map(
                        (item) => {
                          'strategyId': item.strategyId,
                          'status': item.status,
                        },
                      )
                      .toList(),
              },
            ),
    );

    final exchangeOpen = await (db.select(db.exchangeOpenOrders)
          ..where(
            (tbl) =>
                tbl.environment.equals('live') &
                tbl.marketType.equals('spot') &
                tbl.symbol.equals(symbol),
          ))
        .get();
    final unknownOpen = exchangeOpen
        .where(
          (order) => !order.clientOrderId.startsWith(clientOrderPrefix),
        )
        .toList();
    addIssue(
      unknownOpen.isEmpty
          ? LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.unknownOrders,
              title: 'Binance未知订单',
              status: 'passed',
              message: '没有非本程序 $symbol 现货挂单。',
            )
          : LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.unknownOrders,
              title: 'Binance未知订单',
              status: 'failed',
              message: '存在 ${unknownOpen.length} 笔非本 LIVE 网格 $symbol 挂单。',
              actionLabel: 'REST对账',
            ),
    );

    final inventory = await loadBtcInventory(strategyId);
    addIssue(
      inventory.unclassifiedBtc <= Decimal.zero
          ? LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.btcClassification,
              title: '$baseAsset归属',
              status: 'passed',
              message: '没有未分类 $baseAsset。',
            )
          : LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.btcClassification,
              title: '$baseAsset归属',
              status: 'failed',
              message:
                  '未分类$baseAsset=${inventory.unclassifiedBtc}，禁止自动认定为策略 $baseAsset。',
              actionLabel: '处理$baseAsset归属',
              details: {
                'accountTotal$baseAsset': inventory.accountTotalBtc.toString(),
                'currentStrategy$baseAsset': inventory.strategyBtc.toString(),
                'otherStrategy$baseAsset':
                    inventory.otherStrategyBtc.toString(),
                'external$baseAsset': inventory.externalBtc.toString(),
                'unclassified$baseAsset': inventory.unclassifiedBtc.toString(),
                'locked$baseAsset': inventory.btcLocked.toString(),
                'available$baseAsset': inventory.btcFree.toString(),
              },
            ),
    );

    final report = await dryRun(strategyId, skipStatusUpdate: true);
    final usdtFailures =
        report.failures.where((failure) => failure.contains('USDT')).toList();
    addIssue(
      usdtFailures.isEmpty
          ? LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.usdtBalance,
              title: 'USDT余额',
              status: 'passed',
              message: '可用USDT=${report.availableUsdt}',
            )
          : LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.usdtBalance,
              title: 'USDT余额',
              status: 'failed',
              message: usdtFailures.join('; '),
            ),
    );

    final gridFailures = report.failures
        .where(
          (failure) =>
              !failure.contains('USDT') &&
              !failure.contains('未分类 $baseAsset') &&
              !failure.contains('缺少现货交易规则') &&
              !failure.contains('公共行情') &&
              !failure.contains('现货账户快照') &&
              !failure.contains('其他 LIVE'),
        )
        .toList();
    addIssue(
      gridFailures.isEmpty
          ? LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.gridAndCapital,
              title: '网格数量和资金',
              status: 'passed',
              message:
                  '首次订单=${report.initialActiveOrderCount}，最大挂单=${report.maxOpenOrders}。',
            )
          : LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.gridAndCapital,
              title: '网格数量和资金',
              status: 'failed',
              message: gridFailures.join('; '),
            ),
    );

    addIssue(
      liveTradingGate.liveTradingEnabled.value
          ? const LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.liveTrading,
              title: 'LIVE写操作',
              status: 'passed',
              message: '真实写操作已开启。',
            )
          : const LiveSpotGridPreflightIssue(
              type: LiveSpotGridPreflightIssueType.liveTrading,
              title: 'LIVE写操作',
              status: 'failed',
              message: '真实写操作未开启',
              actionLabel: '前往开启LIVE写操作',
            ),
    );

    return issues;
  }

  Future<LiveSpotGridDryRunReport> dryRun(
    String strategyId, {
    bool skipStatusUpdate = false,
  }) async {
    final failures = <String>[];
    final strategy = await _strategy(strategyId);
    final symbol = strategy?.symbol ?? 'BTCUSDT';
    final baseAsset = _baseAssetForSymbol(symbol);
    final editConfig = await loadEditableConfig(strategyId);
    await liveExecution.ensureSpotRules(symbol: symbol).catchError((_) => null);
    final rules = liveExecution.spotRulesForSymbol(symbol);
    final ticker = marketData.latestSpotTicker;
    final snapshot = await _latestSpotSnapshot();
    final baseAssetRow = await _latestAccountAsset(baseAsset);
    final quoteAssetRow = await _latestAccountAsset(_quoteAsset);
    final current = ticker?.midPrice ?? Decimal.zero;
    final levels = <LiveSpotGridDryRunLevel>[];
    var estimatedFirstOrderCount = 0;
    var reservedUsdt = Decimal.zero;
    var reservedBtc = Decimal.zero;
    var initialBtcRequired = Decimal.zero;
    var plannedInitialBuyCount = 0;
    var plannedInitialSellCount = 0;
    var exchangeOpenOrderCount = 0;
    var unknownOpenOrderCount = 0;

    if (strategy == null) {
      failures.add('策略不存在');
    }
    if (marketData.status.overallStatus != MarketConnectionStatus.ready) {
      failures.add('公共行情未就绪');
    }
    if (ticker == null) {
      failures.add('缺少 $symbol 现货行情');
    }
    if (rules == null) {
      failures.add('缺少现货交易规则');
    }
    if (snapshot == null) {
      failures.add('缺少现货账户快照');
    }

    if (strategy != null) {
      final capitalLimitValue = await capitalLimit(symbol: symbol);
      final orderLimitValue = await orderLimit(symbol: symbol);
      if (_d(strategy.spotCapital) > capitalLimitValue) {
        failures.add('现货网格资金超过 $capitalLimitValue USDT');
      }
      if (_d(strategy.maxLossUsdt) > Decimal.fromInt(3)) {
        failures.add('最大策略亏损超过 3 USDT');
      }
      final dryRunCurrent = ticker?.midPrice ?? _d(strategy.centerPrice);
      if (dryRunCurrent <= _d(strategy.lowerPrice) ||
          dryRunCurrent >= _d(strategy.upperPrice)) {
        failures.add('当前价格不在网格区间内部');
      }
      final spacing = (_d(strategy.gridSpacingPercent) / Decimal.fromInt(100))
          .toDecimal(scaleOnInfinitePrecision: 12);
      if (dryRunCurrent - _d(strategy.lowerPrice) < dryRunCurrent * spacing) {
        failures.add('当前价格距离下限不足一格');
      }
      if (_d(strategy.upperPrice) - dryRunCurrent < dryRunCurrent * spacing) {
        failures.add('当前价格距离上限不足一格');
      }
      final otherRunning = await (db.select(db.strategies)
            ..where(
              (tbl) =>
                  tbl.environment.equals(environment) &
                  tbl.symbol.equals(strategy.symbol) &
                  tbl.id.equals(strategy.id).not() &
                  tbl.status.isIn(_conflictingStatuses),
            ))
          .get();
      if (otherRunning.isNotEmpty) {
        failures.add('已有其他 LIVE 现货网格处于运行、暂停或对账状态');
      }

      final exchangeOpen = await (db.select(db.exchangeOpenOrders)
            ..where(
              (tbl) =>
                  tbl.environment.equals('live') &
                  tbl.marketType.equals('spot') &
                  tbl.symbol.equals(strategy.symbol),
            ))
          .get();
      exchangeOpenOrderCount = exchangeOpen.length;
      unknownOpenOrderCount = exchangeOpen
          .where(
            (order) => !order.clientOrderId.startsWith(clientOrderPrefix),
          )
          .length;
      if (unknownOpenOrderCount > 0) {
        failures.add('存在非本 LIVE 网格 ${strategy.symbol} 挂单');
      }

      initialBtcRequired = ticker == null
          ? Decimal.zero
          : ((_d(strategy.spotCapital) * Decimal.parse('0.5')) /
                  ticker.askPrice)
              .toDecimal(scaleOnInfinitePrecision: 12);

      final gridLevels = await _levels(strategyId);
      final initialCandidates = _initialBuyOrderCandidates(
        gridLevels,
        dryRunCurrent,
        editConfig,
      );
      for (final level in gridLevels) {
        final buyPrice = _gridBuyPrice(level);
        final sellPrice = _gridSellPrice(level);
        final price = rules == null
            ? (buyPrice ?? _d(level.price))
            : rules.quantizePrice(buyPrice ?? _d(level.price));
        final quantity = rules == null
            ? _d(level.plannedQuantity)
            : rules.quantizeQuantity(_d(level.plannedQuantity));
        final notional = price * quantity;
        var valid = true;
        final reasons = <String>[];
        if (rules != null &&
            !rules.isAcceptableOrder(price: price, quantity: quantity)) {
          valid = false;
          reasons.add('不满足 minQty/minNotional');
          failures.add('网格 ${level.gridIndex} 不满足 minQty/minNotional');
        }
        if (notional > orderLimitValue) {
          valid = false;
          reasons.add('单笔金额超过 $orderLimitValue USDT');
          failures.add('网格 ${level.gridIndex} 单笔金额超过 $orderLimitValue USDT');
        }
        if (notional < Decimal.fromInt(5)) {
          reasons.add('单笔金额低于 5 USDT，可能因 minNotional 失败');
        }
        if (initialCandidates.contains(level.id)) {
          reservedUsdt += notional;
          plannedInitialBuyCount += 1;
          estimatedFirstOrderCount += 1;
        }
        levels.add(
          LiveSpotGridDryRunLevel(
            gridIndex: level.gridIndex,
            side: sellPrice == null ? 'BUY(no fixed sellPrice)' : 'BUY->SELL',
            price: price,
            quantity: quantity,
            notional: notional,
            valid: valid,
            reason: reasons.isEmpty ? '-' : reasons.join('; '),
          ),
        );
      }
      final configuredMaxOpenOrders =
          editConfig?.maxOpenOrders ?? defaultMaxOpenOrders;
      final configuredBuyCount =
          editConfig?.initialBuyOrderCount ?? defaultInitialBuyOrderCount;
      final configuredSellCount =
          editConfig?.initialSellOrderCount ?? defaultInitialSellOrderCount;
      if (estimatedFirstOrderCount > configuredMaxOpenOrders) {
        failures.add('预计首次挂单超过 $configuredMaxOpenOrders 笔');
      }
      if (plannedInitialBuyCount > configuredBuyCount ||
          plannedInitialSellCount > configuredSellCount) {
        failures.add(
          '首次 LIVE 验证只允许提交下方 BUY $configuredBuyCount 单；SELL 必须等待对应 BUY 成交后提交',
        );
      }
    }

    final availableBtc = baseAsset == 'BTC'
        ? (snapshot == null ? Decimal.zero : _d(snapshot.btcFree))
        : _assetFree(baseAssetRow);
    final availableUsdt = quoteAssetRow == null
        ? (snapshot == null ? Decimal.zero : _d(snapshot.usdtFree))
        : _assetFree(quoteAssetRow);
    final externalBtc =
        strategy == null ? Decimal.zero : _d(strategy.externalSpotBtc);
    final inventory =
        strategy == null ? null : await loadBtcInventory(strategy.id);
    final unclassifiedBtc = inventory?.unclassifiedBtc ?? Decimal.zero;
    if (unclassifiedBtc > Decimal.zero) {
      failures.add('存在未分类 $baseAsset，禁止自动认定为策略 $baseAsset');
    }
    if (reservedUsdt + Decimal.fromInt(25) > availableUsdt) {
      failures.add('可用 USDT 不足以建立初始库存和下方买单');
    }
    final strategyBtc =
        strategy == null ? Decimal.zero : _d(strategy.strategySpotBtc);
    final btcAfterInitialInventory = strategyBtc + initialBtcRequired;
    if (reservedBtc > btcAfterInitialInventory) {
      failures.add(
        '策略 $baseAsset 库存不足，预计 SELL 需要 $reservedBtc $baseAsset，'
        '当前 strategyBtc=$strategyBtc，初始库存预计=$initialBtcRequired。'
        '初始库存成交确认前禁止提交 SELL。',
      );
    }

    final report = LiveSpotGridDryRunReport(
      symbol: strategy?.symbol ?? 'BTCUSDT',
      ok: failures.isEmpty,
      failures: failures,
      gridIntervalCount: strategy?.gridCount ?? 0,
      gridLevelCount: (strategy?.gridCount ?? -1) + 1,
      initialActiveOrderCount: estimatedFirstOrderCount,
      maxOpenOrders: editConfig?.maxOpenOrders ?? defaultMaxOpenOrders,
      initialBuyOrderCount: plannedInitialBuyCount,
      initialSellOrderCount: plannedInitialSellCount,
      currentPrice: current,
      lowerPrice: strategy == null ? Decimal.zero : _d(strategy.lowerPrice),
      upperPrice: strategy == null ? Decimal.zero : _d(strategy.upperPrice),
      levels: levels,
      initialBtcRequired: initialBtcRequired,
      availableBtc: availableBtc,
      availableUsdt: availableUsdt,
      estimatedFirstOrderCount: estimatedFirstOrderCount,
      estimatedReservedUsdt: reservedUsdt,
      estimatedReservedBtc: reservedBtc,
      estimatedFeeUsdt:
          (reservedUsdt + reservedBtc * current) * Decimal.parse('0.001'),
      exchangeOpenOrderCount: exchangeOpenOrderCount,
      unknownOpenOrderCount: unknownOpenOrderCount,
      externalBtc: externalBtc,
      unclassifiedBtc: unclassifiedBtc,
    );
    if (strategy != null) {
      if (!skipStatusUpdate && report.ok) {
        await _setStatus(strategyId, 'previewReady');
      } else if (!skipStatusUpdate && failures.isNotEmpty) {
        await _setStatus(
          strategyId,
          strategy.status,
          lastError: failures.join('; '),
        );
      }
    }
    return report;
  }

  Future<void> start(String strategyId) async {
    await startWithProgress(strategyId);
  }

  Future<FuturesLongGridStartReport> startFuturesLongGrid(
    String strategyId,
  ) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('Strategy not found: $strategyId');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    if (!{
      'idle',
      'previewReady',
      'stopped',
      'error',
      'starting',
    }.contains(strategy.status)) {
      throw StateError('当前策略状态不允许启动合约 LONG 网格: ${strategy.status}');
    }
    final config = await loadEditableConfig(strategyId);
    if (config == null || !config.isFuturesGridHedge) {
      throw StateError('当前策略缺少合约网格配置。');
    }

    final now = DateTime.now().toUtc();
    await _setStatus(strategyId, 'starting', startedAt: now);
    try {
      await _resetStaleFuturesLongSubmissions(strategyId);
      await liveExecution.connectFuturesForSymbol(strategy.symbol);
      await liveExecution.ensureFuturesHedgeMode(strategy.symbol);
      await liveExecution.ensureFuturesRules(symbol: strategy.symbol);

      final current = _currentFuturesGridPrice(strategy);
      final levels = await _levels(strategyId);
      if (current == null) {
        await _setStatus(strategyId, 'running');
        return FuturesLongGridStartReport(
          strategyId: strategyId,
          symbol: strategy.symbol,
          submittedOrders: 0,
          activeOrders: _activeLongGridOrderCount(levels),
          waitingOrders: levels.where(_isWaitingLongBuyLevel).length,
          failures: const [],
        );
      }
      final initialCandidates = _initialFuturesLongBuyCandidates(
        levels,
        current,
        config,
      );
      var activeCount = _activeLongGridOrderCount(levels);
      var submitted = 0;
      final failures = <String>[];
      for (final level in levels) {
        if (activeCount >= config.maxOpenOrders) break;
        if (!initialCandidates.contains(level.id)) continue;
        final buyPrice = _gridBuyPrice(level);
        if (buyPrice == null) {
          continue;
        }
        try {
          await _submitFuturesLongGridLevel(
            level,
            buyPrice,
            leverage: config.futuresLeverage,
          );
          activeCount += 1;
          submitted += 1;
        } catch (error) {
          failures.add('${level.buyPrice ?? level.price}: $error');
        }
      }

      final refreshed = await _levels(strategyId);
      final waiting = refreshed
          .where(
            (level) =>
                _gridBuyPrice(level) != null &&
                _gridBuyPrice(level)! < current &&
                _isWaitingLongBuyLevel(level),
          )
          .length;
      final refreshedActive = _activeLongGridOrderCount(refreshed);
      if (failures.isEmpty) {
        await _setStatus(strategyId, 'running');
        await logRepository.append(
          strategyId: strategyId,
          level: 'info',
          module: 'AUTO_FUTURES_LONG_GRID',
          message:
              'LIVE futures long grid started: submitted=$submitted active=$refreshedActive',
        );
      } else {
        await _setStatus(
          strategyId,
          'error',
          lastError: '合约 LONG 网格启动部分失败: ${failures.join('; ')}',
        );
      }
      return FuturesLongGridStartReport(
        strategyId: strategyId,
        symbol: strategy.symbol,
        submittedOrders: submitted,
        activeOrders: refreshedActive,
        waitingOrders: waiting,
        failures: failures,
      );
    } catch (error) {
      await _setStatus(
        strategyId,
        'error',
        lastError: '合约 LONG 网格启动失败: $error',
      );
      rethrow;
    }
  }

  Future<FuturesLongGridStopReport> stopFuturesLongGridCancelOpenOrders(
    String strategyId,
  ) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('Strategy not found: $strategyId');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }

    final now = DateTime.now().toUtc();
    await _setStatus(strategyId, 'stopping');

    final orders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(futuresLongSource) &
                tbl.marketType.equals('usdtFutures') &
                tbl.side.equals('BUY') &
                tbl.purpose.equals('futuresLongGridBuy') &
                tbl.status.isIn([
                  'created',
                  'submitting',
                  'new',
                  'partiallyFilled',
                  'unknown',
                ]),
          ))
        .get();
    var cancelled = 0;
    var partialFilled = 0;
    var resetLevels = 0;
    final failures = <String>[];

    for (final order in orders) {
      final executed = _d(order.executedQuantity);
      try {
        await liveExecution.cancelFuturesOrder(
          order.clientOrderId,
          symbol: order.symbol,
        );
        cancelled += 1;
        if (executed > Decimal.zero) {
          partialFilled += 1;
        }
        if (order.gridLevelId != null && order.gridLevelId!.isNotEmpty) {
          await _markFuturesLongGridLevelAfterCancel(
            order.gridLevelId!,
            executedQuantity: executed,
            cancelledOrderId: order.id,
          );
          if (executed == Decimal.zero) {
            resetLevels += 1;
          }
        }
      } catch (error) {
        failures.add('${order.price ?? order.clientOrderId}: $error');
        await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
            .write(
          OrdersCompanion(
            status: const Value('unknown'),
            updatedAt: Value(DateTime.now().toUtc()),
            errorMessage: Value('Stop futures long grid cancel failed: $error'),
          ),
        );
      }
    }

    if (failures.isEmpty) {
      await _setStatus(
        strategyId,
        'stopped',
        stoppedAt: now,
        lastError: '已停止并撤销未成交 LONG 挂单',
      );
      await logRepository.append(
        strategyId: strategyId,
        level: 'info',
        module: 'AUTO_FUTURES_LONG_GRID',
        message:
            'LIVE futures long grid stopped: cancelled=$cancelled partialFilled=$partialFilled resetLevels=$resetLevels',
      );
    } else {
      await _setStatus(
        strategyId,
        'error',
        lastError: '停止并撤销 LONG 挂单部分失败: ${failures.join('; ')}',
      );
    }

    return FuturesLongGridStopReport(
      strategyId: strategyId,
      symbol: strategy.symbol,
      cancelledOrders: cancelled,
      partialFilledOrders: partialFilled,
      resetLevels: resetLevels,
      failures: failures,
    );
  }

  Future<FuturesPositionCloseReport> closeFuturesLongPosition(
    String strategyId,
  ) {
    return _closeFuturesPosition(strategyId, positionSide: 'LONG');
  }

  Future<FuturesPositionCloseReport> closeFuturesShortPosition(
    String strategyId,
  ) {
    return _closeFuturesPosition(strategyId, positionSide: 'SHORT');
  }

  Future<FuturesPositionCloseReport> _closeFuturesPosition(
    String strategyId, {
    required String positionSide,
  }) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('Strategy not found: $strategyId');
    }
    final normalizedSide = positionSide.toUpperCase();
    if (normalizedSide != 'LONG' && normalizedSide != 'SHORT') {
      throw StateError('Unsupported futures position side: $positionSide');
    }
    await liveExecution.refreshFuturesSnapshotForSymbol(
      strategy.symbol,
      includeHistory: false,
    );
    final quantity = normalizedSide == 'LONG'
        ? await liveExecution.currentFuturesLongQuantity(strategy.symbol)
        : await liveExecution.currentFuturesShortQuantity(strategy.symbol);
    if (quantity <= Decimal.zero) {
      return FuturesPositionCloseReport(
        strategyId: strategyId,
        symbol: strategy.symbol,
        positionSide: normalizedSide,
        quantity: Decimal.zero,
        orderId: null,
      );
    }
    final orderId = await liveExecution.placeFuturesMarketOrder(
      side: normalizedSide == 'LONG' ? 'SELL' : 'BUY',
      quantity: quantity,
      reduceOnly: true,
      symbol: strategy.symbol,
      positionSide: normalizedSide,
      strategyId: strategyId,
      source: normalizedSide == 'LONG' ? futuresLongSource : 'autoHedge',
      purpose: normalizedSide == 'LONG'
          ? 'manualCloseFuturesLong'
          : 'manualCloseFuturesShort',
    );
    await liveExecution.refreshFuturesSnapshotForSymbol(
      strategy.symbol,
      includeHistory: false,
    );
    await logRepository.append(
      strategyId: strategyId,
      level: 'warning',
      module: 'AUTO_FUTURES_POSITION',
      message:
          'Manual reduceOnly market close submitted: side=$normalizedSide quantity=$quantity order=$orderId',
    );
    return FuturesPositionCloseReport(
      strategyId: strategyId,
      symbol: strategy.symbol,
      positionSide: normalizedSide,
      quantity: quantity,
      orderId: orderId,
    );
  }

  Future<String> submitWaitingFuturesLongGridLevel(String gridLevelId) async {
    var level = await (db.select(db.gridLevels)
          ..where((tbl) => tbl.id.equals(gridLevelId)))
        .getSingleOrNull();
    if (level == null) {
      throw StateError('网格不存在: $gridLevelId');
    }
    final strategy = await _strategy(level.strategyId);
    if (strategy == null) {
      throw StateError('策略不存在: ${level.strategyId}');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    if (!_isWaitingLongBuyLevel(level)) {
      final repaired = await _repairFuturesLongBuyLevelForResubmit(level);
      if (!repaired) {
        throw StateError('该价格层当前不是等待开多状态，不能挂 LONG BUY。');
      }
      level = await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(gridLevelId)))
          .getSingleOrNull();
      if (level == null || !_isWaitingLongBuyLevel(level)) {
        throw StateError('该价格层数据库状态恢复失败，不能挂 LONG BUY。');
      }
    }
    final buyPrice = _gridBuyPrice(level);
    if (buyPrice == null || buyPrice <= Decimal.zero) {
      throw StateError('该价格层缺少合法 LONG BUY 价格。');
    }
    final config = await loadEditableConfig(strategy.id);
    await liveExecution.ensureFuturesHedgeMode(strategy.symbol);
    await liveExecution.ensureFuturesRules(symbol: strategy.symbol);
    return _submitFuturesLongGridLevel(
      level,
      buyPrice,
      leverage: config?.futuresLeverage ?? 1,
    );
  }

  Future<String> submitFuturesLongCloseGridLevel(
    String gridLevelId, {
    bool verifyAvailableQuantity = true,
  }) async {
    var level = await (db.select(db.gridLevels)
          ..where((tbl) => tbl.id.equals(gridLevelId)))
        .getSingleOrNull();
    if (level == null) {
      throw StateError('网格不存在: $gridLevelId');
    }
    final strategy = await _strategy(level.strategyId);
    if (strategy == null) {
      throw StateError('策略不存在: ${level.strategyId}');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    var status = level.lifecycleStatus ?? level.status;
    if (status != 'buyFilled') {
      await _recomputeFuturesLongGridLifecycle(strategy.id);
      level = await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(gridLevelId)))
          .getSingleOrNull();
      if (level == null) {
        throw StateError('网格不存在: $gridLevelId');
      }
      status = level.lifecycleStatus ?? level.status;
    }
    if (status != 'buyFilled') {
      throw StateError('该价格层尚未完成开多，不能补平多。');
    }
    final activeCount = await _activeFuturesLongOrderCountForGrid(level.id);
    if (activeCount > 0) {
      throw StateError('Grid ${level.id} 已存在活动订单，禁止重复补平多。');
    }
    final sellPrice = _gridSellPrice(level);
    if (sellPrice == null || sellPrice <= Decimal.zero) {
      throw StateError('该价格层缺少合法 LONG SELL 价格。');
    }
    final desiredQuantity = await _futuresLongCloseQuantity(level);
    if (desiredQuantity <= Decimal.zero) {
      throw StateError('该价格层没有可平多数量。');
    }
    var quantity = desiredQuantity;
    if (verifyAvailableQuantity) {
      final availability = await _futuresLongReduceAvailability(
        strategy.symbol,
      );
      final availableQuantity = availability.available;
      if (availableQuantity <= Decimal.zero) {
        if (availability.currentLong <= Decimal.zero) {
          await _releaseFuturesLongGridLevelWithoutPosition(
            level,
            reason: 'Binance 当前没有 LONG 持仓，补平多前释放回等待开多。',
          );
          throw StateError(
            '${availability.failureMessage(requestedQuantity: quantity, desiredQuantity: desiredQuantity)} '
            '已将价格层 ${level.gridIndex} 释放回等待开多（状态3），后续会重新按当前层规则开多。',
          );
        }
        await _recomputeFuturesLongGridLifecycle(strategy.id);
        throw StateError(
          '${availability.failureMessage(requestedQuantity: quantity, desiredQuantity: desiredQuantity)} '
          '未继续提交新的平多单，已将价格层 ${level.gridIndex} 恢复为已开多/等待平多；'
          '请先处理已有 reduceOnly 平多挂单或刷新 Binance 对账。',
        );
      }
      quantity = desiredQuantity < availableQuantity
          ? desiredQuantity
          : availableQuantity;
    }
    final config = await loadEditableConfig(strategy.id);
    await liveExecution.ensureFuturesHedgeMode(
      strategy.symbol,
      refreshSnapshot: verifyAvailableQuantity,
    );
    await liveExecution.ensureFuturesRules(symbol: strategy.symbol);
    final orderId = await liveExecution.placeFuturesLimitOrder(
      symbol: strategy.symbol,
      strategyId: strategy.id,
      gridLevelId: level.id,
      side: 'SELL',
      positionSide: 'LONG',
      quantity: quantity,
      price: sellPrice,
      reduceOnly: true,
      leverage: config?.futuresLeverage ?? 1,
      source: futuresLongSource,
      purpose: 'futuresLongGridSell',
    );
    final created = await (db.select(db.orders)
          ..where((tbl) => tbl.id.equals(orderId)))
        .getSingleOrNull();
    final gridStatus = _gridStatusAfterSubmit(
      side: 'SELL',
      order: created,
      submittingStatus: 'sellSubmitting',
    );
    final activeOrder = created != null &&
        [
          'created',
          'submitting',
          'new',
          'partiallyFilled',
          'unknown',
        ].contains(created.status);
    await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(gridLevelId)))
        .write(
      GridLevelsCompanion(
        status: Value(gridStatus),
        lifecycleStatus: Value(gridStatus),
        linkedOrderId: Value(orderId),
        activeOrderId: activeOrder ? Value(orderId) : const Value(null),
        lastSellOrderId: Value(orderId),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    if (_isFuturesReduceOnlyRejected(created)) {
      await _repairFuturesLongCloseReduceOnlyRejection(
        level: level,
        order: created!,
        symbol: strategy.symbol,
      );
    }
    if (_isFailedFuturesLongSubmission(created)) {
      throw StateError(_futuresLongSubmissionError(created));
    }
    return orderId;
  }

  Future<void> renewFuturesLongGridLevel(String gridLevelId) async {
    final level = await (db.select(db.gridLevels)
          ..where((tbl) => tbl.id.equals(gridLevelId)))
        .getSingleOrNull();
    if (level == null) {
      throw StateError('网格不存在: $gridLevelId');
    }
    final strategy = await _strategy(level.strategyId);
    if (strategy == null) {
      throw StateError('策略不存在: ${level.strategyId}');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    final orders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.gridLevelId.equals(level.id) &
                tbl.source.equals(futuresLongSource),
          ))
        .get();
    final activeRows = orders
        .where(
          (order) =>
              _isActiveOrder(order) &&
              !_isRepairableFuturesLongLocalOrder(order),
        )
        .toList(growable: false);
    if (activeRows.any((order) => _d(order.executedQuantity) > Decimal.zero)) {
      throw StateError('当前层仍有已成交/部分成交活动挂单，请先处理持仓后再 Renew。');
    }
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      for (final order in activeRows) {
        await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
            .write(
          OrdersCompanion(
            status: const Value('cancelled'),
            cancelledAt: Value(now),
            updatedAt: Value(now),
            errorMessage: const Value('用户 Renew 当前层，释放本地活动挂单残留。'),
          ),
        );
      }
      await _markFuturesLongBuyOrdersReleasedNoPosition(orders, updatedAt: now);
      await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(level.id)))
          .write(
        GridLevelsCompanion(
          status: const Value('waitingBuy'),
          lifecycleStatus: const Value('waitingBuy'),
          linkedOrderId: const Value(null),
          activeOrderId: const Value(null),
          lastBuyOrderId: const Value(null),
          lastSellOrderId: const Value(null),
          updatedAt: Value(now),
        ),
      );
    });
    await logRepository.append(
      strategyId: level.strategyId,
      level: 'warning',
      module: 'FUTURES_LONG_GRID',
      message: 'FUTURES_LONG_GRID_LEVEL_RENEWED_TO_WAITING_BUY',
      extraJson:
          '{"gridId":"${level.id}","gridIndex":${level.gridIndex},"reason":"manual renew"}',
    );
  }

  Future<void> _releaseFuturesLongGridLevelWithoutPosition(
    GridLevel level, {
    required String reason,
  }) async {
    final now = DateTime.now().toUtc();
    await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(level.id)))
        .write(
      GridLevelsCompanion(
        status: const Value('waitingBuy'),
        lifecycleStatus: const Value('waitingBuy'),
        linkedOrderId: const Value(null),
        activeOrderId: const Value(null),
        lastBuyOrderId: const Value(null),
        lastSellOrderId: const Value(null),
        updatedAt: Value(now),
      ),
    );
    await logRepository.append(
      strategyId: level.strategyId,
      level: 'warning',
      module: 'FUTURES_LONG_GRID',
      message: 'FUTURES_LONG_GRID_RELEASED_NO_POSITION',
      extraJson:
          '{"gridId":"${level.id}","gridIndex":${level.gridIndex},"reason":"$reason"}',
    );
  }

  Future<String> closeFuturesLongGridLevelPosition(String gridLevelId) async {
    var level = await (db.select(db.gridLevels)
          ..where((tbl) => tbl.id.equals(gridLevelId)))
        .getSingleOrNull();
    if (level == null) {
      throw StateError('网格不存在: $gridLevelId');
    }
    final strategy = await _strategy(level.strategyId);
    if (strategy == null) {
      throw StateError('策略不存在: ${level.strategyId}');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    await _recomputeFuturesLongGridLifecycle(strategy.id);
    level = await (db.select(db.gridLevels)
          ..where((tbl) => tbl.id.equals(gridLevelId)))
        .getSingleOrNull();
    if (level == null) {
      throw StateError('网格不存在: $gridLevelId');
    }
    final activeRows = await _activeFuturesLongOrdersForGrid(level.id);
    if (activeRows.isNotEmpty) {
      throw StateError('当前层仍有活动挂单，请先撤单后再按当前层平仓。');
    }
    final desiredQuantity = await _futuresLongCloseQuantity(level);
    if (desiredQuantity <= Decimal.zero) {
      await _releaseFuturesLongGridLevelWithoutPosition(
        level,
        reason: '当前层没有可识别的 LONG 成交数量，单层平仓前释放回等待开多。',
      );
      throw StateError('当前层没有可平多数量，已释放回等待开多。');
    }
    final availability = await _futuresLongReduceAvailability(strategy.symbol);
    if (availability.available <= Decimal.zero) {
      if (availability.currentLong <= Decimal.zero) {
        await _releaseFuturesLongGridLevelWithoutPosition(
          level,
          reason: 'Binance 当前没有 LONG 持仓，单层平仓前释放回等待开多。',
        );
        throw StateError(
          '${availability.failureMessage(requestedQuantity: desiredQuantity, desiredQuantity: desiredQuantity)} '
          '已将价格层 ${level.gridIndex} 释放回等待开多。',
        );
      }
      await _recomputeFuturesLongGridLifecycle(strategy.id);
      throw StateError(
        '${availability.failureMessage(requestedQuantity: desiredQuantity, desiredQuantity: desiredQuantity)} '
        '未继续提交新的平仓单，已将价格层 ${level.gridIndex} 恢复为已开多/等待平多；'
        '请先处理已有 reduceOnly 平多挂单或刷新 Binance 对账。',
      );
    }
    final quantity = desiredQuantity < availability.available
        ? desiredQuantity
        : availability.available;
    final config = await loadEditableConfig(strategy.id);
    await liveExecution.ensureFuturesHedgeMode(strategy.symbol);
    await liveExecution.ensureFuturesRules(symbol: strategy.symbol);
    final orderId = await liveExecution.placeFuturesMarketOrder(
      symbol: strategy.symbol,
      strategyId: strategy.id,
      gridLevelId: level.id,
      side: 'SELL',
      positionSide: 'LONG',
      quantity: quantity,
      reduceOnly: true,
      leverage: config?.futuresLeverage ?? 1,
      source: futuresLongSource,
      purpose: 'futuresLongGridSell',
    );
    final created = await (db.select(db.orders)
          ..where((tbl) => tbl.id.equals(orderId)))
        .getSingleOrNull();
    if (_isFailedFuturesLongSubmission(created)) {
      throw StateError(_futuresLongSubmissionError(created));
    }
    await _releaseFuturesLongGridLevelAfterClose(
      level,
      lastSellOrderId: orderId,
    );
    return orderId;
  }

  Future<int> cancelFuturesLongGridLevelOpenOrders(String gridLevelId) async {
    final level = await (db.select(db.gridLevels)
          ..where((tbl) => tbl.id.equals(gridLevelId)))
        .getSingleOrNull();
    if (level == null) {
      throw StateError('网格不存在: $gridLevelId');
    }
    final strategy = await _strategy(level.strategyId);
    if (strategy == null) {
      throw StateError('策略不存在: ${level.strategyId}');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    final activeRows = await _activeFuturesLongOrdersForGrid(level.id);
    if (activeRows.isEmpty) {
      await _releaseFuturesLongGridLevelToWaitingBuy(
        level,
        reason: '当前层没有活动挂单，按用户撤单操作释放回等待开多。',
      );
      return 0;
    }
    for (final order in activeRows) {
      if (_d(order.executedQuantity) > Decimal.zero) {
        throw StateError('当前层订单 ${order.clientOrderId} 已部分成交，不能直接撤单释放。');
      }
      try {
        await liveExecution.cancelFuturesOrder(
          order.clientOrderId,
          symbol: strategy.symbol,
        );
      } catch (error) {
        if (!_isBinanceUnknownOrder(error)) {
          rethrow;
        }
        final now = DateTime.now().toUtc();
        await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
            .write(
          OrdersCompanion(
            status: const Value('cancelled'),
            cancelledAt: Value(now),
            updatedAt: Value(now),
            errorMessage: const Value('Binance 已无此挂单，按本地残留撤单释放。'),
          ),
        );
      }
    }
    await _releaseFuturesLongGridLevelToWaitingBuy(
      level,
      reason: '用户撤销当前层活动挂单后释放回等待开多。',
    );
    return activeRows.length;
  }

  Future<void> _releaseFuturesLongGridLevelAfterClose(
    GridLevel level, {
    required String lastSellOrderId,
  }) async {
    final now = DateTime.now().toUtc();
    await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(level.id)))
        .write(
      GridLevelsCompanion(
        status: const Value('waitingBuy'),
        lifecycleStatus: const Value('waitingBuy'),
        linkedOrderId: Value(lastSellOrderId),
        activeOrderId: const Value(null),
        lastSellOrderId: Value(lastSellOrderId),
        cycleNumber: Value(level.cycleNumber + 1),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> _releaseFuturesLongGridLevelToWaitingBuy(
    GridLevel level, {
    required String reason,
  }) async {
    final now = DateTime.now().toUtc();
    await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(level.id)))
        .write(
      GridLevelsCompanion(
        status: const Value('waitingBuy'),
        lifecycleStatus: const Value('waitingBuy'),
        linkedOrderId: const Value(null),
        activeOrderId: const Value(null),
        lastBuyOrderId: const Value(null),
        lastSellOrderId: const Value(null),
        updatedAt: Value(now),
      ),
    );
    await logRepository.append(
      strategyId: level.strategyId,
      level: 'warning',
      module: 'FUTURES_LONG_GRID',
      message: 'FUTURES_LONG_GRID_LEVEL_RELEASED_TO_WAITING_BUY',
      extraJson:
          '{"gridId":"${level.id}","gridIndex":${level.gridIndex},"reason":"$reason"}',
    );
  }

  Future<int> repairReleasedFuturesLongGridLevels(String strategyId) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('Strategy not found: $strategyId');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    final orders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(futuresLongSource),
          ))
        .get();
    final repairable = orders
        .where(
          (order) =>
              order.gridLevelId != null &&
              order.gridLevelId!.isNotEmpty &&
              _isRepairableFuturesLongLocalOrder(order),
        )
        .toList(growable: false);
    if (repairable.isEmpty) {
      return 0;
    }
    await liveExecution.refreshFuturesSnapshotForSymbol(
      strategy.symbol,
      includeHistory: false,
    );
    final currentLong = await liveExecution.currentFuturesLongQuantity(
      strategy.symbol,
    );

    final ordersByGrid = <String, List<Order>>{};
    for (final order in orders) {
      final gridId = order.gridLevelId;
      if (gridId == null || gridId.isEmpty) {
        continue;
      }
      ordersByGrid.putIfAbsent(gridId, () => <Order>[]).add(order);
    }
    final now = DateTime.now().toUtc();
    var repaired = 0;
    await db.transaction(() async {
      for (final entry in ordersByGrid.entries) {
        final gridOrders = entry.value;
        if (!gridOrders.any(_isRepairableFuturesLongLocalOrder)) {
          continue;
        }
        final blocking = gridOrders.any(
          (order) =>
              _isActiveOrder(order) &&
              !_isRepairableFuturesLongLocalOrder(order),
        );
        if (blocking) {
          continue;
        }
        for (final order in gridOrders.where(
          _isRepairableFuturesLongLocalOrder,
        )) {
          if (_isActiveOrder(order)) {
            await (db.update(db.orders)
                  ..where((tbl) => tbl.id.equals(order.id)))
                .write(
              OrdersCompanion(
                status: const Value('cancelled'),
                completedAt: Value(now),
                cancelledAt: Value(now),
                updatedAt: Value(now),
              ),
            );
          }
        }
        final hasLongInventory = gridOrders.any(
          (order) =>
              (order.side == 'SELL' &&
                  _isRepairableFuturesLongLocalOrder(order) &&
                  currentLong > Decimal.zero) ||
              (order.side == 'BUY' &&
                  (order.status == 'filled' ||
                      _d(order.executedQuantity) > Decimal.zero)),
        );
        final lastFilledBuy = gridOrders
            .where(
              (order) =>
                  order.side == 'BUY' &&
                  (order.status == 'filled' ||
                      _d(order.executedQuantity) > Decimal.zero),
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        await (db.update(db.gridLevels)
              ..where((tbl) => tbl.id.equals(entry.key)))
            .write(
          GridLevelsCompanion(
            status: Value(hasLongInventory ? 'buyFilled' : 'waitingBuy'),
            lifecycleStatus: Value(
              hasLongInventory ? 'buyFilled' : 'waitingBuy',
            ),
            linkedOrderId: const Value(null),
            activeOrderId: const Value(null),
            lastBuyOrderId: hasLongInventory && lastFilledBuy.isNotEmpty
                ? Value(lastFilledBuy.first.id)
                : const Value(null),
            lastSellOrderId: const Value(null),
            updatedAt: Value(now),
          ),
        );
        repaired += 1;
      }
    });
    if (repaired > 0) {
      await logRepository.append(
        strategyId: strategyId,
        level: 'warning',
        module: 'AUTO_FUTURES_LONG_GRID',
        message: 'Repaired released futures long grid levels: $repaired',
      );
    }
    return repaired;
  }

  Future<bool> repairFuturesLongGridLevel(String gridLevelId) async {
    final level = await (db.select(db.gridLevels)
          ..where((tbl) => tbl.id.equals(gridLevelId)))
        .getSingleOrNull();
    if (level == null) {
      throw StateError('网格不存在: $gridLevelId');
    }
    final strategy = await _strategy(level.strategyId);
    if (strategy == null) {
      throw StateError('策略不存在: ${level.strategyId}');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    final orders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.gridLevelId.equals(gridLevelId) &
                tbl.source.equals(futuresLongSource),
          ))
        .get();
    final syncedFromBinance = await _repairFuturesLongGridLevelFromHistory(
      level,
      orders,
      strategy.symbol,
    );
    if (syncedFromBinance) {
      return true;
    }
    final status = level.lifecycleStatus ?? level.status;
    final activeOrderId = level.activeOrderId;
    final hasDanglingActiveOrder = activeOrderId != null &&
        activeOrderId.isNotEmpty &&
        !orders.any((order) => order.id == activeOrderId);
    final hasRepairableOrder = orders.any(_isRepairableFuturesLongLocalOrder);
    final lastFilledBuy = _lastFilledFuturesLongBuyWithoutCompletedSell(orders);
    final hasFilledBuyMismatch = lastFilledBuy != null && status != 'buyFilled';
    if (!hasRepairableOrder &&
        !hasDanglingActiveOrder &&
        !hasFilledBuyMismatch) {
      return false;
    }
    final blocking = orders.any(
      (order) =>
          _isActiveOrder(order) && !_isRepairableFuturesLongLocalOrder(order),
    );
    if (blocking) {
      return false;
    }
    final now = DateTime.now().toUtc();
    final currentLong =
        hasRepairableOrder || hasFilledBuyMismatch || status == 'buyFilled'
            ? await liveExecution.currentFuturesLongQuantity(strategy.symbol)
            : Decimal.zero;
    final hasLongInventory = currentLong > Decimal.zero;
    await db.transaction(() async {
      if (!hasLongInventory) {
        await _markFuturesLongBuyOrdersReleasedNoPosition(
          orders,
          updatedAt: now,
        );
      }
      for (final order in orders.where(_isRepairableFuturesLongLocalOrder)) {
        if (_isActiveOrder(order)) {
          await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
              .write(
            OrdersCompanion(
              status: const Value('cancelled'),
              completedAt: Value(now),
              cancelledAt: Value(now),
              updatedAt: Value(now),
            ),
          );
        }
      }
      await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(level.id)))
          .write(
        GridLevelsCompanion(
          status: Value(hasLongInventory ? 'buyFilled' : 'waitingBuy'),
          lifecycleStatus: Value(hasLongInventory ? 'buyFilled' : 'waitingBuy'),
          linkedOrderId: const Value(null),
          activeOrderId: const Value(null),
          lastBuyOrderId: hasLongInventory && lastFilledBuy != null
              ? Value(lastFilledBuy.id)
              : const Value(null),
          lastSellOrderId: const Value(null),
          updatedAt: Value(now),
        ),
      );
    });
    await logRepository.append(
      strategyId: strategy.id,
      level: 'warning',
      module: 'AUTO_FUTURES_LONG_GRID',
      message:
          'Repaired futures long grid level: grid=${level.gridIndex} id=$gridLevelId',
    );
    return true;
  }

  Future<bool> _repairFuturesLongGridLevelFromHistory(
    GridLevel level,
    List<Order> orders,
    String symbol,
  ) async {
    final normalizedSymbol = symbol.toUpperCase();
    var synced = 0;
    for (final order in orders) {
      if (_isNoPositionReleasedFuturesLongBuy(order)) {
        continue;
      }
      final historical = await (db.select(db.exchangeHistoricalOrders)
            ..where(
              (tbl) =>
                  tbl.symbol.equals(normalizedSymbol) &
                  tbl.clientOrderId.equals(order.clientOrderId),
            )
            ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
            ..limit(1))
          .getSingleOrNull();
      if (historical == null) {
        final syncedRemote = await liveExecution.syncFuturesOrderFromBinance(
          order,
        );
        if (!syncedRemote) {
          continue;
        }
        synced += 1;
        continue;
      }
      final status = _normalizeExchangeStatus(historical.status);
      await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
          .write(
        OrdersCompanion(
          exchangeOrderId: Value(historical.exchangeOrderId),
          status: Value(status),
          executedQuantity: Value(historical.executedQuantity),
          quoteQuantity: Value(historical.quoteQuantity),
          averagePrice: Value(historical.averagePrice ?? historical.price),
          updatedAt: Value(DateTime.now().toUtc()),
          completedAt: Value(status == 'filled' ? historical.updatedAt : null),
          cancelledAt: Value(
            status == 'cancelled' ? historical.updatedAt : null,
          ),
          errorCode: const Value(null),
          errorMessage: const Value(null),
        ),
      );
      synced += 1;
    }
    if (synced == 0) {
      return false;
    }
    final refreshedOrders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.gridLevelId.equals(level.id) &
                tbl.source.equals(futuresLongSource),
          ))
        .get();
    final runtime = _deriveFuturesLongGridRuntime(level, refreshedOrders);
    if (runtime.lifecycleStatus == 'buyFilled') {
      final currentLong = await liveExecution.currentFuturesLongQuantity(
        normalizedSymbol,
      );
      if (currentLong <= Decimal.zero) {
        final now = DateTime.now().toUtc();
        await db.transaction(() async {
          await _markFuturesLongBuyOrdersReleasedNoPosition(
            refreshedOrders,
            updatedAt: now,
          );
          await (db.update(db.gridLevels)
                ..where((tbl) => tbl.id.equals(level.id)))
              .write(
            GridLevelsCompanion(
              status: const Value('waitingBuy'),
              lifecycleStatus: const Value('waitingBuy'),
              linkedOrderId: const Value(null),
              activeOrderId: const Value(null),
              lastBuyOrderId: const Value(null),
              lastSellOrderId: const Value(null),
              lastCompletedOrderId: Value(runtime.lastCompletedOrderId),
              cycleNumber: Value(runtime.cycleNumber),
              updatedAt: Value(now),
            ),
          );
        });
        await logRepository.append(
          strategyId: level.strategyId,
          level: 'warning',
          module: 'AUTO_FUTURES_LONG_GRID',
          message:
              'Released futures long filled BUY without current LONG position: grid=${level.gridIndex} synced=$synced',
        );
        return true;
      }
    }
    await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(level.id)))
        .write(
      GridLevelsCompanion(
        status: Value(runtime.lifecycleStatus),
        lifecycleStatus: Value(runtime.lifecycleStatus),
        linkedOrderId: Value(runtime.currentOrderId),
        activeOrderId: Value(runtime.activeOrderId),
        lastBuyOrderId: Value(runtime.lastBuyOrderId),
        lastSellOrderId: Value(runtime.lastSellOrderId),
        lastCompletedOrderId: Value(runtime.lastCompletedOrderId),
        cycleNumber: Value(runtime.cycleNumber),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await logRepository.append(
      strategyId: level.strategyId,
      level: 'info',
      module: 'AUTO_FUTURES_LONG_GRID',
      message:
          'Repaired futures long grid level from Binance history: grid=${level.gridIndex} synced=$synced',
    );
    return true;
  }

  Future<bool> _repairFuturesLongBuyLevelForResubmit(GridLevel level) async {
    final orders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.gridLevelId.equals(level.id) &
                tbl.source.equals(futuresLongSource),
          ))
        .get();
    final status = level.lifecycleStatus ?? level.status;
    final activeOrderId = level.activeOrderId;
    final hasDanglingActiveOrder = activeOrderId != null &&
        activeOrderId.isNotEmpty &&
        !orders.any((order) => order.id == activeOrderId);
    final canRepair = orders.any(
          (order) =>
              order.side == 'BUY' &&
              _isRepairableFuturesLongLocalOrder(order) &&
              _d(order.executedQuantity) == Decimal.zero,
        ) ||
        (hasDanglingActiveOrder &&
            {
              'buySubmitting',
              'buyOpen',
              'buyPartiallyFilled',
            }.contains(status));
    if (!canRepair) {
      return false;
    }
    final blocking = orders.any(
      (order) =>
          _isActiveOrder(order) && !_isRepairableFuturesLongLocalOrder(order),
    );
    if (blocking) {
      return false;
    }
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      for (final order in orders.where(_isRepairableFuturesLongLocalOrder)) {
        if (_isActiveOrder(order)) {
          await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
              .write(
            OrdersCompanion(
              status: const Value('cancelled'),
              completedAt: Value(now),
              cancelledAt: Value(now),
              updatedAt: Value(now),
            ),
          );
        }
      }
      await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(level.id)))
          .write(
        GridLevelsCompanion(
          status: const Value('waitingBuy'),
          lifecycleStatus: const Value('waitingBuy'),
          linkedOrderId: const Value(null),
          activeOrderId: const Value(null),
          lastBuyOrderId: const Value(null),
          lastSellOrderId: const Value(null),
          updatedAt: Value(now),
        ),
      );
    });
    return true;
  }

  Future<void> _markFuturesLongBuyOrdersReleasedNoPosition(
    List<Order> orders, {
    required DateTime updatedAt,
  }) async {
    for (final order in orders) {
      if (order.source != futuresLongSource || order.side != 'BUY') {
        continue;
      }
      if (order.status != 'filled' &&
          _d(order.executedQuantity) <= Decimal.zero) {
        continue;
      }
      await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
          .write(
        OrdersCompanion(
          errorMessage: const Value(noPositionReleasedFuturesLongBuyMessage),
          updatedAt: Value(updatedAt),
        ),
      );
    }
  }

  Order? _lastFilledFuturesLongBuyWithoutCompletedSell(List<Order> orders) {
    final effective = orders
        .where((order) => !_isReleasedFuturesLongOrder(order))
        .toList(growable: false)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final lastBuy = _lastWhereOrNull(
      effective,
      (order) =>
          order.side == 'BUY' &&
          (order.status == 'filled' ||
              _d(order.executedQuantity) > Decimal.zero),
    );
    if (lastBuy == null) {
      return null;
    }
    final laterFilledSell = effective.any(
      (order) =>
          order.side == 'SELL' &&
          order.status == 'filled' &&
          order.createdAt.isAfter(lastBuy.createdAt),
    );
    return laterFilledSell ? null : lastBuy;
  }

  Future<FuturesLongGridReconcileReport> reconcileFuturesLongGrid(
    String strategyId, {
    bool autoSubmitClose = false,
    bool autoSubmitNextBuy = false,
    bool refreshFirst = true,
    bool verifyAvailableQuantity = true,
    bool validateMissingOpenOrders = true,
    bool includeHistory = true,
  }) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('Strategy not found: $strategyId');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    _debugTrace(
      'LONG_RECONCILE',
      'start strategy=$strategyId symbol=${strategy.symbol} '
          'refreshFirst=$refreshFirst includeHistory=$includeHistory '
          'validateMissingOpenOrders=$validateMissingOpenOrders '
          'autoSubmitClose=$autoSubmitClose autoSubmitNextBuy=$autoSubmitNextBuy',
    );
    if (refreshFirst) {
      await liveExecution.refreshFuturesSnapshotForSymbol(
        strategy.symbol,
        includeHistory: includeHistory,
      );
      _debugTrace(
        'LONG_RECONCILE',
        'snapshot refreshed symbol=${strategy.symbol} '
            'includeHistory=$includeHistory',
      );
    }
    if (validateMissingOpenOrders) {
      await _markMissingFuturesLongOpenOrders(strategyId, strategy.symbol);
    }

    final orders = await _futuresLongReconcileOrders(strategy);
    _debugTrace(
      'LONG_RECONCILE',
      'local orders=${orders.length} strategy=$strategyId',
    );
    var synced = 0;
    for (final order in orders) {
      if (_isNoPositionReleasedFuturesLongBuy(order)) {
        _debugTrace(
          'LONG_RECONCILE',
          'skip released order client=${order.clientOrderId} '
              'grid=${order.gridLevelId ?? '-'} side=${order.side}',
        );
        continue;
      }
      final historical = await (db.select(db.exchangeHistoricalOrders)
            ..where(
              (tbl) =>
                  tbl.accountType.equals('futuresSubAccount') &
                  tbl.marketType.equals('usdtFutures') &
                  tbl.environment.equals('live') &
                  tbl.keyProfileId.equals(
                    _profileScope(order.keyProfileId),
                  ) &
                  tbl.symbol.equals(strategy.symbol) &
                  tbl.clientOrderId.equals(order.clientOrderId),
            )
            ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
            ..limit(1))
          .getSingleOrNull();
      if (historical == null) {
        if (!_shouldDirectQueryMissingFuturesHistory(order)) {
          _debugTrace(
            'LONG_RECONCILE',
            'history miss; skip terminal/local-old client=${order.clientOrderId} '
                'grid=${order.gridLevelId ?? '-'} side=${order.side} '
                'localStatus=${order.status} profile=${_profileScope(order.keyProfileId)}',
          );
          continue;
        }
        _debugTrace(
          'LONG_RECONCILE',
          'history miss; direct query Binance client=${order.clientOrderId} '
              'grid=${order.gridLevelId ?? '-'} side=${order.side} '
              'localStatus=${order.status} profile=${_profileScope(order.keyProfileId)}',
        );
        final syncedRemote = await _trySyncFuturesOrderFromBinance(order);
        _debugTrace(
          'LONG_RECONCILE',
          'direct query result client=${order.clientOrderId} '
              'synced=$syncedRemote',
        );
        if (!syncedRemote) {
          continue;
        }
        synced += 1;
        continue;
      }
      final status = _normalizeExchangeStatus(historical.status);
      _debugTrace(
        'LONG_RECONCILE',
        'history hit client=${order.clientOrderId} '
            'grid=${order.gridLevelId ?? '-'} side=${order.side} '
            'local=${order.status} remote=${historical.status} '
            'executed=${historical.executedQuantity} '
            'profile=${_profileScope(order.keyProfileId)}',
      );
      await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
          .write(
        OrdersCompanion(
          exchangeOrderId: Value(historical.exchangeOrderId),
          status: Value(status),
          executedQuantity: Value(historical.executedQuantity),
          quoteQuantity: Value(historical.quoteQuantity),
          averagePrice: Value(historical.averagePrice ?? historical.price),
          updatedAt: Value(DateTime.now().toUtc()),
          completedAt: Value(status == 'filled' ? historical.updatedAt : null),
          cancelledAt: Value(
            status == 'cancelled' ? historical.updatedAt : null,
          ),
          errorCode: const Value(null),
          errorMessage: const Value(null),
        ),
      );
      synced += 1;
    }
    final syncedOrders = await _futuresLongReconcileOrders(strategy);
    await _recomputeFuturesLongGridLifecycle(
      strategyId,
      scopedOrders: syncedOrders,
    );
    if (autoSubmitClose) {
      await _autoSubmitFuturesLongCloseOrders(
        strategyId,
        verifyAvailableQuantity: verifyAvailableQuantity,
      );
    }
    await CompletedGridCycleService(db).rebuildForStrategy(strategyId);
    if (autoSubmitNextBuy) {
      await _autoSubmitFuturesLongNextBuyOrders(strategyId);
    }
    final recomputeOrders = await _futuresLongReconcileOrders(strategy);
    await _recomputeFuturesLongGridLifecycle(
      strategyId,
      scopedOrders: recomputeOrders,
    );

    final refreshed = await _futuresLongReconcileOrders(strategy);
    final active = refreshed.where(_isActiveOrder).length;
    final completed = refreshed
        .where((order) => {'filled', 'cancelled'}.contains(order.status))
        .length;
    final levelsById = {
      for (final level in await _levels(strategyId)) level.id: level,
    };
    final errorRows = refreshed
        .where(
          (order) => _isActionableFuturesLongError(
            order,
            level: order.gridLevelId == null
                ? null
                : levelsById[order.gridLevelId],
          ),
        )
        .toList(growable: false);
    final errors = errorRows.length;
    final errorDetails = [
      for (final order in errorRows)
        _futuresLongErrorDetail(
          order,
          level:
              order.gridLevelId == null ? null : levelsById[order.gridLevelId],
        ),
    ];
    await logRepository.append(
      strategyId: strategyId,
      level: 'info',
      module: 'AUTO_FUTURES_LONG_GRID',
      message:
          'Futures long grid reconciled: synced=$synced active=$active completed=$completed errors=$errors',
    );
    _debugTrace(
      'LONG_RECONCILE',
      'done strategy=$strategyId synced=$synced active=$active '
          'completed=$completed errors=$errors',
    );
    return FuturesLongGridReconcileReport(
      strategyId: strategyId,
      symbol: strategy.symbol,
      syncedOrders: synced,
      activeOrders: active,
      completedOrders: completed,
      errorOrders: errors,
      errorDetails: errorDetails,
    );
  }

  Future<FuturesLongGridRecoverReport> recoverAndReconcileFuturesLongGrid(
    String strategyId, {
    bool refreshFirst = true,
  }) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('Strategy not found: $strategyId');
    }
    if (strategy.environment != futuresGridEnvironment) {
      throw StateError('当前策略不是 LIVE 合约 LONG 网格策略。');
    }
    final report = await reconcileFuturesLongGrid(
      strategyId,
      autoSubmitClose: true,
      autoSubmitNextBuy: true,
      refreshFirst: refreshFirst,
      validateMissingOpenOrders: true,
    );
    final levels = await _levels(strategyId);
    final activeOrders = _activeLongGridOrderCount(levels);
    final waitingBuyLevels = levels.where(_isWaitingLongBuyLevel).length;
    final openLongLevels = levels
        .where(
          (level) => const {
            'buyFilled',
            'sellSubmitting',
            'sellOpen',
            'sellPartiallyFilled',
          }.contains(level.lifecycleStatus ?? level.status),
        )
        .length;
    final errorLevels = levels
        .where(
          (level) => (level.lifecycleStatus ?? level.status) == 'error',
        )
        .length;
    final canRestore = report.errorOrders == 0 && errorLevels == 0;
    if (canRestore) {
      await _setStatusClearError(strategyId, 'running');
      await logRepository.append(
        strategyId: strategyId,
        level: 'info',
        module: 'AUTO_FUTURES_LONG_GRID',
        message:
            'Futures long grid recovered: active=$activeOrders waiting=$waitingBuyLevels openLong=$openLongLevels',
      );
    } else {
      await _setStatus(
        strategyId,
        'error',
        lastError: '恢复并对账未完成：错误层=$errorLevels，异常订单=${report.errorOrders}',
      );
    }
    return FuturesLongGridRecoverReport(
      strategyId: strategyId,
      symbol: strategy.symbol,
      restored: canRestore,
      reconcileReport: report,
      activeOrders: activeOrders,
      waitingBuyLevels: waitingBuyLevels,
      openLongLevels: openLongLevels,
      errorLevels: errorLevels,
      message: canRestore
          ? '策略已恢复 running，并已清空旧错误。'
          : '仍存在需要处理的错误层或异常订单，策略保持 error。',
    );
  }

  Future<void> submitTriggeredFuturesLongBuyOrders(String strategyId) {
    return _autoSubmitFuturesLongNextBuyOrders(strategyId);
  }

  String _futuresLongErrorDetail(Order order, {GridLevel? level}) {
    final grid = level == null ? '-' : level.gridIndex.toString();
    final price = order.price ?? level?.buyPrice ?? level?.price ?? '-';
    final clientOrderId = order.clientOrderId;
    final message = order.errorMessage;
    final reason = message == null || message.isEmpty ? '-' : message;
    return [
      'grid=$grid',
      'side=${order.side}',
      'status=${order.status}',
      'price=$price',
      'client=$clientOrderId',
      'reason=$reason',
    ].join(' ');
  }

  bool _isActionableFuturesLongError(Order order, {GridLevel? level}) {
    if (!{'failed', 'unknown', 'rejected', 'expired'}.contains(order.status)) {
      return false;
    }
    if (_isReleasedFuturesLongOrder(order)) {
      return false;
    }
    if (level == null) {
      return true;
    }
    final levelStatus = level.lifecycleStatus ?? level.status;
    if (levelStatus == 'error') {
      return true;
    }
    if (level.activeOrderId == order.id || level.linkedOrderId == order.id) {
      return true;
    }
    if (order.side == 'BUY' &&
        level.lastBuyOrderId == order.id &&
        const {
          'buySubmitting',
          'buyOpen',
          'buyPartiallyFilled',
        }.contains(levelStatus)) {
      return true;
    }
    if (order.side == 'SELL' &&
        level.lastSellOrderId == order.id &&
        const {
          'sellSubmitting',
          'sellOpen',
          'sellPartiallyFilled',
        }.contains(levelStatus)) {
      return true;
    }
    return false;
  }

  bool _isReleasedFuturesLongOrder(Order order) {
    if (_isNoPositionReleasedFuturesLongBuy(order)) {
      return true;
    }
    if (order.status == 'filled' || _d(order.executedQuantity) > Decimal.zero) {
      return false;
    }
    final message = order.errorMessage ?? '';
    return message.contains('已释放本地网格') || message.contains('无有效活动状态');
  }

  bool _isNoPositionReleasedFuturesLongBuy(Order order) {
    final message = order.errorMessage ?? '';
    return order.source == futuresLongSource &&
        order.side == 'BUY' &&
        message.contains(noPositionReleasedFuturesLongBuyMessage);
  }

  bool _isBinanceUnknownOrder(Object error) {
    return error is BinanceRequestException && error.binanceCode == -2011;
  }

  bool _isTerminalZeroFillFuturesLongCloseOrder(Order order) {
    return order.source == futuresLongSource &&
        order.side == 'SELL' &&
        _d(order.executedQuantity) == Decimal.zero &&
        const {
          'failed',
          'rejected',
          'expired',
          'cancelled',
        }.contains(order.status);
  }

  Future<void> _autoSubmitFuturesLongCloseOrders(
    String strategyId, {
    bool verifyAvailableQuantity = true,
  }) async {
    final levels = await (db.select(db.gridLevels)
          ..where((tbl) => tbl.strategyId.equals(strategyId)))
        .get();
    for (final level in levels) {
      final status = level.lifecycleStatus ?? level.status;
      if (status != 'buyFilled') {
        continue;
      }
      final activeCount = await _activeFuturesLongOrderCountForGrid(level.id);
      if (activeCount > 0) {
        continue;
      }
      try {
        await submitFuturesLongCloseGridLevel(
          level.id,
          verifyAvailableQuantity: verifyAvailableQuantity,
        );
      } catch (error) {
        await logRepository.append(
          strategyId: strategyId,
          level: 'warning',
          module: 'AUTO_FUTURES_LONG_GRID',
          message:
              'Auto submit LONG close failed: grid=${level.id} price=${level.sellPrice ?? level.nextUpperPrice ?? '-'} error=$error',
        );
      }
    }
  }

  Future<void> _autoSubmitFuturesLongNextBuyOrders(String strategyId) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null || strategy.environment != futuresGridEnvironment) {
      return;
    }
    final config = await loadEditableConfig(strategyId);
    final maxOrders = config?.maxOpenOrders ?? defaultMaxOpenOrders;
    final targetOrders = config?.longEntryTriggerMode ==
            LiveSpotGridEditableConfig.longEntryTriggerModePrehang
        ? (config!.longEntryPrehangLevels < maxOrders
            ? config.longEntryPrehangLevels
            : maxOrders)
        : maxOrders;
    final leverage = config?.futuresLeverage ?? 1;
    final current = _currentFuturesGridPrice(strategy);
    if (current == null) {
      return;
    }
    final levels = await _levels(strategyId);
    var activeCount = _activeLongGridOrderCount(levels);
    final candidates = levels.where((level) {
      if (activeCount >= targetOrders) {
        return false;
      }
      if (level.activeOrderId != null && level.activeOrderId!.isNotEmpty) {
        return false;
      }
      if (!_isWaitingLongBuyLevel(level)) {
        return false;
      }
      final buyPrice = _gridBuyPrice(level);
      return buyPrice != null &&
          _isFuturesLongBuySubmissionEligible(
            buyPrice: buyPrice,
            currentPrice: current,
            config: config,
          );
    }).toList()
      ..sort(
        (a, b) => _abs(
          _gridBuyPrice(a)! - current,
        ).compareTo(_abs(_gridBuyPrice(b)! - current)),
      );
    for (final level in candidates) {
      if (activeCount >= targetOrders) {
        break;
      }
      final buyPrice = _gridBuyPrice(level);
      if (buyPrice == null) {
        continue;
      }
      try {
        await _submitFuturesLongGridLevel(level, buyPrice, leverage: leverage);
        activeCount += 1;
      } catch (error) {
        await logRepository.append(
          strategyId: strategyId,
          level: 'warning',
          module: 'AUTO_FUTURES_LONG_GRID',
          message:
              'Auto submit next LONG buy failed: grid=${level.id} price=$buyPrice error=$error',
        );
      }
    }
  }

  Future<void> _markMissingFuturesLongOpenOrders(
    String strategyId,
    String symbol,
  ) async {
    final normalizedSymbol = symbol.toUpperCase();
    final localOpen = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(futuresLongSource) &
                tbl.marketType.equals('usdtFutures') &
                tbl.symbol.equals(normalizedSymbol) &
                tbl.status.isIn(['new', 'partiallyFilled']),
          ))
        .get();
    if (localOpen.isEmpty) {
      return;
    }
    final exchangeOpen = await (db.select(db.exchangeOpenOrders)
          ..where(
            (tbl) =>
                tbl.accountType.equals('futuresSubAccount') &
                tbl.marketType.equals('usdtFutures') &
                tbl.environment.equals('live') &
                tbl.symbol.equals(normalizedSymbol) &
                tbl.keyProfileId.isIn(
                  localOpen.map((order) => _profileScope(order.keyProfileId)),
                ),
          ))
        .get();
    final exchangeOpenClientIds = {
      for (final order in exchangeOpen) order.clientOrderId,
    };
    _debugTrace(
      'LONG_RECONCILE',
      'validate open orders symbol=$normalizedSymbol '
          'localOpen=${localOpen.length} exchangeOpen=${exchangeOpen.length}',
    );
    final now = DateTime.now().toUtc();
    final currentLong = await liveExecution.currentFuturesLongQuantity(
      normalizedSymbol,
    );
    final hasLongInventory = currentLong > Decimal.zero;
    for (final order in localOpen) {
      if (exchangeOpenClientIds.contains(order.clientOrderId)) {
        _debugTrace(
          'LONG_RECONCILE',
          'open order still on Binance client=${order.clientOrderId} '
              'grid=${order.gridLevelId ?? '-'} side=${order.side}',
        );
        continue;
      }
      final historical = await (db.select(db.exchangeHistoricalOrders)
            ..where(
              (tbl) =>
                  tbl.accountType.equals('futuresSubAccount') &
                  tbl.marketType.equals('usdtFutures') &
                  tbl.environment.equals('live') &
                  tbl.keyProfileId.equals(
                    _profileScope(order.keyProfileId),
                  ) &
                  tbl.symbol.equals(normalizedSymbol) &
                  tbl.clientOrderId.equals(order.clientOrderId),
            )
            ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
            ..limit(1))
          .getSingleOrNull();
      var historicalStatus = historical?.status.toUpperCase();
      if (historical == null) {
        _debugTrace(
          'LONG_RECONCILE',
          'open missing + history miss; direct query client=${order.clientOrderId} '
              'grid=${order.gridLevelId ?? '-'} side=${order.side} '
              'localStatus=${order.status}',
        );
        final syncedRemote = await _trySyncFuturesOrderFromBinance(order);
        final refreshedOrder = await (db.select(db.orders)
              ..where((tbl) => tbl.id.equals(order.id)))
            .getSingleOrNull();
        _debugTrace(
          'LONG_RECONCILE',
          'direct query after open missing client=${order.clientOrderId} '
              'synced=$syncedRemote '
              'status=${refreshedOrder?.status ?? '-'} '
              'executed=${refreshedOrder?.executedQuantity ?? '-'}',
        );
        if (refreshedOrder != null &&
            {'new', 'partiallyFilled'}.contains(refreshedOrder.status)) {
          final releaseMissing = _shouldReleaseMissingFuturesLongOpenOrder(
            refreshedOrder,
            now,
          );
          if (syncedRemote || !releaseMissing) {
            _debugTrace(
              'LONG_RECONCILE',
              'keep missing open order client=${refreshedOrder.clientOrderId} '
                  'grid=${refreshedOrder.gridLevelId ?? '-'} '
                  'reason=${syncedRemote ? 'direct-sync-active' : 'protect-window'} '
                  'ageSec=${now.difference(refreshedOrder.createdAt).inSeconds}',
            );
            continue;
          }
        }
        if (refreshedOrder != null && refreshedOrder.status == 'filled') {
          continue;
        }
        historicalStatus = null;
      }
      if (historicalStatus != null &&
          {'NEW', 'PARTIALLY_FILLED'}.contains(historicalStatus)) {
        _debugTrace(
          'LONG_RECONCILE',
          'open missing but history active; direct verify client=${order.clientOrderId} '
              'remote=$historicalStatus',
        );
        final syncedRemote = await _trySyncFuturesOrderFromBinance(order);
        final refreshedOrder = await (db.select(db.orders)
              ..where((tbl) => tbl.id.equals(order.id)))
            .getSingleOrNull();
        _debugTrace(
          'LONG_RECONCILE',
          'direct verify active history client=${order.clientOrderId} '
              'synced=$syncedRemote status=${refreshedOrder?.status ?? '-'} '
              'executed=${refreshedOrder?.executedQuantity ?? '-'}',
        );
        if (refreshedOrder != null &&
            {'new', 'partiallyFilled'}.contains(refreshedOrder.status)) {
          final releaseMissing = _shouldReleaseMissingFuturesLongOpenOrder(
            refreshedOrder,
            now,
          );
          if (syncedRemote || !releaseMissing) {
            _debugTrace(
              'LONG_RECONCILE',
              'keep missing open order client=${refreshedOrder.clientOrderId} '
                  'grid=${refreshedOrder.gridLevelId ?? '-'} '
                  'reason=${syncedRemote ? 'direct-sync-active' : 'protect-window'} '
                  'history=$historicalStatus '
                  'ageSec=${now.difference(refreshedOrder.createdAt).inSeconds}',
            );
            continue;
          }
        }
        if (refreshedOrder != null && refreshedOrder.status == 'filled') {
          continue;
        }
        historicalStatus = null;
      }
      if (historical != null && historicalStatus == 'FILLED') {
        _debugTrace(
          'LONG_RECONCILE',
          'open missing but history filled client=${order.clientOrderId} '
              'grid=${order.gridLevelId ?? '-'} side=${order.side}; '
              'mark local filled',
        );
        await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
            .write(
          OrdersCompanion(
            exchangeOrderId: Value(historical.exchangeOrderId),
            status: const Value('filled'),
            executedQuantity: Value(historical.executedQuantity),
            quoteQuantity: Value(historical.quoteQuantity),
            averagePrice: Value(historical.averagePrice ?? historical.price),
            updatedAt: Value(DateTime.now().toUtc()),
            completedAt: Value(historical.updatedAt),
            cancelledAt: const Value(null),
            errorCode: const Value(null),
            errorMessage: const Value(null),
          ),
        );
        continue;
      }
      final releasedStatus = historicalStatus == null
          ? 'cancelled'
          : _normalizeExchangeStatus(historicalStatus);
      _debugTrace(
        'LONG_RECONCILE',
        'release missing open order client=${order.clientOrderId} '
            'grid=${order.gridLevelId ?? '-'} side=${order.side} '
            'local=${order.status} history=${historicalStatus ?? '-'} '
            'released=$releasedStatus ageSec=${now.difference(order.createdAt).inSeconds} '
            'executed=${order.executedQuantity} hasLongInventory=$hasLongInventory',
      );
      await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
          .write(
        OrdersCompanion(
          status: Value(releasedStatus),
          completedAt: Value(now),
          cancelledAt: Value(now),
          updatedAt: Value(now),
          errorMessage: const Value('Binance 当前挂单和历史订单均无有效活动状态，已释放本地网格。'),
        ),
      );
      final executed = _d(order.executedQuantity);
      final gridStatus = order.side == 'SELL'
          ? hasLongInventory
              ? 'buyFilled'
              : 'waitingBuy'
          : executed > Decimal.zero && hasLongInventory
              ? 'buyFilled'
              : 'waitingBuy';
      await (db.update(db.gridLevels)
            ..where((tbl) => tbl.id.equals(order.gridLevelId ?? '')))
          .write(
        GridLevelsCompanion(
          status: Value(gridStatus),
          lifecycleStatus: Value(gridStatus),
          activeOrderId: const Value(null),
          linkedOrderId: const Value(null),
          lastBuyOrderId: order.side == 'BUY' && executed == Decimal.zero
              ? const Value(null)
              : const Value.absent(),
          lastSellOrderId:
              order.side == 'SELL' ? const Value(null) : const Value.absent(),
          updatedAt: Value(now),
        ),
      );
      await logRepository.append(
        strategyId: strategyId,
        level: 'warning',
        module: 'AUTO_FUTURES_LONG_GRID',
        message:
            'Local futures long open order missing from Binance open orders: grid=${order.gridLevelId ?? '-'} side=${order.side} client=${order.clientOrderId}',
      );
    }
  }

  Future<List<Order>> _futuresLongReconcileOrders(Strategy strategy) async {
    final levels = await _levels(strategy.id);
    final referencedIds = <String>{};
    for (final level in levels) {
      for (final id in [
        level.activeOrderId,
        level.linkedOrderId,
        level.lastBuyOrderId,
        level.lastSellOrderId,
        level.lastCompletedOrderId,
      ]) {
        if (id != null && id.isNotEmpty) {
          referencedIds.add(id);
        }
      }
    }

    final rows = <Order>[];
    if (referencedIds.isNotEmpty) {
      rows.addAll(
        await (db.select(db.orders)
              ..where(
                (tbl) =>
                    tbl.strategyId.equals(strategy.id) &
                    tbl.source.equals(futuresLongSource) &
                    tbl.marketType.equals('usdtFutures') &
                    tbl.symbol.equals(strategy.symbol) &
                    tbl.id.isIn(referencedIds),
              ))
            .get(),
      );
    }
    rows.addAll(
      await (db.select(db.orders)
            ..where(
              (tbl) =>
                  tbl.strategyId.equals(strategy.id) &
                  tbl.source.equals(futuresLongSource) &
                  tbl.marketType.equals('usdtFutures') &
                  tbl.symbol.equals(strategy.symbol) &
                  tbl.status.isIn([
                    'created',
                    'submitting',
                    'new',
                    'partiallyFilled',
                    'unknown',
                  ]),
            ))
          .get(),
    );

    final byId = <String, Order>{};
    for (final row in rows) {
      byId[row.id] = row;
    }
    final scoped = byId.values.toList(growable: false)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _debugTrace(
      'LONG_RECONCILE',
      'candidate orders=${scoped.length} referenced=${referencedIds.length} '
          'strategy=${strategy.id} symbol=${strategy.symbol}',
    );
    return scoped;
  }

  Future<void> _recomputeFuturesLongGridLifecycle(
    String strategyId, {
    List<Order>? scopedOrders,
  }) async {
    final levels = await _levels(strategyId);
    final orders = scopedOrders ??
        await (db.select(db.orders)
              ..where(
                (tbl) =>
                    tbl.strategyId.equals(strategyId) &
                    tbl.source.equals(futuresLongSource),
              ))
            .get();
    final ordersByGrid = <String, List<Order>>{};
    for (final order in orders) {
      final gridId = order.gridLevelId;
      if (gridId == null || gridId.isEmpty) {
        continue;
      }
      ordersByGrid.putIfAbsent(gridId, () => <Order>[]).add(order);
    }
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      for (final level in levels) {
        final gridOrders = ordersByGrid[level.id] ?? const <Order>[];
        final runtime = _deriveFuturesLongGridRuntime(level, gridOrders);
        await (db.update(db.gridLevels)
              ..where((tbl) => tbl.id.equals(level.id)))
            .write(
          GridLevelsCompanion(
            status: Value(runtime.lifecycleStatus),
            lifecycleStatus: Value(runtime.lifecycleStatus),
            linkedOrderId: Value(runtime.currentOrderId),
            activeOrderId: Value(runtime.activeOrderId),
            lastBuyOrderId: Value(runtime.lastBuyOrderId),
            lastSellOrderId: Value(runtime.lastSellOrderId),
            lastCompletedOrderId: Value(runtime.lastCompletedOrderId),
            cycleNumber: Value(runtime.cycleNumber),
            updatedAt: Value(now),
          ),
        );
      }
    });
  }

  _GridRuntimeSnapshot _deriveFuturesLongGridRuntime(
    GridLevel level,
    List<Order> orders,
  ) {
    final effectiveOrders = orders
        .where(
          (order) =>
              !_isReleasedFuturesLongOrder(order) &&
              !_isTerminalZeroFillFuturesLongCloseOrder(order),
        )
        .toList();
    if (effectiveOrders.isEmpty) {
      final status = level.status == 'disabled' ? 'disabled' : 'waitingBuy';
      return _GridRuntimeSnapshot(lifecycleStatus: status);
    }
    final sorted = [...effectiveOrders]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final active = sorted.where(_isActiveOrder).toList(growable: false);
    final current = active.isNotEmpty ? active.last : sorted.last;
    final lastBuy = _lastWhereOrNull(sorted, (order) => order.side == 'BUY');
    final lastSell = _lastWhereOrNull(sorted, (order) => order.side == 'SELL');
    final lastCompleted = _lastWhereOrNull(
      sorted,
      (order) => ['filled', 'cancelled'].contains(order.status),
    );
    final rawLifecycleStatus = _gridStatusAfterSubmit(
      side: current.side,
      order: current,
      submittingStatus:
          current.side == 'BUY' ? 'buySubmitting' : 'sellSubmitting',
    );
    final completedSell =
        active.isEmpty && current.side == 'SELL' && current.status == 'filled';
    final lifecycleStatus = completedSell ? 'waitingBuy' : rawLifecycleStatus;
    final retainedLastSell =
        _shouldRetainSellOrderForLifecycle(lifecycleStatus, current)
            ? lastSell
            : null;
    final completedSellCount = sorted
        .where((order) => order.side == 'SELL' && order.status == 'filled')
        .length;
    return _GridRuntimeSnapshot(
      lifecycleStatus: lifecycleStatus,
      currentOrderId: completedSell ? null : current.id,
      activeOrderId: completedSell
          ? null
          : _isActiveOrder(current)
              ? current.id
              : null,
      lastBuyOrderId: completedSell ? null : lastBuy?.id,
      lastSellOrderId: retainedLastSell?.id,
      lastCompletedOrderId: lastCompleted?.id,
      cycleNumber: completedSellCount > level.cycleNumber
          ? completedSellCount
          : level.cycleNumber,
    );
  }

  Future<Decimal> _futuresLongCloseQuantity(GridLevel level) async {
    final lastBuyOrderId = level.lastBuyOrderId;
    if (lastBuyOrderId != null && lastBuyOrderId.isNotEmpty) {
      final buyOrder = await (db.select(db.orders)
            ..where((tbl) => tbl.id.equals(lastBuyOrderId)))
          .getSingleOrNull();
      final executed = _d(buyOrder?.executedQuantity ?? '0');
      if (executed > Decimal.zero) {
        return executed;
      }
    }
    return _d(level.plannedQuantity);
  }

  Future<_FuturesLongReduceAvailability> _futuresLongReduceAvailability(
    String symbol,
  ) async {
    final normalizedSymbol = symbol.toUpperCase();
    await liveExecution.refreshFuturesSnapshotForSymbol(
      normalizedSymbol,
      includeHistory: false,
    );
    final currentLong = await liveExecution.currentFuturesLongQuantity(
      normalizedSymbol,
    );
    if (currentLong <= Decimal.zero) {
      return _FuturesLongReduceAvailability(
        currentLong: currentLong,
        reservedReduceOnlySell: Decimal.zero,
        available: Decimal.zero,
        reduceOnlySellOrderCount: 0,
      );
    }
    final openOrders = await (db.select(db.exchangeOpenOrders)
          ..where(
            (tbl) =>
                tbl.accountType.equals('futuresSubAccount') &
                tbl.marketType.equals('usdtFutures') &
                tbl.environment.equals('live') &
                tbl.symbol.equals(normalizedSymbol) &
                tbl.side.equals('SELL') &
                (tbl.positionSide.equals('LONG') |
                    tbl.positionSide.equals('BOTH') |
                    tbl.positionSide.isNull()),
          ))
        .get();
    var reserved = Decimal.zero;
    var reduceOnlySellOrderCount = 0;
    for (final order in openOrders) {
      if (order.reduceOnly == false) {
        continue;
      }
      final original = _d(order.originalQuantity);
      final executed = _d(order.executedQuantity);
      final remaining = original - executed;
      if (remaining > Decimal.zero) {
        reserved += remaining;
        reduceOnlySellOrderCount += 1;
      }
    }
    final available = currentLong - reserved;
    return _FuturesLongReduceAvailability(
      currentLong: currentLong,
      reservedReduceOnlySell: reserved,
      available: available > Decimal.zero ? available : Decimal.zero,
      reduceOnlySellOrderCount: reduceOnlySellOrderCount,
    );
  }

  Future<void> startWithProgress(
    String strategyId, {
    void Function(LiveSpotGridStartStepUpdate update)? onStep,
  }) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      throw StateError('Strategy not found: $strategyId');
    }
    final baseAsset = _baseAssetForSymbol(strategy.symbol);
    void step(String name, String status, [String? message]) {
      onStep?.call(LiveSpotGridStartStepUpdate(name, status, message: message));
    }

    step('正在校验账户', 'running');
    final result = await preflight(strategyId);
    if (!result.ok) {
      await _setError(strategyId, result.failures.join('; '));
      step('正在校验账户', 'failed', result.failures.join('; '));
      LiveSpotGridPreflightIssue? failedIssue;
      for (final issue in result.issues) {
        if (issue.failed) {
          failedIssue = issue;
          break;
        }
      }
      final message = result.failures.join('; ');
      switch (failedIssue?.type) {
        case LiveSpotGridPreflightIssueType.exchangeRules:
          throw MissingExchangeRulesException(message);
        case LiveSpotGridPreflightIssueType.conflictingStrategy:
          throw ConflictingLiveStrategyException(message);
        case LiveSpotGridPreflightIssueType.btcClassification:
          throw UnclassifiedAssetException(message);
        case LiveSpotGridPreflightIssueType.liveTrading:
          throw LiveTradingDisabledException(message);
        default:
          throw Exception(message);
      }
    }
    step('正在校验账户', 'success');
    final now = DateTime.now().toUtc();
    step('正在校验余额', 'running');
    step('正在校验余额', 'success');
    await _setStatus(strategyId, 'starting', startedAt: now);
    step('正在计算初始 $baseAsset', 'running');
    step('正在计算初始 $baseAsset', 'success');
    step('正在提交初始 $baseAsset 买入', 'running');
    await _buildInitialInventory(strategy);
    step('正在提交初始 $baseAsset 买入', 'success');
    step('正在等待初始买入成交', 'running');
    await liveExecution.refreshSpotSnapshotForSymbol(strategy.symbol);
    await _syncExchangeState(strategyId);
    await _recalculateStrategyBtc(strategyId);
    step('正在等待初始买入成交', 'success');
    step('正在提交下方 BUY 网格', 'running');
    step('正在提交上方 SELL 网格', 'running');
    await _submitInitialGridOrders(strategyId);
    step('正在提交下方 BUY 网格', 'success');
    step('正在提交上方 SELL 网格', 'success');
    step('正在确认 Binance 订单', 'running');
    await liveExecution.refreshSpotSnapshotForSymbol(strategy.symbol);
    await _syncExchangeState(strategyId);
    step('正在确认 Binance 订单', 'success');
    step('正在执行 REST 对账', 'running');
    await _recalculateStrategyBtc(strategyId);
    step('正在执行 REST 对账', 'success');
    await _setStatus(strategyId, 'running');
    step('启动完成', 'success');
    await logRepository.append(
      strategyId: strategyId,
      level: 'info',
      module: 'AUTO_SPOT_GRID',
      message: 'LIVE spot grid started',
    );
  }

  Future<void> pause(String strategyId) => pauseKeepOrders(strategyId);

  Future<void> pauseKeepOrders(String strategyId) async {
    await _setStatus(
      strategyId,
      'pausedKeepOrders',
      lastError: 'pausedKeepOrders: 保留挂单暂停，不会自动补反向单',
    );
  }

  Future<void> pauseCancelOrders(String strategyId) async {
    await _setStatus(
      strategyId,
      'pausedCancelOrders',
      lastError: 'pausedCancelOrders: 撤销挂单暂停',
    );
    await _cancelStrategyOpenOrders(strategyId);
    await reconcile(strategyId);
  }

  Future<void> resume(String strategyId) async {
    await reconcile(strategyId);
    await _setStatus(strategyId, 'running');
  }

  Future<void> stop(String strategyId, {bool cancelOrders = true}) async {
    await _setStatus(strategyId, 'stopping');
    if (cancelOrders) {
      await _cancelStrategyOpenOrders(strategyId);
    }
    final strategy = await _strategy(strategyId);
    await liveExecution.refreshSpotSnapshotForSymbol(
      strategy?.symbol ?? 'BTCUSDT',
    );
    await _syncExchangeState(strategyId);
    await _recalculateStrategyBtc(strategyId);
    await _setStatus(strategyId, 'stopped', stoppedAt: DateTime.now().toUtc());
  }

  Future<void> emergencyExit(String strategyId) async {
    await _setStatus(strategyId, 'circuitBreaker');
    await _cancelStrategyOpenOrders(strategyId);
    final strategy = await _strategy(strategyId);
    await liveExecution.refreshSpotSnapshotForSymbol(
      strategy?.symbol ?? 'BTCUSDT',
    );
    await _syncExchangeState(strategyId);
    await _recalculateStrategyBtc(strategyId);
    liveTradingGate.disable(reason: 'auto spot grid emergency exit');
    await _insertRiskEvent(
      strategyId,
      'emergencyExit',
      'critical',
      'LIVE spot grid emergency exit completed',
    );
    await _setStatus(
      strategyId,
      'stopped',
      stoppedAt: DateTime.now().toUtc(),
      lastError: '紧急退出完成，真实写操作已关闭',
    );
  }

  Future<void> reconcile(
    String strategyId, {
    bool requireManualResume = true,
  }) async {
    final previousStatus = (await _strategy(strategyId))?.status;
    final runId = _uuid.v4();
    await db.into(db.reconciliationRuns).insert(
          ReconciliationRunsCompanion.insert(
            id: runId,
            status: 'running',
            startedAt: DateTime.now().toUtc(),
            summaryJson: Value(jsonEncode({'strategyId': strategyId})),
          ),
        );
    await _setStatus(strategyId, 'reconciling');
    try {
      final strategy = await _strategy(strategyId);
      await liveExecution.refreshSpotSnapshotForSymbol(
        strategy?.symbol ?? 'BTCUSDT',
      );
      await _syncExchangeState(strategyId);
      await _markLocalRejectedGridSubmissionsFailed(strategyId);
      await _recomputeGridLifecycle(strategyId);
      await _recalculateStrategyBtc(strategyId);
      await _processFilledOrders(strategyId);
      await CompletedGridCycleService(db).rebuildForStrategy(strategyId);
      await _recomputeGridLifecycle(strategyId);
      await _recalculateStrategyBtc(strategyId);
      await (db.update(db.reconciliationRuns)
            ..where((tbl) => tbl.id.equals(runId)))
          .write(
        ReconciliationRunsCompanion(
          status: const Value('success'),
          completedAt: Value(DateTime.now().toUtc()),
          summaryJson: Value(jsonEncode({'strategyId': strategyId})),
        ),
      );
      if (requireManualResume) {
        await _setStatus(strategyId, 'paused', lastError: '对账完成，等待人工确认恢复');
      } else if (previousStatus != null && previousStatus != 'reconciling') {
        await _setStatus(strategyId, previousStatus);
      } else {
        await _setStatus(strategyId, 'running', lastError: '对账完成，已恢复运行状态');
      }
      await _checkOutOfRange(strategyId);
    } catch (error) {
      await (db.update(db.reconciliationRuns)
            ..where((tbl) => tbl.id.equals(runId)))
          .write(
        ReconciliationRunsCompanion(
          status: const Value('failed'),
          completedAt: Value(DateTime.now().toUtc()),
          errorMessage: Value(error.toString()),
        ),
      );
      await _setStatus(strategyId, 'error', lastError: '对账失败: $error');
      rethrow;
    }
  }

  Future<LiveSpotGridRecoveryReport> buildRecoveryReport(
    String strategyId,
  ) async {
    final strategy = await _strategy(strategyId);
    final symbol = strategy?.symbol ?? 'BTCUSDT';
    final baseAsset = _baseAssetForSymbol(symbol);
    await liveExecution.refreshSpotSnapshotForSymbol(symbol);
    final beforeFills = await (db.select(db.fills)
          ..where((tbl) => tbl.strategyId.equals(strategyId)))
        .get();
    await _syncExchangeState(strategyId);
    await _recalculateStrategyBtc(strategyId);
    final afterFills = await (db.select(db.fills)
          ..where((tbl) => tbl.strategyId.equals(strategyId)))
        .get();
    final binanceOpen = await (db.select(db.exchangeOpenOrders)
          ..where(
            (tbl) =>
                tbl.environment.equals('live') &
                tbl.marketType.equals('spot') &
                tbl.symbol.equals(symbol) &
                tbl.clientOrderId.like('$clientOrderPrefix%'),
          ))
        .get();
    final localOpen = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(source) &
                tbl.status.isIn([
                  'created',
                  'submitting',
                  'new',
                  'partiallyFilled',
                ]),
          ))
        .get();
    var statusMismatches = 0;
    for (final local in localOpen) {
      ExchangeOpenOrder? remote;
      for (final order in binanceOpen) {
        if (order.clientOrderId == local.clientOrderId) {
          remote = order;
          break;
        }
      }
      if (remote == null ||
          _normalizeExchangeStatus(remote.status) != local.status) {
        statusMismatches += 1;
      }
    }
    final filledWithoutReverse = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(source) &
                tbl.status.equals('filled') &
                tbl.purpose.isIn(['gridBuy', 'gridSell']),
          ))
        .get();
    var missingReverse = 0;
    for (final order in filledWithoutReverse) {
      final reverse = await (db.select(db.orders)
            ..where(
              (tbl) => tbl.parentOrderId.equals(order.id),
            ))
          .getSingleOrNull();
      if (reverse == null) {
        missingReverse += 1;
      }
    }
    final inventory = await loadBtcInventory(strategyId);
    final messages = <String>[];
    if (statusMismatches > 0) {
      messages.add('存在本地和交易所状态不一致订单');
    }
    if (missingReverse > 0) {
      messages.add('存在缺失反向订单，需要恢复时人工确认后补单');
    }
    if (inventory.unclassifiedBtc > Decimal.zero) {
      messages.add('账户存在未分类 $baseAsset，不能自动作为策略库存');
    }
    return LiveSpotGridRecoveryReport(
      symbol: strategy?.symbol ?? 'BTCUSDT',
      safeToResume: statusMismatches == 0 && missingReverse == 0,
      binanceOpenOrders: binanceOpen.length,
      localOpenOrders: localOpen.length,
      newFills: afterFills.length - beforeFills.length,
      statusMismatches: statusMismatches,
      missingReverseOrders: missingReverse,
      strategyBtc:
          strategy == null ? Decimal.zero : _d(strategy.strategySpotBtc),
      accountBtc: inventory.btcFree,
      messages: messages,
    );
  }

  Future<void> _insertGrid(
    String strategyId,
    PaperStrategyConfig config, {
    Decimal? singleGridAmount,
    bool enableFutureHedgeGrid = false,
    int futureGridOffset = 1,
    bool useFuturesRules = false,
    int futuresLeverage = 1,
  }) async {
    BinanceSymbolRules? rules;
    if (useFuturesRules) {
      try {
        rules = await liveExecution.ensureFuturesRules(symbol: config.symbol);
      } catch (_) {
        rules = null;
      }
    } else {
      await liveExecution
          .ensureSpotRules(symbol: config.symbol)
          .catchError((_) => null);
      rules = liveExecution.spotRulesForSymbol(config.symbol);
    }
    final now = DateTime.now().toUtc();
    final levels = _gridGenerator.generate(config);
    final intervals = _liveGridIntervals(levels, rules);
    final perGridQuote = singleGridAmount ??
        (intervals.isEmpty
            ? Decimal.zero
            : (config.spotCapital / Decimal.fromInt(intervals.length))
                .toDecimal(scaleOnInfinitePrecision: 8));
    final leverage = futuresLeverage.clamp(1, 125);
    final perGridNotional = useFuturesRules
        ? perGridQuote * Decimal.fromInt(leverage)
        : perGridQuote;
    for (final interval in intervals) {
      final buyPrice = interval.buyPrice;
      final sellPrice = interval.sellPrice;
      final qty = rules?.quantizeQuantity(
            (perGridNotional / buyPrice).toDecimal(scaleOnInfinitePrecision: 8),
          ) ??
          (perGridNotional / buyPrice).toDecimal(scaleOnInfinitePrecision: 8);
      await db.into(db.gridLevels).insert(
            GridLevelsCompanion.insert(
              id: '${strategyId}_grid_${interval.index}',
              strategyId: strategyId,
              gridIndex: interval.index,
              price: _s(buyPrice),
              nextUpperPrice: Value(_s(sellPrice)),
              nextLowerPrice: const Value(null),
              plannedSide: 'BUY',
              plannedQuantity: _s(qty),
              plannedQuoteAmount: _s(buyPrice * qty),
              status: 'ready',
              buyPrice: Value(_s(buyPrice)),
              sellPrice: Value(_s(sellPrice)),
              lifecycleStatus: const Value('waitingBuy'),
              activeOrderId: const Value(null),
              lastBuyOrderId: const Value(null),
              lastSellOrderId: const Value(null),
              lastCompletedOrderId: const Value(null),
              cycleNumber: const Value(0),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    if (enableFutureHedgeGrid) {
      await futureGridEngine.ensureForStrategy(
        strategyId,
        offset: futureGridOffset,
      );
    }
  }

  List<_LiveGridInterval> _liveGridIntervals(
    List<GeneratedGridLevel> generated,
    BinanceSymbolRules? rules,
  ) {
    final intervals = <_LiveGridInterval>[];
    final seen = <String>{};
    for (final level in generated) {
      final upper = level.nextUpperPrice;
      if (upper == null) continue;
      final buyPrice = rules?.quantizePrice(level.price) ?? level.price;
      final sellPrice = rules?.quantizePrice(upper) ?? upper;
      if (sellPrice <= buyPrice) continue;
      final key = '${_s(buyPrice)}:${_s(sellPrice)}';
      if (!seen.add(key)) continue;
      intervals.add(
        _LiveGridInterval(
          index: intervals.length,
          buyPrice: buyPrice,
          sellPrice: sellPrice,
        ),
      );
    }
    return intervals;
  }

  Future<void> _buildInitialInventory(Strategy strategy) async {
    final config = await loadEditableConfig(strategy.id);
    final ratio = config?.initialBtcRatio ?? Decimal.parse('0.5');
    final targetValue = _d(strategy.spotCapital) * ratio;
    final orderLimitValue = await orderLimit(symbol: strategy.symbol);
    var remaining = targetValue;
    while (remaining > Decimal.zero) {
      final chunk = remaining > orderLimitValue ? orderLimitValue : remaining;
      await liveExecution.placeAutoSpotGridMarketBuy(
        symbol: strategy.symbol,
        strategyId: strategy.id,
        quoteOrderQty: chunk,
      );
      remaining -= chunk;
    }
  }

  Future<void> _submitInitialGridOrders(String strategyId) async {
    final strategy = (await _strategy(strategyId))!;
    final ticker = marketData.latestSpotTicker;
    final current = ticker?.midPrice ?? _d(strategy.centerPrice);
    final levels = await _levels(strategyId);
    final editConfig = await loadEditableConfig(strategyId);
    final initialCandidates = _initialBuyOrderCandidates(
      levels,
      current,
      editConfig,
    );
    var openCount = await _openOrderCount(strategyId);
    for (final level in levels) {
      if (openCount >= (editConfig?.maxOpenOrders ?? defaultMaxOpenOrders)) {
        return;
      }
      if (level.status != 'ready') continue;
      if (!initialCandidates.contains(level.id)) continue;
      final buyPrice = _gridBuyPrice(level);
      if (buyPrice != null && buyPrice < current) {
        await _submitGridLevel(
          level,
          side: 'BUY',
          price: buyPrice,
          lifecycleStatus: 'buySubmitting',
        );
        openCount += 1;
      }
    }
  }

  Decimal? _currentFuturesGridPrice(Strategy strategy) {
    return marketData.latestFuturesMarkPriceFor(strategy.symbol)?.markPrice;
  }

  bool _isFuturesLongBuyTriggerReached({
    required Decimal buyPrice,
    required Decimal currentPrice,
    required Decimal triggerDistance,
  }) {
    final normalizedDistance =
        triggerDistance < Decimal.zero ? Decimal.zero : triggerDistance;
    return currentPrice >= buyPrice - normalizedDistance &&
        currentPrice <= buyPrice + normalizedDistance;
  }

  bool _isFuturesLongBuySubmissionEligible({
    required Decimal buyPrice,
    required Decimal currentPrice,
    required LiveSpotGridEditableConfig? config,
  }) {
    if (config?.longEntryTriggerMode ==
        LiveSpotGridEditableConfig.longEntryTriggerModePrehang) {
      // Prehang mode may place orders at or below the current mark, but never
      // above it.
      return buyPrice <= currentPrice;
    }
    return _isFuturesLongBuyTriggerReached(
      buyPrice: buyPrice,
      currentPrice: currentPrice,
      triggerDistance: config?.longEntryTriggerDistanceUsdt ??
          defaultLongEntryTriggerDistanceUsdt,
    );
  }

  Set<String> _initialFuturesLongBuyCandidates(
    List<GridLevel> levels,
    Decimal currentPrice,
    LiveSpotGridEditableConfig editConfig,
  ) {
    final buyLevels = levels
        .where(
          (level) =>
              _isWaitingLongBuyLevel(level) &&
              _gridBuyPrice(level) != null &&
              _gridSellPrice(level) != null &&
              _isFuturesLongBuySubmissionEligible(
                buyPrice: _gridBuyPrice(level)!,
                currentPrice: currentPrice,
                config: editConfig,
              ),
        )
        .toList()
      ..sort((a, b) => _gridBuyPrice(b)!.compareTo(_gridBuyPrice(a)!));
    final count = editConfig.longEntryTriggerMode ==
            LiveSpotGridEditableConfig.longEntryTriggerModePrehang
        ? editConfig.longEntryPrehangLevels
        : editConfig.initialBuyOrderCount;
    return buyLevels.take(count).map((level) => level.id).toSet();
  }

  int _activeLongGridOrderCount(List<GridLevel> levels) {
    return levels.where((level) {
      if (level.activeOrderId == null || level.activeOrderId!.isEmpty) {
        return false;
      }
      return {
        'buySubmitting',
        'buyOpen',
        'buyPartiallyFilled',
        'sellSubmitting',
        'sellOpen',
        'sellPartiallyFilled',
      }.contains(level.lifecycleStatus ?? level.status);
    }).length;
  }

  bool _isWaitingLongBuyLevel(GridLevel level) {
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

  Future<String> _submitFuturesLongGridLevel(
    GridLevel level,
    Decimal price, {
    required int leverage,
  }) async {
    final strategy = await _strategy(level.strategyId);
    if (strategy == null) {
      throw StateError('策略不存在: ${level.strategyId}');
    }
    final activeCount = await _activeFuturesLongOrderCountForGrid(level.id);
    if (activeCount > 0) {
      throw StateError('Grid ${level.id} 已存在活动订单，禁止重复挂单。');
    }
    final orderId = await liveExecution.placeFuturesLimitOrder(
      symbol: strategy.symbol,
      strategyId: level.strategyId,
      gridLevelId: level.id,
      side: 'BUY',
      positionSide: 'LONG',
      quantity: _d(level.plannedQuantity),
      price: price,
      reduceOnly: false,
      leverage: leverage,
      source: futuresLongSource,
      purpose: 'futuresLongGridBuy',
    );
    final created = await (db.select(db.orders)
          ..where((tbl) => tbl.id.equals(orderId)))
        .getSingleOrNull();
    final gridStatus = _gridStatusAfterSubmit(
      side: 'BUY',
      order: created,
      submittingStatus: 'buySubmitting',
    );
    final activeOrder = created != null &&
        [
          'created',
          'submitting',
          'new',
          'partiallyFilled',
          'unknown',
        ].contains(created.status);
    await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(level.id)))
        .write(
      GridLevelsCompanion(
        status: Value(gridStatus),
        lifecycleStatus: Value(gridStatus),
        linkedOrderId: Value(orderId),
        activeOrderId: activeOrder ? Value(orderId) : const Value(null),
        lastBuyOrderId: Value(orderId),
        lastSellOrderId: const Value(null),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    if (_isFailedFuturesLongSubmission(created)) {
      throw StateError(_futuresLongSubmissionError(created));
    }
    return orderId;
  }

  bool _isFailedFuturesLongSubmission(Order? order) {
    if (order == null) {
      return true;
    }
    return {'failed', 'unknown', 'rejected', 'expired'}.contains(order.status);
  }

  bool _isFuturesReduceOnlyRejected(Order? order) {
    final message = order?.errorMessage ?? '';
    return message.contains('code: -2022') ||
        message.contains('ReduceOnly Order is rejected');
  }

  Future<void> _repairFuturesLongCloseReduceOnlyRejection({
    required GridLevel level,
    required Order order,
    required String symbol,
  }) async {
    final now = DateTime.now().toUtc();
    await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id))).write(
      OrdersCompanion(
        status: const Value('failed'),
        completedAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    final currentLong = await liveExecution.currentFuturesLongQuantity(symbol);
    final hasRemainingLong = currentLong > Decimal.zero;
    await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(level.id)))
        .write(
      GridLevelsCompanion(
        status: Value(hasRemainingLong ? 'buyFilled' : 'waitingBuy'),
        lifecycleStatus: Value(hasRemainingLong ? 'buyFilled' : 'waitingBuy'),
        linkedOrderId: const Value(null),
        activeOrderId: const Value(null),
        lastSellOrderId: const Value(null),
        lastBuyOrderId:
            hasRemainingLong ? const Value.absent() : const Value(null),
        updatedAt: Value(now),
      ),
    );
  }

  String _futuresLongSubmissionError(Order? order) {
    if (order == null) {
      return '没有写入本地订单记录';
    }
    final message = order.errorMessage;
    if (message != null && message.isNotEmpty) {
      if (_isFuturesReduceOnlyRejected(order)) {
        return 'Binance 拒绝 reduceOnly 平多单：当前该层没有可平 LONG 仓位，或可平数量已被其他平多挂单占用。已恢复本地网格状态，请先刷新 Binance 当前挂单/对账后再操作。原始错误: $message';
      }
      return message;
    }
    return 'Binance LONG BUY 下单未成功，订单状态=${order.status}';
  }

  Future<void> _resetStaleFuturesLongSubmissions(String strategyId) async {
    final staleOrders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(futuresLongSource) &
                tbl.status.isIn(['created', 'submitting', 'failed', 'unknown']),
          ))
        .get();
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      final staleByGrid = <String, List<Order>>{};
      for (final order in staleOrders) {
        final gridId = order.gridLevelId;
        if (gridId == null || gridId.isEmpty) {
          continue;
        }
        staleByGrid.putIfAbsent(gridId, () => <Order>[]).add(order);
      }
      for (final entry in staleByGrid.entries) {
        final gridId = entry.key;
        final hasSellFailure = entry.value.any((order) => order.side == 'SELL');
        await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(gridId)))
            .write(
          GridLevelsCompanion(
            status: Value(hasSellFailure ? 'buyFilled' : 'waitingBuy'),
            lifecycleStatus: Value(hasSellFailure ? 'buyFilled' : 'waitingBuy'),
            linkedOrderId: const Value(null),
            activeOrderId: const Value(null),
            lastSellOrderId:
                hasSellFailure ? const Value(null) : const Value.absent(),
            lastBuyOrderId:
                hasSellFailure ? const Value.absent() : const Value(null),
            updatedAt: Value(now),
          ),
        );
      }
      for (final order in staleOrders) {
        await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
            .write(
          OrdersCompanion(
            status: const Value('cancelled'),
            completedAt: Value(now),
            cancelledAt: Value(now),
            updatedAt: Value(now),
            errorMessage: Value(
              order.errorMessage ?? 'Reset before futures long grid retry.',
            ),
          ),
        );
      }
      final levels = await (db.select(db.gridLevels)
            ..where((tbl) => tbl.strategyId.equals(strategyId)))
          .get();
      for (final level in levels) {
        if (staleByGrid.containsKey(level.id)) {
          continue;
        }
        final status = level.lifecycleStatus ?? level.status;
        if (!{'buySubmitting', 'error'}.contains(status)) {
          continue;
        }
        final activeCount = await _activeFuturesLongOrderCountForGrid(level.id);
        if (activeCount > 0) {
          continue;
        }
        await (db.update(db.gridLevels)
              ..where((tbl) => tbl.id.equals(level.id)))
            .write(
          GridLevelsCompanion(
            status: const Value('waitingBuy'),
            lifecycleStatus: const Value('waitingBuy'),
            linkedOrderId: const Value(null),
            activeOrderId: const Value(null),
            updatedAt: Value(now),
          ),
        );
      }
    });
  }

  Future<void> _markFuturesLongGridLevelAfterCancel(
    String gridLevelId, {
    required Decimal executedQuantity,
    required String cancelledOrderId,
  }) async {
    final now = DateTime.now().toUtc();
    if (executedQuantity > Decimal.zero) {
      await (db.update(db.gridLevels)
            ..where((tbl) => tbl.id.equals(gridLevelId)))
          .write(
        GridLevelsCompanion(
          status: const Value('buyFilled'),
          lifecycleStatus: const Value('buyFilled'),
          linkedOrderId: Value(cancelledOrderId),
          activeOrderId: const Value(null),
          lastBuyOrderId: Value(cancelledOrderId),
          updatedAt: Value(now),
        ),
      );
      return;
    }
    await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(gridLevelId)))
        .write(
      GridLevelsCompanion(
        status: const Value('waitingBuy'),
        lifecycleStatus: const Value('waitingBuy'),
        linkedOrderId: const Value(null),
        activeOrderId: const Value(null),
        lastBuyOrderId: const Value(null),
        updatedAt: Value(now),
      ),
    );
  }

  Future<String> submitWaitingBuyGridLevel(String gridLevelId) async {
    final level = await (db.select(db.gridLevels)
          ..where((tbl) => tbl.id.equals(gridLevelId)))
        .getSingleOrNull();
    if (level == null) {
      throw StateError('网格不存在: $gridLevelId');
    }
    final strategy = await _strategy(level.strategyId);
    if (strategy == null) {
      throw StateError('策略不存在: ${level.strategyId}');
    }
    if (!{
      'running',
      'starting',
      'idle',
      'previewReady',
      'reconciling',
    }.contains(strategy.status)) {
      throw StateError('当前策略状态不允许手动挂单: ${strategy.status}');
    }
    final activeCount = await _activeOrderCountForGrid(level.id);
    if (activeCount > 0) {
      throw StateError('该网格已有活动订单，禁止重复挂单。');
    }
    if (!{
          'ready',
          'waiting',
          'waitingBuy',
          'buySubmitting',
        }.contains(level.status) &&
        !{
          'waitingBuy',
          'planned',
          'ready',
          'buySubmitting',
        }.contains(level.lifecycleStatus ?? '')) {
      throw StateError('该网格当前不是等待 BUY 状态，不能手动挂单。');
    }
    final buyPrice = _gridBuyPrice(level);
    if (buyPrice == null || buyPrice <= Decimal.zero) {
      throw StateError('该网格缺少合法 BUY 价格。');
    }
    await liveExecution.refreshSpotSnapshot();
    await _ensureNoSamePriceOrderOnExchange(
      strategyId: level.strategyId,
      side: 'BUY',
      price: buyPrice,
    );
    try {
      await _submitGridLevel(
        level,
        side: 'BUY',
        price: buyPrice,
        lifecycleStatus: 'buySubmitting',
      );
    } finally {
      await _recomputeGridLifecycle(level.strategyId);
    }
    final created = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.gridLevelId.equals(level.id) &
                tbl.source.equals(source) &
                tbl.side.equals('BUY'),
          )
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)])
          ..limit(1))
        .getSingleOrNull();
    return created?.id ?? level.id;
  }

  Set<String> _initialBuyOrderCandidates(
    List<GridLevel> levels,
    Decimal currentPrice,
    LiveSpotGridEditableConfig? editConfig,
  ) {
    final buyCount =
        editConfig?.initialBuyOrderCount ?? defaultInitialBuyOrderCount;
    final buyLevels = levels
        .where(
          (level) =>
              level.status == 'ready' &&
              _gridBuyPrice(level) != null &&
              _gridSellPrice(level) != null &&
              _gridBuyPrice(level)! < currentPrice,
        )
        .toList()
      ..sort((a, b) => _gridBuyPrice(b)!.compareTo(_gridBuyPrice(a)!));
    return buyLevels.take(buyCount).map((level) => level.id).toSet();
  }

  Future<void> _submitGridLevel(
    GridLevel level, {
    required String side,
    required Decimal price,
    String? parentOrderId,
    Decimal? quantity,
    String lifecycleStatus = 'submitting',
  }) async {
    final strategy = await _strategy(level.strategyId);
    final symbol = strategy?.symbol ?? 'BTCUSDT';
    final activeCount = await _activeOrderCountForGrid(level.id);
    if (activeCount > 0) {
      throw StateError('Grid ${level.id} 已存在活动订单，禁止为同一网格行提交第二张订单。');
    }
    if (side == 'SELL' && parentOrderId == null) {
      throw StateError('SELL 必须来源于同一网格 BUY 成交，缺少 parentOrderId。');
    }
    final sameSidePriceActive = await _hasActiveSameSidePriceOrder(
      strategyId: level.strategyId,
      side: side,
      price: price,
      excludingGridLevelId: level.id,
    );
    if (sameSidePriceActive) {
      await _insertRiskEvent(
        level.strategyId,
        'duplicateActiveGridOrderPrevented',
        'critical',
        '已存在同策略同方向同价格活动订单，禁止提交重复单: side=$side price=$price grid=${level.id}',
      );
      throw StateError('已存在同策略同方向同价格活动订单，禁止提交重复单。');
    }
    String orderId;
    try {
      orderId = await liveExecution.placeAutoSpotGridLimitOrder(
        symbol: symbol,
        strategyId: level.strategyId,
        gridLevelId: level.id,
        side: side,
        quantity: quantity ?? _d(level.plannedQuantity),
        price: price,
        parentOrderId: parentOrderId,
      );
    } catch (error) {
      final hasActiveOrder = await _hasActiveOrderForGrid(level.id);
      final resetStatus = side == 'BUY' ? 'ready' : 'buyFilled';
      final resetLifecycle = side == 'BUY' ? 'waitingBuy' : 'buyFilled';
      await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(level.id)))
          .write(
        GridLevelsCompanion(
          status: Value(hasActiveOrder ? 'error' : resetStatus),
          lifecycleStatus: Value(hasActiveOrder ? 'error' : resetLifecycle),
          linkedOrderId:
              hasActiveOrder ? const Value.absent() : const Value(null),
          activeOrderId:
              hasActiveOrder ? const Value.absent() : const Value(null),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      rethrow;
    }
    final created = await (db.select(db.orders)
          ..where((tbl) => tbl.id.equals(orderId)))
        .getSingleOrNull();
    final gridStatus = _gridStatusAfterSubmit(
      side: side,
      order: created,
      submittingStatus: lifecycleStatus,
    );
    final activeOrder = created != null &&
        [
          'created',
          'submitting',
          'new',
          'partiallyFilled',
          'unknown',
        ].contains(created.status);
    await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(level.id)))
        .write(
      GridLevelsCompanion(
        status: Value(gridStatus),
        lifecycleStatus: Value(gridStatus),
        linkedOrderId: Value(orderId),
        activeOrderId: activeOrder ? Value(orderId) : const Value(null),
        lastBuyOrderId: side == 'BUY' ? Value(orderId) : const Value.absent(),
        lastSellOrderId: side == 'SELL' ? Value(orderId) : const Value.absent(),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await _recomputeGridLifecycle(level.strategyId);
  }

  Future<void> _recomputeGridLifecycle(String strategyId) async {
    final levels = await _levels(strategyId);
    final orders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) & tbl.source.equals(source),
          ))
        .get();
    final ordersByGrid = <String, List<Order>>{};
    for (final order in orders) {
      final gridId = order.gridLevelId;
      if (gridId == null || gridId.isEmpty) {
        continue;
      }
      ordersByGrid.putIfAbsent(gridId, () => <Order>[]).add(order);
    }
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      for (final level in levels) {
        final gridOrders = ordersByGrid[level.id] ?? const <Order>[];
        final runtime = _deriveGridRuntime(level, gridOrders);
        await (db.update(db.gridLevels)
              ..where((tbl) => tbl.id.equals(level.id)))
            .write(
          GridLevelsCompanion(
            status: Value(runtime.lifecycleStatus),
            lifecycleStatus: Value(runtime.lifecycleStatus),
            linkedOrderId: Value(runtime.currentOrderId),
            activeOrderId: Value(runtime.activeOrderId),
            lastBuyOrderId: Value(runtime.lastBuyOrderId),
            lastSellOrderId: Value(runtime.lastSellOrderId),
            lastCompletedOrderId: Value(runtime.lastCompletedOrderId),
            cycleNumber: Value(runtime.cycleNumber),
            updatedAt: Value(now),
          ),
        );
      }
    });
  }

  Future<int> _markLocalRejectedGridSubmissionsFailed(String strategyId) async {
    final candidates = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(source) &
                tbl.marketType.equals('spot') &
                tbl.status.isIn(['unknown', 'created', 'submitting', 'failed']),
          ))
        .get();
    final rejected =
        candidates.where(_isDefinitiveLocalRejectedSubmission).toList();
    if (rejected.isEmpty) {
      return 0;
    }

    final now = DateTime.now().toUtc();
    var repaired = 0;
    await db.transaction(() async {
      for (final order in rejected) {
        if (order.status == 'failed') {
          continue;
        }
        await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
            .write(
          OrdersCompanion(
            status: const Value('failed'),
            updatedAt: Value(now),
            completedAt: Value(now),
            errorMessage: Value(
              order.errorMessage ??
                  'Binance rejected local grid submission before order creation.',
            ),
          ),
        );
        repaired += 1;
      }
    });
    return repaired;
  }

  _GridRuntimeSnapshot _deriveGridRuntime(GridLevel level, List<Order> orders) {
    final inertFailedOrderIds =
        orders.where(_isInertFailedSubmission).map((order) => order.id).toSet();
    final effectiveOrders = orders
        .where(
          (order) =>
              !inertFailedOrderIds.contains(order.id) &&
              (order.parentOrderId == null ||
                  !inertFailedOrderIds.contains(order.parentOrderId)),
        )
        .toList();
    if (effectiveOrders.isEmpty) {
      final status = level.status == 'disabled' ? 'disabled' : 'waitingBuy';
      return _GridRuntimeSnapshot(lifecycleStatus: status);
    }
    final sorted = [...effectiveOrders]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final active = sorted.where(_isActiveOrder).toList(growable: false);
    final current = active.isNotEmpty ? active.last : sorted.last;
    final lastBuy = _lastWhereOrNull(sorted, (order) => order.side == 'BUY');
    final lastSell = _lastWhereOrNull(sorted, (order) => order.side == 'SELL');
    final lastCompleted = _lastWhereOrNull(
      sorted,
      (order) => ['filled', 'cancelled'].contains(order.status),
    );
    var cycleNumber = level.cycleNumber;
    if (lastSell?.status == 'filled') {
      cycleNumber = sorted
          .where(
            (order) => order.side == 'SELL' && order.status == 'filled',
          )
          .length;
    }
    final lifecycleStatus = _lifecycleStatusForCurrentOrder(current);
    final retainedLastSell =
        _shouldRetainSellOrderForLifecycle(lifecycleStatus, current)
            ? lastSell
            : null;
    return _GridRuntimeSnapshot(
      lifecycleStatus: lifecycleStatus,
      currentOrderId: current.id,
      activeOrderId: _isActiveOrder(current) ? current.id : null,
      lastBuyOrderId: lastBuy?.id,
      lastSellOrderId: retainedLastSell?.id,
      lastCompletedOrderId: lastCompleted?.id,
      cycleNumber: cycleNumber,
    );
  }

  bool _shouldRetainSellOrderForLifecycle(
    String lifecycleStatus,
    Order current,
  ) {
    if (current.side != 'SELL') {
      return false;
    }
    return const {
      'sellSubmitting',
      'sellOpen',
      'sellPartiallyFilled',
      'sellFilled',
      'cycleCompleted',
    }.contains(lifecycleStatus);
  }

  bool _isActiveOrder(Order order) {
    return const {
      'created',
      'submitting',
      'new',
      'partiallyFilled',
      'cancelling',
      'unknown',
    }.contains(order.status);
  }

  bool _isInertFailedSubmission(Order order) {
    if (!_isLocalOnlyZeroFillGridSubmission(order)) {
      return false;
    }
    return order.status == 'failed' ||
        (order.status == 'unknown' &&
            _isDefinitiveLocalRejectedSubmission(order));
  }

  bool _isDefinitiveLocalRejectedSubmission(Order order) {
    if (!_isLocalOnlyZeroFillGridSubmission(order)) {
      return false;
    }
    final message =
        '${order.errorCode ?? ''} ${order.errorMessage ?? ''}'.toLowerCase();
    if (message.trim().isEmpty) {
      return false;
    }
    return message.contains('-2010') ||
        message.contains('-2013') ||
        message.contains('-1013') ||
        message.contains('order does not exist') ||
        message.contains('insufficient balance') ||
        message.contains('requested action') ||
        message.contains('filter failure') ||
        message.contains('min_notional') ||
        message.contains('notional') ||
        message.contains('lot_size') ||
        message.contains('precision is over') ||
        message.contains('illegal characters');
  }

  bool _isLocalOnlyZeroFillGridSubmission(Order order) {
    final exchangeOrderId = order.exchangeOrderId;
    final purpose = order.purpose;
    return order.source == source &&
        order.marketType == 'spot' &&
        (purpose == 'gridBuy' || purpose == 'gridSell') &&
        (exchangeOrderId == null || exchangeOrderId.isEmpty) &&
        _d(order.executedQuantity) == Decimal.zero;
  }

  String _lifecycleStatusForCurrentOrder(Order order) {
    if (order.status == 'unknown' ||
        order.status == 'rejected' ||
        order.status == 'expired') {
      return 'error';
    }
    if (order.side == 'BUY') {
      return switch (order.status) {
        'created' || 'submitting' => 'buySubmitting',
        'new' => 'buyOpen',
        'partiallyFilled' => 'buyPartiallyFilled',
        'filled' => 'buyFilled',
        'cancelled' => _d(order.executedQuantity) > Decimal.zero
            ? 'buyFilled'
            : 'waitingBuy',
        _ => 'error',
      };
    }
    return switch (order.status) {
      'created' || 'submitting' => 'sellSubmitting',
      'new' => 'sellOpen',
      'partiallyFilled' => 'sellPartiallyFilled',
      'filled' => 'cycleCompleted',
      'cancelled' =>
        _d(order.executedQuantity) > Decimal.zero ? 'sellFilled' : 'waitingBuy',
      _ => 'error',
    };
  }

  Order? _lastWhereOrNull(List<Order> orders, bool Function(Order order) test) {
    for (var i = orders.length - 1; i >= 0; i -= 1) {
      final order = orders[i];
      if (test(order)) {
        return order;
      }
    }
    return null;
  }

  String _gridStatusAfterSubmit({
    required String side,
    required Order? order,
    required String submittingStatus,
  }) {
    if (order == null) {
      return side == 'BUY' ? 'waitingBuy' : 'error';
    }
    final executed = _d(order.executedQuantity);
    if (order.status == 'created' || order.status == 'submitting') {
      return submittingStatus;
    }
    if (order.status == 'new') {
      return side == 'BUY' ? 'buyOpen' : 'sellOpen';
    }
    if (order.status == 'partiallyFilled') {
      return side == 'BUY' ? 'buyPartiallyFilled' : 'sellPartiallyFilled';
    }
    if (order.status == 'filled') {
      return side == 'BUY' ? 'buyFilled' : 'sellFilled';
    }
    if (side == 'BUY' &&
        executed == Decimal.zero &&
        ['cancelled', 'rejected', 'expired'].contains(order.status)) {
      return 'waitingBuy';
    }
    if (side == 'SELL' &&
        executed == Decimal.zero &&
        ['cancelled', 'rejected', 'expired'].contains(order.status)) {
      return 'buyFilled';
    }
    return 'error';
  }

  Future<void> _syncExchangeState(String strategyId) async {
    final localOrders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) & tbl.source.equals(source),
          ))
        .get();
    for (final order in localOrders) {
      final historical = await (db.select(db.exchangeHistoricalOrders)
            ..where((tbl) => tbl.clientOrderId.equals(order.clientOrderId))
            ..limit(1))
          .getSingleOrNull();
      if (historical == null) continue;
      final status = _normalizeExchangeStatus(historical.status);
      if (!_transitionValidator.canTransition(order.status, status)) {
        await _handleInvalidOrderTransition(
          strategyId: strategyId,
          orderId: order.id,
          from: order.status,
          to: status,
        );
        continue;
      }
      try {
        await db.transaction(() async {
          await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
              .write(
            OrdersCompanion(
              exchangeOrderId: Value(historical.exchangeOrderId),
              status: Value(status),
              executedQuantity: Value(historical.executedQuantity),
              quoteQuantity: Value(historical.quoteQuantity),
              averagePrice: Value(historical.price),
              updatedAt: Value(DateTime.now().toUtc()),
              completedAt: Value(
                status == 'filled' ? historical.updatedAt : null,
              ),
              cancelledAt: Value(
                status == 'cancelled' ? historical.updatedAt : null,
              ),
            ),
          );
          final trades = await (db.select(db.exchangeTrades)
                ..where(
                  (tbl) =>
                      tbl.exchangeOrderId.equals(historical.exchangeOrderId),
                ))
              .get();
          for (final trade in trades) {
            final fillKey =
                'spot-${trade.symbol}-${historical.exchangeOrderId}-${trade.exchangeTradeId}';
            await db.into(db.fills).insert(
                  FillsCompanion.insert(
                    id: fillKey,
                    strategyId: strategyId,
                    orderId: order.id,
                    exchangeTradeId: fillKey,
                    symbol: trade.symbol,
                    side: trade.side,
                    price: trade.price,
                    quantity: trade.quantity,
                    quoteQuantity: trade.quoteQuantity,
                    commission: trade.commission,
                    commissionAsset: trade.commissionAsset,
                    realizedPnl: const Value('0'),
                    tradeTime: trade.tradeTime,
                    createdAt: DateTime.now().toUtc(),
                  ),
                  mode: InsertMode.insertOrIgnore,
                );
          }
        });
      } catch (error) {
        await _setStatus(
          strategyId,
          'paused',
          lastError: '数据库事务失败，已暂停补单: $error',
        );
        await _insertRiskEvent(
          strategyId,
          'databaseWriteFailed',
          'critical',
          '成交对账写入事务失败，未创建反向订单: $error',
        );
      }
    }
    await _detectDuplicateActiveGridOrders(strategyId);
  }

  Future<void> _processFilledOrders(String strategyId) async {
    final completed = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(source) &
                tbl.status.isIn(['filled', 'cancelled']) &
                tbl.purpose.isIn(['gridBuy', 'gridSell']),
          ))
        .get();
    for (final order in completed) {
      try {
        await _createReplacementForFilledOrder(order);
      } catch (error) {
        await _markReplacementFailure(order, error);
        await _insertRiskEvent(
          strategyId,
          'replacementFailed',
          'warning',
          '自动补反向单失败: parent=${order.id}, error=$error',
        );
      }
    }
    await CompletedGridCycleService(db).rebuildForStrategy(strategyId);
  }

  Future<void> _markReplacementFailure(Order order, Object error) async {
    final gridLevelId = order.gridLevelId;
    if (gridLevelId == null) {
      return;
    }
    await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(gridLevelId)))
        .write(
      GridLevelsCompanion(
        status: Value(order.side == 'BUY' ? 'buyFilled' : 'sellFilled'),
        lifecycleStatus: const Value('replacementFailed'),
        activeOrderId: const Value(null),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id))).write(
      OrdersCompanion(
        errorMessage: Value(error.toString()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<Order?> _findExistingReplacementOrder({
    required Order parent,
    required GridLevel grid,
    required String replacementSide,
    required Decimal replacementPrice,
  }) async {
    final byParent = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(parent.strategyId) &
                tbl.parentOrderId.equals(parent.id),
          )
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)])
          ..limit(1))
        .getSingleOrNull();
    if (byParent != null &&
        byParent.side == replacementSide &&
        byParent.createdAt.isAfter(parent.createdAt)) {
      return byParent;
    }

    final candidates = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(parent.strategyId) &
                tbl.gridLevelId.equals(grid.id) &
                tbl.side.equals(replacementSide) &
                tbl.marketType.equals('spot') &
                tbl.source.equals(source) &
                tbl.id.equals(parent.id).not(),
          )
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .get();
    const meaningfulStatuses = {
      'created',
      'submitting',
      'new',
      'partiallyFilled',
      'unknown',
      'failed',
      'rejected',
      'expired',
    };
    for (final candidate in candidates) {
      if (!meaningfulStatuses.contains(candidate.status)) {
        continue;
      }
      if (!candidate.createdAt.isAfter(parent.createdAt)) {
        continue;
      }
      final candidatePrice = candidate.price;
      if (candidatePrice != null &&
          _d(candidatePrice) != Decimal.zero &&
          _d(candidatePrice) != replacementPrice) {
        continue;
      }
      return candidate;
    }
    return null;
  }

  bool _isLocalOnlyReplacementCandidate(Order order) {
    final exchangeOrderId = order.exchangeOrderId;
    return (exchangeOrderId == null || exchangeOrderId.isEmpty) &&
        _d(order.executedQuantity) == Decimal.zero &&
        const {
          'created',
          'submitting',
          'unknown',
          'failed',
          'rejected',
          'expired',
        }.contains(order.status);
  }

  Future<Order> _submitExistingReplacementOrder({
    required Order parent,
    required GridLevel grid,
    required Order replacement,
  }) async {
    final rules = liveExecution.spotRulesForSymbol(parent.symbol);
    final price = rules == null
        ? _d(replacement.price ?? '0')
        : rules.quantizePrice(_d(replacement.price ?? '0'));
    final quantity = await _replacementQuantityForOrder(
      parent,
      replacementSide: replacement.side,
      price: price,
      rules: rules,
    );
    await _linkExistingReplacementOrder(
      parent: parent,
      grid: grid,
      replacement: replacement,
    );
    try {
      final adjusted = await _updateLocalReplacementQuantityIfNeeded(
        replacement,
        quantity,
      );
      await liveExecution.submitExistingAutoSpotGridLimitOrder(adjusted);
    } catch (_) {
      await refreshGridLifecycle(parent.strategyId);
      rethrow;
    }
    final submitted = await (db.select(db.orders)
          ..where((tbl) => tbl.id.equals(replacement.id)))
        .getSingleOrNull();
    if (submitted == null) {
      throw StateError('提交本地反向单后未找到订单: ${replacement.id}');
    }
    return submitted;
  }

  Future<void> _linkExistingReplacementOrder({
    required Order parent,
    required GridLevel grid,
    required Order replacement,
  }) async {
    final now = DateTime.now().toUtc();
    final replacementStatus = _gridStatusAfterSubmit(
      side: replacement.side,
      order: replacement,
      submittingStatus:
          replacement.side == 'BUY' ? 'buySubmitting' : 'sellSubmitting',
    );
    await db.transaction(() async {
      await (db.update(db.orders)
            ..where((tbl) => tbl.id.equals(replacement.id)))
          .write(
        OrdersCompanion(
          parentOrderId: Value(parent.id),
          gridLevelId: Value(grid.id),
          updatedAt: Value(now),
        ),
      );
      await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(grid.id)))
          .write(
        GridLevelsCompanion(
          status: Value(replacementStatus),
          lifecycleStatus: Value(replacementStatus),
          linkedOrderId: Value(replacement.id),
          activeOrderId: _isActiveOrder(replacement)
              ? Value(replacement.id)
              : const Value(null),
          lastCompletedOrderId: Value(parent.id),
          lastBuyOrderId:
              parent.side == 'BUY' ? Value(parent.id) : Value(replacement.id),
          lastSellOrderId: replacement.side == 'SELL'
              ? Value(replacement.id)
              : const Value.absent(),
          updatedAt: Value(now),
        ),
      );
    });
  }

  Future<String> _createReplacementForFilledOrder(
    Order order, {
    bool manual = false,
  }) async {
    final isPartialFillRecovery = order.status == 'cancelled' &&
        _d(order.executedQuantity) > Decimal.zero;
    if (order.status != 'filled' && !isPartialFillRecovery) {
      throw StateError('父订单状态不是 filled 或已撤销部分成交: ${order.status}');
    }
    final qty = _d(order.executedQuantity);
    if (qty <= Decimal.zero || order.gridLevelId == null) {
      throw StateError('父订单无有效成交数量或缺少 gridLevelId。');
    }
    final grid = await (db.select(
      db.gridLevels,
    )..where((tbl) => tbl.id.equals(order.gridLevelId!)))
        .getSingleOrNull();
    if (grid == null) {
      throw StateError('父订单关联网格不存在。');
    }
    final replacementSide = order.side == 'BUY' ? 'SELL' : 'BUY';
    final reversePrice =
        order.side == 'BUY' ? _gridSellPrice(grid) : _gridBuyPrice(grid);
    if (reversePrice == null) {
      throw StateError('当前固定网格行缺少对应反向价格。');
    }
    await _syncFutureHedgeLayerForFilledOrder(order, grid);
    final existingReverse = await _findExistingReplacementOrder(
      parent: order,
      grid: grid,
      replacementSide: replacementSide,
      replacementPrice: reversePrice,
    );
    if (existingReverse != null) {
      final replacement = _isLocalOnlyReplacementCandidate(existingReverse)
          ? await _submitExistingReplacementOrder(
              parent: order,
              grid: grid,
              replacement: existingReverse,
            )
          : existingReverse;
      await _linkExistingReplacementOrder(
        parent: order,
        grid: grid,
        replacement: replacement,
      );
      await logRepository.append(
        strategyId: order.strategyId,
        level: 'info',
        module: 'AUTO_SPOT_GRID',
        message: 'existing replacement order linked',
        extraJson: jsonEncode({
          'parentOrderId': order.id,
          'replacementOrderId': replacement.id,
        }),
      );
      return replacement.id;
    }
    final activeCount = await _activeOrderCountForGrid(grid.id);
    if (activeCount > 0) {
      throw StateError(
        'Grid ${grid.id} 当前已有活动订单，禁止重复补单。'
        'SELL 未成交期间不会创建新的 BUY。',
      );
    }
    await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(grid.id)))
        .write(
      GridLevelsCompanion(
        status: Value(order.side == 'BUY' ? 'buyFilled' : 'sellFilled'),
        lifecycleStatus: Value(
          order.side == 'BUY' ? 'buyFilled' : 'sellFilled',
        ),
        activeOrderId: const Value(null),
        lastCompletedOrderId: Value(order.id),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    final rules = liveExecution.spotRulesForSymbol(order.symbol);
    final reversePriceValue =
        rules == null ? reversePrice : rules.quantizePrice(reversePrice);
    final reverseQuantity = await _replacementQuantityForOrder(
      order,
      replacementSide: replacementSide,
      price: reversePriceValue,
      rules: rules,
    );
    if (rules != null &&
        !rules.isAcceptableOrder(
          price: reversePriceValue,
          quantity: reverseQuantity,
        )) {
      await _insertRiskEvent(
        order.strategyId,
        'residualBtc',
        'warning',
        '部分成交剩余数量不满足最小下单要求，暂不补反向单: order=${order.id}',
      );
      throw StateError('反向数量或金额不满足 minQty/minNotional。');
    }
    final duplicateActive = await _hasActiveOrderForGrid(grid.id);
    if (duplicateActive) {
      await _insertRiskEvent(
        order.strategyId,
        'duplicateReversePrevented',
        'warning',
        '同一固定网格行已存在活动订单，阻止重复补单: parent=${order.id}',
      );
      throw StateError('同一固定网格行已存在活动订单。');
    }
    await _submitGridLevel(
      grid,
      side: replacementSide,
      price: reversePriceValue,
      parentOrderId: order.id,
      quantity: reverseQuantity,
      lifecycleStatus:
          replacementSide == 'BUY' ? 'buySubmitting' : 'sellSubmitting',
    );
    final created = await (db.select(db.orders)
          ..where((tbl) => tbl.parentOrderId.equals(order.id))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)])
          ..limit(1))
        .getSingleOrNull();
    if (created == null) {
      throw StateError('补单提交后未找到本地反向订单。');
    }
    await logRepository.append(
      strategyId: order.strategyId,
      level: 'info',
      module: 'AUTO_SPOT_GRID',
      message: manual
          ? 'manual replacement order created'
          : 'automatic replacement order created',
      extraJson: jsonEncode({
        'parentOrderId': order.id,
        'replacementOrderId': created.id,
      }),
    );
    return created.id;
  }

  Future<void> _syncFutureHedgeLayerForFilledOrder(
    Order order,
    GridLevel grid,
  ) async {
    final editConfig = await loadEditableConfig(order.strategyId);
    if (editConfig?.enableFutureHedgeGrid != true) {
      return;
    }
    if (order.side == 'BUY') {
      try {
        await futureGridEngine.onSpotBuyFilled(order);
      } catch (error) {
        await _insertRiskEvent(
          order.strategyId,
          'futureLayerOpenFailed',
          'warning',
          'Spot BUY 已成交，但价格层 Future Short 开仓失败: grid=${grid.id}, error=$error',
        );
      }
      return;
    }
    if (order.side == 'SELL') {
      try {
        await futureGridEngine.onSpotSellFilled(order);
      } catch (error) {
        await _insertRiskEvent(
          order.strategyId,
          'futureLayerCloseFailed',
          'warning',
          'Spot SELL 已成交，但价格层 Future Short 平仓失败: grid=${grid.id}, error=$error',
        );
      }
    }
  }

  Future<Decimal> _replacementQuantityForOrder(
    Order parent, {
    required String replacementSide,
    required Decimal price,
    required BinanceSymbolRules? rules,
  }) async {
    final parentQty = _d(parent.executedQuantity);
    if (parentQty <= Decimal.zero) {
      return Decimal.zero;
    }
    var quantity = parentQty;
    if (replacementSide == 'SELL') {
      final baseAsset = _baseAssetForSymbol(parent.symbol);
      final available = _assetFree(await _latestAccountAsset(baseAsset));
      quantity = available < quantity ? available : quantity;
    }
    quantity = rules == null ? quantity : rules.quantizeQuantity(quantity);
    if (quantity <= Decimal.zero) {
      return Decimal.zero;
    }
    if (replacementSide == 'SELL' && quantity < parentQty) {
      await logRepository.append(
        strategyId: parent.strategyId,
        level: 'warning',
        module: 'AUTO_SPOT_GRID',
        message: 'replacement SELL quantity capped by available balance: '
            'parent=${parent.id}, requested=$parentQty, adjusted=$quantity',
      );
    }
    return quantity;
  }

  Future<Order> _updateLocalReplacementQuantityIfNeeded(
    Order replacement,
    Decimal quantity,
  ) async {
    if (_d(replacement.originalQuantity) == quantity) {
      return replacement;
    }
    await (db.update(db.orders)..where((tbl) => tbl.id.equals(replacement.id)))
        .write(
      OrdersCompanion(
        originalQuantity: Value(_s(quantity)),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    final updated = await (db.select(db.orders)
          ..where((tbl) => tbl.id.equals(replacement.id)))
        .getSingleOrNull();
    return updated ?? replacement;
  }

  Decimal? _gridBuyPrice(GridLevel level) {
    final raw = level.buyPrice ??
        (level.plannedSide == 'BUY' ? level.price : level.nextLowerPrice);
    if (raw == null) {
      return null;
    }
    final value = _d(raw);
    return value <= Decimal.zero ? null : value;
  }

  Decimal? _gridSellPrice(GridLevel level) {
    final raw = level.sellPrice ??
        (level.plannedSide == 'BUY' ? level.nextUpperPrice : level.price);
    if (raw == null) {
      return null;
    }
    final value = _d(raw);
    return value <= Decimal.zero ? null : value;
  }

  Future<int> _activeOrderCountForGrid(String gridLevelId) async {
    final rows = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.gridLevelId.equals(gridLevelId) &
                tbl.source.equals(source) &
                tbl.status.isIn([
                  'created',
                  'submitting',
                  'new',
                  'partiallyFilled',
                  'cancelling',
                  'unknown',
                ]),
          ))
        .get();
    return rows.length;
  }

  Future<int> _activeFuturesLongOrderCountForGrid(String gridLevelId) async {
    return (await _activeFuturesLongOrdersForGrid(gridLevelId)).length;
  }

  Future<List<Order>> _activeFuturesLongOrdersForGrid(
    String gridLevelId,
  ) async {
    final rows = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.gridLevelId.equals(gridLevelId) &
                tbl.source.equals(futuresLongSource) &
                tbl.status.isIn([
                  'created',
                  'submitting',
                  'new',
                  'partiallyFilled',
                  'cancelling',
                  'unknown',
                ]),
          ))
        .get();
    return rows
        .where((order) => !_isRepairableFuturesLongLocalOrder(order))
        .toList(growable: false);
  }

  bool _isReleasedLocalGridOrder(Order order) {
    final error = order.errorMessage ?? '';
    return error.contains('已释放本地网格') || error.contains('无有效活动状态');
  }

  bool _isRepairableFuturesLongLocalOrder(Order order) {
    return _isReleasedLocalGridOrder(order) ||
        _isFuturesReduceOnlyRejected(order) ||
        _isLocalOnlyZeroFillFuturesLongGridSubmission(order);
  }

  bool _isLocalOnlyZeroFillFuturesLongGridSubmission(Order order) {
    final exchangeOrderId = order.exchangeOrderId;
    return order.source == futuresLongSource &&
        order.marketType == 'usdtFutures' &&
        (order.purpose == 'futuresLongGridBuy' ||
            order.purpose == 'futuresLongGridSell') &&
        (exchangeOrderId == null || exchangeOrderId.isEmpty) &&
        _d(order.executedQuantity) == Decimal.zero &&
        {'created', 'submitting', 'failed', 'unknown'}.contains(order.status);
  }

  Future<bool> _hasActiveOrderForGrid(String gridLevelId) async {
    return (await _activeOrderCountForGrid(gridLevelId)) > 0;
  }

  Future<bool> _hasActiveSameSidePriceOrder({
    required String strategyId,
    required String side,
    required Decimal price,
    String? excludingGridLevelId,
  }) async {
    final rows = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(source) &
                tbl.side.equals(side) &
                tbl.price.equals(_s(price)) &
                tbl.status.isIn([
                  'created',
                  'submitting',
                  'new',
                  'partiallyFilled',
                  'cancelling',
                  'unknown',
                ]),
          ))
        .get();
    return rows.any((order) => order.gridLevelId != excludingGridLevelId);
  }

  Future<void> _ensureNoSamePriceOrderOnExchange({
    required String strategyId,
    required String side,
    required Decimal price,
  }) async {
    final strategy = await _strategy(strategyId);
    final symbol = strategy?.symbol ?? 'BTCUSDT';
    final exchangeOrders = await (db.select(db.exchangeOpenOrders)
          ..where(
            (tbl) =>
                tbl.environment.equals('live') &
                tbl.marketType.equals('spot') &
                tbl.symbol.equals(symbol) &
                tbl.side.equals(side),
          ))
        .get();
    final samePriceOrders = exchangeOrders
        .where((order) => _d(order.price) == price)
        .toList(growable: false);
    if (samePriceOrders.isEmpty) return;
    final details = samePriceOrders
        .map((order) => '${order.clientOrderId}/${order.exchangeOrderId}')
        .join(', ');
    await _insertRiskEvent(
      strategyId,
      'duplicateExchangePriceOrderPrevented',
      'critical',
      'Binance 已存在同方向同价格挂单，禁止重复提交: side=$side price=$price orders=$details',
    );
    throw StateError('Binance 已存在同方向同价格挂单，禁止重复提交。');
  }

  Future<void> _detectDuplicateActiveGridOrders(String strategyId) async {
    final rows = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(source) &
                tbl.status.isIn([
                  'created',
                  'submitting',
                  'new',
                  'partiallyFilled',
                  'cancelling',
                  'unknown',
                ]),
          ))
        .get();
    final groups = <String, List<Order>>{};
    for (final order in rows) {
      final key = '${order.side}|${order.price ?? '-'}';
      groups.putIfAbsent(key, () => []).add(order);
    }
    final duplicates =
        groups.values.where((orders) => orders.length > 1).toList();
    if (duplicates.isEmpty) {
      return;
    }
    final details = duplicates
        .map(
          (orders) => '${orders.first.side} ${orders.first.price ?? '-'}: '
              '${orders.map((order) => order.clientOrderId).join(', ')}',
        )
        .join('; ');
    await _insertRiskEvent(
      strategyId,
      'duplicateActiveGridOrders',
      'critical',
      '检测到同方向同价格重复活动挂单: $details',
    );
    await _setStatus(
      strategyId,
      'paused',
      lastError: '检测到重复活动挂单，已暂停自动补单: $details',
    );
  }

  Future<void> _cancelStrategyOpenOrders(String strategyId) async {
    final orders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(source) &
                tbl.status.isIn([
                  'created',
                  'submitting',
                  'new',
                  'partiallyFilled',
                ]),
          ))
        .get();
    for (final order in orders) {
      try {
        await liveExecution.cancelSpotOrder(order.clientOrderId);
      } catch (_) {
        await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id)))
            .write(
          OrdersCompanion(
            status: const Value('unknown'),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
      }
    }
  }

  Future<void> _checkOutOfRange(String strategyId) async {
    final strategy = await _strategy(strategyId);
    final ticker = marketData.latestSpotTicker;
    if (strategy == null || ticker == null || strategy.status != 'running') {
      return;
    }
    final current = ticker.midPrice;
    final lower = _d(strategy.lowerPrice);
    final upper = _d(strategy.upperPrice);
    final side = current < lower
        ? 'lower'
        : current > upper
            ? 'upper'
            : null;
    if (side == null) {
      _outOfRangeSince.remove(strategyId);
      _outOfRangeSide.remove(strategyId);
      return;
    }
    final now = DateTime.now().toUtc();
    if (_outOfRangeSide[strategyId] != side) {
      _outOfRangeSide[strategyId] = side;
      _outOfRangeSince[strategyId] = now;
      return;
    }
    final since = _outOfRangeSince[strategyId] ?? now;
    if (now.difference(since) >= const Duration(seconds: 30)) {
      await _setStatus(
        strategyId,
        side == 'upper' ? 'outOfRangeUpper' : 'outOfRangeLower',
        lastError: 'price out of range for 30 seconds',
      );
      await _insertRiskEvent(
        strategyId,
        side == 'upper' ? 'outOfRangeUpper' : 'outOfRangeLower',
        'critical',
        'BTCUSDT price out of LIVE spot grid range for 30 seconds',
      );
      liveTradingGate.disable(reason: 'LIVE spot grid out of range');
    }
  }

  Future<void> _handleInvalidOrderTransition({
    required String strategyId,
    required String orderId,
    required String from,
    required String to,
  }) async {
    final message = '非法订单状态流转: order=$orderId $from -> $to';
    await _setStatus(strategyId, 'paused', lastError: message);
    await _insertRiskEvent(
      strategyId,
      'invalidOrderStateTransition',
      'critical',
      message,
    );
    await logRepository.append(
      strategyId: strategyId,
      level: 'error',
      module: 'AUTO_SPOT_GRID',
      message: message,
    );
  }

  Future<int> _openOrderCount(String strategyId) async {
    final rows = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(source) &
                tbl.status.isIn([
                  'created',
                  'submitting',
                  'new',
                  'partiallyFilled',
                ]),
          ))
        .get();
    return rows.length;
  }

  Future<List<GridLevel>> _levels(String strategyId) {
    return (db.select(db.gridLevels)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.gridIndex)]))
        .get();
  }

  Future<SpotAccountSnapshot?> _latestSpotSnapshot() {
    return (db.select(db.spotAccountSnapshots)
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.recordedAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<AccountAsset?> _latestAccountAsset(String asset) {
    return (db.select(db.accountAssets)
          ..where(
            (tbl) =>
                tbl.accountType.equals('spotSubAccount') &
                tbl.asset.equals(asset.toUpperCase()),
          ))
        .getSingleOrNull();
  }

  Decimal _assetFree(AccountAsset? row) =>
      row == null ? Decimal.zero : _d(row.free);

  Decimal _assetLocked(AccountAsset? row) =>
      row == null ? Decimal.zero : _d(row.locked);

  Decimal _assetTotal(AccountAsset? row) =>
      row == null ? Decimal.zero : _d(row.total);

  Future<Strategy?> _strategy(String strategyId) {
    return (db.select(db.strategies)..where((tbl) => tbl.id.equals(strategyId)))
        .getSingleOrNull();
  }

  Future<void> _setStatus(
    String strategyId,
    String status, {
    DateTime? startedAt,
    DateTime? stoppedAt,
    String? lastError,
  }) async {
    await (db.update(db.strategies)..where((tbl) => tbl.id.equals(strategyId)))
        .write(
      StrategiesCompanion(
        status: Value(status),
        startedAt: startedAt == null ? const Value.absent() : Value(startedAt),
        stoppedAt: stoppedAt == null ? const Value.absent() : Value(stoppedAt),
        lastError: lastError == null ? const Value.absent() : Value(lastError),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<void> _setStatusClearError(
    String strategyId,
    String status, {
    DateTime? startedAt,
    DateTime? stoppedAt,
  }) async {
    await (db.update(db.strategies)..where((tbl) => tbl.id.equals(strategyId)))
        .write(
      StrategiesCompanion(
        status: Value(status),
        startedAt: startedAt == null ? const Value.absent() : Value(startedAt),
        stoppedAt: stoppedAt == null ? const Value.absent() : Value(stoppedAt),
        lastError: const Value(null),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<void> _setError(String strategyId, String error) async {
    await _setStatus(strategyId, 'error', lastError: error);
  }

  Future<void> _recalculateStrategyBtc(String strategyId) async {
    final fills = await (db.select(db.fills)
          ..where((tbl) => tbl.strategyId.equals(strategyId)))
        .get();
    var btc = Decimal.zero;
    for (final fill in fills) {
      final qty = _d(fill.quantity);
      btc += fill.side == 'BUY' ? qty : -qty;
    }
    await (db.update(db.strategies)..where((tbl) => tbl.id.equals(strategyId)))
        .write(
      StrategiesCompanion(
        strategySpotBtc: Value(_s(btc)),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<void> _insertRiskEvent(
    String strategyId,
    String type,
    String level,
    String message,
  ) async {
    await db.into(db.riskEvents).insert(
          RiskEventsCompanion.insert(
            id: _uuid.v4(),
            strategyId: strategyId,
            type: type,
            level: level,
            message: message,
            actionTaken: const Value('stopNewOrders'),
            createdAt: DateTime.now().toUtc(),
          ),
        );
  }

  Future<void> _saveEditableConfig(
    String strategyId,
    LiveSpotGridEditableConfig config,
  ) async {
    await db.into(db.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: _configKey(strategyId),
            value: jsonEncode(config.toJson()),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }

  String _configKey(String strategyId) => 'live_spot_grid_config_$strategyId';

  bool _canEditStatus(String status) {
    return status == 'idle' || status == 'stopped' || status == 'error';
  }

  String statusText(String status) {
    switch (status) {
      case 'idle':
        return '未启动，仅已创建策略配置';
      case 'validating':
        return '正在执行启动前检查';
      case 'previewReady':
        return '预演通过，尚未真实下单';
      case 'starting':
        return '正在建立初始库存和提交首批订单';
      case 'running':
        return '正在运行，真实订单已经提交 Binance';
      case 'pausedKeepOrders':
        return '已暂停，保留交易所挂单';
      case 'pausedCancelOrders':
        return '已暂停，挂单已撤销';
      case 'paused':
        return '已暂停';
      case 'reconciling':
        return '正在与 Binance 对账';
      case 'outOfRangeUpper':
        return '已突破上限，停止新增买单';
      case 'outOfRangeLower':
        return '已跌破下限，停止新增买单';
      case 'stopping':
        return '正在停止';
      case 'stopped':
        return '已停止';
      case 'circuitBreaker':
        return '已熔断';
      case 'error':
        return '运行异常';
      default:
        return status;
    }
  }

  String _lastSuccessFor(String status) {
    switch (status) {
      case 'previewReady':
        return '启动预演通过';
      case 'running':
        return 'LIVE 网格已启动';
      case 'pausedKeepOrders':
        return '已保留挂单暂停';
      case 'pausedCancelOrders':
        return '已撤销挂单暂停';
      case 'stopped':
        return '策略已停止';
      default:
        return '-';
    }
  }

  String _normalizeExchangeStatus(String status) {
    switch (status.toUpperCase()) {
      case 'NEW':
        return 'new';
      case 'PARTIALLY_FILLED':
        return 'partiallyFilled';
      case 'FILLED':
        return 'filled';
      case 'CANCELED':
        return 'cancelled';
      case 'REJECTED':
        return 'rejected';
      case 'EXPIRED':
        return 'expired';
      default:
        return 'unknown';
    }
  }

  String _profileScope(String? keyProfileId) {
    final value = keyProfileId?.trim();
    return value == null || value.isEmpty ? 'legacy' : value;
  }

  void _debugTrace(String tag, String message) {
    assert(() {
      // ignore: avoid_print
      print('[GH_DIAG][$tag] $message');
      return true;
    }());
  }

  Future<bool> _trySyncFuturesOrderFromBinance(Order order) async {
    try {
      return await liveExecution.syncFuturesOrderFromBinance(order);
    } catch (error) {
      _debugTrace(
        'LONG_RECONCILE',
        'direct query failed client=${order.clientOrderId} '
            'grid=${order.gridLevelId ?? '-'} side=${order.side} '
            'error=$error',
      );
      return false;
    }
  }

  bool _shouldDirectQueryMissingFuturesHistory(Order order) {
    return const {
      'created',
      'submitting',
      'new',
      'partiallyFilled',
      'unknown',
    }.contains(order.status);
  }

  bool _shouldReleaseMissingFuturesLongOpenOrder(Order order, DateTime now) {
    return now.toUtc().difference(order.createdAt.toUtc()) >=
        const Duration(seconds: 60);
  }

  Decimal _d(String value) => Decimal.tryParse(value) ?? Decimal.zero;

  String _s(Decimal value) => value.toString();

  Decimal _abs(Decimal value) => value < Decimal.zero ? -value : value;

  Map<String, Object?> _rulesDetails(SpotExchangeRulesDiagnostics diagnostics) {
    return {
      'requestUrl': diagnostics.url,
      'httpStatus': diagnostics.httpStatus,
      'binanceCode': diagnostics.binanceCode,
      'binanceMessage': diagnostics.binanceMessage,
      'lastSuccessAt': diagnostics.lastSuccessAt?.toIso8601String(),
      'lastAttemptAt': diagnostics.lastAttemptAt?.toIso8601String(),
      'usingCache': diagnostics.usingCache,
      'lastError': diagnostics.lastError,
    };
  }
}

class _LiveGridInterval {
  const _LiveGridInterval({
    required this.index,
    required this.buyPrice,
    required this.sellPrice,
  });

  final int index;
  final Decimal buyPrice;
  final Decimal sellPrice;
}

class _GridRuntimeSnapshot {
  const _GridRuntimeSnapshot({
    required this.lifecycleStatus,
    this.currentOrderId,
    this.activeOrderId,
    this.lastBuyOrderId,
    this.lastSellOrderId,
    this.lastCompletedOrderId,
    this.cycleNumber = 0,
  });

  final String lifecycleStatus;
  final String? currentOrderId;
  final String? activeOrderId;
  final String? lastBuyOrderId;
  final String? lastSellOrderId;
  final String? lastCompletedOrderId;
  final int cycleNumber;
}

Decimal _parseDecimal(String value) => Decimal.tryParse(value) ?? Decimal.zero;
