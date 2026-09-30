import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/services/binance/auth/binance_credentials.dart';
import 'package:grid_hedge_trader/services/binance/auth/binance_signed_request.dart';
import 'package:grid_hedge_trader/services/binance/auth/binance_signature_service.dart';
import 'package:grid_hedge_trader/services/binance/futures/futures_account_models.dart';
import 'package:grid_hedge_trader/services/binance/auth/binance_server_time_service.dart';
import 'package:grid_hedge_trader/services/binance/futures/binance_futures_account_client.dart';
import 'package:grid_hedge_trader/services/binance/futures/futures_user_data_stream.dart';
import 'package:grid_hedge_trader/services/binance/spot/spot_account_models.dart';
import 'package:grid_hedge_trader/services/binance/spot/spot_user_data_stream.dart';
import 'package:grid_hedge_trader/services/security/secure_key_storage.dart';

void main() {
  test('HMAC signature and parameter sorting are deterministic', () {
    const signer = BinanceSignatureService();

    final query = signer.canonicalQuery({'b': 2, 'a': 1});
    final signature = signer.hmacSha256(secretKey: 'secret', payload: query);

    expect(query, 'a=1&b=2');
    expect(
      signature,
      '604fe97c66c6393ff22e3cae366eee1131e351ebc736bf12f5d62e1755b7a233',
    );
  });

  test(
    'signed request sends parameters in the same canonical order as signature payload',
    () {
      const factory = BinanceSignedRequestFactory(
        signatureService: BinanceSignatureService(),
        recvWindowMs: 5000,
      );

      final request = factory.get(
        path: '/v1/account',
        credentials: const BinanceCredentials(
          apiKey: 'key',
          secretKey: 'secret',
          accountType: 'futuresSubAccount',
        ),
        timestamp: 123456789,
        params: {'symbol': 'BTCUSDT', 'limit': 10},
      );

      expect(request.queryParameters.keys.toList(), [
        'limit',
        'recvWindow',
        'symbol',
        'timestamp',
        'signature',
      ]);
    },
  );

  test('masks API key without leaking full value', () {
    final masked = SecureKeyStorage().maskApiKey('ABCDEFGHIJKLMNOP');

    expect(masked, 'ABCD****MNOP');
    expect(masked, isNot(contains('EFGHIJKL')));
  });

  test('futures REST base URL uses binance fapi host and /fapi prefix', () {
    final client = BinanceFuturesAccountClient(
      credentials: const BinanceCredentials(
        apiKey: 'key',
        secretKey: 'secret',
        accountType: 'futuresSubAccount',
      ),
      timeService: BinanceServerTimeService(),
    );

    expect(client.baseUrl, 'https://fapi.binance.com/fapi');
    expect(client.baseUrl.endsWith('/fapi'), isTrue);
  });

  test('parses spot account balances and permissions', () {
    final snapshot = SpotAccountSnapshot.fromJson({
      'canTrade': true,
      'canWithdraw': false,
      'permissions': ['SPOT'],
      'updateTime': 1720000000000,
      'balances': [
        {'asset': 'BTC', 'free': '0.01000000', 'locked': '0.00200000'},
        {'asset': 'USDT', 'free': '100.50', 'locked': '5.00'},
      ],
    });

    expect(snapshot.canTrade, isTrue);
    expect(snapshot.canWithdraw, isFalse);
    expect(snapshot.balanceOf('BTC').total.toString(), '0.012');
    expect(snapshot.balanceOf('USDT').free.toString(), '100.5');
  });

  test('parses spot open order and trade', () {
    final order = SpotOpenOrder.fromJson({
      'symbol': 'BTCUSDT',
      'orderId': 123,
      'clientOrderId': 'abc',
      'price': '60000.10',
      'origQty': '0.001',
      'executedQty': '0.0005',
      'status': 'PARTIALLY_FILLED',
      'timeInForce': 'GTC',
      'type': 'LIMIT',
      'side': 'BUY',
      'time': 1720000000000,
      'updateTime': 1720000001000,
    });
    final trade = SpotTrade.fromJson({
      'symbol': 'BTCUSDT',
      'id': 9,
      'orderId': 123,
      'price': '60000',
      'qty': '0.001',
      'quoteQty': '60',
      'commission': '0.01',
      'commissionAsset': 'USDT',
      'time': 1720000000000,
      'isBuyer': true,
      'isMaker': false,
    });

    expect(order.status, 'PARTIALLY_FILLED');
    expect(order.executedQuantity.toString(), '0.0005');
    expect(trade.side, 'BUY');
    expect(trade.quoteQuantity.toString(), '60');
  });

  test('parses one-way and hedge futures positions', () {
    final both = FuturesPosition.fromJson({
      'symbol': 'BTCUSDT',
      'positionSide': 'BOTH',
      'positionAmt': '-0.010',
      'entryPrice': '61000',
      'markPrice': '60000',
      'unRealizedProfit': '10',
      'leverage': '1',
      'marginType': 'isolated',
      'liquidationPrice': '0',
      'updateTime': 1720000000000,
    });
    final long = FuturesPosition.fromJson({
      'symbol': 'BTCUSDT',
      'positionSide': 'LONG',
      'positionAmt': '0.010',
      'entryPrice': '59000',
      'markPrice': '60000',
      'unRealizedProfit': '10',
      'leverage': '1',
      'marginType': 'isolated',
      'updateTime': 1720000000000,
    });

    expect(both.isShort, isTrue);
    expect(both.isLong, isFalse);
    expect(long.isLong, isTrue);
  });

  test('parses futures order, trade, and funding fee', () {
    final order = FuturesOpenOrder.fromJson({
      'symbol': 'BTCUSDT',
      'orderId': 99,
      'clientOrderId': 'fut',
      'side': 'SELL',
      'positionSide': 'SHORT',
      'type': 'LIMIT',
      'timeInForce': 'GTC',
      'price': '61000',
      'origQty': '0.01',
      'executedQty': '0',
      'avgPrice': '0',
      'status': 'NEW',
      'reduceOnly': false,
      'time': 1720000000000,
      'updateTime': 1720000000000,
    });
    final trade = FuturesTrade.fromJson({
      'symbol': 'BTCUSDT',
      'id': 100,
      'orderId': 99,
      'side': 'SELL',
      'positionSide': 'SHORT',
      'price': '61000',
      'qty': '0.01',
      'quoteQty': '610',
      'commission': '0.244',
      'commissionAsset': 'USDT',
      'realizedPnl': '0',
      'maker': true,
      'time': 1720000000000,
    });
    final funding = FundingFeeRecord.fromJson({
      'symbol': 'BTCUSDT',
      'income': '0.12',
      'asset': 'USDT',
      'info': 'FUNDING_FEE',
      'tranId': 777,
      'time': 1720000000000,
    });

    expect(order.positionSide, 'SHORT');
    expect(trade.commission.toString(), '0.244');
    expect(funding.income.toString(), '0.12');
  });

  test('spot user stream parser deduplicates execution reports', () {
    final parser = SpotUserDataStreamParser();
    const payload =
        '{"e":"executionReport","E":1720000000000,"s":"BTCUSDT","c":"c1","S":"BUY","o":"LIMIT","X":"FILLED","x":"TRADE","i":1,"l":"0.001","z":"0.001","L":"60000","n":"0.01","N":"USDT","t":11}';

    final first = parser.parse(payload);
    final second = parser.parse(payload);

    expect(first, isA<SpotExecutionReportEvent>());
    expect(second, isNull);
  });

  test('futures user stream parser handles ACCOUNT_UPDATE and order update', () {
    final parser = FuturesUserDataStreamParser();
    final account = parser.parse(
      '{"e":"ACCOUNT_UPDATE","E":1720000000000,"a":{"m":"ORDER","B":[{"a":"USDT","wb":"100"}],"P":[{"s":"BTCUSDT","pa":"-0.01","ps":"SHORT"}]}}',
    );
    final order = parser.parse(
      '{"e":"ORDER_TRADE_UPDATE","E":1720000000001,"o":{"s":"BTCUSDT","c":"c1","S":"SELL","ps":"SHORT","o":"LIMIT","X":"FILLED","x":"TRADE","i":2,"t":3}}',
    );

    expect(account, isA<FuturesAccountUpdateEvent>());
    expect(order, isA<FuturesOrderTradeUpdateEvent>());
  });
}
