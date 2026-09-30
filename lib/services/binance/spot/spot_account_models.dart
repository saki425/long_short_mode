import 'package:decimal/decimal.dart';

Decimal decimalFromJson(Object? value) => Decimal.parse(value?.toString() ?? '0');
DateTime timeFromMs(Object? value) => DateTime.fromMillisecondsSinceEpoch(int.parse(value?.toString() ?? '0'), isUtc: true);

class SpotAssetBalance {
  const SpotAssetBalance({
    required this.asset,
    required this.free,
    required this.locked,
  });

  final String asset;
  final Decimal free;
  final Decimal locked;
  Decimal get total => free + locked;

  factory SpotAssetBalance.fromJson(Map<String, dynamic> json) {
    return SpotAssetBalance(
      asset: json['asset']?.toString() ?? '',
      free: decimalFromJson(json['free']),
      locked: decimalFromJson(json['locked']),
    );
  }
}

class SpotAccountSnapshot {
  const SpotAccountSnapshot({
    required this.balances,
    required this.canTrade,
    required this.canWithdraw,
    required this.permissions,
    required this.updateTime,
  });

  final List<SpotAssetBalance> balances;
  final bool canTrade;
  final bool canWithdraw;
  final List<String> permissions;
  final DateTime? updateTime;

  SpotAssetBalance balanceOf(String asset) {
    return balances.firstWhere(
      (balance) => balance.asset == asset,
      orElse: () => SpotAssetBalance(asset: asset, free: Decimal.zero, locked: Decimal.zero),
    );
  }

  factory SpotAccountSnapshot.fromJson(Map<String, dynamic> json) {
    final balances = (json['balances'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => SpotAssetBalance.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    return SpotAccountSnapshot(
      balances: balances,
      canTrade: json['canTrade'] == true,
      canWithdraw: json['canWithdraw'] == true,
      permissions: (json['permissions'] as List? ?? const []).map((item) => item.toString()).toList(),
      updateTime: json['updateTime'] == null ? null : timeFromMs(json['updateTime']),
    );
  }
}

class SpotOpenOrder {
  const SpotOpenOrder({
    required this.symbol,
    required this.orderId,
    required this.clientOrderId,
    required this.price,
    required this.originalQuantity,
    required this.executedQuantity,
    required this.status,
    required this.timeInForce,
    required this.type,
    required this.side,
    required this.createdAt,
    required this.updatedAt,
  });

  final String symbol;
  final String orderId;
  final String clientOrderId;
  final Decimal price;
  final Decimal originalQuantity;
  final Decimal executedQuantity;
  final String status;
  final String timeInForce;
  final String type;
  final String side;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory SpotOpenOrder.fromJson(Map<String, dynamic> json) {
    return SpotOpenOrder(
      symbol: json['symbol']?.toString() ?? '',
      orderId: json['orderId']?.toString() ?? '',
      clientOrderId: json['clientOrderId']?.toString() ?? '',
      price: decimalFromJson(json['price']),
      originalQuantity: decimalFromJson(json['origQty']),
      executedQuantity: decimalFromJson(json['executedQty']),
      status: json['status']?.toString() ?? '',
      timeInForce: json['timeInForce']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      side: json['side']?.toString() ?? '',
      createdAt: timeFromMs(json['time']),
      updatedAt: timeFromMs(json['updateTime'] ?? json['time']),
    );
  }
}

class SpotHistoricalOrder extends SpotOpenOrder {
  const SpotHistoricalOrder({
    required super.symbol,
    required super.orderId,
    required super.clientOrderId,
    required super.price,
    required super.originalQuantity,
    required super.executedQuantity,
    required super.status,
    required super.timeInForce,
    required super.type,
    required super.side,
    required super.createdAt,
    required super.updatedAt,
    required this.quoteQuantity,
  });

  final Decimal quoteQuantity;

  factory SpotHistoricalOrder.fromJson(Map<String, dynamic> json) {
    final order = SpotOpenOrder.fromJson(json);
    return SpotHistoricalOrder(
      symbol: order.symbol,
      orderId: order.orderId,
      clientOrderId: order.clientOrderId,
      price: order.price,
      originalQuantity: order.originalQuantity,
      executedQuantity: order.executedQuantity,
      status: order.status,
      timeInForce: order.timeInForce,
      type: order.type,
      side: order.side,
      createdAt: order.createdAt,
      updatedAt: order.updatedAt,
      quoteQuantity: decimalFromJson(json['cummulativeQuoteQty']),
    );
  }
}

class SpotTrade {
  const SpotTrade({
    required this.symbol,
    required this.id,
    required this.orderId,
    required this.price,
    required this.quantity,
    required this.quoteQuantity,
    required this.commission,
    required this.commissionAsset,
    required this.side,
    required this.isMaker,
    required this.tradeTime,
  });

  final String symbol;
  final String id;
  final String orderId;
  final Decimal price;
  final Decimal quantity;
  final Decimal quoteQuantity;
  final Decimal commission;
  final String commissionAsset;
  final String side;
  final bool isMaker;
  final DateTime tradeTime;

  factory SpotTrade.fromJson(Map<String, dynamic> json) {
    return SpotTrade(
      symbol: json['symbol']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      orderId: json['orderId']?.toString() ?? '',
      price: decimalFromJson(json['price']),
      quantity: decimalFromJson(json['qty']),
      quoteQuantity: decimalFromJson(json['quoteQty']),
      commission: decimalFromJson(json['commission']),
      commissionAsset: json['commissionAsset']?.toString() ?? '',
      side: json['isBuyer'] == true ? 'BUY' : 'SELL',
      isMaker: json['isMaker'] == true,
      tradeTime: timeFromMs(json['time']),
    );
  }
}
