import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import 'notification_service.dart';

class BackgroundEventConnection {
  BackgroundEventConnection._();

  static final BackgroundEventConnection instance =
      BackgroundEventConnection._();

  OpenClawHttpClient? _client;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _reconnectTimer;
  final Map<String, String> _sessionTitles = {};
  int? _lastSeq;
  bool _running = false;
  String _activeSessionId = '';

  bool get isRunning => _running;
  String get activeSessionId => _activeSessionId;

  Future<void> start() async {
    if (_running) return;

    final config = await OpenClawSettingsStore.load();
    if (config.baseUrl.trim().isEmpty) {
      debugPrint('[alicechat.bg.events] skipped, missing baseUrl');
      return;
    }

    _client = OpenClawHttpClient(config);
    _running = true;
    _attach();
  }

  Future<void> stop() async {
    _running = false;
    _activeSessionId = '';
    await _subscription?.cancel();
    _subscription = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void rememberSession({required String sessionId, required String title}) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) return;
    _sessionTitles[normalizedSessionId] = title.trim().isEmpty ? 'AliceChat' : title.trim();
  }

  void setActiveSession(String sessionId) {
    _activeSessionId = sessionId.trim();
  }

  void _attach() {
    final client = _client;
    if (!_running || client == null) return;

    _subscription = client
        .subscribeEvents(since: _lastSeq)
        .listen(
          _onEvent,
          onError: (error, stackTrace) {
            debugPrint('[alicechat.bg.events] stream error: $error');
            _scheduleReconnect();
          },
          onDone: () {
            debugPrint('[alicechat.bg.events] stream done');
            _scheduleReconnect();
          },
          cancelOnError: true,
        );
  }

  void _onEvent(Map<String, dynamic> event) {
    final seq = event['seq'];
    if (seq is num) {
      _lastSeq = seq.toInt();
    }

    final type = (event['event'] ?? '').toString();
    if (type != 'assistant.message.completed' && type != 'message.created') {
      return;
    }

    final sessionId = (event['sessionId'] ?? '').toString().trim();
    if (sessionId.isEmpty) return;
    if (sessionId == _activeSessionId) return;

    final message = event['message'];
    if (message is! Map<String, dynamic>) return;

    final role = (message['role'] ?? '').toString();
    if (role != 'assistant') return;

    final text = (message['text'] ?? '').toString().trim();
    if (text.isEmpty) return;

    final title = _resolveTitle(sessionId, event, message);
    final messageId = (message['id'] ?? event['messageId'] ?? '').toString();

    unawaited(
      NotificationService.instance.showChatNotification(
        sessionId: sessionId,
        title: title,
        body: text,
        senderName: title,
        messageId: messageId,
        force: true,
      ),
    );
  }

  String _resolveTitle(
    String sessionId,
    Map<String, dynamic> event,
    Map<String, dynamic> message,
  ) {
    final cached = _sessionTitles[sessionId];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final eventTitle = (event['sessionTitle'] ?? event['senderName'] ?? '').toString().trim();
    if (eventTitle.isNotEmpty) {
      _sessionTitles[sessionId] = eventTitle;
      return eventTitle;
    }

    final messageTitle = (message['senderName'] ?? message['authorName'] ?? '').toString().trim();
    if (messageTitle.isNotEmpty) {
      _sessionTitles[sessionId] = messageTitle;
      return messageTitle;
    }

    return 'AliceChat';
  }

  void _scheduleReconnect() {
    if (!_running) return;
    _subscription?.cancel();
    _subscription = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _attach);
  }
}
