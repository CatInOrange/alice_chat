import 'dart:async';

import 'package:flutter/services.dart';

import 'debug_log_store.dart';

class NativeDebugBridge {
  NativeDebugBridge._();

  static final NativeDebugBridge instance = NativeDebugBridge._();
  static const MethodChannel _channel = MethodChannel('alicechat/debug_logs');
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'appendLog') {
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? const {});
        await DebugLogStore.instance.log(
          (args['tag'] ?? 'native').toString(),
          (args['message'] ?? '').toString(),
          level: (args['level'] ?? 'INFO').toString(),
        );
        return;
      }
      if (call.method == 'appendLogs') {
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? const {});
        final lines = (args['lines'] as List? ?? const []).map((e) => e.toString());
        await DebugLogStore.instance.importLines(
          lines,
          fallbackTag: (args['tag'] ?? 'native').toString(),
        );
        return;
      }
    });
  }

  Future<void> log(String tag, String message, {String level = 'INFO'}) {
    return DebugLogStore.instance.log(tag, message, level: level);
  }

  Future<List<String>> fetchNativeLogs() async {
    final result = await _channel.invokeMethod<List<dynamic>>('getLogs');
    return (result ?? const []).map((e) => e.toString()).toList();
  }

  Future<void> clearNativeLogs() async {
    await _channel.invokeMethod('clearLogs');
  }
}
