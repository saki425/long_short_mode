import 'futures_mark_price.dart';
import 'market_data_status.dart';
import 'market_tick.dart';
import 'spot_book_ticker.dart';

abstract class MarketDataService {
  Stream<SpotBookTicker> get spotBookTickerStream;
  Stream<FuturesMarkPrice> get futuresMarkPriceStream;
  Stream<MarketDataStatus> get statusStream;
  Stream<MarketTick> get uiMarketStream;

  SpotBookTicker? get latestSpotTicker;
  FuturesMarkPrice? get latestFuturesMarkPrice;
  MarketDataStatus get status;

  Future<void> connect();
  Future<void> disconnect();
  Future<void> reconnect();
  Future<void> setMode(MarketDataMode mode);
}
