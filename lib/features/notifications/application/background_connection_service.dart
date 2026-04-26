import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/debug/native_debug_bridge.dart';
import '../../../core/openclaw/openclaw_settings.dart';

class BackgroundConnectionService {
  BackgroundConnectionService._();

  static final BackgroundConnectionService instance =
      BackgroundConnectionService._();

  static const MethodChannel _channel = MethodChannel(
    'alicechat/background_connection',
  );

  bool _serviceRequested = false;
  String _activeSessionId = '';

  bool get isServiceRequested => _serviceRequested;
  String get activeSessionId => _activeSessionId;

  Future<void> start({String sessionId = ''}) async {
    final enabled = await OpenClawSettingsStore.loadBackgroundServiceEnabled();
    if (!enabled) {
      _serviceRequested = false;
      await NativeDebugBridge.instance.log(
        'bg-service',
        'start skipped because background service disabled',
      );
      return;
    }
    final previousRequested = _serviceRequested;
    _serviceRequested = true;
    _activeSessionId = sessionId.trim();
    await NativeDebugBridge.instance.log(
      'bg-service',
      'start requested session=$_activeSessionId launchMode=background-notify-all prevRequested=$previousRequested',
    );
    try {
      await _channel.invokeMethod('startForegroundService', {
        'sessionId': _activeSessionId,
      });
      await NativeDebugBridge.instance.log(
        'bg-service',
        'startForegroundService invoked successfully requested=$_serviceRequested active=$_activeSessionId forwarded=$_activeSessionId',
      );
    } catch (error) {
      await NativeDebugBridge.instance.log(
        'bg-service',
        'startForegroundService failed error=$error',
        level: 'ERROR',
      );
      debugPrint('[alicechat.bg] start service failed: $error');
    }
  }

  Future<void> stop() async {
    final previousRequested = _serviceRequested;
    _serviceRequested = false;
    await NativeDebugBridge.instance.log(
      'bg-service',
      'stop requested prevRequested=$previousRequested active=$_activeSessionId',
    );
    try {
      await _channel.invokeMethod('stopForegroundService');
      await NativeDebugBridge.instance.log(
        'bg-service',
        'stopForegroundService invoked successfully',
      );
    } catch (error) {
      await NativeDebugBridge.instance.log(
        'bg-service',
        'stopForegroundService failed error=$error',
        level: 'ERROR',
      );
      debugPrint('[alicechat.bg] stop service failed: $error');
    }
  }

  Future<void> updateActiveSession(String sessionId) async {
    _activeSessionId = sessionId.trim();
    await NativeDebugBridge.instance.log(
      'bg-service',
      'updateActiveSession session=$_activeSessionId serviceRequested=$_serviceRequested',
    );
    if (!_serviceRequested) return;
    try {
      await _channel.invokeMethod('updateActiveSession', {
        'sessionId': _activeSessionId,
      });
      await NativeDebugBridge.instance.log(
        'bg-service',
        'updateActiveSession invoked successfully session=$_activeSessionId',
      );
    } catch (error) {
      await NativeDebugBridge.instance.log(
        'bg-service',
        'updateActiveSession failed error=$error',
        level: 'ERROR',
      );
      debugPrint('[alicechat.bg] update session failed: $error');
    }
  }

  Future<String?> consumePendingNotificationOpen() async {
    try {
      final result = await _channel.invokeMethod<String>(
        'consumePendingNotificationOpen',
      );
      final value = result?.trim();
      await NativeDebugBridge.instance.log(
        'bg-service',
        'consumePendingNotificationOpen session=${value ?? ''}',
      );
      return (value == null || value.isEmpty) ? null : value;
    } catch (error) {
      debugPrint('[alicechat.bg] consume pending open failed: $error');
      return null;
    }
  }

  Future<void> onAppLifecycleChanged(AppLifecycleState state) async {
    await NativeDebugBridge.instance.log(
      'bg-service',
      'lifecycle state=$state active=$_activeSessionId requested=$_serviceRequested',
    );
    if (state == AppLifecycleState.resumed) {
      await NativeDebugBridge.instance.log(
        'bg-service',
        'lifecycle decision=stop on resumed',
      );
      await stop();
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      await NativeDebugBridge.instance.log(
        'bg-service',
        'lifecycle decision=start on state=$state',
      );
      await start(sessionId: _activeSessionId);
    }
  }
}
