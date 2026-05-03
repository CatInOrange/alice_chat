import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:image_picker/image_picker.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart'
    show Builders, TimeAndStatusPosition;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme.dart';
import '../../../core/debug/native_debug_bridge.dart';
import '../application/chat_session_store.dart';
import '../domain/chat_session.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.session, this.onBack});

  final ChatSession session;
  final VoidCallback? onBack;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

enum _PullEdgeState { idle, pulling, armed, loading }

class _StreamingHintResolution {
  const _StreamingHintResolution({
    required this.previewText,
    required this.statusText,
    required this.decorative,
    required this.signature,
  });

  final String previewText;
  final String statusText;
  final bool decorative;
  final String signature;
}

const _fallbackStreamingHints = <String>[
  '让我想想呀…',
  '脑袋转转中～',
  '我去翻翻代码喔',
  '我帮你扒拉一下线索',
  '我动手试一下哈',
  '我在缝缝补补中～',
];

class _QuotedMessageDraft {
  const _QuotedMessageDraft({
    required this.messageId,
    required this.authorName,
    required this.previewText,
    required this.rawText,
  });

  final String messageId;
  final String authorName;
  final String previewText;
  final String rawText;
}

class _PendingImageDraft {
  const _PendingImageDraft({
    required this.filePath,
    required this.fileName,
    required this.fileSize,
  });

  final String filePath;
  final String fileName;
  final int fileSize;
}

class _SlashSuggestionItem {
  const _SlashSuggestionItem({
    required this.insertText,
    required this.label,
    this.subtitle,
  });

  final String insertText;
  final String label;
  final String? subtitle;
}

class _SlashModelOption {
  const _SlashModelOption({
    required this.commandValue,
    required this.label,
    this.subtitle,
  });

  final String commandValue;
  final String label;
  final String? subtitle;
}

const _allowedSlashModels = <_SlashModelOption>[
  _SlashModelOption(
    commandValue: 'minimax/MiniMax-M2.7-highspeed',
    label: 'minimax/MiniMax-M2.7-highspeed',
    subtitle: 'default primary',
  ),
  _SlashModelOption(
    commandValue: 'google/gemini-2.5-flash',
    label: 'google/gemini-2.5-flash',
    subtitle: 'default fallback',
  ),
  _SlashModelOption(
    commandValue: 'deepseek-v4-flash',
    label: 'deepseek-v4-flash',
    subtitle: 'default fallback',
  ),
];

class _ChatScreenState extends State<ChatScreen> {
  final _currentUserId = 'user';
  final _composerController = TextEditingController();
  final _composerFocusNode = FocusNode();
  final _imagePicker = ImagePicker();
  final _chatListController = ScrollController();
  final _chatController = core.InMemoryChatController();
  Timer? _streamingHintPulseTimer;
  int _fallbackStreamingHintIndex = 0;

  static const double _pullTriggerDistance = 72;
  static const double _pullMaxVisualDistance = 108;
  static const double _edgeHintHeight = 52;
  static const double _edgeHintCardHeight = 64;

  double _lastSavedOffset = -1;
  bool _lastSavedStickToBottom = true;
  bool _showJumpToBottom = false;
  double _topPullDistance = 0;
  double _bottomPullDistance = 0;
  _PullEdgeState _topPullState = _PullEdgeState.idle;
  _PullEdgeState _bottomPullState = _PullEdgeState.idle;
  final List<String> _appliedMessageIds = [];
  DateTime? _lastBuildLogAt;
  String _lastMeaningfulStreamingStatus = '';
  String _lastStreamingHintSignature = '';
  bool _streamingHintPulseActive = false;
  _QuotedMessageDraft? _quotedMessageDraft;
  _PendingImageDraft? _pendingImageDraft;
  bool _isSendingImage = false;
  List<_SlashSuggestionItem> _slashSuggestions = const [];

  // Composer height tracking for relative positioning of floating elements
  static const double _composerPaddingVertical = 20.0; // 8 + 12
  static const double _composerRowHeight = 40.0;
  static const double _composerMinContentHeight =
      _composerPaddingVertical + _composerRowHeight; // 60
  static const double _composerMinHeight =
      _composerMinContentHeight; // 68 with SafeArea bottom padding
  double _composerHeight = _composerMinHeight;

  // Cache for MarkdownStyleSheet to avoid rebuilding on every message
  static final _markdownStyleSheetCache = <ThemeData, MarkdownStyleSheet>{};

  // Cache for parsed markdown widgets
  static final _markdownWidgetCache = <String, MarkdownBody>{};

  String get _assistantName => widget.session.title;

  String _assistantSubtitle(ChatViewState state) {
    if (!state.isAssistantStreaming) return widget.session.subtitle;
    return '正在输入中…';
  }

  Builders get _chatBuilders => Builders(
    textMessageBuilder: _buildTextMessage,
    imageMessageBuilder: _buildImageMessage,
    composerBuilder: _buildComposer,
    chatAnimatedListBuilder:
        (context, itemBuilder) => ChatAnimatedList(
          itemBuilder: itemBuilder,
          scrollController: _chatListController,
          reversed: true,
          initialScrollToEndMode: InitialScrollToEndMode.none,
          shouldScrollToEndWhenAtBottom: false,
          shouldScrollToEndWhenSendingMessage: false,
          bottomPadding: 110,
        ),
  );

  @override
  void initState() {
    super.initState();
    _chatListController.addListener(_handleScroll);
    _composerController.addListener(_handleComposerTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = context.read<ChatSessionStore>();
      store.addListener(_handleStoreChanged);
      _handleStoreChanged();
      store.ensureReady(widget.session);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<ChatSessionStore>().stateFor(widget.session);
    final now = DateTime.now();
    if (_lastBuildLogAt == null ||
        now.difference(_lastBuildLogAt!).inMilliseconds >= 500) {
      _lastBuildLogAt = now;
      debugPrint(
        '[alicechat.screen] ${jsonEncode({'tag': 'build', 'sessionId': state.backendSessionId, 'sessionLocalId': widget.session.id, 'isSubmitting': state.isSubmitting, 'isAssistantStreaming': state.isAssistantStreaming, 'pendingCount': state.pendingClientMessageIds.length, 'streamingCount': state.streamingMessageIds.length, 'messageCount': state.messages.length, 'lastEventSeq': state.lastEventSeq})}',
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          widget.onBack?.call();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
          ),
          toolbarHeight: 72,
          titleSpacing: 8,
          title: Row(
            children: [
              _buildHeaderAvatar(radius: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _assistantSubtitle(state),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            state.isAssistantStreaming
                                ? theme.colorScheme.primary
                                : const Color(0xFF98A1B3),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: const Color(0xFFE7EAF3)),
          ),
        ),
        body: DecoratedBox(
          decoration: const BoxDecoration(color: Color(0xFFF6F7FB)),
          child: _buildBody(state),
        ),
      ),
    );
  }

