import 'package:decimal/decimal.dart';

import '../spot/spot_account_models.dart';

class FuturesWalletBalance {
  const FuturesWalletBalance({
    required this.asset,
    required this.walletBalance,
    required this.availableBalance,
    required this.unrealizedPnl,
  });

  final String asset;
  final Decimal walletBalance;
  final Decimal availableBalance;
  final Decimal unrealizedPnl;

  factory FuturesWalletBalance.fromAssetJson(Map<String, dynamic> json, {String? availableBalance}) {
    return FuturesWalletBalance(
      asset: json['asset']?.toString() ?? '',
      walletBalance: decimalFromJson(json['walletBalance']),
      availableBalance: decimalFromJson(json['availableBalance'] ?? availableBalance),
      unrealizedPnl: decimalFromJson(json['unrealizedProfit'] ?? json['unrealizedPnl']),
    );
  }
}

class FuturesPosition {
  const FuturesPosition({
    required this.symbol,
    required this.positionSide,
    required this.positionAmount,
    required this.entryPrice,
    required this.markPrice,
    required this.unrealizedPnl,
    required this.leverage,
    required this.marginType,
    required this.liquidationPrice,
    required this.updatedAt,
  });

  final String symbol;
  final String positionSide;
  final Decimal positionAmount;
  final Decimal entryPrice;
  final Decimal markPrice;
  final Decimal unrealizedPnl;
  final String leverage;
  final String marginType;
  final Decimal? liquidationPrice;
  final DateTime updatedAt;

  bool get isLong => positionSide == 'LONG' || (positionSide == 'BOTH' && positionAmount > Decimal.zero);
  bool get isShort => positionSide == 'SHORT' || (positionSide == 'BOTH' && positionAmount < Decimal.zero);

  factory FuturesPosition.fromJson(Map<String, dynamic> json) {
    return FuturesPosition(
      symbol: json['symbol']?.toString() ?? '',
      positionSide: json['positionSide']?.toString() ?? 'BOTH',
      positionAmount: decimalFromJson(json['positionAmt']),
      entryPrice: decimalFromJson(json['entryPrice']),
      markPrice: decimalFromJson(json['markPrice']),
      unrealizedPnl: decimalFromJson(json['unRealizedProfit'] ?? json['unrealizedProfit']),
      leverage: json['leverage']?.toString() ?? '',
      marginType: json['marginType']?.toString() ?? '',
      liquidationPrice: json['liquidationPrice'] == null ? null : decimalFromJson(json['liquidationPrice']),
      updatedAt: json['updateTime'] == null || json['updateTime'].toString() == '0' ? DateTime.now().toUtc() : timeFromMs(json['updateTime']),
    );
  }
}

class FuturesOrder {
  const FuturesOrder({
    required this.symbol,
    required this.orderId,
    required this.clientOrderId,
    required this.side,
    required this.positionSide,
    required this.type,
    required this.timeInForce,
    required this.price,
    required this.originalQuantity,
    required this.executedQuantity,
    required this.averagePrice,
    required this.status,
    required this.reduceOnly,
    required this.createdAt,
    required this.updatedAt,
  });

  final String symbol;
  final String orderId;
  final String clientOrderId;
  final String side;
  final String positionSide;
  final String type;
  final String timeInForce;
  final Decimal price;
  final Decimal originalQuantity;
  final Decimal executedQuantity;
  final Decimal averagePrice;
  final String status;
  final bool reduceOnly;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory FuturesOrder.fromJson(Map<String, dynamic> json) {
    return FuturesOrder(
      symbol: json['symbol']?.toString() ?? '',
      orderId: json['orderId']?.toString() ?? '',
      clientOrderId: json['clientOrderId']?.toString() ?? json['origClientOrderId']?.toString() ?? '',
      side: json['side']?.toString() ?? '',
      positionSide: json['positionSide']?.toString() ?? 'BOTH',
      type: json['type']?.toString() ?? '',
      timeInForce: json['timeInForce']?.toString() ?? '',
      price: decimalFromJson(json['price']),
      originalQuantity: decimalFromJson(json['origQty']),
      executedQuantity: decimalFromJson(json['executedQty']),
      averagePrice: decimalFromJson(json['avgPrice']),
      status: json['status']?.toString() ?? '',
      reduceOnly: json['reduceOnly'] == true,
      createdAt: timeFromMs(json['time'] ?? json['updateTime']),
      updatedAt: timeFromMs(json['updateTime'] ?? json['time']),
    );
  }
}

class FuturesOpenOrder extends FuturesOrder {
  const FuturesOpenOrder({
    required super.symbol,
    required super.orderId,
    required super.clientOrderId,
    required super.side,
    required super.positionSide,
    required super.type,
    required super.timeInForce,
    required super.price,
    required super.originalQuantity,
    required super.executedQuantity,
    required super.averagePrice,
    required super.status,
    required super.reduceOnly,
    required super.createdAt,
    required super.updatedAt,
  });

