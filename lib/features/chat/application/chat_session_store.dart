import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:uuid/uuid.dart';

import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../domain/chat_message.dart' as domain;
import '../domain/chat_session.dart';

class ChatSessionStore extends ChangeNotifier {
  ChatSessionStore({OpenClawHttpClient? client})
    : _client =
          client ??
          OpenClawHttpClient(
            const OpenClawConfig(
              baseUrl: 'https://alice.newthu.com',
              modelId: 'bian',
              providerId: 'alicechat-channel',
              agent: 'main',
              sessionName: 'alicechat',
              bridgeUrl:
                  'ws://127.0.0.1:18791?token=yuanzhe-7611681-668128-zheyuan-012345',
            ),
          );

  static const int initialMessageLimit = 20;
  static const Duration sendStuckTimeout = Duration(seconds: 45);
  static const Duration eventReconnectBaseDelay = Duration(seconds: 1);
  static const Duration eventReconnectMaxDelay = Duration(seconds: 8);

  final OpenClawHttpClient _client;
  final Uuid _uuid = const Uuid();
  final Map<String, ChatViewState> _states = {};
  final Map<String, StreamSubscription<Map<String, dynamic>>>
  _eventSubscriptions = {};
  final Map<String, Timer> _sendWatchdogs = {};
  final Map<String, Timer> _eventReconnectTimers = {};

  ChatViewState stateFor(ChatSession session) {
    return _states.putIfAbsent(
      _keyFor(session),
      () => ChatViewState(session: session),
    );
  }

  Future<void> ensureReady(ChatSession session) async {
    final state = stateFor(session);
    if (state.isReady || state.isLoading) return;

    state
      ..isLoading = true
      ..error = null;
    notifyListeners();

    try {
      final sessionId = await _ensureBackendSession(session);
      final messages = await _loadMessages(
        sessionId,
        limitToLatest: initialMessageLimit,
      );

      state
        ..backendSessionId = sessionId
        ..replaceMessages(messages)
        ..isLoading = false
        ..isReady = true;

      _ensureEventSubscription(session, sessionId);
      notifyListeners();
    } catch (error) {
      state
        ..isLoading = false
        ..error = error.toString();
      notifyListeners();
    }
  }

  Future<void> retry(ChatSession session) => ensureReady(session);

  Future<void> sendMessage(ChatSession session, String text) async {
    final state = stateFor(session);
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final sessionId =
        state.backendSessionId ?? await _ensureBackendSession(session);
    state.backendSessionId = sessionId;
    _ensureEventSubscription(session, sessionId);

    final clientMessageId = 'client_${_uuid.v4()}';
    final userMessage = core.TextMessage(
      id: clientMessageId,
      authorId: 'user',
      createdAt: DateTime.now(),
      text: trimmed,
    );

    state
      ..isSubmitting = true
      ..appendMessage(userMessage)
      ..markShouldStickToBottom()
      ..pendingClientMessageIds.add(clientMessageId);
    _armSendWatchdog(state, clientMessageId);
    notifyListeners();

    try {
      await _client.sendMessage(
        sessionId: sessionId,
        text: trimmed,
        contactId: session.contactId,
        userId: sessionId,
        clientMessageId: clientMessageId,
      );
    } catch (error) {
      _clearPendingClientMessage(state, clientMessageId);
      state.appendMessage(
        core.TextMessage(
          id: _uuid.v4(),
          authorId: 'assistant',
          createdAt: DateTime.now(),
          text: '❌ 发送失败: ${error.toString()}',
        ),
      );
      notifyListeners();
    }
  }

  void updateScrollState(
    ChatSession session, {
    required double offset,
    required bool stickToBottom,
  }) {
    final state = stateFor(session);
    state
      ..scrollOffset = offset
      ..stickToBottom = stickToBottom;
  }

  String _keyFor(ChatSession session) => session.backendSessionId ?? session.id;