  Widget _buildBody(ChatViewState state) {
    if (state.isLoading && state.messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null && state.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0F1F2430),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                const SizedBox(height: 16),
                Text(
                  '连接失败',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.red[700],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  state.error!,
                  style: TextStyle(color: Colors.grey[600], height: 1.45),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () {
                    context.read<ChatSessionStore>().retry(widget.session);
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            _handleScrollNotification(notification, state);
            return false;
          },
          child: Chat(
            currentUserId: _currentUserId,
            resolveUser: _resolveUser,
            chatController: _chatController,
            onMessageSend: _handleSend,
            builders: _chatBuilders,
            backgroundColor: const Color(0xFFF6F7FB),
          ),
        ),
        if (_showJumpToBottom)
          Positioned(
            right: 16,
            bottom: state.isAssistantStreaming ? 178 : 130,
            child: SafeArea(
              top: false,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Material(
                  color: Colors.white,
                  shape: const CircleBorder(),
                  elevation: 6,
                  shadowColor: const Color(0x1A1F2430),
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    onPressed: _jumpToBottom,
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Color(0xFF667085),
                      size: 28,
                    ),
                    splashRadius: 22,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ),
              ),
            ),
          ),
        if (_topPullState != _PullEdgeState.idle || state.isLoadingOlder)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildEdgeHint(
              context,
              alignment: Alignment.topCenter,
              height: _effectiveTopHintHeight(state),
              label: _topHintLabel(state),
              loading: state.isLoadingOlder,
              dividerLabel: state.hasMoreHistory ? '再往上就是老记录了' : '已经翻到底了',
            ),
          ),
        if (_bottomPullState != _PullEdgeState.idle || state.isRefreshingLatest)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildEdgeHint(
              context,
              alignment: Alignment.bottomCenter,
              height: _effectiveBottomHintHeight(state),
              label: _bottomHintLabel(state),
              loading: state.isRefreshingLatest,
              dividerLabel: '我是有底线的',
            ),
          ),
        if (state.isAssistantStreaming)
          Positioned(
            left: 12,
            right: 12,
            bottom: 72,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x121F2430),
                        blurRadius: 18,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                    padding: EdgeInsets.symmetric(
                      horizontal: _streamingHintPulseActive ? 2 : 0,
                    ),
                    decoration: BoxDecoration(
                      color:
                          _streamingHintPulseActive
                              ? const Color(0xFFF4E9FF)
                              : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow:
                          _streamingHintPulseActive
                              ? const [
                                BoxShadow(
                                  color: Color(0x1A8B5CF6),
                                  blurRadius: 14,
                                  spreadRadius: 0.5,
                                ),
                              ]
                              : const [],
                    ),
                    child: Builder(
                      builder: (context) {
                        final resolved = _resolveStreamingHint(state);
                        final previewLine = resolved.previewText.trim();
                        final statusLine =
                            _displayStreamingStatus(state).trim();
                        final showPreview = previewLine.isNotEmpty;
                        final showStatus = statusLine.isNotEmpty;
                        return AnimatedScale(
                          scale: _streamingHintPulseActive ? 1.015 : 1,
                          duration: const Duration(milliseconds: 420),
                          curve: Curves.easeOutCubic,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildHeaderAvatar(radius: 12),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (showPreview)
                                      Text(
                                        previewLine,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall?.copyWith(
                                          color: const Color(0xFF111827),
                                          fontWeight: FontWeight.w600,
                                          height: 1.25,
                                        ),
                                      ),
                                    if (showPreview && showStatus)
                                      const SizedBox(height: 4),
                                    if (showStatus)
                                      Text(
                                        statusLine,
                                        maxLines: showPreview ? 1 : 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall?.copyWith(
                                          color:
                                              _streamingHintPulseActive
                                                  ? const Color(0xFF7C3AED)
                                                  : const Color(0xFF667085),
                                          fontWeight: FontWeight.w500,
                                          height: 1.2,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id == widget.session.id) return;

    _lastSavedOffset = -1;
    _lastSavedStickToBottom = true;
    _appliedMessageIds.clear();
    _chatController.setMessages(const []);
    _handleStoreChanged();
    context.read<ChatSessionStore>().ensureReady(widget.session);
  }

  void _handleStoreChanged() {
    if (!mounted) return;
    final state = context.read<ChatSessionStore>().stateFor(widget.session);
    final quotedId = _quotedMessageDraft?.messageId;
    if (quotedId != null &&
        !state.messages.any((message) => message.id == quotedId)) {
      _quotedMessageDraft = null;
    }
    debugPrint(
      '[alicechat.screen] ${jsonEncode({'tag': 'handleStoreChanged', 'sessionId': state.backendSessionId, 'sessionLocalId': widget.session.id, 'isSubmitting': state.isSubmitting, 'isAssistantStreaming': state.isAssistantStreaming, 'pendingCount': state.pendingClientMessageIds.length, 'streamingCount': state.streamingMessageIds.length, 'messageCount': state.messages.length, 'lastEventSeq': state.lastEventSeq, 'assistantProgressSequence': state.assistantProgressSequence})}',
    );
    _applyMessagesIncrementally(state.messages);
    _syncStreamingHintState(state);
    setState(() {});
  }

  void _applyMessagesIncrementally(List<core.Message> messages) {
    final existingMessages = _chatController.messages;

    if (existingMessages.isEmpty) {
      _chatController.setMessages(messages);
    } else {
      final existingIds = existingMessages.map((m) => m.id).toSet();
      final nextIds = messages.map((m) => m.id).toSet();

      // If the ID sets are identical and counts match, check for content changes
      if (existingIds.length == nextIds.length &&
          existingIds.containsAll(nextIds) &&
          existingIds.length == _appliedMessageIds.length &&
          _appliedMessageIds.toSet() == existingIds) {
        // IDs match exactly with what we last applied; check if any content changed
        final existingById = {for (final m in existingMessages) m.id: m};
        final hasContentChanges = messages.any((next) {
          final existing = existingById[next.id];
          return existing == null || existing != next;
        });
        if (!hasContentChanges) return;
      }

      // Simple approach: just replace the whole list
      _chatController.setMessages(messages, animated: false);
    }

    _appliedMessageIds
      ..clear()
      ..addAll(messages.map((message) => message.id));
  }

  void _handleScroll() {
    if (!_chatListController.hasClients) return;
    final offset = _chatListController.offset;
    final shouldShowJump = offset > 300;
    if (_showJumpToBottom != shouldShowJump && mounted) {
      setState(() => _showJumpToBottom = shouldShowJump);
    }
    final atBottom = offset <= 24;
    if ((_lastSavedOffset - offset).abs() < 24 &&
        _lastSavedStickToBottom == atBottom) {
      return;
    }
    _lastSavedOffset = offset;
    _lastSavedStickToBottom = atBottom;
    context.read<ChatSessionStore>().updateScrollState(
      widget.session,
      offset: offset,
      stickToBottom: atBottom,
    );
  }

  void _handleScrollNotification(
    ScrollNotification notification,
    ChatViewState state,
  ) {
    if (!_chatListController.hasClients) return;

    if (notification is OverscrollNotification) {
      final metrics = notification.metrics;
      final atBottom = metrics.pixels <= 24;
      final atTop = metrics.pixels >= metrics.maxScrollExtent - 24;
      var didChange = false;

      if (notification.overscroll < 0 &&
          atBottom &&
          !state.isRefreshingLatest) {
        final nextDistance = (_bottomPullDistance +
                (-notification.overscroll * 0.65))
            .clamp(0.0, _pullMaxVisualDistance);
        final nextState =
            nextDistance >= _pullTriggerDistance
                ? _PullEdgeState.armed
                : _PullEdgeState.pulling;
        if (nextDistance != _bottomPullDistance ||
            nextState != _bottomPullState) {
          _bottomPullDistance = nextDistance;
          _bottomPullState = nextState;
          didChange = true;
        }
      } else if (notification.overscroll > 0 &&
          atTop &&
          !state.isLoadingOlder) {
        final nextDistance = (_topPullDistance +
                (notification.overscroll * 0.65))
            .clamp(0.0, _pullMaxVisualDistance);
        final nextState =
            nextDistance >= _pullTriggerDistance
                ? _PullEdgeState.armed
                : _PullEdgeState.pulling;
        if (nextDistance != _topPullDistance || nextState != _topPullState) {
          _topPullDistance = nextDistance;
          _topPullState = nextState;
          didChange = true;
        }
      }

      if (didChange && mounted) {
        setState(() {});
      }
      return;
    }

    if (notification is ScrollUpdateNotification) {
      final metrics = notification.metrics;
      var didChange = false;
      if (metrics.pixels > 24 && _bottomPullState != _PullEdgeState.loading) {
        if (_bottomPullDistance != 0 ||
            _bottomPullState != _PullEdgeState.idle) {
          _bottomPullDistance = 0;
          _bottomPullState = _PullEdgeState.idle;
          didChange = true;
        }
      }
      if (metrics.pixels < metrics.maxScrollExtent - 24 &&
          _topPullState != _PullEdgeState.loading) {
        if (_topPullDistance != 0 || _topPullState != _PullEdgeState.idle) {
          _topPullDistance = 0;
          _topPullState = _PullEdgeState.idle;
          didChange = true;
        }
      }
      if (didChange && mounted) {
        setState(() {});
      }
      return;
    }

    if (notification is ScrollEndNotification) {
      if (_bottomPullState == _PullEdgeState.armed &&
          !state.isRefreshingLatest) {
        _bottomPullState = _PullEdgeState.loading;
        _bottomPullDistance = _edgeHintHeight;
        if (mounted) setState(() {});
        _triggerRefreshLatest();
        return;
      }
      if (_topPullState == _PullEdgeState.armed && !state.isLoadingOlder) {
        _topPullState = _PullEdgeState.loading;
        _topPullDistance = _edgeHintHeight;
        if (mounted) setState(() {});
        _triggerLoadOlder();
        return;
      }
      _resetPullHints();
    }
  }

  Future<void> _triggerLoadOlder() async {
    if (!_chatListController.hasClients) return;
    final store = context.read<ChatSessionStore>();
    final beforeExtent = _chatListController.position.maxScrollExtent;
    final loaded = await store.loadOlderMessages(widget.session);
    if (!mounted) return;
    if (loaded && _chatListController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_chatListController.hasClients) return;
        final afterExtent = _chatListController.position.maxScrollExtent;
        final delta = afterExtent - beforeExtent;
        if (delta.abs() > 0.5) {
          _chatListController.jumpTo(_chatListController.offset + delta);
        }
      });
    }
    _resetTopPullHint();
  }

  Future<void> _triggerRefreshLatest() async {
    await context.read<ChatSessionStore>().refreshLatestMessages(
      widget.session,
    );
    if (!mounted) return;
    _resetBottomPullHint();
  }

  void _resetTopPullHint() {
    if (_topPullDistance == 0 && _topPullState == _PullEdgeState.idle) return;
    setState(() {
      _topPullDistance = 0;
      _topPullState = _PullEdgeState.idle;
    });
  }

  void _resetBottomPullHint() {
    if (_bottomPullDistance == 0 && _bottomPullState == _PullEdgeState.idle) {
      return;
    }
    setState(() {
      _bottomPullDistance = 0;
      _bottomPullState = _PullEdgeState.idle;
    });
  }

  void _resetPullHints() {
    if (!mounted) return;
    if ((_topPullDistance == 0 || _topPullState == _PullEdgeState.loading) &&
        (_bottomPullDistance == 0 ||
            _bottomPullState == _PullEdgeState.loading)) {
      return;
    }
    setState(() {
      if (_topPullState != _PullEdgeState.loading) {
        _topPullDistance = 0;
        _topPullState = _PullEdgeState.idle;
      }
      if (_bottomPullState != _PullEdgeState.loading) {
        _bottomPullDistance = 0;
        _bottomPullState = _PullEdgeState.idle;
      }
    });
  }

  double _effectiveTopHintHeight(ChatViewState state) {
    if (state.isLoadingOlder) return _edgeHintHeight;
    return _topPullDistance.clamp(0.0, _pullMaxVisualDistance);
  }

  double _effectiveBottomHintHeight(ChatViewState state) {
    if (state.isRefreshingLatest) return _edgeHintHeight;
    return _bottomPullDistance.clamp(0.0, _pullMaxVisualDistance);
  }

  String _topHintLabel(ChatViewState state) {
    if (state.isLoadingOlder) return '正在翻更早的消息…';
    return switch (_topPullState) {
      _PullEdgeState.armed => '松手加载更早消息',
      _PullEdgeState.pulling => '上拉加载更早消息',
      _PullEdgeState.loading => '正在翻更早的消息…',
      _PullEdgeState.idle => '上拉加载更早消息',
    };
  }

  String _bottomHintLabel(ChatViewState state) {
    if (state.isRefreshingLatest) return '正在检查有没有漏掉的消息…';
    return switch (_bottomPullState) {
      _PullEdgeState.armed => '松手刷新',
      _PullEdgeState.pulling => '下拉检查漏消息',
      _PullEdgeState.loading => '正在检查有没有漏掉的消息…',
      _PullEdgeState.idle => '下拉检查漏消息',
    };
  }

  Widget _buildEdgeHint(
    BuildContext context, {
    required Alignment alignment,
    required double height,
    required String label,
    required bool loading,
    required String dividerLabel,
  }) {
    final visibleHeight = height.clamp(0.0, _pullMaxVisualDistance);
    final card = Container(
      height: _edgeHintCardHeight,
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x121F2430),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              loading
                  ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : Icon(
                    alignment == Alignment.topCenter
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: const Color(0xFF667085),
                  ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF667085),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Divider(color: Color(0xFFE7EAF3), height: 1),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  dividerLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF98A1B3),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Expanded(
                child: Divider(color: Color(0xFFE7EAF3), height: 1),
              ),
            ],
          ),
        ],
      ),
    );

    return IgnorePointer(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        height: visibleHeight,
        child: ClipRect(
          child: Align(
            alignment: alignment,
            child: SizedBox(
              height: _edgeHintCardHeight + 12,
              child: Opacity(
                opacity: (visibleHeight / _edgeHintHeight).clamp(0.0, 1.0),
                child: card,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _jumpToBottom() {
    if (!_chatListController.hasClients) return;
    _chatListController.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _handleSend(String text) async {
    final trimmed = text.trim();
    final pendingImage = _pendingImageDraft;
    if (trimmed.isEmpty && pendingImage == null) return;
    final store = context.read<ChatSessionStore>();
    final quoteDraft = _quotedMessageDraft;
    final payload =
        quoteDraft == null
            ? trimmed
            : '> ${quoteDraft.rawText.replaceAll(RegExp(r'\s+'), '\n> ')}\n\n$trimmed';
    _composerController.clear();
    setState(() {
      _quotedMessageDraft = null;
      if (pendingImage != null) {
        _pendingImageDraft = null;
        _isSendingImage = true;
      }
    });

    try {
      if (pendingImage != null) {
        await store.sendImageMessage(
          widget.session,
          filePath: pendingImage.filePath,
          caption: payload,
        );
      } else {
        await store.sendMessage(widget.session, payload);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (pendingImage != null) {
          _pendingImageDraft = pendingImage;
          _isSendingImage = false;
        }
      });
      _showSnackBar('发送图片失败：${_humanizeUiError(error)}');
      return;
    }

    if (!mounted) return;
    if (pendingImage != null) {
      setState(() => _isSendingImage = false);
    }
  }

  void _handleComposerTextChanged() {
    _refreshSlashSuggestions();
  }

  void _refreshSlashSuggestions() {
    final text = _composerController.text;
    if (!text.startsWith('/')) {
      if (_slashSuggestions.isNotEmpty && mounted) {
        setState(() => _slashSuggestions = const []);
      }
      return;
    }

    final next = _buildSlashSuggestions(text);
    if (!mounted) return;
    setState(() => _slashSuggestions = next);
  }

  List<_SlashSuggestionItem> _buildSlashSuggestions(String text) {
    if (!text.startsWith('/')) return const [];
    if (text == '/' || !text.contains(' ')) {
      final query = text.substring(1).trim().toLowerCase();
      return [
            const _SlashSuggestionItem(
              insertText: '/status ',
              label: '/status',
              subtitle: '查看当前会话状态',
            ),
            const _SlashSuggestionItem(
              insertText: '/reasoning ',
              label: '/reasoning',
              subtitle: '切换 reasoning 模式',
            ),
            const _SlashSuggestionItem(
              insertText: '/think ',
              label: '/think',
              subtitle: '调整思考强度',
            ),
            const _SlashSuggestionItem(
              insertText: '/model ',
              label: '/model',
              subtitle: '切换默认模型',
            ),
            const _SlashSuggestionItem(
              insertText: '/new',
              label: '/new',
              subtitle: '新建/重置会话',
            ),
            const _SlashSuggestionItem(
              insertText: '/reset',
              label: '/reset',
              subtitle: '重置当前会话',
            ),
            const _SlashSuggestionItem(
              insertText: '/help',
              label: '/help',
              subtitle: '查看帮助',
            ),
            const _SlashSuggestionItem(
              insertText: '/compact',
              label: '/compact',
              subtitle: '压缩上下文',
            ),
          ]
          .where((item) {
            return query.isEmpty || item.label.substring(1).contains(query);
          })
          .toList(growable: false);
    }

    if (text.startsWith('/reasoning ')) {
      final query = text.substring('/reasoning '.length).trim().toLowerCase();
      return ['on', 'off', 'stream']
          .where((item) => query.isEmpty || item.contains(query))
          .map(
            (item) => _SlashSuggestionItem(
              insertText: '/reasoning $item',
              label: item,
              subtitle: '/reasoning $item',
            ),
          )
          .toList(growable: false);
    }

    if (text.startsWith('/think ')) {
      final query = text.substring('/think '.length).trim().toLowerCase();
      return [
            'off',
            'minimal',
            'low',
            'medium',
            'high',
            'xhigh',
            'adaptive',
            'max',
          ]
          .where((item) => query.isEmpty || item.contains(query))
          .map(
            (item) => _SlashSuggestionItem(
              insertText: '/think $item',
              label: item,
              subtitle: '/think $item',
            ),
          )
          .toList(growable: false);
    }

    if (text.startsWith('/model ')) {
      final query = text.substring('/model '.length).trim().toLowerCase();
      return _allowedSlashModels
          .where((model) {
            return query.isEmpty ||
                model.commandValue.toLowerCase().contains(query) ||
                model.label.toLowerCase().contains(query) ||
                (model.subtitle?.toLowerCase().contains(query) ?? false);
          })
          .map(
            (model) => _SlashSuggestionItem(
              insertText: '/model ${model.commandValue}',
              label: model.label,
              subtitle: model.subtitle,
            ),
          )
          .toList(growable: false);
    }

    return const [];
  }

  Future<void> _applySlashSuggestion(_SlashSuggestionItem item) async {
    _composerController.value = TextEditingValue(
      text: item.insertText,
      selection: TextSelection.collapsed(offset: item.insertText.length),
    );
    if (mounted) {
      setState(
        () => _slashSuggestions = _buildSlashSuggestions(item.insertText),
      );
    }
    _composerFocusNode.requestFocus();
  }

  Widget _buildSlashSuggestionPanel(ThemeData theme) {
    if (_slashSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x121F2430),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ..._slashSuggestions
              .take(8)
              .map(
                (item) => ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    item.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle:
                      item.subtitle == null
                          ? null
                          : Text(
                            item.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                  onTap: () => _applySlashSuggestion(item),
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _handlePickImage() async {
    try {
      final file = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 92,
      );
      if (file == null || !mounted) return;
      final imageFile = File(file.path);
      final fileSize = await imageFile.length();
      const maxUploadBytes = 20 * 1024 * 1024;
      if (fileSize > maxUploadBytes) {
        _showSnackBar('图片不能超过 20MB');
        return;
      }
      setState(() {
        _pendingImageDraft = _PendingImageDraft(
          filePath: file.path,
          fileName: file.name,
          fileSize: fileSize,
        );
      });
      _composerFocusNode.requestFocus();
    } catch (error) {
      if (!mounted) return;
      _showSnackBar('选取图片失败：${_humanizeUiError(error)}');
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb >= 100 ? 0 : 1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB';
  }

  String _humanizeUiError(Object error) {
    final text = error.toString().trim();
    if (text.startsWith('Exception: ')) {
      return text.substring('Exception: '.length).trim();
    }
    return text.isEmpty ? '未知错误' : text;
  }

  void _showSnackBar(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1800),
        ),
      );
  }

  Future<void> _showAttachmentMenu(ChatViewState state) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: Text(
                    '图片',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: const Text('从相册选择一张图片发送'),
                  onTap: () => Navigator.of(sheetContext).pop('image'),
                ),
                ListTile(
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(
                    '文件',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: const Text('暂未支持，后端目前只能上传图片'),
                  enabled: false,
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) return;
    switch (action) {
      case 'image':
        await _handlePickImage();
        break;
    }
  }

  Future<core.User> _resolveUser(String id) async {
    switch (id) {
      case 'assistant':
        return core.User(
          id: 'assistant',
          name: _assistantName,
          imageSource:
              widget.session.avatarAssetPath ?? 'assets/avatars/alice.jpg',
        );
      case 'system':
        return core.User(id: 'system', name: 'System');
      default:
        return core.User(id: _currentUserId, name: 'You');
    }
  }

  Widget _buildTextMessage(
    BuildContext context,
    core.TextMessage message,
    int index, {
    bool? isSentByMe,
    core.MessageGroupStatus? groupStatus,
  }) {
    final sentByMe = isSentByMe ?? false;
    final showAvatar = !sentByMe && (groupStatus == null || groupStatus.isLast);
    final maxWidth = MediaQuery.of(context).size.width * 0.72;
    final bubbleRadius = BorderRadius.only(
      topLeft: const Radius.circular(20),
      topRight: const Radius.circular(20),
      bottomLeft: Radius.circular(sentByMe ? 20 : 8),
      bottomRight: Radius.circular(sentByMe ? 8 : 20),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        groupStatus?.isFirst == true || groupStatus == null ? 10 : 3,
        12,
        groupStatus?.isLast == true || groupStatus == null ? 10 : 3,
      ),
      child: Row(
        mainAxisAlignment:
            sentByMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!sentByMe)
            SizedBox(
              width: 34,
              child: Align(
                alignment: Alignment.bottomLeft,
                child:
                    showAvatar
                        ? _buildHeaderAvatar(radius: 15)
                        : const SizedBox.shrink(),
              ),
            ),
          if (!sentByMe) const SizedBox(width: 8),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Column(
                crossAxisAlignment:
                    sentByMe
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                children: [
                  sentByMe
                      ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onLongPress:
                            () => _showMessageActionSheet(
                              context,
                              message: message,
                              sentByMe: sentByMe,
                            ),
                        child: SimpleTextMessage(
                          message: message,
                          index: index,
                          showStatus: false,
                          timeAndStatusPosition: TimeAndStatusPosition.end,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 11,
                          ),
                          constraints: BoxConstraints(maxWidth: maxWidth),
                          borderRadius: bubbleRadius,
                          sentBackgroundColor: const Color(0xFF7C4DFF),
                          receivedBackgroundColor: Colors.white,
                          sentTextStyle: Theme.of(
                            context,
                          ).textTheme.bodyLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                          receivedTextStyle: Theme.of(
                            context,
                          ).textTheme.bodyLarge?.copyWith(
                            color: const Color(0xFF1F2430),
                            fontWeight: FontWeight.w500,
                          ),
                          timeStyle: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(
                            color:
                                sentByMe
                                    ? Colors.white.withValues(alpha: 0.72)
                                    : const Color(0xFF98A1B3),
                            fontSize: 11,
                          ),
                          topWidget: null,
                        ),
                      )
                      : _buildAssistantMarkdownBubble(
                        context,
                        message: message,
                        index: index,
                        maxWidth: maxWidth,
                        bubbleRadius: bubbleRadius,
                      ),
                ],
              ),
            ),
          ),
          if (sentByMe) const SizedBox(width: 8),
          if (sentByMe && (groupStatus == null || groupStatus.isLast))
            _buildUserAvatar(radius: 15),
        ],
      ),
    );
  }

  Widget _buildAssistantMarkdownBubble(
    BuildContext context, {
    required core.TextMessage message,
    required int index,
    required double maxWidth,
    required BorderRadius bubbleRadius,
  }) {
    final theme = Theme.of(context);
    final markdownTheme = _getMarkdownStyleSheet(theme);

    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress:
            () => _showMessageActionSheet(
              context,
              message: message,
              sentByMe: false,
            ),
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: bubbleRadius,
            boxShadow: const [
              BoxShadow(
                color: Color(0x081F2430),
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildMarkdownBody(
                  _stripModelNamePrefix(message.text),
                  markdownTheme,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Text(
                      _assistantName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF98A1B3),
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                    if (_extractModelName(message.text) != null) ...[
                      Text(
                        " · ",
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF98A1B3),
                          fontSize: 11,
                        ),
                      ),
                      _buildModelNameText(message.text),
                    ],
                    Text(
                      " | ",
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF98A1B3),
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      _formatMessageTime(message.createdAt ?? DateTime.now()),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF98A1B3),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  MarkdownStyleSheet _buildMarkdownStyleSheet(ThemeData theme) {
    final monoFontFamily =
        theme.extension<AliceChatFontScheme>()?.monospaceFontFamily ??
        'monospace';
    final bodyStyle =
        theme.textTheme.bodyLarge?.copyWith(
          color: const Color(0xFF1F2430),
          fontWeight: FontWeight.w500,
          height: 1.28,
        ) ??
        const TextStyle(
          color: Color(0xFF1F2430),
          fontSize: 16,
          fontWeight: FontWeight.w500,
          height: 1.28,
        );

    final mono =
        theme.textTheme.bodyMedium?.copyWith(
          fontFamily: monoFontFamily,
          color: const Color(0xFF2B2F3A),
          height: 1.25,
        ) ??
        TextStyle(
          fontFamily: monoFontFamily,
          color: const Color(0xFF2B2F3A),
          fontSize: 14,
          height: 1.25,
        );

    return MarkdownStyleSheet(
      p: bodyStyle,
      h1: bodyStyle.copyWith(fontSize: 18, fontWeight: FontWeight.w800),
      h2: bodyStyle.copyWith(fontSize: 16, fontWeight: FontWeight.w800),
      h3: bodyStyle.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
      h1Padding: const EdgeInsets.only(bottom: 4),
      h2Padding: const EdgeInsets.only(top: 1, bottom: 3),
      h3Padding: const EdgeInsets.only(top: 1, bottom: 2),
      strong: bodyStyle.copyWith(fontWeight: FontWeight.w800),
      em: bodyStyle.copyWith(fontStyle: FontStyle.italic),
      listBullet: bodyStyle.copyWith(color: const Color(0xFF667085)),
      blockquote: bodyStyle.copyWith(
        color: const Color(0xFF5B657A),
        height: 1.25,
      ),
      blockSpacing: 4,
      listIndent: 16,
      unorderedListAlign: WrapAlignment.start,
      orderedListAlign: WrapAlignment.start,
      code: mono.copyWith(
        backgroundColor: const Color(0xFFF1EEFF),
        fontSize: 13.5,
      ),
      codeblockDecoration: BoxDecoration(
        color: const Color(0xFFF7F8FC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE6E9F2)),
      ),
      codeblockPadding: const EdgeInsets.all(8),
      a: bodyStyle.copyWith(
        color: const Color(0xFF6D4AFF),
        decoration: TextDecoration.underline,
        fontWeight: FontWeight.w700,
      ),
      horizontalRuleDecoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFE7EAF3), width: 1)),
      ),
    );
  }

  MarkdownStyleSheet _getMarkdownStyleSheet(ThemeData theme) {
    return _markdownStyleSheetCache.putIfAbsent(
      theme,
      () => _buildMarkdownStyleSheet(theme),
    );
  }

  MarkdownBody _buildMarkdownBody(String text, MarkdownStyleSheet styleSheet) {
    return _markdownWidgetCache.putIfAbsent(
      text,
      () => MarkdownBody(
        data: text,
        selectable: false, // Disabled for performance
        styleSheet: styleSheet,
        softLineBreak: true,
        builders: {
          'code': _InlineCodeBuilder(styleSheet),
          'pre': _CodeBlockBuilder(styleSheet),
          'blockquote': _BlockquoteBuilder(styleSheet),
        },
        onTapLink: (text, href, title) {
          _openMarkdownLink(href);
        },
      ),
    );
  }

  Future<void> _showMessageActionSheet(
    BuildContext context, {
    required core.Message message,
    required bool sentByMe,
  }) async {
    final plainText = _extractPlainMessageText(message);

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF6F7FB),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    _oneLinePreview(plainText, maxWidth: 48),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF667085),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _buildMessageActionButton(
                        context: sheetContext,
                        icon: Icons.copy_rounded,
                        label: '复制',
                        enabled: plainText.isNotEmpty,
                        onTap:
                            plainText.isNotEmpty
                                ? () => Navigator.of(sheetContext).pop('copy')
                                : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildMessageActionButton(
                        context: sheetContext,
                        icon: Icons.format_quote_rounded,
                        label: '引用',
                        onTap: () => Navigator.of(sheetContext).pop('quote'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildMessageActionButton(
                        context: sheetContext,
                        icon: Icons.delete_outline_rounded,
                        label: '删除',
                        destructive: true,
                        enabled: true,
                        onTap: () => Navigator.of(sheetContext).pop('delete'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    switch (action) {
      case 'copy':
        if (plainText.isEmpty) return;
        await Clipboard.setData(ClipboardData(text: plainText));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已复制'),
            duration: Duration(milliseconds: 1200),
          ),
        );
        return;
      case 'quote':
        if (plainText.isEmpty) return;
        setState(() {
          _quotedMessageDraft = _QuotedMessageDraft(
            messageId: message.id,
            authorName: sentByMe ? '你' : _assistantName,
            previewText: _oneLinePreview(plainText, maxWidth: 42),
            rawText: plainText,
          );
        });
        if (!_composerController.selection.isValid) {
          _composerController.selection = TextSelection.collapsed(
            offset: _composerController.text.length,
          );
        }
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(this.context)?.showSnackBar(
          const SnackBar(
            content: Text('已添加引用'),
            duration: Duration(milliseconds: 900),
          ),
        );
        return;
      case 'delete':
        _confirmDeleteMessage(message);
        return;
      default:
        return;
    }
  }

  Future<void> _confirmDeleteMessage(core.Message message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('删除这条消息？'),
            content: const Text('删除后会从当前会话中彻底移除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    if (_quotedMessageDraft?.messageId == message.id) {
      setState(() => _quotedMessageDraft = null);
    }
    await context.read<ChatSessionStore>().deleteMessage(
      widget.session,
      message.id,
    );
  }

  String _extractPlainMessageText(core.Message message) {
    if (message is core.TextMessage) {
      return _stripModelNamePrefix(message.text).trim();
    }
    if (message is core.ImageMessage) {
      return (message.text ?? '').trim();
    }
    return '';
  }

  Widget _buildMessageActionButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool destructive = false,
    bool enabled = true,
  }) {
    final color =
        !enabled
            ? const Color(0xFF98A1B3)
            : destructive
            ? const Color(0xFFE5484D)
            : const Color(0xFF5B5BD6);
    return Material(
      color: const Color(0xFFF8F7FF),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openMarkdownLink(String? href) async {
    if (href == null || href.isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String _formatMessageTime(DateTime dateTime) {
    final month = dateTime.month;
    final day = dateTime.day;
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$month月$day日 $hour:$minute';
  }

  String _stripModelNamePrefix(String text) {
    final trimmedLeft = text.trimLeft();
    if (!trimmedLeft.startsWith('[')) return text;
    final bracketEnd = trimmedLeft.indexOf(']');
    if (bracketEnd <= 1) return text;
    return trimmedLeft.substring(bracketEnd + 1).trimLeft();
  }

  String? _extractModelName(String text) {
    final trimmedLeft = text.trimLeft();
    if (!trimmedLeft.startsWith('[')) return null;
    final bracketEnd = trimmedLeft.indexOf(']');
    if (bracketEnd <= 1) return null;
    final modelName = trimmedLeft.substring(1, bracketEnd).trim();
    return modelName.isEmpty ? null : modelName;
  }

  String _formatModelNameForDisplay(String modelName) {
    const maxLength = 18;
    if (modelName.length <= maxLength) return modelName;
    final lastDash = modelName.lastIndexOf('-');
    if (lastDash > 0) {
      final shortened = modelName.substring(0, lastDash).trim();
      if (shortened.isNotEmpty) return shortened;
    }
    return modelName;
  }

  Widget _buildModelNameText(String text) {
    final modelName = _extractModelName(text);
    if (modelName == null) return const SizedBox.shrink();
    final displayModelName = _formatModelNameForDisplay(modelName);
    return Text(
      displayModelName,
      style: const TextStyle(color: Color(0xFF98A1B3), fontSize: 11),
    );
  }

  _StreamingHintResolution _resolveStreamingHint(ChatViewState state) {
    final mode = (state.assistantProgressMode ?? '').trim();
    final origin = (state.assistantProgressOrigin ?? '').trim();
    final progressText = (state.assistantProgressText ?? '').trim();
    final previewText =
        (state.assistantReplyPreviewText ?? state.assistantPreviewText ?? '')
            .trim();
    final progressKind = (state.assistantProgressKind ?? '').trim();
    final progressStage = (state.assistantProgressStage ?? '').trim();
    final progressToolName = (state.assistantProgressToolName ?? '').trim();
    final progressToolCallId = (state.assistantProgressToolCallId ?? '').trim();
    final progressPhase = (state.assistantProgressPhase ?? '').trim();
    final progressStatus = (state.assistantProgressStatus ?? '').trim();
    final progressTitle = (state.assistantProgressTitle ?? '').trim();
    final progressCommand = (state.assistantProgressCommand ?? '').trim();
    final progressApprovalSlug =
        (state.assistantProgressApprovalSlug ?? '').trim();
    final progressSource = (state.assistantProgressSource ?? '').trim();

    final resolvedPreview =
        previewText.isNotEmpty
            ? _oneLinePreview(previewText)
            : (origin == 'llm_text' || mode == 'preview')
            ? _oneLinePreview(progressText)
            : '';

    String resolvedStatus = '';
    if (mode == 'thinking' && progressText.isNotEmpty) {
      resolvedStatus = _oneLinePreview('我在想：$progressText');
    } else if (mode == 'plan' && progressText.isNotEmpty) {
      resolvedStatus = _oneLinePreview('我在列步骤：$progressText');
    } else if (progressText.isNotEmpty) {
      final normalized = _humanizeProgressText(
        text: progressText,
        kind: progressKind,
        stage: progressStage,
        toolName: progressToolName,
        toolCallId: progressToolCallId,
        phase: progressPhase,
        status: progressStatus,
        title: progressTitle,
        command: progressCommand,
        approvalSlug: progressApprovalSlug,
        source: progressSource,
      );
      resolvedStatus = _oneLinePreview(normalized);
    } else if (progressToolName.isNotEmpty ||
        progressToolCallId.isNotEmpty ||
        progressApprovalSlug.isNotEmpty ||
        progressSource.isNotEmpty ||
        progressKind == 'plan' ||
        progressStage == 'approval') {
      final normalized = _humanizeProgressText(
        text: '',
        kind: progressKind,
        stage: progressStage,
        toolName: progressToolName,
        toolCallId: progressToolCallId,
        phase: progressPhase,
        status: progressStatus,
        title: progressTitle,
        command: progressCommand,
        approvalSlug: progressApprovalSlug,
        source: progressSource,
      );
      resolvedStatus = _oneLinePreview(normalized);
    } else {
      final sequence = state.assistantProgressSequence;
      if (sequence != null) {
        resolvedStatus = _buildProgressLabel(
          sequence,
          kind: progressKind,
          stage: progressStage,
        );
      }
    }

    final decorative = _isDecorativeStreamingHint(resolvedStatus);
    final signature = [
      mode,
      origin,
      progressKind,
      progressStage,
      progressToolName,
      progressToolCallId,
      progressPhase,
      progressStatus,
      progressTitle,
      progressCommand,
      progressApprovalSlug,
      progressSource,
      progressText,
      previewText,
      state.assistantProgressSequence?.toString() ?? '',
    ].join('|');
    return _StreamingHintResolution(
      previewText: resolvedPreview,
      statusText: decorative ? '' : resolvedStatus,
      decorative: decorative,
      signature: signature,
    );
  }

  String _displayStreamingStatus(ChatViewState state) {
    final resolved = _resolveStreamingHint(state);
    if (resolved.statusText.isNotEmpty) return resolved.statusText;
    if (_lastMeaningfulStreamingStatus.isNotEmpty) {
      return _lastMeaningfulStreamingStatus;
    }
    return _fallbackStreamingHintFor(state);
  }

  String _fallbackStreamingHintFor(ChatViewState state) {
    final seedSource = [
      widget.session.id,
      state.assistantProgressToolCallId ?? '',
      state.assistantProgressMessageId ?? '',
      state.assistantProgressSequence?.toString() ?? '',
    ].join('|');
    final seed = seedSource.hashCode;
    final rawIndex =
        (seed + _fallbackStreamingHintIndex) % _fallbackStreamingHints.length;
    final index =
        rawIndex < 0 ? rawIndex + _fallbackStreamingHints.length : rawIndex;
    return _fallbackStreamingHints[index];
  }

  void _syncStreamingHintState(ChatViewState state) {
    if (!state.isAssistantStreaming) {
      _lastMeaningfulStreamingStatus = '';
      _lastStreamingHintSignature = '';
      _streamingHintPulseActive = false;
      _streamingHintPulseTimer?.cancel();
      _fallbackStreamingHintIndex =
          (_fallbackStreamingHintIndex + 1) % _fallbackStreamingHints.length;
      return;
    }

    final resolved = _resolveStreamingHint(state);
    if (resolved.statusText.isNotEmpty) {
      _lastMeaningfulStreamingStatus = resolved.statusText;
      _lastStreamingHintSignature = resolved.signature;
      return;
    }

    if (resolved.decorative &&
        resolved.signature != _lastStreamingHintSignature) {
      _lastStreamingHintSignature = resolved.signature;
      _triggerStreamingHintPulse();
    }
  }

  void _triggerStreamingHintPulse() {
    _streamingHintPulseTimer?.cancel();
    _streamingHintPulseActive = true;
    _streamingHintPulseTimer = Timer(const Duration(milliseconds: 520), () {
      if (!mounted) return;
      setState(() {
        _streamingHintPulseActive = false;
      });
    });
  }

  bool _isDecorativeStreamingHint(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return true;
    const decorativeHints = <String>{
      '让我想想呀…',
      '脑袋转转中～',
      '我去翻翻代码喔',
      '让我瞅瞅这里写了啥',
      '我帮你扒拉一下线索',
      '我去找找看呀',
      '我动手试一下哈',
      '我在悄悄跑命令呢',
      '这个要你点个头呀',
      '这步我得先乖乖等你',
      '我在缝缝补补中～',
      '改一改，很快好呀',
      '我在偷偷排计划呢',
      '先理一理思路呀',
    };
    return decorativeHints.contains(normalized);
  }

  String _buildProgressLabel(
    int sequence, {
    String kind = '',
    String stage = '',
  }) {
    switch (kind) {
      case 'search':
        return const ['我帮你扒拉一下线索', '我去找找看呀', '线索快拢好了'][(sequence - 1).clamp(
          0,
          2,
        )];
      case 'read':
        return const ['我去翻翻代码喔', '让我瞅瞅这里写了啥', '这段我快看明白啦'][(sequence - 1).clamp(
          0,
          2,
        )];
      case 'exec':
        return const ['我动手试一下哈', '我在悄悄跑命令呢', '结果应该快出来啦'][(sequence - 1).clamp(
          0,
          2,
        )];
      case 'thinking':
        return const ['让我想想呀…', '脑袋转转中～', '思路快理顺啦'][(sequence - 1).clamp(0, 2)];
      case 'plan':
        return const ['我在偷偷排计划呢', '先理一理思路呀', '步骤差不多顺好啦'][(sequence - 1).clamp(
          0,
          2,
        )];
      default:
        const texts = [
          '让我想想呀…',
          '我去翻翻代码喔',
          '我帮你扒拉一下线索',
          '我动手试一下哈',
          '脑袋转转中～',
          '我在缝缝补补中～',
          '改一改，很快好呀',
        ];
        if (sequence >= 1 && sequence <= texts.length) {
          return texts[sequence - 1];
        }
        if (stage == 'tool') return '我还在替你忙活呢';
        return '再等我一下下，马上贴过来';
    }
  }

  String _humanizeProgressText({
    required String text,
    String kind = '',
    String stage = '',
    String toolName = '',
    String toolCallId = '',
    String phase = '',
    String status = '',
    String title = '',
    String command = '',
    String approvalSlug = '',
    String source = '',
  }) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final phaseLabel =
        phase.isNotEmpty
            ? '（$phase${status.isNotEmpty ? ' / $status' : ''}）'
            : (status.isNotEmpty ? '（$status）' : '');
    final toolLabel =
        toolName.isNotEmpty ? toolName : (title.isNotEmpty ? title : 'tool');
    final callSuffix =
        toolCallId.isNotEmpty
            ? ' #${toolCallId.length > 8 ? toolCallId.substring(0, 8) : toolCallId}'
            : '';
    final commandLabel = command.isNotEmpty ? ' $command' : '';
    final approvalLabel = approvalSlug.isNotEmpty ? '（等待$approvalSlug）' : '';
    final sourceLabel = source.isNotEmpty ? '（$source）' : '';

    if (cleaned.isEmpty) {
      if (toolName.isNotEmpty || toolCallId.isNotEmpty) {
        return '我在忙 $toolLabel$callSuffix$phaseLabel$commandLabel$approvalLabel';
      }
      if (kind == 'plan' && sourceLabel.isNotEmpty) {
        return '我在排执行步骤$sourceLabel';
      }
      if (approvalLabel.isNotEmpty) {
        return '这步我得先等你确认$approvalLabel';
      }
      return _buildProgressLabel(1, kind: kind, stage: stage);
    }

    switch (kind) {
      case 'search':
        return toolLabel != 'tool'
            ? '我在用 $toolLabel$callSuffix 帮你找：$cleaned$phaseLabel'
            : '我在帮你找线索：$cleaned';
      case 'read':
        return toolLabel != 'tool'
            ? '我在用 $toolLabel$callSuffix 翻内容：$cleaned$phaseLabel'
            : '我在翻内容给你看：$cleaned';
      case 'exec':
        return toolLabel != 'tool'
            ? '我在跑 $toolLabel$callSuffix：$cleaned$phaseLabel'
            : '我在动手试这个：$cleaned';
      case 'tool':
        return '我在用 $toolLabel$callSuffix 忙这个：$cleaned$phaseLabel$approvalLabel';
      case 'thinking':
        return '我在想这个怎么最稳：$cleaned';
      case 'plan':
        return '我在排执行步骤${sourceLabel.isNotEmpty ? sourceLabel : ''}：$cleaned';
      default:
        return cleaned;
    }
  }

  String _oneLinePreview(String text, {int maxWidth = 33}) {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.isEmpty) return '';
    int totalWidth = 0;
    int lastFitIndex = 0;
    for (int i = 0; i < collapsed.length; i++) {
      final char = collapsed[i];
      final codeUnit = char.codeUnitAt(0);
      // Full-width (Chinese, Japanese, Korean, full-width punctuation) or emoji
      final charWidth =
          (codeUnit >= 0x1100 &&
                  (codeUnit <= 0x115F || // Hangul Jamo
                      codeUnit >= 0x2329 || // Left-pointing angle bracket
                      codeUnit >= 0x2E80 || // CJK radicals
                      (codeUnit >= 0x3000 &&
                          codeUnit <= 0x303F) || // CJK punctuation
                      (codeUnit >= 0x3040 && codeUnit <= 0x309F) || // Hiragana
                      (codeUnit >= 0x30A0 && codeUnit <= 0x30FF) || // Katakana
                      (codeUnit >= 0x3100 && codeUnit <= 0x312F) || // Bopomofo
                      (codeUnit >= 0x3130 &&
                          codeUnit <= 0x318F) || // Hangul compat
                      (codeUnit >= 0x3190 && codeUnit <= 0x319F) || // Kanbun
                      (codeUnit >= 0x31A0 &&
                          codeUnit <= 0x31BF) || // Bopomofo ext
                      (codeUnit >= 0x31C0 &&
                          codeUnit <= 0x31EF) || // CJK strokes
                      (codeUnit >= 0x31F0 &&
                          codeUnit <= 0x31FF) || // Katakana ext
                      (codeUnit >= 0x3200 &&
                          codeUnit <= 0x32FF) || // Enclosed CJK
                      (codeUnit >= 0x3300 &&
                          codeUnit <= 0x33FF) || // CJK compat
                      (codeUnit >= 0x3400 && codeUnit <= 0x4DBF) || // CJK ext A
                      (codeUnit >= 0x4E00 &&
                          codeUnit <= 0x9FFF) || // CJK Unified Ideographs
                      (codeUnit >= 0xA000 && codeUnit <= 0xA48F) || // Yi
                      (codeUnit >= 0xAC00 &&
                          codeUnit <= 0xD7AF) || // Hangul syllables
                      (codeUnit >= 0xF900 &&
                          codeUnit <= 0xFAFF) || // CJK compat ideographs
                      (codeUnit >= 0xFE10 &&
                          codeUnit <= 0xFE1F) || // Vertical forms
                      (codeUnit >= 0xFE30 &&
                          codeUnit <= 0xFE4F) || // CJK compat forms
                      (codeUnit >= 0xFF00 &&
                          codeUnit <= 0xFF60) || // Full-width ASCII
                      (codeUnit >= 0xFFE0 &&
                          codeUnit <= 0xFFE6) || // Full-width symbols
                      (codeUnit >= 0x20000 &&
                          codeUnit <= 0x2FFFD) || // CJK ext B+
                      (codeUnit >= 0x30000 &&
                          codeUnit <= 0x3FFFD))) // CJK ext C+
              ? 2
              : 1;
      if (totalWidth + charWidth > maxWidth) {
        break;
      }
      totalWidth += charWidth;
      lastFitIndex = i + 1;
    }
    if (lastFitIndex >= collapsed.length) return collapsed;
    return '${collapsed.substring(0, lastFitIndex)}…';
  }

  Widget _buildComposer(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<ChatSessionStore>().stateFor(widget.session);

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          decoration: const BoxDecoration(
            color: Color(0xFFF6F7FB),
            border: Border(top: BorderSide(color: Color(0xFFE7EAF3))),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final measured = constraints.maxHeight;
              if (measured != _composerHeight) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _composerHeight = measured);
                });
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildSlashSuggestionPanel(theme),
                  if (_slashSuggestions.isNotEmpty) const SizedBox(height: 8),
                  if (_quotedMessageDraft != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE7EAF3)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 4,
                            height: 34,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '引用 ${_quotedMessageDraft!.authorName}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  _quotedMessageDraft!.previewText,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF667085),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed:
                                () =>
                                    setState(() => _quotedMessageDraft = null),
                            icon: const Icon(Icons.close_rounded, size: 18),
                            color: const Color(0xFF98A1B3),
                            splashRadius: 18,
                            tooltip: '取消引用',
                          ),
                        ],
                      ),
                    ),
                  if (_pendingImageDraft != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE7EAF3)),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              File(_pendingImageDraft!.filePath),
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              errorBuilder:
                                  (_, __, ___) => Container(
                                    width: 56,
                                    height: 56,
                                    color: const Color(0xFFF1F3F9),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.broken_image_outlined,
                                    ),
                                  ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '准备发送图片',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _pendingImageDraft!.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF667085),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _formatFileSize(_pendingImageDraft!.fileSize),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF98A1B3),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed:
                                _isSendingImage
                                    ? null
                                    : () => setState(
                                      () => _pendingImageDraft = null,
                                    ),
                            icon: const Icon(Icons.close_rounded, size: 18),
                            color: const Color(0xFF98A1B3),
                            splashRadius: 18,
                            tooltip: '取消图片',
                          ),
                        ],
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: IconButton(
                          onPressed:
                              (state.isSubmitting || _isSendingImage)
                                  ? null
                                  : () => _showAttachmentMenu(state),
                          icon: const Icon(Icons.add_rounded),
                          color:
                              (state.isSubmitting || _isSendingImage)
                                  ? const Color(0xFF98A1B3)
                                  : theme.colorScheme.primary,
                          tooltip: '附件',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x0A1F2430),
                                blurRadius: 14,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: TextField(
                            controller: _composerController,
                            focusNode: _composerFocusNode,
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: TextInputAction.send,
                            decoration: const InputDecoration(
                              hintText: '发消息…',
                              isDense: true,
                            ),
                            onSubmitted: (value) {
                              if ((value.trim().isNotEmpty ||
                                      _pendingImageDraft != null) &&
                                  !state.isSubmitting &&
                                  !_isSendingImage) {
                                _handleSend(value);
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color:
                              (state.isSubmitting || _isSendingImage)
                                  ? const Color(0xFFD7CCFF)
                                  : theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x1A7C4DFF),
                              blurRadius: 16,
                              offset: Offset(0, 6),
                            ),
                          ],
                        ),
                        child: IconButton(
                          onPressed:
                              (state.isSubmitting || _isSendingImage)
                                  ? null
                                  : () {
                                    final text = _composerController.text;
                                    if (text.trim().isNotEmpty ||
                                        _pendingImageDraft != null) {
                                      _handleSend(text);
                                    }
                                  },
                          icon:
                              (state.isSubmitting || _isSendingImage)
                                  ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                  : const Icon(Icons.arrow_upward_rounded),
                          color: Colors.white,
                          tooltip: '发送',
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildImageMessage(
    BuildContext context,
    core.ImageMessage message,
    int index, {
    bool? isSentByMe,
    core.MessageGroupStatus? groupStatus,
  }) {
    final sentByMe = isSentByMe ?? false;
    final showAvatar = !sentByMe && (groupStatus == null || groupStatus.isLast);
    final maxWidth = MediaQuery.of(context).size.width * 0.72;
    final config = context.read<ChatSessionStore>().currentConfig;
    final password = config.appPassword?.trim();
    final headers =
        (password == null || password.isEmpty)
            ? const <String, String>{}
            : <String, String>{'X-AliceChat-Password': password};
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        groupStatus?.isFirst == true || groupStatus == null ? 10 : 3,
        12,
        groupStatus?.isLast == true || groupStatus == null ? 10 : 3,
      ),
      child: Row(
        mainAxisAlignment:
            sentByMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!sentByMe)
            SizedBox(
              width: 34,
              child: Align(
                alignment: Alignment.bottomLeft,
                child:
                    showAvatar
                        ? _buildHeaderAvatar(radius: 15)
                        : const SizedBox.shrink(),
              ),
            ),
          if (!sentByMe) const SizedBox(width: 8),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Column(
                crossAxisAlignment:
                    sentByMe
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPress:
                        () => _showMessageActionSheet(
                          context,
                          message: message,
                          sentByMe: sentByMe,
                        ),
                    child: _ChatImageBubble(
                      messageId: message.id,
                      imageUrl: message.source,
                      headers: headers,
                      maxWidth: maxWidth,
                    ),
                  ),
                  if ((message.text ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      message.text!.trim(),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    _formatMessageTime(message.createdAt ?? DateTime.now()),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF98A1B3),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (sentByMe) const SizedBox(width: 42),
        ],
      ),
    );
  }

  Widget _buildHeaderAvatar({double radius = 20}) {
    if (widget.session.avatarAssetPath != null) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: AssetImage(widget.session.avatarAssetPath!),
        backgroundColor: const Color(0xFFE9ECF5),
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFFE9ECF5),
      foregroundColor: const Color(0xFF5C667A),
      child: Text(
        widget.session.title.isEmpty
            ? '?'
            : widget.session.title[0].toUpperCase(),
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: radius * 0.9),
      ),
    );
  }

  Widget _buildUserAvatar({double radius = 15}) {
    return CircleAvatar(
      radius: radius,
      backgroundImage: const AssetImage('assets/avatars/user.jpg'),
      backgroundColor: const Color(0xFFE9ECF5),
    );
  }

  @override
  void dispose() {
    final store = context.read<ChatSessionStore>();
    store.removeListener(_handleStoreChanged);
    _streamingHintPulseTimer?.cancel();
    _chatListController.removeListener(_handleScroll);
    _chatListController.dispose();
    _composerController.removeListener(_handleComposerTextChanged);
    _composerController.dispose();
    _composerFocusNode.dispose();
    super.dispose();
  }
}

