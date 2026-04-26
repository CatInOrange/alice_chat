import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/debug/native_debug_bridge.dart';
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

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;

    final config = await OpenClawSettingsStore.load();
    if (config.baseUrl.trim().isEmpty) {
      await NativeDebugBridge.instance.log(
        'bg-events',
        'start skipped missing baseUrl',
      );
      debugPrint('[alicechat.bg.events] skipped, missing baseUrl');
      return;
    }

    _client = OpenClawHttpClient(config);
    _running = true;
    await NativeDebugBridge.instance.log(
      'bg-events',
      'start running=true lastSeq=${_lastSeq ?? 'null'}',
    );
    _attach();
  }

  Future<void> stop() async {
    _running = false;
    await NativeDebugBridge.instance.log(
      'bg-events',
      'stop requested lastSeq=${_lastSeq ?? 'null'}',
    );
    await _subscription?.cancel();
    _subscription = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void rememberSession({required String sessionId, required String title}) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) return;
    _sessionTitles[normalizedSessionId] =
        title.trim().isEmpty ? 'AliceChat' : title.trim();
  }

  void _attach() {
    final client = _client;
    if (!_running || client == null) return;

    unawaited(
      NativeDebugBridge.instance.log(
        'bg-events',
        'attach subscribe since=${_lastSeq ?? 'null'}',
      ),
    );
    _subscription = client
        .subscribeEvents(since: _lastSeq)
        .listen(
          _onEvent,
          onError: (error, stackTrace) {
            unawaited(
              NativeDebugBridge.instance.log(
                'bg-events',
                'stream error error=$error lastSeq=${_lastSeq ?? 'null'}',
                level: 'ERROR',
              ),
            );
            debugPrint('[alicechat.bg.events] stream error: $error');
            _scheduleReconnect();
          },
          onDone: () {
            unawaited(
              NativeDebugBridge.instance.log(
                'bg-events',
                'stream done lastSeq=${_lastSeq ?? 'null'}',
              ),
            );
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
    final message = event['message'];
    if (message is! Map<String, dynamic>) {
      unawaited(
        NativeDebugBridge.instance.log(
          'bg-events',
          'decision=skip_missing_message type=$type session=$sessionId seq=${_lastSeq ?? 'null'}',
        ),
      );
      return;
    }

    final role = (message['role'] ?? '').toString();
    final text = (message['text'] ?? '').toString().trim();
    final attachments = (message['attachments'] as List<dynamic>? ?? const []);
    final messageId = (message['id'] ?? event['messageId'] ?? '').toString();
    if (sessionId.isEmpty) {
      unawaited(
        NativeDebugBridge.instance.log(
          'bg-events',
          'decision=skip_empty_session type=$type messageId=$messageId seq=${_lastSeq ?? 'null'}',
        ),
      );
      return;
    }
    if (role != 'assistant') {
      unawaited(
        NativeDebugBridge.instance.log(
          'bg-events',
          'decision=skip_role type=$type session=$sessionId role=$role messageId=$messageId',
        ),
      );
      return;
    }
    final preview =
        text.isNotEmpty
            ? text
            : attachments.isNotEmpty
            ? '[图片]'
            : '';
    if (preview.isEmpty) {
      unawaited(
        NativeDebugBridge.instance.log(
          'bg-events',
          'decision=skip_empty_text type=$type session=$sessionId role=$role messageId=$messageId',
        ),
      );
      return;
    }

    final title = _resolveTitle(sessionId, event, message);
    unawaited(
      NativeDebugBridge.instance.log(
        'bg-events',
        'decision=notify_attempt type=$type session=$sessionId messageId=$messageId seq=${_lastSeq ?? 'null'} title=$title textLen=${preview.length}',
      ),
    );

    unawaited(
      NotificationService.instance.showChatNotification(
        sessionId: sessionId,
        title: title,
        body: preview,
        senderName: title,
        messageId: messageId,
        force: false,
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

    final eventTitle =
        (event['sessionTitle'] ?? event['senderName'] ?? '').toString().trim();
    if (eventTitle.isNotEmpty) {
      _sessionTitles[sessionId] = eventTitle;
      return eventTitle;
    }

    final messageTitle =
        (message['senderName'] ?? message['authorName'] ?? '')
            .toString()
            .trim();
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
    unawaited(
      NativeDebugBridge.instance.log(
        'bg-events',
        'scheduleReconnect delaySeconds=3 lastSeq=${_lastSeq ?? 'null'}',
      ),
    );
    _reconnectTimer = Timer(const Duration(seconds: 3), _attach);
  }
}
