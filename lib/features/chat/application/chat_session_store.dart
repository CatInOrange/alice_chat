import 'package:flutter/foundation.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:uuid/uuid.dart';

import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../domain/chat_message.dart' as domain;
import '../domain/chat_session.dart';

class ChatSessionStore extends ChangeNotifier {
  ChatSessionStore({OpenClawHttpClient? client})
      : _client = client ??
            OpenClawHttpClient(
              const OpenClawConfig(
                baseUrl: 'http://43.156.5.177:8081',
                modelId: 'bian',
                providerId: 'alicechat-channel',
                agent: 'main',
                sessionName: 'alicechat',
                bridgeUrl:
                    'ws://127.0.0.1:18791?token=yuanzhe-7611681-668128-zheyuan-012345',
              ),
            );

  static const int initialMessageLimit = 20;

  final OpenClawHttpClient _client;
  final Uuid _uuid = const Uuid();
  final Map<String, ChatViewState> _states = {};

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
    if (trimmed.isEmpty || state.isSending) return;

    final sessionId = state.backendSessionId ?? await _ensureBackendSession(session);
    state.backendSessionId = sessionId;

    final userMessage = core.TextMessage(
      id: _uuid.v4(),
      authorId: 'user',
      createdAt: DateTime.now(),
      text: trimmed,
    );

    state
      ..isSending = true
      ..appendMessage(userMessage)
      ..markShouldStickToBottom();
    notifyListeners();

    try {
      final reply = await _client.sendMessage(
        sessionId: sessionId,
        text: trimmed,
        contactId: session.contactId,
        userId: sessionId,
      );

      if (reply.isNotEmpty) {
        state.appendMessage(
          core.TextMessage(
            id: _uuid.v4(),
            authorId: 'assistant',
            createdAt: DateTime.now(),
            text: reply,
          ),
        );
      }
    } catch (error) {
      state.appendMessage(
        core.TextMessage(
          id: _uuid.v4(),
          authorId: 'assistant',
          createdAt: DateTime.now(),
          text: '❌ 发送失败: ${error.toString()}',
        ),
      );
    } finally {
      state.isSending = false;
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

  Future<List<core.TextMessage>> _loadMessages(
    String sessionId, {
    int? limitToLatest,
  }) async {
    final rawMessages = await _client.loadMessages(sessionId);
    final messages = rawMessages
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
  bool isSending = false;
  String? error;
  double scrollOffset = 0;
  bool stickToBottom = true;
  List<core.TextMessage> messages = const [];

  void replaceMessages(List<core.TextMessage> nextMessages) {
    messages = List<core.TextMessage>.unmodifiable(nextMessages);
  }

  void appendMessage(core.TextMessage message) {
    messages = List<core.TextMessage>.unmodifiable([...messages, message]);
  }

  void markShouldStickToBottom() {
    stickToBottom = true;
  }
}
