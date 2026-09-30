import 'package:flutter/foundation.dart';

import '../../database/app_database.dart';
import 'market_data_status.dart';

@immutable
class FuturesWsDiagnostics {
  const FuturesWsDiagnostics({
    required this.status,
    required this.url,
    required this.streamName,
    required this.startedAt,
    required this.reconnectCount,
    this.lastConnectedAt,
    this.lastMessageAt,
    this.currentReconnectDelay,
    this.httpStatusCode,
    this.closeCode,
    this.closeReason,
    this.exceptionType,
    this.exceptionMessage,
    this.stackTrace,
    this.lastRawMessage,
    this.lastJsonParseError,
    this.lastErrorSummary,
  });

  final MarketConnectionStatus status;
  final String url;
  final String streamName;
  final DateTime startedAt;
  final DateTime? lastConnectedAt;
  final DateTime? lastMessageAt;
  final int reconnectCount;
  final Duration? currentReconnectDelay;
  final int? httpStatusCode;
  final int? closeCode;
  final String? closeReason;
  final String? exceptionType;
  final String? exceptionMessage;
  final String? stackTrace;
  final String? lastRawMessage;
  final String? lastJsonParseError;
  final String? lastErrorSummary;

  static FuturesWsDiagnostics initial({
    required String url,
    required String streamName,
  }) {
    final now = DateTime.now().toUtc();
    return FuturesWsDiagnostics(
      status: MarketConnectionStatus.disconnected,
      url: url,
      streamName: streamName,
      startedAt: now,
      reconnectCount: 0,
    );
  }

  FuturesWsDiagnostics copyWith({
    MarketConnectionStatus? status,
    String? url,
    String? streamName,
    DateTime? startedAt,
    DateTime? lastConnectedAt,
    DateTime? lastMessageAt,
    int? reconnectCount,
    Duration? currentReconnectDelay,
    int? httpStatusCode,
    int? closeCode,
    String? closeReason,
    String? exceptionType,
    String? exceptionMessage,
    String? stackTrace,
    String? lastRawMessage,
    String? lastJsonParseError,
    String? lastErrorSummary,
  }) {
    return FuturesWsDiagnostics(
      status: status ?? this.status,
      url: url ?? this.url,
      streamName: streamName ?? this.streamName,
      startedAt: startedAt ?? this.startedAt,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      reconnectCount: reconnectCount ?? this.reconnectCount,
      currentReconnectDelay: currentReconnectDelay ?? this.currentReconnectDelay,
      httpStatusCode: httpStatusCode ?? this.httpStatusCode,
      closeCode: closeCode ?? this.closeCode,
      closeReason: closeReason ?? this.closeReason,
      exceptionType: exceptionType ?? this.exceptionType,
      exceptionMessage: exceptionMessage ?? this.exceptionMessage,
      stackTrace: stackTrace ?? this.stackTrace,
      lastRawMessage: lastRawMessage ?? this.lastRawMessage,
      lastJsonParseError: lastJsonParseError ?? this.lastJsonParseError,
      lastErrorSummary: lastErrorSummary ?? this.lastErrorSummary,
    );
  }
}

class FuturesWsProbeResult {
  const FuturesWsProbeResult({
    required this.success,
    required this.details,
  });

  final bool success;
  final String details;
}

String formatDurationLabel(Duration? duration) {
  if (duration == null) return '-';
  final seconds = duration.inSeconds;
  if (seconds <= 0) {
    return '${duration.inMilliseconds}ms';
  }
  return '${seconds}s';
}

String formatLogEntry(AppLog log) {
  final buffer = StringBuffer()
    ..write('[')
    ..write(log.createdAt.toLocal().toIso8601String())
    ..write('] ')
    ..write(log.level)
    ..write(' ')
    ..write(log.module)
    ..write(' - ')
    ..write(log.message);
  if (log.extraJson != null && log.extraJson!.isNotEmpty) {
    buffer
      ..write(' | ')
      ..write(log.extraJson);
  }
  return buffer.toString();
}
