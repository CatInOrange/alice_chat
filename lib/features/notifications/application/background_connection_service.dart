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
  bool _appForeground = true;
  bool _serviceInitialized = false;
  final Map<String, Map<String, String>> _sessionMetadata = {};

  bool get isServiceRequested => _serviceRequested;
  String get activeSessionId => _activeSessionId;

  Future<void> start({String sessionId = ''}) async {
    final enabled = await OpenClawSettingsStore.loadBackgroundServiceEnabled();
    if (!enabled) {
      _serviceRequested = false;
      _serviceInitialized = false;
      await NativeDebugBridge.instance.log(
        'bg-service',
        'start skipped because background service disabled',
      );
      return;
    }
    final previousRequested = _serviceRequested;
    _serviceRequested = true;
    _serviceInitialized = true;
    _activeSessionId = sessionId.trim();
    await NativeDebugBridge.instance.log(
      'bg-service',
      'start requested session=$_activeSessionId appForeground=$_appForeground launchMode=background-notify-all prevRequested=$previousRequested',
    );
    try {
      await _channel.invokeMethod('startForegroundService', {
        'sessionId': _activeSessionId,
      });
      await NativeDebugBridge.instance.log(
        'bg-service',
        'startForegroundService invoked successfully requested=$_serviceRequested active=$_activeSessionId appForeground=$_appForeground forwarded=$_activeSessionId',
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
    _serviceInitialized = false;
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
      'updateActiveSession session=$_activeSessionId appForeground=$_appForeground serviceRequested=$_serviceRequested',
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

  Future<void> updateSessionMetadata({
    required String sessionId,
    required String title,
    String avatarAssetPath = '',
  }) async {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) return;
    _sessionMetadata[normalizedSessionId] = {
      'title': title.trim(),
      'avatarAssetPath': avatarAssetPath.trim(),
    };
    await NativeDebugBridge.instance.log(
      'bg-service',
      'updateSessionMetadata session=$normalizedSessionId title=${title.trim()} avatar=${avatarAssetPath.trim()}',
    );
    if (!_serviceRequested) return;
    try {
      await _channel.invokeMethod('updateSessionMetadata', {
        'sessionId': normalizedSessionId,
        'title': title.trim(),
        'avatarAssetPath': avatarAssetPath.trim(),
      });
      await NativeDebugBridge.instance.log(
        'bg-service',
        'updateSessionMetadata invoked successfully session=$normalizedSessionId',
      );
    } catch (error) {
      await NativeDebugBridge.instance.log(
        'bg-service',
        'updateSessionMetadata failed error=$error',
        level: 'ERROR',
      );
      debugPrint('[alicechat.bg] update metadata failed: $error');
    }
  }

  Future<void> updateAppForeground(bool isForeground) async {
    _appForeground = isForeground;
    await NativeDebugBridge.instance.log(
      'bg-service',
      'updateAppForeground foreground=$_appForeground active=$_activeSessionId serviceRequested=$_serviceRequested',
    );
    if (!_serviceRequested) return;
    try {
      await _channel.invokeMethod('updateAppForeground', {
        'isForeground': _appForeground,
      });
      await NativeDebugBridge.instance.log(
        'bg-service',
        'updateAppForeground invoked successfully foreground=$_appForeground active=$_activeSessionId',
      );
    } catch (error) {
      await NativeDebugBridge.instance.log(
        'bg-service',
        'updateAppForeground failed error=$error',
        level: 'ERROR',
      );
      debugPrint('[alicechat.bg] update foreground failed: $error');
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
    _appForeground = state == AppLifecycleState.resumed;
    await NativeDebugBridge.instance.log(
      'bg-service',
      'lifecycle state=$state foreground=$_appForeground active=$_activeSessionId requested=$_serviceRequested mode=always-on',
    );
    await updateAppForeground(_appForeground);
    if (!_serviceInitialized) {
      await NativeDebugBridge.instance.log(
        'bg-service',
        'lifecycle decision=skip_not_initialized state=$state mode=always-on',
      );
      return;
    }
    if (state == AppLifecycleState.resumed) {
      await NativeDebugBridge.instance.log(
        'bg-service',
        'lifecycle decision=keep_running on resumed mode=always-on active=$_activeSessionId foreground=$_appForeground',
      );
      return;
    }
    await NativeDebugBridge.instance.log(
      'bg-service',
      'lifecycle decision=ensure_started on state=$state mode=always-on active=$_activeSessionId foreground=$_appForeground',
    );
    await start(sessionId: _activeSessionId);
  }
}
