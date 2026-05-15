import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/app.dart';
import 'core/debug/debug_log_store.dart';
import 'core/debug/native_debug_bridge.dart';
import 'features/notifications/application/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _initializeDesktopDatabaseFactory();
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
