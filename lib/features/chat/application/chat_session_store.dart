import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:uuid/uuid.dart';

import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../data/chat_cache_store.dart';
import '../domain/chat_message.dart' as domain;
import '../domain/chat_session.dart';

class _SessionMessageWindow {
  const _SessionMessageWindow({this.oldestMessageId, this.newestMessageId});

  final String? oldestMessageId;
  final String? newestMessageId;
}

class ChatSessionStore extends ChangeNotifier {
  ChatSessionStore({OpenClawHttpClient? client})
    : _client =
          client ??
          OpenClawHttpClient(
            const OpenClawConfig(
              baseUrl: '',
              modelId: 'alicechat-default',
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
  static const int maxMessagesAfterReconnect = 200;
  static const Duration sendPostReconcileDelay = Duration(seconds: 1);
  static const Duration replyStuckTimeout = Duration(seconds: 25);
  static const Duration eventReconnectBaseDelay = Duration(seconds: 1);
  static const Duration eventReconnectMaxDelay = Duration(seconds: 8);

  OpenClawHttpClient _client;
  late Future<void> _configReady;
  final Uuid _uuid = const Uuid();
  final ChatCacheStore _cacheStore = ChatCacheStore.instance;
  final Map<String, ChatViewState> _states = {};
  final Map<String, String> _sessionIdBySessionKey = {};
  final Map<String, StreamSubscription<Map<String, dynamic>>>
  _eventSubscriptions = {};
  final Map<String, Timer> _replyWatchdogs = {};
  final Map<String, String> _replyWatchdogSessions = {};
  final Map<String, Timer> _eventReconnectTimers = {};
  final Map<String, DateTime> _lastDebugLogAt = {};
  DateTime? _lastBackendLoadLogAt;

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

    await _hydrateStateFromCache(session, state);

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
      unawaited(_persistStateCache(session, state));
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

  Future<void> handleAppResumed() async {
    for (final state in _states.values) {
      final sessionId = (state.backendSessionId ?? '').trim();
      if (sessionId.isEmpty || !state.isReady) continue;
      await reconnectSession(state.session, force: true, reason: 'app_resumed');
    }
  }

  Future<void> reconnectSession(
    ChatSession session, {
    bool force = false,
    String reason = 'manual',
  }) async {
    final state = stateFor(session);
    final sessionId = (state.backendSessionId ?? '').trim();
    if (sessionId.isEmpty) return;
    if (!force && _eventSubscriptions.containsKey(sessionId)) {
      return;
    }
    _eventReconnectTimers.remove(sessionId)?.cancel();
    await _eventSubscriptions.remove(sessionId)?.cancel();
    state.isEventConnecting = true;
    _debugState(
      'events.reconnect.$reason',
      state,
      extra: {'sessionId': sessionId},
      force: true,
    );
    notifyListeners();
    unawaited(
      _reconcileSessionMessages(
        session,
        state,
        sessionId: sessionId,
        reason: 'reconnect_$reason',
      ),
    );
    _ensureEventSubscription(session, sessionId);
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
      ..requestPhase = ChatRequestPhase.posting
      ..appendMessage(userMessage)
      ..markShouldStickToBottom()
      ..pendingClientMessageIds.add(clientMessageId);
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
      final sendResult = await _client.sendMessage(
        sessionId: sessionId,
        text: trimmed,
        attachments: attachments,
        contactId: session.contactId,
        userId: sessionId,
        clientMessageId: clientMessageId,
      );
      final reconcileWindow = _snapshotMessageWindow(state);
      _confirmPostedMessage(
        state,
        clientMessageId: clientMessageId,
        persistedMessageId: sendResult.persistedUserMessageId,
      );
      _armReplyWatchdog(
        session,
        state,
        sessionId: sessionId,
        clientMessageId: clientMessageId,
      );
      unawaited(
        _reconcileSessionMessages(
          session,
          state,
          sessionId: sessionId,
          delay: sendPostReconcileDelay,
          reason: 'post_send',
          window: reconcileWindow,
        ),
      );
      _debugState(
        'sendMessage.posted',
        state,
        extra: {
          'clientMessageId': clientMessageId,
          'persistedUserMessageId': sendResult.persistedUserMessageId,
          'requestId': sendResult.requestId,
        },
      );
      notifyListeners();
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
          final sendResult = await _client.sendMessage(
            sessionId: sessionId,
            text: trimmed,
            attachments: attachments,
            contactId: session.contactId,
            userId: sessionId,
            clientMessageId: clientMessageId,
          );
          final reconcileWindow = _snapshotMessageWindow(state);
          _confirmPostedMessage(
            state,
            clientMessageId: clientMessageId,
            persistedMessageId: sendResult.persistedUserMessageId,
          );
          _armReplyWatchdog(
            session,
            state,
            sessionId: sessionId,
            clientMessageId: clientMessageId,
          );
          unawaited(
            _reconcileSessionMessages(
              session,
              state,
              sessionId: sessionId,
              delay: sendPostReconcileDelay,
              reason: 'post_send_retry',
              window: reconcileWindow,
            ),
          );
          _debugState(
            'sendMessage.posted.retry',
            state,
            extra: {
              'clientMessageId': clientMessageId,
              'sessionId': sessionId,
              'persistedUserMessageId': sendResult.persistedUserMessageId,
              'requestId': sendResult.requestId,
            },
            force: true,
          );
          notifyListeners();
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

  Future<void> deleteMessage(ChatSession session, String messageId) async {
    await _ensureConfigReady();
    final state = stateFor(session);
    final sessionId =
        state.backendSessionId ?? await _ensureBackendSession(session);
    state.backendSessionId = sessionId;

    final index = state.messages.indexWhere(
      (message) => message.id == messageId,
    );
    if (index < 0) return;
    final removedMessage = state.messages[index];
    final nextMessages = [...state.messages]..removeAt(index);
    state.messages = List<core.Message>.unmodifiable(nextMessages);
    if (state.messages.isNotEmpty) {
      state.oldestLoadedMessageId = state.messages.first.id;
      state.newestLoadedMessageId = state.messages.last.id;
    } else {
      state.oldestLoadedMessageId = null;
      state.newestLoadedMessageId = null;
    }
    state.pendingClientMessageIds.remove(messageId);
    state.postedClientMessageIds.remove(messageId);
    state.streamingMessageIds.remove(messageId);
    if (state.assistantProgressMessageId == messageId) {
      state.clearAssistantProgress();
    }
    state.recomputeRequestPhase();
    notifyListeners();
    unawaited(_persistStateCache(session, state));

    try {
      await _client.deleteMessage(sessionId: sessionId, messageId: messageId);
      _debugState(
        'message.delete.success',
        state,
        extra: {'messageId': messageId, 'sessionId': sessionId},
        force: true,
      );
    } catch (error) {
      state.messages = List<core.Message>.unmodifiable(
        [...state.messages, removedMessage]..sort((a, b) {
          final createdAtA =
              a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final createdAtB =
              b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final cmp = createdAtA.compareTo(createdAtB);
          if (cmp != 0) return cmp;
          return a.id.compareTo(b.id);
        }),
      );
      if (state.messages.isNotEmpty) {
        state.oldestLoadedMessageId = state.messages.first.id;
        state.newestLoadedMessageId = state.messages.last.id;
      }
      state.recomputeRequestPhase();
      state.appendMessage(
        core.TextMessage(
          id: _uuid.v4(),
          authorId: 'assistant',
          createdAt: DateTime.now(),
          text: '❌ 删除失败: ${_humanizeError(error)}',
        ),
      );
      _debugState(
        'message.delete.error',
        state,
        extra: {'messageId': messageId, 'error': error.toString()},
        force: true,
      );
      notifyListeners();
      unawaited(_persistStateCache(session, state));
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
      unawaited(_persistStateCache(session, state));
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
      MessageLoadResult page;
      int totalFetched = 0;
      String? currentAfterId = afterMessageId;
      bool hasMore = true;

      while (hasMore && totalFetched < maxMessagesAfterReconnect) {
        page = await _loadMessagesPage(
          sessionId,
          limit: latestRefreshPageSize,
          afterMessageId: currentAfterId,
        );
        if (page.messages.isEmpty) break;
        state.mergeMessages(page.messages);
        totalFetched += page.messages.length;
        currentAfterId = page.newestMessageId;
        hasMore =
            page.hasMoreAfter && page.messages.length >= latestRefreshPageSize;
      }

      if (state.messages.isNotEmpty) {
        state.oldestLoadedMessageId ??= state.messages.first.id;
        state.newestLoadedMessageId = state.messages.last.id;
      }
      state.error = null;
      unawaited(_persistStateCache(session, state));
      return totalFetched > 0;
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
    final desiredSessionId =
        (session.backendSessionId ?? '').trim().isNotEmpty
            ? (session.backendSessionId ?? '').trim()
            : session.id;
    final state = stateFor(session);
    final existing = state.backendSessionId;
    if (existing != null && existing.trim() == desiredSessionId) {
      return existing.trim();
    }

    final cacheKey = _keyFor(session);
    final cachedSessionId = _sessionIdBySessionKey[cacheKey];
    if (cachedSessionId != null && cachedSessionId.trim() == desiredSessionId) {
      state.backendSessionId = cachedSessionId;
      return cachedSessionId;
    }

    final sessionId = await _client.ensureSession(
      sessionId: desiredSessionId,
      preferredName: session.title,
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
              ..clearStreaming()
              ..clearAssistantProgress()
              ..isEventConnecting = false;
            state.recomputeRequestPhase();
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
              ..isEventConnecting = false;
            state.recomputeRequestPhase();
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
      case 'message.deleted':
        final messageId = (event['messageId'] ?? '').toString();
        if (messageId.isNotEmpty) {
          state.messages = List<core.Message>.unmodifiable(
            state.messages.where((message) => message.id != messageId),
          );
          if (state.oldestLoadedMessageId == messageId) {
            state.oldestLoadedMessageId =
                state.messages.isNotEmpty ? state.messages.first.id : null;
          }
          if (state.newestLoadedMessageId == messageId) {
            state.newestLoadedMessageId =
                state.messages.isNotEmpty ? state.messages.last.id : null;
          }
          state.pendingClientMessageIds.remove(messageId);
          state.postedClientMessageIds.remove(messageId);
          state.streamingMessageIds.remove(messageId);
          if (state.assistantProgressMessageId == messageId) {
            state.clearAssistantProgress();
          }
          state.recomputeRequestPhase();
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
        state.recomputeRequestPhase();
        state.requestPhase = ChatRequestPhase.replying;
        break;
      case 'assistant.progress':
        final messageId = (event['messageId'] ?? '').toString();
        final sequenceValue = event['sequence'];
        final sequence = sequenceValue is num ? sequenceValue.toInt() : 0;
        if (messageId.isNotEmpty && sequence > 0) {
          state.setAssistantProgress(
            messageId: messageId,
            sequence: sequence,
            text: (event['text'] ?? '').toString(),
            mode: (event['mode'] ?? '').toString(),
            origin: (event['origin'] ?? '').toString(),
            stage: (event['stage'] ?? '').toString(),
            kind: (event['kind'] ?? '').toString(),
            preview: (event['replyPreview'] ?? event['reply'] ?? '').toString(),
            eventStream: (event['eventStream'] ?? '').toString(),
            toolCallId: (event['toolCallId'] ?? '').toString(),
            toolName: (event['toolName'] ?? '').toString(),
            phase: (event['phase'] ?? '').toString(),
            status: (event['status'] ?? '').toString(),
            itemId: (event['itemId'] ?? '').toString(),
            approvalId: (event['approvalId'] ?? '').toString(),
            command: (event['command'] ?? '').toString(),
            output: (event['output'] ?? '').toString(),
            title: (event['title'] ?? '').toString(),
          );
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
        state.recomputeRequestPhase();
        state.requestPhase = ChatRequestPhase.replying;
        break;
      case 'assistant.message.completed':
        final message = _mapEventMessage(event['message']);
        if (message == null) return;
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        state.upsertMessage(message);
        state
          ..clearStreaming()
          ..clearAssistantProgress();
        state.postedClientMessageIds.remove(clientMessageId);
        state.trackMessageWindow(message.id);
        if (clientMessageId.isNotEmpty) {
          _clearPendingClientMessage(state, clientMessageId, notify: false);
        } else {
          _clearOldestPendingClientMessage(state);
        }
        state.recomputeRequestPhase();
        break;
      case 'assistant.message.failed':
        final error = (event['error'] ?? 'unknown error').toString();
        final clientMessageId = (event['clientMessageId'] ?? '').toString();
        state
          ..clearStreaming()
          ..clearAssistantProgress();
        state.postedClientMessageIds.remove(clientMessageId);
        state.appendMessage(
          core.TextMessage(
            id: _uuid.v4(),
            authorId: 'assistant',
            createdAt: DateTime.now(),
            text: '❌ 回复失败: $error',
          ),
        );
        if (clientMessageId.isNotEmpty) {
          _clearPendingClientMessage(state, clientMessageId, notify: false);
        } else {
          _clearOldestPendingClientMessage(state);
        }
        state.recomputeRequestPhase();
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
    final shouldPersist =
        type == 'message.created' ||
        type == 'assistant.message.completed' ||
        type == 'assistant.message.failed' ||
        type == 'message.status' ||
        type == 'message.deleted';
    if (shouldPersist) {
      unawaited(_persistStateCache(state.session, state));
    }
    notifyListeners();
  }

  void _confirmPostedMessage(
    ChatViewState state, {
    required String clientMessageId,
    required String persistedMessageId,
  }) {
    final nextMessageId = persistedMessageId.trim();
    if (nextMessageId.isNotEmpty) {
      state.replaceMessageId(clientMessageId, nextMessageId);
      state.trackMessageWindow(nextMessageId);
    }
    state.pendingClientMessageIds.remove(clientMessageId);
    state.postedClientMessageIds.add(clientMessageId);
    _replyWatchdogs.remove(clientMessageId)?.cancel();
    _replyWatchdogSessions.remove(clientMessageId);
    state.recomputeRequestPhase();
  }

  void _armReplyWatchdog(
    ChatSession session,
    ChatViewState state, {
    required String sessionId,
    required String clientMessageId,
  }) {
    _replyWatchdogs.remove(clientMessageId)?.cancel();
    _replyWatchdogSessions[clientMessageId] = sessionId;
    _replyWatchdogs[clientMessageId] = Timer(replyStuckTimeout, () {
      _replyWatchdogs.remove(clientMessageId)?.cancel();
      _replyWatchdogSessions.remove(clientMessageId);
      if (state.backendSessionId != sessionId) {
        return;
      }
      if (state.isAssistantStreaming) {
        return;
      }
      unawaited(
        _reconcileSessionMessages(
          session,
          state,
          sessionId: sessionId,
          reason: 'reply_watchdog',
          appendSlowNotice: true,
        ),
      );
    });
  }

  _SessionMessageWindow _snapshotMessageWindow(ChatViewState state) {
    return _SessionMessageWindow(
      oldestMessageId: state.oldestLoadedMessageId,
      newestMessageId: state.newestLoadedMessageId,
    );
  }

  Future<void> _reconcileSessionMessages(
    ChatSession session,
    ChatViewState state, {
    required String sessionId,
    Duration? delay,
    required String reason,
    bool appendSlowNotice = false,
    _SessionMessageWindow? window,
  }) async {
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
    if (state.backendSessionId != sessionId) {
      return;
    }
    final reconcileWindow = window ?? _snapshotMessageWindow(state);
    try {
      final page = await _loadMessagesPage(
        sessionId,
        limit: latestRefreshPageSize,
        afterMessageId: reconcileWindow.newestMessageId,
      );
      if (page.messages.isNotEmpty) {
        state.mergeMessages(page.messages);
      }
      if (state.isAssistantStreaming &&
          page.messages.any((message) => message.authorId == 'assistant')) {
        state
          ..clearStreaming()
          ..clearAssistantProgress();
        state.postedClientMessageIds.clear();
      }
      if (state.messages.isNotEmpty) {
        state.oldestLoadedMessageId ??= state.messages.first.id;
        state.newestLoadedMessageId = state.messages.last.id;
      }
      state.error = null;
      state.recomputeRequestPhase();
      _debugState(
        'reconcile.$reason',
        state,
        extra: {
          'sessionId': sessionId,
          'afterMessageId': reconcileWindow.newestMessageId,
          'fetchedCount': page.messages.length,
        },
        force: true,
      );
      notifyListeners();
      unawaited(_persistStateCache(session, state));
    } catch (error) {
      _debugState(
        'reconcile.$reason.error',
        state,
        extra: {'sessionId': sessionId, 'error': error.toString()},
        force: true,
      );
      if (appendSlowNotice) {
        final hasSlowNotice = state.messages.any(
          (message) =>
              message.authorId == 'assistant' &&
              message is core.TextMessage &&
              message.text == '⚠️ 消息已送达，助手回复可能因网络较慢稍后补上。',
        );
        if (!hasSlowNotice) {
          state.appendMessage(
            core.TextMessage(
              id: _uuid.v4(),
              authorId: 'assistant',
              createdAt: DateTime.now(),
              text: '⚠️ 消息已送达，助手回复可能因网络较慢稍后补上。',
            ),
          );
          notifyListeners();
        }
      }
    }
  }

  void _clearPendingClientMessage(
    ChatViewState state,
    String clientMessageId, {
    bool notify = false,
  }) {
    state.pendingClientMessageIds.remove(clientMessageId);
    state.postedClientMessageIds.remove(clientMessageId);
    _replyWatchdogs.remove(clientMessageId)?.cancel();
    _replyWatchdogSessions.remove(clientMessageId);
    state.recomputeRequestPhase();
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
      state.recomputeRequestPhase();
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
    _cancelWatchdogsForState(state);
    _sessionIdBySessionKey.remove(_keyFor(state.session));
    state
      ..backendSessionId = null
      ..isReady = false
      ..isEventConnecting = false
      ..lastEventSeq = null
      ..reconnectAttempts = 0
      ..clearPending()
      ..clearPosted()
      ..clearStreaming()
      ..requestPhase = ChatRequestPhase.idle;
  }

  void _cancelWatchdogsForState(ChatViewState state) {
    final backendSessionId = (state.backendSessionId ?? '').trim();
    final keys = _replyWatchdogSessions.entries
        .where((entry) => entry.value == backendSessionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final clientMessageId in keys) {
      _replyWatchdogs.remove(clientMessageId)?.cancel();
      _replyWatchdogSessions.remove(clientMessageId);
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

  Future<void> _hydrateStateFromCache(
    ChatSession session,
    ChatViewState state,
  ) async {
    final snapshot = await _cacheStore.loadSessionSnapshot(session);
    if (snapshot == null || snapshot.messages.isEmpty) {
      return;
    }
    state
      ..replaceMessages(snapshot.messages)
      ..backendSessionId = snapshot.backendSessionId ?? state.backendSessionId
      ..oldestLoadedMessageId =
          snapshot.oldestMessageId ?? state.oldestLoadedMessageId
      ..newestLoadedMessageId =
          snapshot.newestMessageId ?? state.newestLoadedMessageId
      ..lastEventSeq = snapshot.lastEventSeq ?? state.lastEventSeq
      ..hasMoreHistory = snapshot.hasMoreHistory ?? state.hasMoreHistory
      ..isReady = true;
    if (snapshot.backendSessionId != null &&
        snapshot.backendSessionId!.isNotEmpty) {
      _sessionIdBySessionKey[_keyFor(session)] = snapshot.backendSessionId!;
    }
    notifyListeners();
  }

  Future<void> _persistStateCache(
    ChatSession session,
    ChatViewState state,
  ) async {
    if (state.messages.isEmpty) return;
    await _cacheStore.saveSessionSnapshot(
      session: session,
      messages: state.stableMessagesForCache,
      backendSessionId: state.backendSessionId,
      oldestMessageId: state.oldestLoadedMessageId,
      newestMessageId: state.newestLoadedMessageId,
      lastEventSeq: state.lastEventSeq,
      hasMoreHistory: state.hasMoreHistory,
    );
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
          MessageLoadResult? page;
          int totalFetched = 0;
          String? currentAfterId = state.newestLoadedMessageId;
          bool hasMore = true;

          while (hasMore && totalFetched < maxMessagesAfterReconnect) {
            page = await _loadMessagesPage(
              sessionId,
              limit: latestRefreshPageSize,
              afterMessageId: currentAfterId,
            );
            if (page.messages.isEmpty) break;
            state.mergeMessages(page.messages);
            totalFetched += page.messages.length;
            currentAfterId = page.newestMessageId;
            hasMore =
                page.hasMoreAfter &&
                page.messages.length >= latestRefreshPageSize;
          }

          if (state.messages.isNotEmpty) {
            state.oldestLoadedMessageId ??= state.messages.first.id;
            state.newestLoadedMessageId = state.messages.last.id;
          }
          state.error = null;
          notifyListeners();
          unawaited(_persistStateCache(session, state));
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
            unawaited(_persistStateCache(session, state));
          } catch (_) {}
        }
        _ensureEventSubscription(session, sessionId);
        unawaited(
          _reconcileSessionMessages(
            session,
            state,
            sessionId: sessionId,
            reason: 'post_reconnect',
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    for (final subscription in _eventSubscriptions.values) {
      subscription.cancel();
    }
    for (final timer in _replyWatchdogs.values) {
      timer.cancel();
    }
    for (final timer in _eventReconnectTimers.values) {
      timer.cancel();
    }
    _eventSubscriptions.clear();
    _replyWatchdogs.clear();
    _replyWatchdogSessions.clear();
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
      hasMoreAfter: paging['hasMoreAfter'] == true,
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
    final now = DateTime.now();
    if (_lastBackendLoadLogAt == null ||
        now.difference(_lastBackendLoadLogAt!).inSeconds >= 5) {
      _lastBackendLoadLogAt = now;
      unawaited(_client.sendClientDebugLog(payload));
    }
  }

  String _resolveMediaUrl(String rawUrl) {
    final value = rawUrl.trim();
    if (value.isEmpty) return value;
    final lower = value.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return value;
    }
    final baseUrl = _client.config.baseUrl.trim();
    if (_looksLikeLocalAbsolutePath(value)) {
      if (baseUrl.isEmpty) {
        return value;
      }
      final normalizedBase =
          baseUrl.endsWith('/')
              ? baseUrl.substring(0, baseUrl.length - 1)
              : baseUrl;
      return '$normalizedBase/api/media/file?path=${Uri.encodeComponent(value)}';
    }
    if (!value.startsWith('/')) {
      return value;
    }
    if (baseUrl.isEmpty) {
      return value;
    }
    final normalizedBase =
        baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl;
    return '$normalizedBase$value';
  }

  bool _looksLikeLocalAbsolutePath(String value) {
    if (value.startsWith('/root/')) return true;
    if (value.startsWith('/Users/')) return true;
    if (value.startsWith('/home/')) return true;
    final windowsDrive = RegExp(r'^[a-zA-Z]:[\\/]');
    return windowsDrive.hasMatch(value);
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
    this.hasMoreAfter = false,
    this.oldestMessageId,
    this.newestMessageId,
  });

  final List<core.Message> messages;
  final bool hasMoreBefore;
  final bool hasMoreAfter;
  final String? oldestMessageId;
  final String? newestMessageId;
}

enum ChatRequestPhase { idle, posting, posted, replying }

class ChatViewState {
  ChatViewState({required this.session})
    : draftController = ValueNotifier<String>('');

  final ChatSession session;
  final ValueNotifier<String> draftController;

  String? backendSessionId;
  bool isLoading = false;
  bool isReady = false;
  ChatRequestPhase requestPhase = ChatRequestPhase.idle;
  bool get isSubmitting => requestPhase == ChatRequestPhase.posting;
  bool get isAssistantStreaming => requestPhase == ChatRequestPhase.replying;
  bool get isSending => requestPhase != ChatRequestPhase.idle;
  bool get hasPostedRequest =>
      requestPhase == ChatRequestPhase.posted ||
      requestPhase == ChatRequestPhase.replying;
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
  String? assistantProgressText;
  String? assistantProgressMode;
  String? assistantProgressOrigin;
  String? assistantProgressStage;
  String? assistantProgressKind;
  String? assistantPreviewText;
  String? assistantProgressEventStream;
  String? assistantProgressToolCallId;
  String? assistantProgressToolName;
  String? assistantProgressPhase;
  String? assistantProgressStatus;
  String? assistantProgressItemId;
  String? assistantProgressApprovalId;
  String? assistantProgressCommand;
  String? assistantProgressOutput;
  String? assistantProgressTitle;
  String? oldestLoadedMessageId;
  String? newestLoadedMessageId;
  List<core.Message> messages = const [];
  final Set<String> pendingClientMessageIds = <String>{};
  final Set<String> postedClientMessageIds = <String>{};
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
      list.sort((a, b) {
        final createdAtA =
            a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final createdAtB =
            b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final cmp = createdAtA.compareTo(createdAtB);
        if (cmp != 0) return cmp;
        return a.id.compareTo(b.id);
      });
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
    merged.sort((a, b) {
      final createdAtA = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final createdAtB = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final cmp = createdAtA.compareTo(createdAtB);
      if (cmp != 0) return cmp;
      return a.id.compareTo(b.id);
    });
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

  void clearPosted() {
    postedClientMessageIds.clear();
  }

  void clearStreaming() {
    streamingMessageIds.clear();
  }

  void recomputeRequestPhase() {
    if (pendingClientMessageIds.isNotEmpty) {
      requestPhase = ChatRequestPhase.posting;
      return;
    }
    if (streamingMessageIds.isNotEmpty) {
      requestPhase = ChatRequestPhase.replying;
      return;
    }
    if (postedClientMessageIds.isNotEmpty) {
      requestPhase = ChatRequestPhase.posted;
      return;
    }
    requestPhase = ChatRequestPhase.idle;
  }

  void setAssistantProgress({
    required String messageId,
    required int sequence,
    String? text,
    String? mode,
    String? origin,
    String? stage,
    String? kind,
    String? preview,
    String? eventStream,
    String? toolCallId,
    String? toolName,
    String? phase,
    String? status,
    String? itemId,
    String? approvalId,
    String? command,
    String? output,
    String? title,
  }) {
    assistantProgressMessageId = messageId;
    assistantProgressSequence = sequence;
    assistantProgressText = text;
    assistantProgressMode = mode;
    assistantProgressOrigin = origin;
    assistantProgressStage = stage;
    assistantProgressKind = kind;
    assistantPreviewText = preview;
    assistantProgressEventStream = eventStream;
    assistantProgressToolCallId = toolCallId;
    assistantProgressToolName = toolName;
    assistantProgressPhase = phase;
    assistantProgressStatus = status;
    assistantProgressItemId = itemId;
    assistantProgressApprovalId = approvalId;
    assistantProgressCommand = command;
    assistantProgressOutput = output;
    assistantProgressTitle = title;
  }

  void clearAssistantProgress() {
    assistantProgressMessageId = null;
    assistantProgressSequence = null;
    assistantProgressText = null;
    assistantProgressMode = null;
    assistantProgressOrigin = null;
    assistantProgressStage = null;
    assistantProgressKind = null;
    assistantPreviewText = null;
    assistantProgressEventStream = null;
    assistantProgressToolCallId = null;
    assistantProgressToolName = null;
    assistantProgressPhase = null;
    assistantProgressStatus = null;
    assistantProgressItemId = null;
    assistantProgressApprovalId = null;
    assistantProgressCommand = null;
    assistantProgressOutput = null;
    assistantProgressTitle = null;
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
    list.sort((a, b) {
      final createdAtA = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final createdAtB = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final cmp = createdAtA.compareTo(createdAtB);
      if (cmp != 0) return cmp;
      return a.id.compareTo(b.id);
    });
    messages = List<core.Message>.unmodifiable(list);
    return true;
  }

  List<core.Message> get stableMessagesForCache {
    return List<core.Message>.unmodifiable(
      messages.where((message) {
        if (pendingClientMessageIds.contains(message.id)) return false;
        if (streamingMessageIds.contains(message.id)) return false;
        if (message.id.startsWith('client_')) return false;
        return true;
      }),
    );
  }

  void markShouldStickToBottom() {
    stickToBottom = true;
  }
}
