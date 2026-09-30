import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../database/app_database.dart';
import '../../repositories/basic_repositories.dart';
import '../../services/market_data/futures_ws_diagnostics.dart';
import '../../services/market_data/market_data_coordinator.dart';

class FuturesWsConnectionDialog extends StatelessWidget {
  const FuturesWsConnectionDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final market = Get.find<MarketDataCoordinator>();
    final logs = Get.find<LogRepository>();
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 820),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: StreamBuilder<FuturesWsDiagnostics>(
            stream: market.futuresDiagnosticsStream,
            initialData: market.futuresDiagnostics,
            builder: (context, diagnosticsSnapshot) {
              final diagnostics =
                  diagnosticsSnapshot.data ?? market.futuresDiagnostics;
              return StreamBuilder<List<AppLog>>(
                stream: logs.watchLogs(module: 'MARKET_FUTURES', limit: 20),
                builder: (context, logSnapshot) {
                  final recentLogs = logSnapshot.data ?? const [];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '合约行情连接详情',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed:
                                () => _copyDetails(
                                  context,
                                  diagnostics,
                                  recentLogs,
                                ),
                            icon: const Icon(Icons.copy),
                            label: const Text('复制错误详情'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => market.reconnectFuturesOnly(),
                            icon: const Icon(Icons.refresh),
                            label: const Text('立即重连'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                final result =
                                    await market.testFuturesWebSocket();
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text(result.details),
                                    backgroundColor:
                                        result.success
                                            ? Colors.green
                                            : Colors.red,
                                  ),
                                );
                              } catch (error) {
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text('Test failed: $error'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('测试合约WebSocket'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 5,
                              child: _DetailPanel(diagnostics: diagnostics),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 4,
                              child: _LogPanel(logs: recentLogs),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('关闭'),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  void _copyDetails(
    BuildContext context,
    FuturesWsDiagnostics diagnostics,
    List<AppLog> logs,
  ) {
    final buffer =
        StringBuffer()
          ..writeln('Futures WebSocket connection details')
          ..writeln('Current status: ${diagnostics.status.name}')
          ..writeln('WebSocket URL: ${diagnostics.url}')
          ..writeln('Stream: ${diagnostics.streamName}')
          ..writeln('Started at: ${diagnostics.startedAt.toLocal()}')
          ..writeln(
            'Last success: ${diagnostics.lastConnectedAt?.toLocal() ?? '-'}',
          )
          ..writeln(
            'Last message: ${diagnostics.lastMessageAt?.toLocal() ?? '-'}',
          )
          ..writeln('Reconnect attempts: ${diagnostics.reconnectCount}')
          ..writeln(
            'Next retry: ${formatDurationLabel(diagnostics.currentReconnectDelay)}',
          )
          ..writeln(
            'HTTP/WebSocket status: ${diagnostics.httpStatusCode ?? diagnostics.closeCode ?? '-'}',
          )
          ..writeln('Close code: ${diagnostics.closeCode ?? '-'}')
          ..writeln('Close reason: ${diagnostics.closeReason ?? '-'}')
          ..writeln('Exception type: ${diagnostics.exceptionType ?? '-'}')
          ..writeln('Exception message: ${diagnostics.exceptionMessage ?? '-'}')
          ..writeln('StackTrace: ${diagnostics.stackTrace ?? '-'}')
          ..writeln('Last raw message: ${diagnostics.lastRawMessage ?? '-'}')
          ..writeln('Last JSON error: ${diagnostics.lastJsonParseError ?? '-'}')
          ..writeln('Recent logs:');
    for (final log in logs) {
      buffer.writeln(formatLogEntry(log));
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('错误详情已复制')));
  }
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({required this.diagnostics});

  final FuturesWsDiagnostics diagnostics;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _detail('当前状态', diagnostics.status.name),
              _detail('WebSocket URL', diagnostics.url),
              _detail('Stream 名称', diagnostics.streamName),
              _detail('开始连接时间', diagnostics.startedAt.toLocal().toString()),
              _detail(
                '最后连接成功时间',
                diagnostics.lastConnectedAt?.toLocal().toString() ?? '-',
              ),
              _detail(
                '最后一条消息时间',
                diagnostics.lastMessageAt?.toLocal().toString() ?? '-',
              ),
              _detail('重连次数', diagnostics.reconnectCount.toString()),
              _detail(
                '当前重连等待时间',
                formatDurationLabel(diagnostics.currentReconnectDelay),
              ),
              _detail(
                'HTTP/WebSocket状态码',
                '${diagnostics.httpStatusCode ?? '-'} / ${diagnostics.closeCode ?? '-'}',
              ),
              _detail('Close Code', diagnostics.closeCode?.toString() ?? '-'),
              _detail('Close Reason', diagnostics.closeReason ?? '-'),
              _detail('Exception类型', diagnostics.exceptionType ?? '-'),
              _detail('Exception message', diagnostics.exceptionMessage ?? '-'),
              _detail('StackTrace', diagnostics.stackTrace ?? '-'),
              _detail('最近一次原始消息', diagnostics.lastRawMessage ?? '-'),
              _detail('最近一次JSON解析错误', diagnostics.lastJsonParseError ?? '-'),
              _detail('最近错误摘要', diagnostics.lastErrorSummary ?? '-'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.logs});

  final List<AppLog> logs;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '最近20条连接日志',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: logs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final log = logs[index];
                  return SelectableText(
                    formatLogEntry(log),
                    style: const TextStyle(fontSize: 12),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
