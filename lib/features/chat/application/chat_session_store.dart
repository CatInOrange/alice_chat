import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:uuid/uuid.dart';

import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../../notifications/application/notification_service.dart';
import '../domain/chat_message.dart' as domain;
import '../domain/chat_session.dart';

class ChatSessionStore extends ChangeNotifier {
  ChatSessionStore({OpenClawHttpClient? client})
    : _client =
          client ??
          OpenClawHttpClient(
            const OpenClawConfig(
              baseUrl: '',
              modelId: 'bian',
              providerId: 'alicechat-channel',
              agent: 'main',
              sessionName: 'alicechat',
              bridgeUrl:
                  'ws://127.0.0.1:18791?token=yuanzhe-7611681-668128-zheyuan-012345',
            ),
          ) {
    _configReady = reloadConfig();
  }

  static const int initialMessageLimit = 20;
  static const int olderMessagePageSize = 5;
  static const int latestRefreshPageSize = 20;
  static const Duration sendStuckTimeout = Duration(seconds: 45);
  static const Duration eventReconnectBaseDelay = Duration(seconds: 1);
  static const Duration eventReconnectMaxDelay = Duration(seconds: 8);

  OpenClawHttpClient _client;
  late Future<void> _configReady;
  final Uuid _uuid = const Uuid();
  final Map<String, ChatViewState> _states = {};
  final Map<String, String> _sessionIdBySessionKey = {};
  final Map<String, StreamSubscription<Map<String, dynamic>>>
  _eventSubscriptions = {};
  final Map<String, Timer> _sendWatchdogs = {};
  final Map<String, Timer> _eventReconnectTimers = {};
  final Map<String, DateTime> _lastDebugLogAt = {};

  Future<void> reloadConfig() async {
    final config = await OpenClawSettingsStore.load();
    _client = OpenClawHttpClient(config);
    _dropRealtimeConnections();
    for (final state in _states.values) {
      _resetBackendSession(state);
      state
        ..isLoading = false
        ..isReady = false
        ..error = null;
    }
    notifyListeners();
  }

  Future<void> _ensureConfigReady() async {
    await _configReady;
    final baseUrl = _client.config.baseUrl.trim();
    if (baseUrl.isEmpty) {
      throw Exception('请先在设置页填写后端地址');
    }
  }

  OpenClawConfig get currentConfig => _client.config;

  ChatViewState stateFor(ChatSession session) {
    return _states.putIfAbsent(
      _keyFor(session),
      () => ChatViewState(session: session),
    );
  }

