import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/services/binance/trading/binance_symbol_rules.dart';
import 'package:grid_hedge_trader/strategy/hedge/hedge_engine.dart';

void main() {
  const engine = HedgeEngine();
  final rules = BinanceSymbolRules(
    symbol: 'BTCUSDT',
    marketType: 'usdtFutures',
    tickSize: Decimal.parse('0.01'),
    stepSize: Decimal.parse('0.000001'),
    minQty: Decimal.parse('0.000001'),
    maxQty: Decimal.fromInt(100),
    minNotional: Decimal.fromInt(1),
    pricePrecision: 2,
    quantityPrecision: 6,
  );

  HedgeCalculationInput input({
    required List<HedgeGridExposure> exposures,
    Decimal? currentShortQty,
    Decimal? hedgeRatio,
    Decimal? currentPrice,
    bool hedgeEnabled = true,
  }) {
    return HedgeCalculationInput(
      hedgeEnabled: hedgeEnabled,
      hedgeDryRun: true,
      hedgeRatio: hedgeRatio ?? Decimal.parse('0.5'),
      currentPrice: currentPrice ?? Decimal.fromInt(60000),
      lowerPrice: Decimal.fromInt(60000),
      upperPrice: Decimal.fromInt(66000),
      currentShortQty: currentShortQty ?? Decimal.zero,
      markPrice: Decimal.fromInt(60000),
      minAdjustQty: Decimal.zero,
      minAdjustNotional: Decimal.zero,
      maxHedgeQty: Decimal.fromInt(1),
      futuresRules: rules,
      gridExposures: exposures,
      maxHedgeRatio: hedgeRatio ?? Decimal.parse('0.5'),
      emergencyHedgeRatio: Decimal.fromInt(1),
      hedgeReleaseBufferPct: Decimal.parse('0.005'),
    );
  }

  test('BUY not filled has zero exposed spot BTC', () {
    final result = engine.calculate(
      input(
        exposures: [
          HedgeGridExposure(
            gridId: 'g1',
            cycleNumber: 0,
            buyFilledQty: Decimal.zero,
            sellFilledQty: Decimal.zero,
            phase: 'waitingBuy',
          ),
        ],
      ),
    );

    expect(result.exposedSpotQty, Decimal.zero);
    expect(result.actionType, HedgeActionType.syncOnly);
    expect(result.hedgeStage, HedgeStage.noExposure);
  });

  test('BUY filled and SELL not filled increases exposed spot BTC', () {
    final result = engine.calculate(
      input(
        exposures: [
          HedgeGridExposure(
            gridId: 'g1',
            cycleNumber: 0,
            buyFilledQty: Decimal.parse('0.001'),
            sellFilledQty: Decimal.zero,
            phase: 'sellOpen',
          ),
        ],
      ),
    );

    expect(result.exposedSpotQty, Decimal.parse('0.001'));
    expect(result.targetShortQty, Decimal.parse('0.0005'));
    expect(result.actionType, HedgeActionType.increaseShort);
  });

  test('BUY filled but price above strategy mid has zero target short', () {
    final result = engine.calculate(
      input(
        currentPrice: Decimal.fromInt(64000),
        exposures: [
          HedgeGridExposure(
            gridId: 'g1',
            cycleNumber: 0,
            buyFilledQty: Decimal.parse('0.001'),
            sellFilledQty: Decimal.zero,
            phase: 'sellOpen',
          ),
        ],
      ),
    );

    expect(result.exposedSpotQty, Decimal.parse('0.001'));
    expect(result.effectiveHedgeRatio, Decimal.zero);
    expect(result.targetShortQty, Decimal.zero);
    expect(result.hedgeStage, HedgeStage.aboveMidNoHedge);
    expect(result.actionType, HedgeActionType.syncOnly);
  });

  test(
    'small live BTC exposure above configured limits suggests increase short',
    () {
      final result = engine.calculate(
        HedgeCalculationInput(
          hedgeEnabled: true,
          hedgeDryRun: true,
          hedgeRatio: Decimal.parse('0.5'),
          currentPrice: Decimal.fromInt(60000),
          lowerPrice: Decimal.fromInt(60000),
          upperPrice: Decimal.fromInt(66000),
          currentShortQty: Decimal.zero,
          markPrice: Decimal.fromInt(61900),
          minAdjustQty: Decimal.parse('0.000001'),
          minAdjustNotional: Decimal.fromInt(5),
          maxHedgeQty: Decimal.fromInt(1),
          futuresRules: rules,
          gridExposures: [
            HedgeGridExposure(
              gridId: 'g1',
              cycleNumber: 0,
              buyFilledQty: Decimal.parse('0.00066'),
              sellFilledQty: Decimal.zero,
              phase: 'sellOpen',
            ),
          ],
          maxHedgeRatio: Decimal.parse('0.5'),
          emergencyHedgeRatio: Decimal.fromInt(1),
          hedgeReleaseBufferPct: Decimal.parse('0.005'),
        ),
      );

      expect(result.exposedSpotQty, Decimal.parse('0.00066'));
      expect(result.targetShortQty, Decimal.parse('0.00033'));
      expect(result.currentShortQty, Decimal.zero);
      expect(result.diffQty, Decimal.parse('0.00033'));
      expect(result.actionQty, Decimal.parse('0.00033'));
      expect(result.actionNotional, Decimal.parse('20.42700'));
      expect(result.actionType, HedgeActionType.increaseShort);
      expect(result.debug.rawTargetShortQty, Decimal.parse('0.000330'));
      expect(result.debug.adjustedTargetShortQty, Decimal.parse('0.00033'));
    },
  );

  test(
    'coarse futures filters do not hide theoretical target short quantity',
    () {
      final coarseRules = BinanceSymbolRules(
        symbol: 'BTCUSDT',
        marketType: 'usdtFutures',
        tickSize: Decimal.parse('0.1'),
        stepSize: Decimal.parse('0.001'),
        minQty: Decimal.parse('0.001'),
        maxQty: Decimal.fromInt(100),
        minNotional: Decimal.fromInt(50),
        pricePrecision: 2,
        quantityPrecision: 3,
      );
      final result = engine.calculate(
        HedgeCalculationInput(
          hedgeEnabled: true,
          hedgeDryRun: true,
          hedgeRatio: Decimal.parse('0.5'),
          currentPrice: Decimal.fromInt(60000),
          lowerPrice: Decimal.fromInt(60000),
          upperPrice: Decimal.fromInt(66000),
          currentShortQty: Decimal.zero,
          markPrice: Decimal.fromInt(61900),
          minAdjustQty: Decimal.parse('0.000001'),
          minAdjustNotional: Decimal.fromInt(5),
          maxHedgeQty: Decimal.fromInt(1),
          futuresRules: coarseRules,
          gridExposures: [
            HedgeGridExposure(
              gridId: 'g1',
              cycleNumber: 0,
              buyFilledQty: Decimal.parse('0.00066'),
              sellFilledQty: Decimal.zero,
              phase: 'sellOpen',
            ),
          ],
          maxHedgeRatio: Decimal.parse('0.5'),
          emergencyHedgeRatio: Decimal.fromInt(1),
          hedgeReleaseBufferPct: Decimal.parse('0.005'),
        ),
      );

      expect(result.targetShortQty, Decimal.parse('0.000330'));
      expect(result.diffQty, Decimal.parse('0.000330'));
      expect(result.actionQty, Decimal.zero);
      expect(result.actionType, HedgeActionType.skipTooSmall);
      expect(result.debug.adjustedTargetShortQty, Decimal.zero);
      expect(result.reason, contains('futuresMinQty 0.001'));
      expect(result.reason, contains('futuresMinNotional 50'));
    },
  );

  test('SELL partial fill reduces exposed spot BTC', () {
    final result = engine.calculate(
      input(
        exposures: [
          HedgeGridExposure(
            gridId: 'g1',
            cycleNumber: 0,
            buyFilledQty: Decimal.parse('0.001'),
            sellFilledQty: Decimal.parse('0.0004'),
            phase: 'sellPartiallyFilled',
          ),
        ],
      ),
    );

    expect(result.exposedSpotQty, Decimal.parse('0.0006'));
    expect(result.targetShortQty, Decimal.parse('0.0003'));
  });

  test('current short above target suggests reduceOnly BUY', () {
    final result = engine.calculate(
      input(
        currentShortQty: Decimal.parse('0.001'),
        exposures: [
          HedgeGridExposure(
            gridId: 'g1',
            cycleNumber: 0,
            buyFilledQty: Decimal.parse('0.001'),
            sellFilledQty: Decimal.zero,
            phase: 'sellOpen',
          ),
        ],
      ),
    );

    expect(result.actionType, HedgeActionType.reduceShort);
    expect(result.side, 'BUY');
    expect(result.reduceOnly, isTrue);
  });

  test('disabled hedge never submits action', () {
    final result = engine.calculate(
      input(
        hedgeEnabled: false,
        exposures: [
          HedgeGridExposure(
            gridId: 'g1',
            cycleNumber: 0,
            buyFilledQty: Decimal.parse('0.001'),
            sellFilledQty: Decimal.zero,
            phase: 'sellOpen',
          ),
        ],
      ),
    );

    expect(result.actionType, HedgeActionType.skipDisabled);
    expect(result.canSubmit, isFalse);
  });
}
