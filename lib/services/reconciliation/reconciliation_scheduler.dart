import 'dart:async';

import 'account_reconciliation_service.dart';

class ReconciliationScheduler {
  ReconciliationScheduler(this.service);

  final AccountReconciliationService service;
  Timer? _timer;

  void start({Duration interval = const Duration(seconds: 30)}) {
    stop();
    _timer = Timer.periodic(interval, (_) => service.runReadOnlyReconciliation());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