  Future<String> _ensureBackendSession(ChatSession session) async {
    final state = stateFor(session);
    final existing = state.backendSessionId;
    if (existing != null && existing.isNotEmpty) return existing;

    final sessionId = await _client.ensureSession(
      preferredName: session.backendSessionId ?? session.title,
    );
    state.backendSessionId = sessionId;
    return sessionId;
  }

  void _ensureEventSubscription(ChatSession session, String sessionId) {
    if (_eventSubscriptions.containsKey(sessionId)) return;
    _eventReconnectTimers.remove(sessionId)?.cancel();
    final state = stateFor(session);
    state.isEventConnecting = true;
    notifyListeners();
    _eventSubscriptions[sessionId] = _client
        .subscribeEvents(sessionId: sessionId, since: state.lastEventSeq)
        .listen(
          (event) {
            state.isEventConnecting = false;
            _handleEvent(state, event);
          },
          onError: (error) {
            _eventSubscriptions.remove(sessionId);
            state
              ..error = error.toString()
              ..clearPending()
              ..clearStreaming()
              ..isSubmitting = false
              ..isAssistantStreaming = false
              ..isEventConnecting = false;
            _cancelWatchdogsForState(state);
            notifyListeners();
            _scheduleEventReconnect(session, sessionId, state);
          },
          onDone: () {
            _eventSubscriptions.remove(sessionId);
            state
              ..clearStreaming()
              ..isSubmitting = state.pendingClientMessageIds.isNotEmpty
              ..isAssistantStreaming = false
              ..isEventConnecting = false;
            _cancelWatchdogsForState(state);
            notifyListeners();
            _scheduleEventReconnect(session, sessionId, state);
          },
        );
  }

  void _handleEvent(ChatViewState state, Map<String, dynamic> event) {
    final seqValue = event['seq'];
    if (seqValue is num) {
      if (state.lastEventSeq != null &&
          seqValue.toInt() <= state.lastEventSeq!) {
        return;
      }
      state.lastEventSeq = seqValue.toInt();
      state.reconnectAttempts = 0;
    }
    final type = (event['event'] ?? '').toString();
    switch (type) {
      case 'message.created':
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        final message = _mapEventMessage(event['message']);
        if (message == null) return;
        if (clientMessageId.isNotEmpty) {
          state.replaceMessageId(clientMessageId, message.id);
        }
        state.upsertMessage(message);
        break;
      case 'message.status':
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        if (clientMessageId.isNotEmpty) {
          _clearPendingClientMessage(state, clientMessageId);
        }
        break;
      case 'assistant.message.started':
        final message = _mapEventMessage(event['message']);
        if (message == null) return;
        state.upsertMessage(message);
        state.streamingMessageIds
          ..clear()
          ..add(message.id);
        state
          ..isSubmitting = false
          ..isAssistantStreaming = true;
        break;
      case 'assistant.message.delta':
        final messageId = (event['messageId'] ?? '').toString();
        final text = (event['text'] ?? '').toString();
        if (messageId.isNotEmpty) {
          state.upsertOrPatchAssistantMessage(messageId, text);
          state.streamingMessageIds.add(messageId);
        }
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        if (clientMessageId.isNotEmpty) {
          _clearPendingClientMessage(state, clientMessageId);
        }
        state
          ..isSubmitting = false
          ..isAssistantStreaming = true;
        break;
      case 'assistant.message.completed':
        final message = _mapEventMessage(event['message']);
        if (message == null) return;
        state.upsertMessage(message);
        state.clearStreaming();
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        if (clientMessageId.isNotEmpty) {
          _clearPendingClientMessage(state, clientMessageId, notify: false);
        }
        state
          ..isSubmitting = state.pendingClientMessageIds.isNotEmpty
          ..isAssistantStreaming = false;
        break;
      case 'assistant.message.failed':
        final messageId = (event['messageId'] ?? '').toString();
        final error = (event['error'] ?? 'unknown error').toString();
        if (messageId.isNotEmpty) {
          state.upsertOrPatchAssistantMessage(messageId, '❌ 回复失败: $error');
        }
        state.clearStreaming();
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        if (clientMessageId.isNotEmpty) {
          _clearPendingClientMessage(state, clientMessageId, notify: false);
        }
        state
          ..isSubmitting = state.pendingClientMessageIds.isNotEmpty
          ..isAssistantStreaming = false;
        break;
    }
    notifyListeners();
  }

