import 'dart:async';
import 'dart:math' as math;

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/services/market_data/binance_futures_market_stream.dart';
import 'package:grid_hedge_trader/services/market_data/binance_spot_market_stream.dart';
import 'package:grid_hedge_trader/services/market_data/futures_mark_price.dart';
import 'package:grid_hedge_trader/services/market_data/market_data_status.dart';
import 'package:grid_hedge_trader/services/market_data/spot_book_ticker.dart';

void main() {
  test('parses spot bookTicker JSON with Decimal precision', () {
    final ticker = SpotBookTicker.fromJson({
      's': 'BTCUSDT',
      'b': '58999.90000000',
      'B': '1.23000000',
      'a': '59000.10000000',
      'A': '2.34000000',
    });

    expect(ticker.symbol, 'BTCUSDT');
    expect(ticker.bidPrice, Decimal.parse('58999.90000000'));
    expect(ticker.askPrice, Decimal.parse('59000.10000000'));
    expect(ticker.midPrice, Decimal.fromInt(59000));
    expect(ticker.spread, Decimal.parse('0.20000000'));
  });

  test('spot parser rejects missing fields', () {
    expect(() => SpotBookTicker.fromJson({'s': 'BTCUSDT'}), throwsFormatException);
  });

  test('parses futures markPrice JSON', () {
    final mark = FuturesMarkPrice.fromJson({
      'e': 'markPriceUpdate',
      'E': 1562305380000,
      's': 'BTCUSDT',
      'p': '11794.15000000',
      'i': '11784.62659091',
      'P': '11784.25641265',
      'r': '0.00038167',
      'T': 1562306400000,
    });

    expect(mark.symbol, 'BTCUSDT');
    expect(mark.markPrice, Decimal.parse('11794.15000000'));
    expect(mark.indexPrice, Decimal.parse('11784.62659091'));
    expect(mark.fundingRate, Decimal.parse('0.00038167'));
    expect(mark.eventTime, DateTime.fromMillisecondsSinceEpoch(1562305380000, isUtc: true));
  });

  test('futures markPrice websocket uses market route', () {
    expect(
      futuresMarkPriceStreamUrl('BTCUSDT'),
      'wss://fstream.binance.com/market/ws/btcusdt@markPrice@1s',
    );
    expect(futuresMarkPriceStreamName('BTCUSDT'), 'btcusdt@markPrice@1s');
  });

  test('futures parser rejects missing fields', () {
    expect(() => FuturesMarkPrice.fromJson({'s': 'BTCUSDT'}), throwsFormatException);
  });

  test('invalid spot JSON emits error event and does not close stream', () async {
    final controller = StreamController<dynamic>.broadcast();
    final stream = BinanceSpotMarketStream(streamFactory: (_) => controller.stream);
    final events = <MarketConnectionStatus?>[];
    final sub = stream.events.listen((event) => events.add(event.status));

    await stream.connect();
    controller.add('{bad json');
    controller.add('{"s":"BTCUSDT","b":"1","B":"2","a":"3","A":"4"}');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(events, contains(MarketConnectionStatus.error));
    expect(events, contains(MarketConnectionStatus.ready));
    await sub.cancel();
    await stream.disconnect();
    await controller.close();
  });

  test('serverShutdown triggers reconnecting event', () async {
    final controller = StreamController<dynamic>.broadcast();
    final stream = BinanceFuturesMarketStream(streamFactory: (_) => controller.stream);
    final statuses = <MarketConnectionStatus?>[];
    final sub = stream.events.listen((event) => statuses.add(event.status));

    await stream.connect();
    controller.add('{"e":"serverShutdown","E":1770123456789}');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(statuses, contains(MarketConnectionStatus.reconnecting));
    await sub.cancel();
    await stream.disconnect();
    await controller.close();
  });

  test('exponential backoff is capped with jitter', () {
    final d1 = BinanceSpotMarketStream.reconnectDelayForAttempt(1, math.Random(1));
    final d2 = BinanceSpotMarketStream.reconnectDelayForAttempt(2, math.Random(1));
    final d6 = BinanceSpotMarketStream.reconnectDelayForAttempt(6, math.Random(1));

    expect(d1 >= const Duration(seconds: 1), isTrue);
    expect(d1 <= const Duration(milliseconds: 1500), isTrue);
    expect(d2 >= const Duration(seconds: 2), isTrue);
    expect(d2 <= const Duration(milliseconds: 2500), isTrue);
    expect(d6 >= const Duration(seconds: 30), isTrue);
    expect(d6 <= const Duration(milliseconds: 30500), isTrue);
  });
}
