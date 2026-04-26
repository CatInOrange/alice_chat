import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/debug/debug_log_store.dart';
import 'core/debug/native_debug_bridge.dart';
import 'features/notifications/application/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DebugLogStore.instance.ensureLoaded();
  await NativeDebugBridge.instance.initialize();
  await NotificationService.instance.initialize();
  await NativeDebugBridge.instance.log('app', 'app bootstrap complete');
  runApp(const AliceChatApp());
}
