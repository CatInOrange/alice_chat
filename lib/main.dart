import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'core/debug/debug_log_store.dart';
import 'core/debug/native_debug_bridge.dart';
import 'features/notifications/application/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _initializeDesktopDatabaseFactory();
  await _initializeDesktopWindowing();
  await DebugLogStore.instance.ensureLoaded();
  await NativeDebugBridge.instance.initialize();
  await NotificationService.instance.initialize();
  await NativeDebugBridge.instance.log('app', 'app bootstrap complete');
  runApp(const AliceChatApp());
}

void _initializeDesktopDatabaseFactory() {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    return;
  }
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

Future<void> _initializeDesktopWindowing() async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    return;
  }
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    titleBarStyle: TitleBarStyle.hidden,
    backgroundColor: Colors.transparent,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
