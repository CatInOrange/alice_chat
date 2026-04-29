import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/debug/native_debug_bridge.dart';
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

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final StreamController<NotificationOpenData> _openController =
      StreamController<NotificationOpenData>.broadcast();
  final Map<String, Contact> _contactsBySessionId = {};
  final Map<String, Contact> _contactsByContactId = {};
  final Map<String, Uint8List> _avatarCache = {};

  bool _initialized = false;
  String _activeSessionId = '';
  String? _deviceId;

  Stream<NotificationOpenData> get onNotificationOpened =>
      _openController.stream;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await NativeDebugBridge.instance.log('notifications', 'initialize start');
    await _initLocalNotifications();
    await _ensureDeviceRegistration();
    await NativeDebugBridge.instance.log('notifications', 'initialize done');
  }

  Future<void> refreshConfig() async {
    if (!_initialized) return;
    await _ensureDeviceRegistration();
  }

  void registerContacts(Iterable<Contact> contacts) {
    for (final contact in contacts) {
      final contactId = contact.id.trim();
      if (contactId.isNotEmpty) {
        _contactsByContactId[contactId] = contact;
      }
      final sessionId = (contact.backendSessionId ?? '').trim();
      if (sessionId.isEmpty) continue;
      _contactsBySessionId[sessionId] = contact;
    }
  }

  void bindSessionToContact({
    required String sessionId,
    required Contact contact,
  }) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) return;
    _contactsBySessionId[normalizedSessionId] = contact;
  }

  Contact? contactForSessionId(String sessionId) {
    return _contactsBySessionId[sessionId.trim()];
  }

  Contact? contactForContactId(String contactId) {
    return _contactsByContactId[contactId.trim()];
  }

  Future<void> setActiveSession(String sessionId) async {
    _activeSessionId = sessionId.trim();
    await NativeDebugBridge.instance.log(
      'notifications',
      'setActiveSession session=$_activeSessionId',
    );
    await _reportPresence(isForeground: true);
  }

  Future<void> clearActiveSession() async {
    _activeSessionId = '';
    await NativeDebugBridge.instance.log('notifications', 'clearActiveSession');
    await _reportPresence(isForeground: true);
  }

  Future<void> setAppForeground(bool isForeground) async {
    await NativeDebugBridge.instance.log(
      'notifications',
      'setAppForeground foreground=$isForeground active=$_activeSessionId',
    );
    await _reportPresence(isForeground: isForeground);
  }

  @Deprecated('Android chat notifications are now owned by native foreground service.')
  Future<void> showChatNotification({
    required String sessionId,
    required String title,
    required String body,
    String senderName = '',
    String messageId = '',
    bool force = false,
    bool suppressForActiveSession = true,
    bool foregroundOnly = false,
    String source = 'flutter',
  }) async {
    final normalizedSessionId = sessionId.trim();
    const platform = TargetPlatform.android;
    await NativeDebugBridge.instance.log(
      'notifications',
      'decision=delegate_to_native source=$source session=$normalizedSessionId title=$title platform=$platform messageId=$messageId bodyLen=${body.length}',
    );
    if (platform == TargetPlatform.android) {
      return;
    }

    final contact = contactForSessionId(normalizedSessionId);
    final resolvedTitle = _resolveTitle(
      title: title,
      senderName: senderName,
      contact: contact,
    );
    final resolvedBody = _stripModelPrefix(body);
    final payload = {
      'sessionId': normalizedSessionId,
      'senderName': senderName,
      'messageId': messageId,
      'preview': resolvedBody,
    };
    final largeIcon = await _loadLargeIcon(contact?.avatarAssetPath);
    final notificationId = normalizedSessionId.hashCode ^ messageId.hashCode;
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
    try {
      await _localNotifications.show(
        notificationId,
        resolvedTitle,
        resolvedBody,
        NotificationDetails(android: androidDetails),
        payload: jsonEncode(payload),
      );
      await NativeDebugBridge.instance.log(
        'notifications',
        'decision=shown_non_android source=$source session=$normalizedSessionId messageId=$messageId notificationId=$notificationId resolvedTitle=$resolvedTitle icon=${largeIcon != null}',
      );
    } catch (error) {
      await NativeDebugBridge.instance.log(
        'notifications',
        'decision=show_failed_non_android source=$source session=$normalizedSessionId messageId=$messageId notificationId=$notificationId error=$error',
        level: 'ERROR',
      );
      rethrow;
    }
  }

  String _stripModelPrefix(String text) {
    final value = text.trimLeft();
    if (!value.startsWith('[')) return text.trim();
    final bracketEnd = value.indexOf(']');
    if (bracketEnd <= 1) return text.trim();
    return value.substring(bracketEnd + 1).trimLeft();
  }

  String _resolveTitle({
    required String title,
    required String senderName,
    Contact? contact,
  }) {
    final senderContact = contactForContactId(senderName) ?? contactForContactId(title);
    final candidates = [contact?.name, senderContact?.name, senderName, title];
    for (final item in candidates) {
      final value = item?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return _defaultTitle;
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
      final bytes = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
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
          final data = NotificationOpenData.fromMap(json);
          unawaited(
            NativeDebugBridge.instance.log(
              'notifications',
              'notification tapped session=${data.sessionId} messageId=${data.messageId}',
            ),
          );
          _openController.add(data);
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
      await NativeDebugBridge.instance.log(
        'notifications',
        'local registration failed: $error',
        level: 'ERROR',
      );
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
      await NativeDebugBridge.instance.log(
        'notifications',
        'presence failed foreground=$isForeground active=$_activeSessionId error=$error',
        level: 'ERROR',
      );
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
