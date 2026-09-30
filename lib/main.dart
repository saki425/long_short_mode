import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';

Future<void> main() async {
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        if (_isExpectedSocketClose(details.exception)) {
          return;
        }
        FlutterError.presentError(details);
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        if (_isExpectedSocketClose(error)) {
          return true;
        }
        return true;
      };
      await windowManager.ensureInitialized();
      const windowOptions = WindowOptions(
        size: Size(1280, 820),
        minimumSize: Size(1100, 700),
        center: true,
        title: 'Grid Hedge Desktop',
      );
      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
      final app = await GridHedgeApp.bootstrap();
      runApp(app);
    },
    (error, stackTrace) {
      if (_isExpectedSocketClose(error)) {
        return;
      }
    },
  );
}

bool _isExpectedSocketClose(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('reading from a closed socket') ||
      message.contains('socket is closed') ||
      message.contains('connection reset') ||
      message.contains('broken pipe') ||
      message.contains('connection closed');
}
