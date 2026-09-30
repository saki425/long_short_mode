import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../database/app_database.dart';
import '../repositories/basic_repositories.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  static const _modules = <String>[
    'ALL',
    'MARKET_SPOT',
    'MARKET_FUTURES',
    'ACCOUNT_SPOT',
    'ACCOUNT_FUTURES',
    'REST',
    'WEBSOCKET',
  ];

  String _selectedModule = 'ALL';
  String? _selectedLevel;
  final _horizontalController = ScrollController();
  final _verticalController = ScrollController();

  @override
  void dispose() {
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = Get.find<LogRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('Logs')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final module in _modules)
                  ChoiceChip(
                    label: Text(module),
                    selected: _selectedModule == module,
                    onSelected: (_) => setState(() => _selectedModule = module),
                  ),
                ChoiceChip(
                  label: const Text('ALL LEVELS'),
                  selected: _selectedLevel == null,
                  onSelected: (_) => setState(() => _selectedLevel = null),
                ),
                for (final level in const ['info', 'warning', 'error'])
                  ChoiceChip(
                    label: Text(level.toUpperCase()),
                    selected: _selectedLevel == level,
                    onSelected: (_) => setState(() => _selectedLevel = level),
                  ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<AppLog>>(
              stream: repo.watchLogs(
                module: _selectedModule == 'ALL' ? null : _selectedModule,
                level: _selectedLevel,
                limit: 500,
              ),
              builder: (context, snapshot) {
                final logs = snapshot.data ?? const [];
                if (logs.isEmpty) {
                  return const Center(child: Text('暂无日志'));
                }
                return Scrollbar(
                  controller: _horizontalController,
                  notificationPredicate:
                      (notification) => notification.depth == 0,
                  child: SingleChildScrollView(
                    controller: _horizontalController,
                    scrollDirection: Axis.horizontal,
                    child: Scrollbar(
                      controller: _verticalController,
                      notificationPredicate:
                          (notification) => notification.depth == 0,
                      child: SingleChildScrollView(
                        controller: _verticalController,
                        padding: const EdgeInsets.all(12),
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('时间')),
                            DataColumn(label: Text('模块')),
                            DataColumn(label: Text('级别')),
                            DataColumn(label: Text('消息')),
                            DataColumn(label: Text('Extra')),
                          ],
                          rows:
                              logs
                                  .map(
                                    (log) => DataRow(
                                      cells: [
                                        DataCell(
                                          Text(
                                            log.createdAt.toLocal().toString(),
                                          ),
                                        ),
                                        DataCell(Text(log.module)),
                                        DataCell(Text(log.level)),
                                        DataCell(SelectableText(log.message)),
                                        DataCell(
                                          SelectableText(log.extraJson ?? '-'),
                                        ),
                                      ],
                                    ),
                                  )
                                  .toList(),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