  void _armSendWatchdog(ChatViewState state, String clientMessageId) {
    _sendWatchdogs.remove(clientMessageId)?.cancel();
    _sendWatchdogs[clientMessageId] = Timer(sendStuckTimeout, () {
      if (!state.pendingClientMessageIds.contains(clientMessageId)) {
        _sendWatchdogs.remove(clientMessageId)?.cancel();
        return;
      }
      state.pendingClientMessageIds.remove(clientMessageId);
      state
        ..isSubmitting = false
        ..isAssistantStreaming = state.streamingMessageIds.isNotEmpty;
      state.appendMessage(
        core.TextMessage(
          id: _uuid.v4(),
          authorId: 'assistant',
          createdAt: DateTime.now(),
          text: '⚠️ 这条消息已经发出，但确认事件迟迟没回来。我先把输入框解锁了。',
        ),
      );
      _sendWatchdogs.remove(clientMessageId)?.cancel();
      notifyListeners();
    });
  }

  void _clearPendingClientMessage(
    ChatViewState state,
    String clientMessageId, {
    bool notify = false,
  }) {
    state.pendingClientMessageIds.remove(clientMessageId);
    _sendWatchdogs.remove(clientMessageId)?.cancel();
    state.isSubmitting = state.pendingClientMessageIds.isNotEmpty;
    state.isAssistantStreaming = state.streamingMessageIds.isNotEmpty;
    if (notify) {
      notifyListeners();
    }
  }

  void _cancelWatchdogsForState(ChatViewState state) {
    for (final clientMessageId in state.pendingClientMessageIds.toList()) {
      _sendWatchdogs.remove(clientMessageId)?.cancel();
    }
  }

  void _scheduleEventReconnect(
    ChatSession session,
    String sessionId,
    ChatViewState state,
  ) {
    if (_eventReconnectTimers.containsKey(sessionId)) return;
    state.reconnectAttempts += 1;
    final multiplier = 1 << (state.reconnectAttempts - 1).clamp(0, 3);
    final delayMs = (eventReconnectBaseDelay.inMilliseconds * multiplier).clamp(
      eventReconnectBaseDelay.inMilliseconds,
      eventReconnectMaxDelay.inMilliseconds,
    );
    _eventReconnectTimers[sessionId] = Timer(
      Duration(milliseconds: delayMs),
      () async {
        _eventReconnectTimers.remove(sessionId)?.cancel();
        if (state.backendSessionId != sessionId) return;
        try {
          final messages = await _loadMessages(
            sessionId,
            limitToLatest: initialMessageLimit,
          );
          state
            ..replaceMessages(messages)
            ..error = null;
          notifyListeners();
        } catch (_) {}
        _ensureEventSubscription(session, sessionId);
      },
    );
  }

  @override
  void dispose() {
    for (final subscription in _eventSubscriptions.values) {
      subscription.cancel();
    }
    for (final timer in _sendWatchdogs.values) {
      timer.cancel();
    }
    for (final timer in _eventReconnectTimers.values) {
      timer.cancel();
    }
    _eventSubscriptions.clear();
    _sendWatchdogs.clear();
    _eventReconnectTimers.clear();
    super.dispose();
  }

  core.TextMessage? _mapEventMessage(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final createdAtValue = raw['createdAt'];
    final createdAt =
        createdAtValue is num
            ? DateTime.fromMillisecondsSinceEpoch(
              (createdAtValue * 1000).round(),
            )
            : DateTime.now();
    final role = (raw['role'] ?? '').toString();
    final authorId =
        role == 'assistant'
            ? 'assistant'
            : role == 'system'
            ? 'system'
            : 'user';
    return core.TextMessage(
      id: (raw['id'] ?? _uuid.v4()).toString(),
      authorId: authorId,
      createdAt: createdAt,
      text: (raw['text'] ?? '').toString(),
    );
  }