  factory FuturesOpenOrder.fromJson(Map<String, dynamic> json) {
    final order = FuturesOrder.fromJson(json);
    return FuturesOpenOrder(
      symbol: order.symbol,
      orderId: order.orderId,
      clientOrderId: order.clientOrderId,
      side: order.side,
      positionSide: order.positionSide,
      type: order.type,
      timeInForce: order.timeInForce,
      price: order.price,
      originalQuantity: order.originalQuantity,
      executedQuantity: order.executedQuantity,
      averagePrice: order.averagePrice,
      status: order.status,
      reduceOnly: order.reduceOnly,
      createdAt: order.createdAt,
      updatedAt: order.updatedAt,
    );
  }
}

class FuturesHistoricalOrder extends FuturesOrder {
  const FuturesHistoricalOrder({
    required super.symbol,
    required super.orderId,
    required super.clientOrderId,
    required super.side,
    required super.positionSide,
    required super.type,
    required super.timeInForce,
    required super.price,
    required super.originalQuantity,
    required super.executedQuantity,
    required super.averagePrice,
    required super.status,
    required super.reduceOnly,
    required super.createdAt,
    required super.updatedAt,
  });

  factory FuturesHistoricalOrder.fromJson(Map<String, dynamic> json) {
    final order = FuturesOrder.fromJson(json);
    return FuturesHistoricalOrder(
      symbol: order.symbol,
      orderId: order.orderId,
      clientOrderId: order.clientOrderId,
      side: order.side,
      positionSide: order.positionSide,
      type: order.type,
      timeInForce: order.timeInForce,
      price: order.price,
      originalQuantity: order.originalQuantity,
      executedQuantity: order.executedQuantity,
      averagePrice: order.averagePrice,
      status: order.status,
      reduceOnly: order.reduceOnly,
      createdAt: order.createdAt,
      updatedAt: order.updatedAt,
    );
  }
}

class FuturesTrade {
  const FuturesTrade({
    required this.symbol,
    required this.id,
    required this.orderId,
    required this.side,
    required this.positionSide,
    required this.price,
    required this.quantity,
    required this.quoteQuantity,
    required this.commission,
    required this.commissionAsset,
    required this.realizedPnl,
    required this.isMaker,
    required this.tradeTime,
  });

  final String symbol;
  final String id;
  final String orderId;
  final String side;
  final String positionSide;
  final Decimal price;
  final Decimal quantity;
  final Decimal quoteQuantity;
  final Decimal commission;
  final String commissionAsset;
  final Decimal realizedPnl;
  final bool isMaker;
  final DateTime tradeTime;

  factory FuturesTrade.fromJson(Map<String, dynamic> json) {
    return FuturesTrade(
      symbol: json['symbol']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      orderId: json['orderId']?.toString() ?? '',
      side: json['side']?.toString() ?? '',
      positionSide: json['positionSide']?.toString() ?? 'BOTH',
      price: decimalFromJson(json['price']),
      quantity: decimalFromJson(json['qty']),
      quoteQuantity: decimalFromJson(json['quoteQty']),
      commission: decimalFromJson(json['commission']),
      commissionAsset: json['commissionAsset']?.toString() ?? '',
      realizedPnl: decimalFromJson(json['realizedPnl']),
      isMaker: json['maker'] == true,
      tradeTime: timeFromMs(json['time']),
    );
  }
}

class FundingFeeRecord {
  const FundingFeeRecord({
    required this.symbol,
    required this.income,
    required this.asset,
    required this.info,
    required this.transactionId,
    required this.time,
  });

  final String symbol;
  final Decimal income;
  final String asset;
  final String info;
  final String transactionId;
  final DateTime time;

  factory FundingFeeRecord.fromJson(Map<String, dynamic> json) {
    return FundingFeeRecord(
      symbol: json['symbol']?.toString() ?? '',
      income: decimalFromJson(json['income']),
      asset: json['asset']?.toString() ?? '',
      info: json['info']?.toString() ?? '',
      transactionId: json['tranId']?.toString() ?? '',
      time: timeFromMs(json['time']),
    );
  }
}

class FuturesAccountSnapshot {
  const FuturesAccountSnapshot({
    required this.walletBalance,
    required this.availableBalance,
    required this.totalUnrealizedPnl,
    required this.assets,
    required this.positions,
    required this.positionMode,
  });

  final Decimal walletBalance;
  final Decimal availableBalance;
  final Decimal totalUnrealizedPnl;
  final List<FuturesWalletBalance> assets;
  final List<FuturesPosition> positions;
  final String positionMode;

  factory FuturesAccountSnapshot.fromJson(Map<String, dynamic> json) {
    final availableBalance = json['availableBalance']?.toString();
    final assets = (json['assets'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => FuturesWalletBalance.fromAssetJson(Map<String, dynamic>.from(item), availableBalance: availableBalance))
        .toList();
    final positions = (json['positions'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => FuturesPosition.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    return FuturesAccountSnapshot(
      walletBalance: decimalFromJson(json['totalWalletBalance']),
      availableBalance: decimalFromJson(json['availableBalance']),
      totalUnrealizedPnl: decimalFromJson(json['totalUnrealizedProfit']),
      assets: assets,
      positions: positions,
      positionMode: positions.any((position) => position.positionSide == 'LONG' || position.positionSide == 'SHORT') ? 'HEDGE' : 'ONE_WAY',
    );
  }
}