  Future<void> ensureReady(ChatSession session) async {
    final state = stateFor(session);
    if (state.isReady || state.isLoading) {
      if (state.isReady &&
          state.backendSessionId != null &&
          state.backendSessionId!.isNotEmpty) {
        _ensureEventSubscription(session, state.backendSessionId!);
      }
      return;
    }

    final shouldShowLoading = state.messages.isEmpty;
    state
      ..isLoading = true
      ..error = null;
    if (shouldShowLoading) {
      notifyListeners();
    }

    try {
      await _ensureConfigReady();
      var sessionId = await _ensureBackendSession(session);
      MessageLoadResult initialLoad;
      try {
        initialLoad = await _loadMessagesPage(
          sessionId,
          limit: initialMessageLimit,
        );
      } catch (error) {
        if (!_isUnknownSessionError(error)) rethrow;
        _resetBackendSession(state);
        _debugState(
          'session.recover.ensureReady',
          state,
          extra: {'reason': error.toString()},
          force: true,
        );
        sessionId = await _ensureBackendSession(session);
        initialLoad = await _loadMessagesPage(
          sessionId,
          limit: initialMessageLimit,
        );
      }

      state
        ..backendSessionId = sessionId
        ..replaceMessages(initialLoad.messages)
        ..hasMoreHistory = initialLoad.hasMoreBefore
        ..oldestLoadedMessageId = initialLoad.oldestMessageId
        ..newestLoadedMessageId = initialLoad.newestMessageId
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

  Future<void> retry(ChatSession session) async {
    _configReady = reloadConfig();
    await ensureReady(session);
  }

  Future<void> sendMessage(ChatSession session, String text) async {
    await _sendMessageInternal(session, text: text, attachments: const []);
  }

  Future<void> sendImageMessage(
    ChatSession session, {
    required String filePath,
    String caption = '',
  }) async {
    await _ensureConfigReady();
    final upload = await _client.uploadMedia(filePath: filePath);
    await _sendMessageInternal(
      session,
      text: caption,
      attachments: [upload.attachment],
    );
  }

  Future<void> _sendMessageInternal(
    ChatSession session, {
    required String text,
    required List<Map<String, dynamic>> attachments,
  }) async {
    await _ensureConfigReady();
    final state = stateFor(session);
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return;

    var sessionId =
        state.backendSessionId ?? await _ensureBackendSession(session);
    state.backendSessionId = sessionId;
    _ensureEventSubscription(session, sessionId);

    final clientMessageId = 'client_${_uuid.v4()}';
    final userMessage =
        attachments.isNotEmpty
            ? core.ImageMessage(
              id: clientMessageId,
              authorId: 'user',
              createdAt: DateTime.now(),
              source: (attachments.first['url'] ?? '').toString(),
              text: trimmed.isEmpty ? null : trimmed,
              metadata: {'attachments': attachments},
            )
            : core.TextMessage(
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
    _debugState(
      'sendMessage.begin',
      state,
      extra: {
        'clientMessageId': clientMessageId,
        'text': trimmed,
        'attachmentCount': attachments.length,
      },
    );
    notifyListeners();

    try {
      await _client.sendMessage(
        sessionId: sessionId,
        text: trimmed,
        attachments: attachments,
        contactId: session.contactId,
        userId: sessionId,
        clientMessageId: clientMessageId,
      );
      _debugState(
        'sendMessage.posted',
        state,
        extra: {'clientMessageId': clientMessageId},
      );
    } catch (error) {
      Object finalError = error;
      if (_isUnknownSessionError(error)) {
        _resetBackendSession(state);
        _debugState(
          'session.recover.sendMessage',
          state,
          extra: {
            'clientMessageId': clientMessageId,
            'reason': error.toString(),
          },
          force: true,
        );
        try {
          sessionId = await _ensureBackendSession(session);
          state.backendSessionId = sessionId;
          _ensureEventSubscription(session, sessionId);
          await _client.sendMessage(
            sessionId: sessionId,
            text: trimmed,
            attachments: attachments,
            contactId: session.contactId,
            userId: sessionId,
            clientMessageId: clientMessageId,
          );
          _debugState(
            'sendMessage.posted.retry',
            state,
            extra: {'clientMessageId': clientMessageId, 'sessionId': sessionId},
            force: true,
          );
          return;
        } catch (retryError) {
          finalError = retryError;
        }
      }
      _clearPendingClientMessage(state, clientMessageId);
      state.appendMessage(
        core.TextMessage(
          id: _uuid.v4(),
          authorId: 'assistant',
          createdAt: DateTime.now(),
          text: '❌ ${_humanizeError(finalError)}',
        ),
      );
      _debugState(
        'sendMessage.error',
        state,
        extra: {
          'clientMessageId': clientMessageId,
          'error': finalError.toString(),
        },
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

  Future<bool> loadOlderMessages(ChatSession session) async {
    await _ensureConfigReady();
    final state = stateFor(session);
    final sessionId =
        state.backendSessionId ?? await _ensureBackendSession(session);
    final beforeMessageId = state.oldestLoadedMessageId;
    if (beforeMessageId == null || beforeMessageId.isEmpty) return false;
    if (state.isLoadingOlder || !state.hasMoreHistory) return false;

    state.isLoadingOlder = true;
    notifyListeners();
    try {
      final page = await _loadMessagesPage(
        sessionId,
        limit: olderMessagePageSize,
        beforeMessageId: beforeMessageId,
      );
      if (page.messages.isNotEmpty) {
        state.mergeMessages(page.messages);
      }
      state
        ..hasMoreHistory = page.hasMoreBefore
        ..oldestLoadedMessageId =
            page.oldestMessageId ?? state.oldestLoadedMessageId
        ..newestLoadedMessageId =
            page.newestMessageId ?? state.newestLoadedMessageId
        ..error = null;
      return page.messages.isNotEmpty;
    } catch (error) {
      state.error = _humanizeError(error);
      return false;
    } finally {
      state.isLoadingOlder = false;
      notifyListeners();
    }
  }

  Future<bool> refreshLatestMessages(ChatSession session) async {
    _configReady = reloadConfig();
    await _ensureConfigReady();
    final state = stateFor(session);
    final sessionId =
        state.backendSessionId ?? await _ensureBackendSession(session);
    if (state.isRefreshingLatest) return false;

    state.isRefreshingLatest = true;
    notifyListeners();
    try {
      final afterMessageId = state.newestLoadedMessageId;
      final page = await _loadMessagesPage(
        sessionId,
        limit: latestRefreshPageSize,
        afterMessageId: afterMessageId,
      );
      if (page.messages.isNotEmpty) {
        state.mergeMessages(page.messages);
      }
      state
        ..oldestLoadedMessageId =
            page.oldestMessageId ?? state.oldestLoadedMessageId
        ..newestLoadedMessageId =
            page.newestMessageId ?? state.newestLoadedMessageId
        ..error = null;
      return page.messages.isNotEmpty;
    } catch (error) {
      state.error = _humanizeError(error);
      return false;
    } finally {
      state.isRefreshingLatest = false;
      notifyListeners();
    }
  }

  String _keyFor(ChatSession session) => session.id;

  Future<String> _ensureBackendSession(ChatSession session) async {
    final state = stateFor(session);
    final existing = state.backendSessionId;
    if (existing != null && existing.isNotEmpty) return existing;

    final cacheKey = _keyFor(session);
    final cachedSessionId = _sessionIdBySessionKey[cacheKey];
    if (cachedSessionId != null && cachedSessionId.isNotEmpty) {
      state.backendSessionId = cachedSessionId;
      return cachedSessionId;
    }

    final sessionId = await _client.ensureSession(
      preferredName: session.backendSessionId ?? session.title,
    );
    state.backendSessionId = sessionId;
    _sessionIdBySessionKey[cacheKey] = sessionId;
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
              ..error = _humanizeError(error)
              ..clearPending()
              ..clearStreaming()
              ..clearAssistantProgress()
              ..isSubmitting = false
              ..isAssistantStreaming = false
              ..isEventConnecting = false;
            _cancelWatchdogsForState(state);
            _debugState(
              'events.onError',
              state,
              extra: {'error': error.toString()},
              force: true,
            );
            notifyListeners();
            _scheduleEventReconnect(session, sessionId, state);
          },
          onDone: () {
            _eventSubscriptions.remove(sessionId);
            state
              ..clearStreaming()
              ..clearAssistantProgress()
              ..isSubmitting = state.pendingClientMessageIds.isNotEmpty
              ..isAssistantStreaming = false
              ..isEventConnecting = false;
            _cancelWatchdogsForState(state);
            _debugState('events.onDone', state, force: true);
            notifyListeners();
            _scheduleEventReconnect(session, sessionId, state);
          },
        );
  }

  void _handleEvent(ChatViewState state, Map<String, dynamic> event) {
    final beforeMessageCount = state.messages.length;
    final beforeAssistantCount =
        state.messages
            .where((message) => message.authorId == 'assistant')
            .length;
    final seqValue = event['seq'];
    if (seqValue is num) {
      if (state.lastEventSeq != null &&
          seqValue.toInt() <= state.lastEventSeq!) {
        _debugState(
          'events.duplicate',
          state,
          extra: {
            'eventType': (event['event'] ?? '').toString(),
            'seq': seqValue.toInt(),
            'event': _compactEvent(event),
          },
          force: true,
        );
        return;
      }
      state.lastEventSeq = seqValue.toInt();
      state.reconnectAttempts = 0;
    }
    final type = (event['event'] ?? '').toString();
    _debugState(
      'events.$type',
      state,
      extra: {'eventType': type, 'event': _compactEvent(event)},
    );
    switch (type) {
      case 'message.created':
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        final message = _mapEventMessage(event['message']);
        if (message == null) return;
        if (clientMessageId.isNotEmpty &&
            state.confirmPendingMessage(clientMessageId, message)) {
        } else {
          state.upsertMessage(message);
        }
        state.trackMessageWindow(message.id);
        break;
      case 'message.status':
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        if (clientMessageId.isNotEmpty) {
          _clearPendingClientMessage(state, clientMessageId);
        }
        break;
      case 'assistant.message.started':
        final messageId = (event['messageId'] ?? '').toString();
        state.streamingMessageIds.clear();
        if (messageId.isNotEmpty) {
          state.streamingMessageIds.add(messageId);
        }
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        if (clientMessageId.isNotEmpty) {
          _clearPendingClientMessage(state, clientMessageId);
        } else {
          _clearOldestPendingClientMessage(state);
        }
        state
          ..isSubmitting = false
          ..isAssistantStreaming = true;
        break;
      case 'assistant.progress':
        final messageId = (event['messageId'] ?? '').toString();
        final sequenceValue = event['sequence'];
        final sequence = sequenceValue is num ? sequenceValue.toInt() : 0;
        if (messageId.isNotEmpty && sequence > 0) {
          state.setAssistantProgress(messageId: messageId, sequence: sequence);
          state.streamingMessageIds
            ..clear()
            ..add(messageId);
        }
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        if (clientMessageId.isNotEmpty) {
          _clearPendingClientMessage(state, clientMessageId);
        } else {
          _clearOldestPendingClientMessage(state);
        }
        state
          ..isSubmitting = false
          ..isAssistantStreaming = true;
        break;
      case 'assistant.message.completed':
        final message = _mapEventMessage(event['message']);
        if (message == null) return;
        state.upsertMessage(message);
        state
          ..clearStreaming()
          ..clearAssistantProgress();
        state.trackMessageWindow(message.id);
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        if (clientMessageId.isNotEmpty) {
          _clearPendingClientMessage(state, clientMessageId, notify: false);
        } else {
          _clearOldestPendingClientMessage(state);
        }
        state
          ..isSubmitting = false
          ..isAssistantStreaming = false;
        final notificationBody = switch (message) {
          core.TextMessage textMessage => textMessage.text,
          core.ImageMessage _ => '[图片]',
          _ => '你收到一条新消息',
        };
        unawaited(
          NotificationService.instance.showChatNotification(
            sessionId: state.backendSessionId ?? state.session.id,
            title: state.session.title,
            body: notificationBody,
            senderName: state.session.title,
            messageId: message.id,
            foregroundOnly: true,
            source: 'flutter-session-store',
          ),
        );
        break;
      case 'assistant.message.failed':
        final error = (event['error'] ?? 'unknown error').toString();
        state
          ..clearStreaming()
          ..clearAssistantProgress();
        state.appendMessage(
          core.TextMessage(
            id: _uuid.v4(),
            authorId: 'assistant',
            createdAt: DateTime.now(),
            text: '❌ 回复失败: $error',
          ),
        );
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        if (clientMessageId.isNotEmpty) {
          _clearPendingClientMessage(state, clientMessageId, notify: false);
        } else {
          _clearOldestPendingClientMessage(state);
        }
        state
          ..isSubmitting = false
          ..isAssistantStreaming = false;
        break;
    }
    final afterAssistantCount =
        state.messages
            .where((message) => message.authorId == 'assistant')
            .length;
    _debugState(
      'events.$type.applied',
      state,
      extra: {
        'eventType': type,
        'beforeMessageCount': beforeMessageCount,
        'afterMessageCount': state.messages.length,
        'beforeAssistantCount': beforeAssistantCount,
        'afterAssistantCount': afterAssistantCount,
        'assistantDelta': afterAssistantCount - beforeAssistantCount,
        'messageDelta': state.messages.length - beforeMessageCount,
      },
    );
    if (!state.isAssistantStreaming &&
        type.startsWith('assistant.message') &&
        afterAssistantCount == beforeAssistantCount) {
      _debugState(
        'assistant.visible-message.missing',
        state,
        extra: {
          'eventType': type,
          'beforeMessageCount': beforeMessageCount,
          'afterMessageCount': state.messages.length,
          'beforeAssistantCount': beforeAssistantCount,
          'afterAssistantCount': afterAssistantCount,
        },
        force: true,
      );
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
      _debugState(
        'watchdog.timeout',
        state,
        extra: {'clientMessageId': clientMessageId},
        force: true,
      );
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
    _debugState(
      'pending.clear',
      state,
      extra: {'clientMessageId': clientMessageId},
    );
    if (notify) {
      notifyListeners();
    }
  }

  void _clearOldestPendingClientMessage(
    ChatViewState state, {
    bool notify = false,
  }) {
    if (state.pendingClientMessageIds.isEmpty) {
      state.isSubmitting = false;
      if (notify) {
        notifyListeners();
      }
      return;
    }
    final oldest = state.pendingClientMessageIds.first;
    _clearPendingClientMessage(state, oldest, notify: notify);
  }

  bool _isUnknownSessionError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('unknown session id') || text.contains('404');
  }

  String _humanizeError(Object error) {
    final text = error.toString();
    if (text.contains('认证失败')) return text;
    return text.replaceFirst(RegExp(r'^Exception:\s*'), '');
  }

  void _dropRealtimeConnections() {
    for (final subscription in _eventSubscriptions.values) {
      subscription.cancel();
    }
    for (final timer in _eventReconnectTimers.values) {
      timer.cancel();
    }
    _eventSubscriptions.clear();
    _eventReconnectTimers.clear();
  }

  void _resetBackendSession(ChatViewState state) {
    final oldSessionId = state.backendSessionId;
    if (oldSessionId != null && oldSessionId.isNotEmpty) {
      _eventSubscriptions.remove(oldSessionId)?.cancel();
      _eventReconnectTimers.remove(oldSessionId)?.cancel();
    }
    _sessionIdBySessionKey.remove(_keyFor(state.session));
    state
      ..backendSessionId = null
      ..isReady = false
      ..isEventConnecting = false
      ..lastEventSeq = null
      ..reconnectAttempts = 0
      ..clearPending()
      ..clearStreaming()
      ..isSubmitting = false
      ..isAssistantStreaming = false;
    _cancelWatchdogsForState(state);
  }

  void _cancelWatchdogsForState(ChatViewState state) {
    for (final clientMessageId in state.pendingClientMessageIds.toList()) {
      _sendWatchdogs.remove(clientMessageId)?.cancel();
    }
  }

  Map<String, dynamic> _compactEvent(Map<String, dynamic> event) {
    return {
      if (event['event'] != null) 'event': event['event'],
      if (event['seq'] != null) 'seq': event['seq'],
      if (event['clientMessageId'] != null)
        'clientMessageId': event['clientMessageId'],
      if (event['messageId'] != null) 'messageId': event['messageId'],
      if (event['requestId'] != null) 'requestId': event['requestId'],
      if (event['status'] != null) 'status': event['status'],
      if (event['message'] is Map<String, dynamic>)
        'message': {
          'id': (event['message'] as Map<String, dynamic>)['id'],
          'role': (event['message'] as Map<String, dynamic>)['role'],
          'text': ((event['message'] as Map<String, dynamic>)['text'] ?? '')
              .toString()
              .substring(
                0,
                (((event['message'] as Map<String, dynamic>)['text'] ?? '')
                            .toString()
                            .length) >
                        80
                    ? 80
                    : ((event['message'] as Map<String, dynamic>)['text'] ?? '')
                        .toString()
                        .length,
              ),
        },
    };
  }

  void _debugState(
    String tag,
    ChatViewState state, {
    Map<String, dynamic>? extra,
    bool force = false,
  }) {
    final now = DateTime.now();
    final lastAt = _lastDebugLogAt[tag];
    if (!force &&
        lastAt != null &&
        now.difference(lastAt).inMilliseconds < 250) {
      return;
    }
    _lastDebugLogAt[tag] = now;

    final payload = {
      'tag': tag,
      'ts': now.toIso8601String(),
      'sessionId': state.backendSessionId,
      'sessionLocalId': state.session.id,
      'sessionTitle': state.session.title,
      'isSubmitting': state.isSubmitting,
      'isAssistantStreaming': state.isAssistantStreaming,
      'isEventConnecting': state.isEventConnecting,
      'pendingCount': state.pendingClientMessageIds.length,
      'streamingCount': state.streamingMessageIds.length,
      'messageCount': state.messages.length,
      'lastEventSeq': state.lastEventSeq,
      'pendingIds': state.pendingClientMessageIds.toList(),
      'streamingIds': state.streamingMessageIds.toList(),
      if (extra != null) ...extra,
    };

    debugPrint('[alicechat.front] ${jsonEncode(payload)}');
    unawaited(_client.sendClientDebugLog(payload));
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
          final page = await _loadMessagesPage(
            sessionId,
            limit: latestRefreshPageSize,
            afterMessageId: state.newestLoadedMessageId,
          );
          if (page.messages.isNotEmpty) {
            state.mergeMessages(page.messages);
          }
          state
            ..oldestLoadedMessageId =
                page.oldestMessageId ?? state.oldestLoadedMessageId
            ..newestLoadedMessageId =
                page.newestMessageId ?? state.newestLoadedMessageId
            ..error = null;
          notifyListeners();
        } catch (_) {
          try {
            final initial = await _loadMessagesPage(
              sessionId,
              limit: initialMessageLimit,
            );
            state
              ..replaceMessages(initial.messages)
              ..hasMoreHistory = initial.hasMoreBefore
              ..oldestLoadedMessageId = initial.oldestMessageId
              ..newestLoadedMessageId = initial.newestMessageId
              ..error = null;
            notifyListeners();
          } catch (_) {}
        }
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

  core.Message? _mapEventMessage(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final message = domain.ChatMessage.fromBackend(raw);
    return _toCoreMessage(message);
  }

  Future<MessageLoadResult> _loadMessagesPage(
    String sessionId, {
    int? limit,
    String? beforeMessageId,
    String? afterMessageId,
  }) async {
    final page = await _client.loadMessages(
      sessionId,
      limit: limit,
      beforeMessageId: beforeMessageId,
      afterMessageId: afterMessageId,
    );
    final mappedMessages =
        page.messages.map(domain.ChatMessage.fromBackend).toList();
    final filteredOutMessages = mappedMessages
        .where((message) => !message.hasVisibleContent)
        .toList(growable: false);
    final messages =
        mappedMessages.where((message) => message.hasVisibleContent).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    _debugBackendLoad(
      sessionId,
      mappedMessages,
      filteredOutMessages,
      limit: limit,
      beforeMessageId: beforeMessageId,
      afterMessageId: afterMessageId,
      paging: page.paging,
    );

    final chatMessages = messages.map(_toCoreMessage).toList(growable: false);

    final paging = page.paging;
    return MessageLoadResult(
      messages: chatMessages,
      hasMoreBefore: paging['hasMoreBefore'] == true,
      oldestMessageId:
          (paging['oldestMessageId'] ??
                  (chatMessages.isNotEmpty ? chatMessages.first.id : null))
              ?.toString(),
      newestMessageId:
          (paging['newestMessageId'] ??
                  (chatMessages.isNotEmpty ? chatMessages.last.id : null))
              ?.toString(),
    );
  }

  void _debugBackendLoad(
    String sessionId,
    List<domain.ChatMessage> mappedMessages,
    List<domain.ChatMessage> filteredOutMessages, {
    int? limit,
    String? beforeMessageId,
    String? afterMessageId,
    Map<String, dynamic>? paging,
  }) {
    final assistantMessages = mappedMessages
        .where((message) => message.authorId == 'assistant')
        .toList(growable: false);
    final recentPreview = mappedMessages.reversed
        .take(5)
        .map((message) {
          final text = message.text;
          final preview = text.length > 60 ? text.substring(0, 60) : text;
          return {
            'id': message.id,
            'authorId': message.authorId,
            'textLength': text.length,
            'preview': preview,
          };
        })
        .toList(growable: false);
    final payload = {
      'tag': 'loadMessages.result',
      'ts': DateTime.now().toIso8601String(),
      'sessionId': sessionId,
      'rawCount': mappedMessages.length,
      'assistantCount': assistantMessages.length,
      'filteredEmptyCount': filteredOutMessages.length,
      'visibleCountBeforeLimit':
          mappedMessages.length - filteredOutMessages.length,
      'limit': limit,
      'beforeMessageId': beforeMessageId,
      'afterMessageId': afterMessageId,
      'paging': paging,
      'recentPreview': recentPreview,
      if (filteredOutMessages.isNotEmpty)
        'filteredPreview': filteredOutMessages
            .take(3)
            .map((message) {
              return {
                'id': message.id,
                'authorId': message.authorId,
                'textLength': message.text.length,
              };
            })
            .toList(growable: false),
    };
    debugPrint('[alicechat.front] ${jsonEncode(payload)}');
    unawaited(_client.sendClientDebugLog(payload));
  }

  String _resolveMediaUrl(String rawUrl) {
    final value = rawUrl.trim();
    if (value.isEmpty) return value;
    final lower = value.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return value;
    }

    String normalizedPath = value;
    if (!value.startsWith('/api/') &&
        !value.startsWith('/uploads/') &&
        _looksLikeLocalAbsolutePath(value)) {
      normalizedPath = '/api/media/file?path=${Uri.encodeComponent(value)}';
    }

    if (!normalizedPath.startsWith('/')) {
      return normalizedPath;
    }
    final baseUrl = _client.config.baseUrl.trim();
    if (baseUrl.isEmpty) {
      return normalizedPath;
    }
    final normalizedBase =
        baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl;
    return '$normalizedBase$normalizedPath';
  }

  bool _looksLikeLocalAbsolutePath(String value) {
    if (value.startsWith('/')) {
      return true;
    }
    return Platform.isWindows && RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
  }

  core.Message _toCoreMessage(domain.ChatMessage message) {
    final id = message.id.isEmpty ? _uuid.v4() : message.id;
    final firstAttachment =
        message.attachments.isNotEmpty ? message.attachments.first : null;
    if (firstAttachment != null &&
        firstAttachment.kind == 'image' &&
        firstAttachment.url.trim().isNotEmpty) {
      return core.ImageMessage(
        id: id,
        authorId: message.authorId,
        createdAt: message.createdAt,
        source: _resolveMediaUrl(firstAttachment.url),
        text: message.text.trim().isEmpty ? null : message.text,
        width: firstAttachment.width,
        height: firstAttachment.height,
        size: firstAttachment.size,
        metadata: {
          'attachments': message.attachments
              .map(
                (e) => {
                  'id': e.id,
                  'kind': e.kind,
                  'url': _resolveMediaUrl(e.url),
                  'rawUrl': e.url,
                  'mimeType': e.mimeType,
                  'name': e.name,
                },
              )
              .toList(growable: false),
        },
      );
    }
    return core.TextMessage(
      id: id,
      authorId: message.authorId,
      createdAt: message.createdAt,
      text: message.text,
      metadata:
          message.attachments.isEmpty
              ? null
              : {
                'attachments': message.attachments
                    .map(
                      (e) => {
                        'id': e.id,
                        'kind': e.kind,
                        'url': _resolveMediaUrl(e.url),
                        'rawUrl': e.url,
                        'mimeType': e.mimeType,
                        'name': e.name,
                      },
                    )
                    .toList(growable: false),
              },
    );
  }
}

class MessageLoadResult {
  const MessageLoadResult({
    required this.messages,
    required this.hasMoreBefore,
    this.oldestMessageId,
    this.newestMessageId,
  });

  final List<core.Message> messages;
  final bool hasMoreBefore;
  final String? oldestMessageId;
  final String? newestMessageId;
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
  bool isLoadingOlder = false;
  bool isRefreshingLatest = false;
  bool hasMoreHistory = true;
  int? assistantProgressSequence;
  String? assistantProgressMessageId;
  String? oldestLoadedMessageId;
  String? newestLoadedMessageId;
  List<core.Message> messages = const [];
  final Set<String> pendingClientMessageIds = <String>{};
  final Set<String> streamingMessageIds = <String>{};

  void replaceMessages(List<core.Message> nextMessages) {
    messages = List<core.Message>.unmodifiable(nextMessages);
    if (nextMessages.isNotEmpty) {
      oldestLoadedMessageId = nextMessages.first.id;
      newestLoadedMessageId = nextMessages.last.id;
    }
  }

  void appendMessage(core.Message message) {
    messages = List<core.Message>.unmodifiable([...messages, message]);
  }

  void upsertMessage(core.Message message) {
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
    messages = List<core.Message>.unmodifiable(list);
    trackMessageWindow(message.id);
  }

  void mergeMessages(List<core.Message> incoming) {
    if (incoming.isEmpty) return;
    final merged = [...messages];
    for (final message in incoming) {
      final index = merged.indexWhere((item) => item.id == message.id);
      if (index >= 0) {
        merged[index] = message;
      } else {
        merged.add(message);
      }
    }
    merged.sort(
      (a, b) => (a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
    );
    messages = List<core.Message>.unmodifiable(merged);
    if (messages.isNotEmpty) {
      oldestLoadedMessageId = messages.first.id;
      newestLoadedMessageId = messages.last.id;
    }
  }

  void replaceMessageId(String oldId, String newId) {
    final list = [...messages];
    final index = list.indexWhere((item) => item.id == oldId);
    if (index < 0) return;
    final old = list[index];
    if (old is core.TextMessage) {
      list[index] = core.TextMessage(
        id: newId,
        authorId: old.authorId,
        createdAt: old.createdAt,
        text: old.text,
        metadata: old.metadata,
      );
    } else if (old is core.ImageMessage) {
      list[index] = core.ImageMessage(
        id: newId,
        authorId: old.authorId,
        createdAt: old.createdAt,
        source: old.source,
        text: old.text,
        width: old.width,
        height: old.height,
        size: old.size,
        metadata: old.metadata,
      );
    }
    messages = List<core.Message>.unmodifiable(list);
  }

  void patchMessageText(String messageId, String nextText) {
    final list = [...messages];
    final index = list.indexWhere((item) => item.id == messageId);
    if (index < 0) return;
    final old = list[index];
    if (old is core.TextMessage) {
      list[index] = core.TextMessage(
        id: old.id,
        authorId: old.authorId,
        createdAt: old.createdAt,
        text: nextText,
        metadata: old.metadata,
      );
    } else if (old is core.ImageMessage) {
      list[index] = core.ImageMessage(
        id: old.id,
        authorId: old.authorId,
        createdAt: old.createdAt,
        source: old.source,
        text: nextText,
        width: old.width,
        height: old.height,
        size: old.size,
        metadata: old.metadata,
      );
    }
    messages = List<core.Message>.unmodifiable(list);
  }

  void upsertOrPatchAssistantMessage(String messageId, String text) {
    final list = [...messages];
    final index = list.indexWhere((item) => item.id == messageId);
    if (index >= 0) {
      final old = list[index];
      if (old is core.TextMessage) {
        list[index] = core.TextMessage(
          id: old.id,
          authorId: old.authorId,
          createdAt: old.createdAt,
          text: text,
          metadata: old.metadata,
        );
      }
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
    messages = List<core.Message>.unmodifiable(list);
  }

  void clearPending() {
    pendingClientMessageIds.clear();
  }

  void clearStreaming() {
    streamingMessageIds.clear();
  }

  void setAssistantProgress({
    required String messageId,
    required int sequence,
  }) {
    assistantProgressMessageId = messageId;
    assistantProgressSequence = sequence;
  }

  void clearAssistantProgress() {
    assistantProgressMessageId = null;
    assistantProgressSequence = null;
  }

  void trackMessageWindow(String? messageId) {
    final id = messageId?.trim();
    if (id == null || id.isEmpty) return;
    oldestLoadedMessageId ??= id;
    newestLoadedMessageId = id;
  }

  bool confirmPendingMessage(
    String clientMessageId,
    core.Message confirmedMessage,
  ) {
    final list = [...messages];
    final index = list.indexWhere((item) => item.id == clientMessageId);
    if (index < 0) return false;
    list[index] = confirmedMessage;
    list.sort(
      (a, b) => (a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
    );
    messages = List<core.Message>.unmodifiable(list);
    return true;
  }

  void markShouldStickToBottom() {
    stickToBottom = true;
  }
}