  Future<List<core.TextMessage>> _loadMessages(
    String sessionId, {
    int? limitToLatest,
  }) async {
    final rawMessages = await _client.loadMessages(sessionId);
    final messages =
        rawMessages
            .map(domain.ChatMessage.fromBackend)
            .where((message) => message.text.trim().isNotEmpty)
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final visibleMessages =
        limitToLatest != null && messages.length > limitToLatest
            ? messages.sublist(messages.length - limitToLatest)
            : messages;

    return visibleMessages
        .map(
          (message) => core.TextMessage(
            id: message.id.isEmpty ? _uuid.v4() : message.id,
            authorId: message.authorId,
            createdAt: message.createdAt,
            text: message.text,
          ),
        )
        .toList(growable: false);
  }
}

class ChatViewState {
  ChatViewState({required this.session})
    : draftController = ValueNotifier<String>('');

  final ChatSession session;
  final ValueNotifier<String> draftController;

  String? backendSessionId;
  bool isLoading = false;
  bool isReady = false;
  bool isSubmitting = false;
  bool isAssistantStreaming = false;
  bool get isSending => isSubmitting;
  bool isEventConnecting = false;
  String? error;
  int? lastEventSeq;
  int reconnectAttempts = 0;
  double scrollOffset = 0;
  bool stickToBottom = true;
  List<core.TextMessage> messages = const [];
  final Set<String> pendingClientMessageIds = <String>{};
  final Set<String> streamingMessageIds = <String>{};

  void replaceMessages(List<core.TextMessage> nextMessages) {
    messages = List<core.TextMessage>.unmodifiable(nextMessages);
  }

  void appendMessage(core.TextMessage message) {
    messages = List<core.TextMessage>.unmodifiable([...messages, message]);
  }

  void upsertMessage(core.TextMessage message) {
    final list = [...messages];
    final index = list.indexWhere((item) => item.id == message.id);
    if (index >= 0) {
      list[index] = message;
    } else {
      list.add(message);
      list.sort(
        (a, b) => (a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
      );
    }
    messages = List<core.TextMessage>.unmodifiable(list);
  }

  void replaceMessageId(String oldId, String newId) {
    final list = [...messages];
    final index = list.indexWhere((item) => item.id == oldId);
    if (index < 0) return;
    final old = list[index];
    list[index] = core.TextMessage(
      id: newId,
      authorId: old.authorId,
      createdAt: old.createdAt,
      text: old.text,
    );
    messages = List<core.TextMessage>.unmodifiable(list);
  }

  void patchMessageText(String messageId, String nextText) {
    final list = [...messages];
    final index = list.indexWhere((item) => item.id == messageId);
    if (index < 0) return;
    final old = list[index];
    list[index] = core.TextMessage(
      id: old.id,
      authorId: old.authorId,
      createdAt: old.createdAt,
      text: nextText,
    );
    messages = List<core.TextMessage>.unmodifiable(list);
  }

  void upsertOrPatchAssistantMessage(String messageId, String text) {
    final list = [...messages];
    final index = list.indexWhere((item) => item.id == messageId);
    if (index >= 0) {
      final old = list[index];
      list[index] = core.TextMessage(
        id: old.id,
        authorId: old.authorId,
        createdAt: old.createdAt,
        text: text,
      );
    } else {
      list.add(
        core.TextMessage(
          id: messageId,
          authorId: 'assistant',
          createdAt: DateTime.now(),
          text: text,
        ),
      );
    }
    messages = List<core.TextMessage>.unmodifiable(list);
  }

  void clearPending() {
    pendingClientMessageIds.clear();
  }

  void clearStreaming() {
    streamingMessageIds.clear();
  }

  void markShouldStickToBottom() {
    stickToBottom = true;
  }
}
