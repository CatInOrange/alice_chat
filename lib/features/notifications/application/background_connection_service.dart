import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/debug/native_debug_bridge.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../../chat/domain/chat_session.dart';

class BackgroundConnectionService {
  BackgroundConnectionService._();

  static final BackgroundConnectionService instance =
      BackgroundConnectionService._();

  static const MethodChannel _channel = MethodChannel(
    'alicechat/background_connection',
  );

  bool _serviceRequested = false;
  String _activeSessionId = '';
  ChatSession? _activeSession;

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
    _serviceRequested = true;
    _activeSessionId = sessionId.trim();
    await NativeDebugBridge.instance.log(
      'bg-service',
      'start requested session=$_activeSessionId',
    );
    try {
      await _channel.invokeMethod('startForegroundService', {
        'sessionId': _activeSessionId,
      });
    } catch (error) {
      debugPrint('[alicechat.bg] start service failed: $error');
    }
  }

  Future<void> stop() async {
    _serviceRequested = false;
    await NativeDebugBridge.instance.log('bg-service', 'stop requested');
    try {
      await _channel.invokeMethod('stopForegroundService');
    } catch (error) {
      debugPrint('[alicechat.bg] stop service failed: $error');
    }
  }

  Future<void> updateActiveSession(
    String sessionId, {
    ChatSession? session,
  }) async {
    _activeSessionId = sessionId.trim();
    _activeSession = session ?? _activeSession;
    await NativeDebugBridge.instance.log(
      'bg-service',
      'updateActiveSession session=$_activeSessionId serviceRequested=$_serviceRequested',
    );
    if (!_serviceRequested) return;
    try {
      await _channel.invokeMethod('updateActiveSession', {
        'sessionId': _activeSessionId,
      });
    } catch (error) {
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
      await stop();
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      await start(sessionId: _activeSessionId);
    }
  }
}