class _ChatImageBubble extends StatefulWidget {
  const _ChatImageBubble({
    required this.messageId,
    required this.imageUrl,
    required this.headers,
    required this.maxWidth,
  });

  final String messageId;
  final String imageUrl;
  final Map<String, String> headers;
  final double maxWidth;

  @override
  State<_ChatImageBubble> createState() => _ChatImageBubbleState();
}

class _ChatImageBubbleState extends State<_ChatImageBubble> {
  static final _cacheManager = CacheManager(
    Config(
      'alicechat_chat_images',
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 400,
    ),
  );

  late Future<File> _fileFuture;

  @override
  void initState() {
    super.initState();
    _fileFuture = _loadFile();
  }

  @override
  void didUpdateWidget(covariant _ChatImageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    final headersChanged = !_mapEquals(oldWidget.headers, widget.headers);
    if (oldWidget.imageUrl != widget.imageUrl || headersChanged) {
      _fileFuture = _loadFile();
    }
  }

  Future<File> _loadFile() {
    return _cacheManager.getSingleFile(
      widget.imageUrl,
      key: _cacheKey,
      headers: widget.headers,
    );
  }

  String get _cacheKey {
    final password = widget.headers['X-AliceChat-Password'] ?? '';
    return '${widget.messageId}|${widget.imageUrl}|$password';
  }

