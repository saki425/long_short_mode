import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/database/app_database.dart';
import 'package:grid_hedge_trader/services/market_data/binance_futures_market_stream.dart';
import 'package:grid_hedge_trader/services/market_data/binance_spot_market_stream.dart';
import 'package:grid_hedge_trader/services/market_data/market_data_coordinator.dart';
import 'package:grid_hedge_trader/services/market_data/market_data_status.dart';

void main() {
  late AppDatabase db;
  late StreamController<dynamic> spotController;
  late StreamController<dynamic> futuresController;
  late MarketDataCoordinator coordinator;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    spotController = StreamController<dynamic>();
    futuresController = StreamController<dynamic>();
    coordinator = MarketDataCoordinator(
      db: db,
      spotStream: BinanceSpotMarketStream(
        streamFactory: (_) => spotController.stream,
      ),
      futuresStream: BinanceFuturesMarketStream(
        streamFactory: (_) => futuresController.stream,
      ),
    );
  });

  tearDown(() async {
    await coordinator.disconnect();
    await spotController.close();
    await futuresController.close();
    await db.close();
  });

  Future<void> connectBtcWorkspace() async {
    await coordinator.setWorkspaceSymbols(const [
      'BTCUSDT',
    ], activeSymbol: 'BTCUSDT');
    await coordinator.setMode(MarketDataMode.binanceLive);
  }

  test('two streams both receiving first data makes coordinator ready', () async {
    await connectBtcWorkspace();
    spotController.add(
      '{"s":"BTCUSDT","b":"58999.9","B":"1","a":"59000.1","A":"1"}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      coordinator.status.overallStatus,
      isNot(MarketConnectionStatus.ready),
    );

    futuresController.add(
      '{"e":"markPriceUpdate","E":1562305380000,"s":"BTCUSDT","p":"59003.2","i":"59000","P":"59000","r":"0.0001","T":1562306400000}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(coordinator.status.overallStatus, MarketConnectionStatus.ready);
    expect(coordinator.latestSpotTicker?.askPrice.toString(), '59000.1');
    expect(coordinator.latestFuturesMarkPrice?.markPrice.toString(), '59003.2');
  });

  test(
    'ui market stream emits after startup cancels pending workspace tick',
    () async {
      final tickFuture = coordinator.uiMarketStream
          .firstWhere((tick) => tick.spot?.symbol == 'BTCUSDT')
          .timeout(const Duration(seconds: 1));

      await connectBtcWorkspace();
      spotController.add(
        '{"s":"BTCUSDT","b":"58999.9","B":"1","a":"59000.1","A":"1"}',
      );

      final tick = await tickFuture;

      expect(tick.spot?.bidPrice.toString(), '58999.9');
      expect(tick.spot?.askPrice.toString(), '59000.1');
    },
  );

  test('single stream stale makes coordinator stale', () async {
    await connectBtcWorkspace();
    spotController.add('{"s":"BTCUSDT","b":"1","B":"1","a":"2","A":"1"}');
    futuresController.add(
      '{"e":"markPriceUpdate","E":1562305380000,"s":"BTCUSDT","p":"2","i":"2","P":"2","r":"0","T":1562306400000}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    coordinator.checkHealth(
      now: DateTime.now().toUtc().add(const Duration(seconds: 16)),
    );

    expect(coordinator.status.overallStatus, MarketConnectionStatus.stale);
  });

  test('writes throttled market snapshot on demand', () async {
    await connectBtcWorkspace();
    spotController.add(
      '{"s":"BTCUSDT","b":"58999.9","B":"1","a":"59000.1","A":"1"}',
    );
    futuresController.add(
      '{"e":"markPriceUpdate","E":1562305380000,"s":"BTCUSDT","p":"59003.2","i":"59000","P":"59000","r":"0.0001","T":1562306400000}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await coordinator.writeMarketSnapshot();
    final rows = await db.select(db.marketSnapshots).get();

    expect(rows, hasLength(1));
    expect(rows.single.spotMid, '59000');
    expect(rows.single.futuresMarkPrice, '59003.2');
  });
}
