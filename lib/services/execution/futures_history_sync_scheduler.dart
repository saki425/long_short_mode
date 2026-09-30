import 'dart:async';

import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../market_data/market_data_coordinator.dart';
import 'auto_spot_grid_execution_service.dart';
import 'live_exchange_execution_service.dart';

class FuturesHistorySyncScheduler {
  FuturesHistorySyncScheduler({
    required LiveExchangeExecutionService liveExecution,
    required AppDatabase db,
    required MarketDataCoordinator marketData,
    AutoSpotGridExecutionService? gridExecution,
    Duration interval = const Duration(minutes: 5),
    Duration symbolDelay = const Duration(seconds: 20),
  })  : _liveExecution = liveExecution,
        _db = db,
        _marketData = marketData,
        _gridExecution = gridExecution,
        _interval = interval,
        _symbolDelay = symbolDelay;

  final LiveExchangeExecutionService _liveExecution;
  final AppDatabase _db;
  final MarketDataCoordinator _marketData;
  final AutoSpotGridExecutionService? _gridExecution;
  final Duration _interval;
  final Duration _symbolDelay;
  final Map<String, Timer> _timers = {};
  final Set<String> _running = {};
  final Set<String> _symbols = {};
  Future<void> _runQueue = Future.value();

  void setSymbols(Iterable<String> symbols) {
    final next = symbols
        .map((symbol) => symbol.toUpperCase().replaceAll('/', '').trim())
        .where((symbol) => symbol.isNotEmpty)
        .toSet();
    _debugTrace(
      'FUTURES_HISTORY_SCHED',
      'setSymbols symbols=${next.toList()..sort()}',
    );
    for (final symbol in _symbols.difference(next)) {
      _timers.remove(symbol)?.cancel();
      _running.remove(symbol);
      _debugTrace('FUTURES_HISTORY_SCHED', 'cancel symbol=$symbol');
    }
    _symbols
      ..clear()
      ..addAll(next);
    final ordered = next.toList()..sort();
    for (var index = 0; index < ordered.length; index += 1) {
      final symbol = ordered[index];
      if (_timers.containsKey(symbol) || _running.contains(symbol)) {
        continue;
      }
      _schedule(symbol, _symbolDelay * index);
    }
  }

  void stop() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _running.clear();
    _symbols.clear();
  }

  void _schedule(String symbol, Duration delay) {
    _timers.remove(symbol)?.cancel();
    _debugTrace(
      'FUTURES_HISTORY_SCHED',
      'schedule symbol=$symbol delayMs=${delay.inMilliseconds}',
    );
    _timers[symbol] = Timer(delay, () {
      _timers.remove(symbol);
      unawaited(_run(symbol));
    });
  }

  Future<void> _run(String symbol) async {
    if (!_symbols.contains(symbol) || _running.contains(symbol)) {
      _debugTrace(
        'FUTURES_HISTORY_SCHED',
        'skip symbol=$symbol subscribed=${_symbols.contains(symbol)} '
            'running=${_running.contains(symbol)}',
      );
      return;
    }
    _running.add(symbol);
    try {
      _runQueue = _runQueue.catchError((_) {}).then((_) async {
        if (_symbols.contains(symbol)) {
          _debugTrace('FUTURES_HISTORY_SCHED', 'start symbol=$symbol');
          final socketConnected =
              await _marketData.ensureFuturesSocketConnected(symbol);
          _debugTrace(
            'FUTURES_HISTORY_SCHED',
            'socket check symbol=$symbol connected=$socketConnected',
          );
          await _liveExecution.refreshRecentFuturesHistoryForSymbol(symbol);
          await _advanceRunningGridStrategies(symbol);
          _debugTrace('FUTURES_HISTORY_SCHED', 'done symbol=$symbol');
        }
      });
      await _runQueue;
    } catch (error) {
      _debugTrace(
        'FUTURES_HISTORY_SCHED',
        'failed symbol=$symbol error=$error',
      );
    } finally {
      _running.remove(symbol);
      if (_symbols.contains(symbol)) {
        _schedule(symbol, _interval);
      }
    }
  }

  Future<void> _advanceRunningGridStrategies(String symbol) async {
    final gridExecution = _gridExecution;
    if (gridExecution == null) {
      _debugTrace(
        'FUTURES_HISTORY_SCHED',
        'advance skipped symbol=$symbol reason=no-grid-execution',
      );
      return;
    }
    final strategies = await (_db.select(_db.strategies)
          ..where(
            (tbl) =>
                tbl.symbol.equals(symbol) &
                tbl.environment.equals(
                  AutoSpotGridExecutionService.futuresGridEnvironment,
                ) &
                tbl.status.equals('running'),
          ))
        .get();
    _debugTrace(
      'FUTURES_HISTORY_SCHED',
      'advance strategies symbol=$symbol count=${strategies.length}',
    );
    for (final strategy in strategies) {
      try {
        final report = await gridExecution.reconcileFuturesLongGrid(
          strategy.id,
          refreshFirst: false,
          includeHistory: false,
          validateMissingOpenOrders: true,
          autoSubmitClose: true,
          autoSubmitNextBuy: true,
        );
        _debugTrace(
          'FUTURES_HISTORY_SCHED',
          'long advanced symbol=$symbol strategy=${strategy.id} '
              'synced=${report.syncedOrders} active=${report.activeOrders} '
              'completed=${report.completedOrders} errors=${report.errorOrders}',
        );
      } catch (error) {
        _debugTrace(
          'FUTURES_HISTORY_SCHED',
          'long advance failed symbol=$symbol strategy=${strategy.id} '
              'error=$error',
        );
      }
      try {
        final report = await gridExecution.futureGridEngine.reconcileStrategy(
          strategy.id,
          refreshFirst: false,
          includeHistory: false,
        );
        _debugTrace(
          'FUTURES_HISTORY_SCHED',
          'short advanced symbol=$symbol strategy=${strategy.id} '
              'synced=${report.syncedRows} open=${report.openRows} '
              'closing=${report.closingRows} closed=${report.closedRows} '
              'failed=${report.failedRows}',
        );
      } catch (error) {
        _debugTrace(
          'FUTURES_HISTORY_SCHED',
          'short advance failed symbol=$symbol strategy=${strategy.id} '
              'error=$error',
        );
      }
    }
  }

  void _debugTrace(String tag, String message) {
    assert(() {
      // ignore: avoid_print
      print('[GH_DIAG][$tag] $message');
      return true;
    }());
  }
}