  String get _heroTag =>
      'chat-image-preview:${widget.messageId}:${widget.imageUrl}';

  bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: widget.maxWidth,
            maxHeight: 320,
          ),
          child: FutureBuilder<File>(
            future: _fileFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return _buildLoading();
              }
              if (snapshot.hasError || !snapshot.hasData) {
                unawaited(
                  NativeDebugBridge.instance.log(
                    'chat-image',
                    'cache/network error messageId=${widget.messageId} source=${widget.imageUrl} error=${snapshot.error}',
                    level: 'ERROR',
                  ),
                );
                return _buildError();
              }
              return GestureDetector(
                onTap: () => _openPreview(context, snapshot.data!),
                child: Hero(
                  tag: _heroTag,
                  child: Image.file(
                    snapshot.data!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, error, stackTrace) {
                      unawaited(
                        NativeDebugBridge.instance.log(
                          'chat-image',
                          'file decode error messageId=${widget.messageId} source=${widget.imageUrl} error=$error',
                          level: 'ERROR',
                        ),
                      );
                      return _buildError();
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Container(
      width: widget.maxWidth,
      height: 180,
      color: Colors.white,
      alignment: Alignment.center,
      child: const CircularProgressIndicator(strokeWidth: 2),
    );
  }

  Widget _buildError() {
    return Container(
      width: widget.maxWidth,
      color: Colors.white,
      padding: const EdgeInsets.all(18),
      child: const Text('图片加载失败'),
    );
  }

  Future<void> _openPreview(BuildContext context, File file) async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: true,
        pageBuilder: (context, animation, secondaryAnimation) {
          return _ImagePreviewPage(file: file, heroTag: _heroTag);
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          );
        },
      ),
    );
  }
}

