import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../../contacts/domain/contact.dart';
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
  static const _defaultTitle = 'AliceChat';

  static const List<String> _defaultQuips = [
    '有条新消息在等你翻牌。',
    '有人轻轻敲了敲你的聊天窗。',
    '新动静来了，快去看看。',
    '对方递来了一句悄悄话。',
    '消息已送达，就等你回眸。',
  ];

  static const Map<String, List<String>> _characterQuips = {
    'alice': [
      'Alice 又来找你玩啦。',
      'Alice 带着新消息冒泡了。',
      '快看，Alice 正在等你回应。',
    ],
    '玲珑': [
      '玲珑又来敲你了。',
      '玲珑留了一句话，不看会后悔。',
      '玲珑那边有新动静。',
    ],
    '素心': [
      '素心抱着新消息跑来了。',
      '素心又勤勤恳恳地来汇报了。',
      '素心那边有更新，瞧一眼吧。',
    ],
  };

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final StreamController<NotificationOpenData> _openController =
      StreamController<NotificationOpenData>.broadcast();
  final Random _random = Random();
  final Map<String, Contact> _contactsBySessionId = {};
  final Map<String, Uint8List> _avatarCache = {};

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

  void registerContacts(Iterable<Contact> contacts) {
    for (final contact in contacts) {
      final sessionId = (contact.backendSessionId ?? contact.id).trim();
      if (sessionId.isEmpty) continue;
      _contactsBySessionId[sessionId] = contact;
    }
  }

  Contact? contactForSessionId(String sessionId) {
    return _contactsBySessionId[sessionId.trim()];
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
    final normalizedSessionId = sessionId.trim();
    if (!force &&
        normalizedSessionId.isNotEmpty &&
        normalizedSessionId == _activeSessionId) {
      return;
    }
    final contact = contactForSessionId(normalizedSessionId);
    final resolvedTitle = _resolveTitle(title: title, senderName: senderName, contact: contact);
    final teaser = _pickTeaser(resolvedTitle);
    final payload = {
      'sessionId': normalizedSessionId,
      'senderName': senderName,
      'messageId': messageId,
      'preview': body,
    };
    final largeIcon = await _loadLargeIcon(contact?.avatarAssetPath);
    final androidDetails = AndroidNotificationDetails(
      _androidChannelId,
      _androidChannelName,
      channelDescription: _androidChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: const DefaultStyleInformation(true, true),
      largeIcon: largeIcon,
      category: AndroidNotificationCategory.message,
    );
    await _localNotifications.show(
      normalizedSessionId.hashCode ^ messageId.hashCode ^ teaser.hashCode,
      resolvedTitle,
      teaser,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode(payload),
    );
  }

  String _resolveTitle({
    required String title,
    required String senderName,
    Contact? contact,
  }) {
    final candidates = [contact?.name, senderName, title];
    for (final item in candidates) {
      final value = item?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return _defaultTitle;
  }

  String _pickTeaser(String title) {
    final themed = _characterQuips[title] ?? _defaultQuips;
    return themed[_random.nextInt(themed.length)];
  }

  Future<ByteArrayAndroidBitmap?> _loadLargeIcon(String? assetPath) async {
    final normalized = assetPath?.trim() ?? '';
    if (normalized.isEmpty) return null;
    final cached = _avatarCache[normalized];
    if (cached != null) {
      return ByteArrayAndroidBitmap(cached);
    }
    try {
      final data = await rootBundle.load(normalized);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: 192,
        targetHeight: 192,
      );
      final frame = await codec.getNextFrame();
      final bytes = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;
      final png = bytes.buffer.asUint8List();
      _avatarCache[normalized] = png;
      return ByteArrayAndroidBitmap(png);
    } catch (error) {
      debugPrint('[alicechat.notifications] avatar load failed: $error');
      return null;
    }
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
