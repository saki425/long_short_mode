enum MarketTypeFilter { all, spot, usdtFutures }

enum OrderEnvironmentFilter { all, paper, live }

enum OrderDateField { createdAt, completedAt, updatedAt }

enum OrderStatusBucket { all, unfinished, completed, cancelled, failed }

enum UnfinishedOrderFilter {
  all,
  localPlan,
  submitting,
  open,
  partiallyFilled,
  unknown,
  pendingRecovery,
  pendingReplacement,
}

class DateRange {
  const DateRange({
    required this.startInclusiveUtc,
    required this.endExclusiveUtc,
  });

  final DateTime startInclusiveUtc;
  final DateTime endExclusiveUtc;
}

class LocalDateRange {
  const LocalDateRange({
    required this.label,
    required this.startLocal,
    required this.endLocalInclusive,
  });

  final String label;
  final DateTime startLocal;
  final DateTime endLocalInclusive;

  DateRange toUtcHalfOpenRange() {
    final startDate = DateTime(
      startLocal.year,
      startLocal.month,
      startLocal.day,
    );
    final endDate = DateTime(
      endLocalInclusive.year,
      endLocalInclusive.month,
      endLocalInclusive.day,
    ).add(const Duration(days: 1));
    return DateRange(
      startInclusiveUtc: startDate.toUtc(),
      endExclusiveUtc: endDate.toUtc(),
    );
  }
}

LocalDateRange todayRange(DateTime now) {
  final local = now.toLocal();
  final day = DateTime(local.year, local.month, local.day);
  return LocalDateRange(label: '今天', startLocal: day, endLocalInclusive: day);
}

LocalDateRange yesterdayRange(DateTime now) {
  final local = now.toLocal();
  final day = DateTime(
    local.year,
    local.month,
    local.day,
  ).subtract(const Duration(days: 1));
  return LocalDateRange(label: '昨天', startLocal: day, endLocalInclusive: day);
}

LocalDateRange lastDaysRange(DateTime now, int days, String label) {
  final local = now.toLocal();
  final end = DateTime(local.year, local.month, local.day);
  final start = end.subtract(Duration(days: days - 1));
  return LocalDateRange(
    label: label,
    startLocal: start,
    endLocalInclusive: end,
  );
}

LocalDateRange thisMonthRange(DateTime now) {
  final local = now.toLocal();
  final start = DateTime(local.year, local.month);
  final end = DateTime(
    local.year,
    local.month + 1,
  ).subtract(const Duration(days: 1));
  return LocalDateRange(label: '本月', startLocal: start, endLocalInclusive: end);
}

LocalDateRange previousMonthRange(DateTime now) {
  final local = now.toLocal();
  final start = DateTime(local.year, local.month - 1);
  final end = DateTime(
    local.year,
    local.month,
  ).subtract(const Duration(days: 1));
  return LocalDateRange(label: '上月', startLocal: start, endLocalInclusive: end);
}