class _ImagePreviewPage extends StatelessWidget {
  const _ImagePreviewPage({required this.file, required this.heroTag});

  final File file;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.96),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: Center(
                  child: InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 4.0,
                    child: Hero(
                      tag: heroTag,
                      child: Image.file(
                        file,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                tooltip: '关闭',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineCodeBuilder extends MarkdownElementBuilder {
  _InlineCodeBuilder(this.styleSheet);

  final MarkdownStyleSheet styleSheet;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final text = element.textContent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF1EEFF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: styleSheet.code),
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this.styleSheet);

  final MarkdownStyleSheet styleSheet;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final text = element.textContent.replaceAll(RegExp(r'\n$'), '');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: styleSheet.codeblockDecoration,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: styleSheet.codeblockPadding,
        child: Text(text, style: styleSheet.code),
      ),
    );
  }
}

class _BlockquoteBuilder extends MarkdownElementBuilder {
  _BlockquoteBuilder(this.styleSheet);

  final MarkdownStyleSheet styleSheet;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F6FF),
        borderRadius: BorderRadius.circular(12),
        border: const Border(
          left: BorderSide(color: Color(0xFFB9A8FF), width: 3),
        ),
      ),
      child: Text(element.textContent, style: styleSheet.blockquote),
    );
  }
}
