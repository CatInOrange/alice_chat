import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../data/push_api.dart';
import '../domain/push_device.dart';

class NotificationOpenData {
  const NotificationOpenData({
    required this.sessionId,
    this.senderName = '',
    this.messageId = '',
    this.preview = '',
  });

  final String sessionId;
  final String senderName;
  final String messageId;
  final String preview;

  factory NotificationOpenData.fromMap(Map<String, dynamic> data) {
    return NotificationOpenData(
      sessionId: (data['sessionId'] ?? '').toString(),
      senderName: (data['senderName'] ?? '').toString(),
      messageId: (data['messageId'] ?? '').toString(),
      preview: (data['preview'] ?? '').toString(),
    );
  }
}

class NotificationService extends ChangeNotifier {
  NotificationService._();

  static final NotificationService instance = NotificationService._();
  static const _deviceIdKey = 'notifications.deviceId';
  static const _androidChannelId = 'chat_messages';
  static const _androidChannelName = '聊天消息';
  static const _androidChannelDescription = 'AliceChat 聊天消息通知';

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final StreamController<NotificationOpenData> _openController =
      StreamController<NotificationOpenData>.broadcast();

  bool _initialized = false;
  String _activeSessionId = '';
  String? _deviceId;

  Stream<NotificationOpenData> get onNotificationOpened =>
      _openController.stream;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _initLocalNotifications();
    await _ensureDeviceRegistration();
  }

  Future<void> refreshConfig() async {
    if (!_initialized) return;
    await _ensureDeviceRegistration();
  }

  Future<void> setActiveSession(String sessionId) async {
    _activeSessionId = sessionId.trim();
    await _reportPresence(isForeground: true);
  }

  Future<void> clearActiveSession() async {
    _activeSessionId = '';
    await _reportPresence(isForeground: true);
  }

  Future<void> setAppForeground(bool isForeground) async {
    await _reportPresence(isForeground: isForeground);
  }

  Future<void> showChatNotification({
    required String sessionId,
    required String title,
    required String body,
    String senderName = '',
    String messageId = '',
    bool force = false,
  }) async {
    if (!force &&
        sessionId.trim().isNotEmpty &&
        sessionId.trim() == _activeSessionId) {
      return;
    }
    final payload = {
      'sessionId': sessionId,
      'senderName': senderName,
      'messageId': messageId,
      'preview': body,
    };
    await _localNotifications.show(
      sessionId.hashCode ^ messageId.hashCode ^ body.hashCode,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannelId,
          _androidChannelName,
          channelDescription: _androidChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      payload: jsonEncode(payload),
    );
  }

  Future<void> _initLocalNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          final json = jsonDecode(payload) as Map<String, dynamic>;
          _openController.add(NotificationOpenData.fromMap(json));
        } catch (_) {}
      },
    );

    final androidPlugin =
        _localNotifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _androidChannelId,
        _androidChannelName,
        description: _androidChannelDescription,
        importance: Importance.high,
      ),
    );
    await androidPlugin?.requestNotificationsPermission();
  }

  Future<void> _ensureDeviceRegistration() async {
    final config = await OpenClawSettingsStore.load();
    if (config.baseUrl.trim().isEmpty) return;
    final deviceId = await _ensureDeviceId();
    final api = PushApi(config);
    try {
      await api.registerDevice(
        PushDeviceRegistration(
          deviceId: deviceId,
          pushToken: 'local:$deviceId',
          provider: 'local-persistent',
          appVersion: '0.1.0',
          deviceName: 'android',
        ),
      );
      await _reportPresence(isForeground: true, configOverride: config);
    } catch (error) {
      debugPrint('[alicechat.notifications] local registration failed: $error');
    }
  }

  Future<void> _reportPresence({
    required bool isForeground,
    OpenClawConfig? configOverride,
  }) async {
    final config = configOverride ?? await OpenClawSettingsStore.load();
    if (config.baseUrl.trim().isEmpty) return;
    final deviceId = await _ensureDeviceId();
    final api = PushApi(config);
    try {
      await api.updatePresence(
        PushPresenceUpdate(
          deviceId: deviceId,
          isForeground: isForeground,
          activeSessionId: isForeground ? _activeSessionId : '',
        ),
      );
    } catch (error) {
      debugPrint('[alicechat.notifications] presence failed: $error');
    }
  }

  Future<String> _ensureDeviceId() async {
    if (_deviceId != null && _deviceId!.isNotEmpty) return _deviceId!;
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_deviceIdKey)?.trim();
    if (cached != null && cached.isNotEmpty) {
      _deviceId = cached;
      return cached;
    }
    final created = const Uuid().v4();
    await prefs.setString(_deviceIdKey, created);
    _deviceId = created;
    return created;
  }
}
