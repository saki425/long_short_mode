import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import 'binance_symbol_rules.dart';

class BinanceExchangeInfoService {
  BinanceExchangeInfoService({
    Dio? dio,
    this.spotBaseUrl = 'https://api.binance.com',
    this.futuresBaseUrl = 'https://fapi.binance.com/fapi',
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 10),
             ),
           );

  final Dio _dio;
  final String spotBaseUrl;
  final String futuresBaseUrl;

  Future<BinanceSymbolRules> loadSpotRules({required String symbol}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '$spotBaseUrl/api/v3/exchangeInfo',
      queryParameters: {'symbol': symbol},
    );
    return parseSpotSymbolRules(response.data, symbol: symbol);
  }

  Future<BinanceSymbolRules> loadFuturesRules({required String symbol}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '$futuresBaseUrl/v1/exchangeInfo',
      queryParameters: {'symbol': symbol},
    );
    return parseFuturesSymbolRules(response.data, symbol: symbol);
  }

  static BinanceSymbolRules parseSpotSymbolRules(
    Map<String, dynamic>? json, {
    required String symbol,
  }) {
    final data = _extractSymbolJson(json, symbol);
    final filters =
        (data['filters'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
    return BinanceSymbolRules(
      symbol: symbol,
      marketType: 'spot',
      tickSize:
          _decimalFilter(filters, 'PRICE_FILTER', 'tickSize') ??
          Decimal.parse('0.01'),
      stepSize:
          _decimalFilter(filters, 'LOT_SIZE', 'stepSize') ??
          Decimal.parse('0.000001'),
      minQty: _decimalFilter(filters, 'LOT_SIZE', 'minQty') ?? Decimal.zero,
      maxQty:
          _decimalFilter(filters, 'LOT_SIZE', 'maxQty') ??
          Decimal.parse('99999999'),
      minNotional:
          _decimalFilter(filters, 'MIN_NOTIONAL', 'minNotional') ??
          _decimalFilter(filters, 'NOTIONAL', 'minNotional') ??
          Decimal.zero,
      pricePrecision:
          int.tryParse(data['pricePrecision']?.toString() ?? '') ?? 2,
      quantityPrecision:
          int.tryParse(data['quantityPrecision']?.toString() ?? '') ?? 6,
    );
  }

  static BinanceSymbolRules parseFuturesSymbolRules(
    Map<String, dynamic>? json, {
    required String symbol,
  }) {
    final data = _extractSymbolJson(json, symbol);
    final filters =
        (data['filters'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
    final lotSize =
        _decimalFilter(filters, 'MARKET_LOT_SIZE', 'stepSize') ??
        _decimalFilter(filters, 'LOT_SIZE', 'stepSize') ??
        Decimal.parse('0.001');
    return BinanceSymbolRules(
      symbol: symbol,
      marketType: 'usdtFutures',
      tickSize:
          _decimalFilter(filters, 'PRICE_FILTER', 'tickSize') ??
          Decimal.parse('0.1'),
      stepSize: lotSize,
      minQty:
          _decimalFilter(filters, 'MARKET_LOT_SIZE', 'minQty') ??
          _decimalFilter(filters, 'LOT_SIZE', 'minQty') ??
          Decimal.zero,
      maxQty:
          _decimalFilter(filters, 'MARKET_LOT_SIZE', 'maxQty') ??
          _decimalFilter(filters, 'LOT_SIZE', 'maxQty') ??
          Decimal.parse('99999999'),
      minNotional:
          _decimalFilter(filters, 'MIN_NOTIONAL', 'notional') ??
          _decimalFilter(filters, 'MIN_NOTIONAL', 'minNotional') ??
          _decimalFilter(filters, 'NOTIONAL', 'notional') ??
          Decimal.zero,
      pricePrecision:
          int.tryParse(data['pricePrecision']?.toString() ?? '') ?? 2,
      quantityPrecision:
          int.tryParse(data['quantityPrecision']?.toString() ?? '') ?? 3,
    );
  }

  static Map<String, dynamic> _extractSymbolJson(
    Map<String, dynamic>? json,
    String symbol,
  ) {
    if (json == null) {
      return <String, dynamic>{'symbol': symbol};
    }
    final symbols =
        (json['symbols'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
    if (symbols.isEmpty) {
      return json;
    }
    final match = symbols.firstWhere(
      (item) => item['symbol']?.toString() == symbol,
      orElse: () => symbols.first,
    );
    return match;
  }

  static Decimal? _decimalFilter(
    List<Map<String, dynamic>> filters,
    String filterType,
    String key,
  ) {
    for (final filter in filters) {
      if (filter['filterType']?.toString() == filterType) {
        final raw = filter[key]?.toString();
        if (raw == null || raw.isEmpty) {
          return null;
        }
        return Decimal.tryParse(raw);
      }
    }
    return null;
  }
}
