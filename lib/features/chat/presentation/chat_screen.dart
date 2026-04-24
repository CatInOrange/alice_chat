import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_chat_core/flutter_chat_core.dart'
    show Builders, ChatAnimatedList, TimeAndStatusPosition;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/chat_session_store.dart';
import '../domain/chat_session.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.session, this.onBack});

  final ChatSession session;
  final VoidCallback? onBack;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _currentUserId = 'user';
  final _composerController = TextEditingController();
  final _chatListController = ScrollController();
  final _chatController = core.InMemoryChatController();

  double _lastSavedOffset = -1;
  bool _lastSavedStickToBottom = true;
  bool _showJumpToBottom = false;
  final List<String> _appliedMessageIds = [];

  // Composer height tracking for relative positioning of floating elements
  static const double _composerPaddingVertical = 20.0; // 8 + 12
  static const double _composerRowHeight = 40.0;
  static const double _composerMinContentHeight =
      _composerPaddingVertical + _composerRowHeight; // 60
  static const double _composerMinHeight =
      _composerMinContentHeight; // 68 with SafeArea bottom padding
  static const double _jumpButtonGap = 8.0;
  static const double _typingIndicatorTotalHeight =
      44.0; // 10+10 padding + 24 text row
  double _composerHeight = _composerMinHeight;

  // Cache for MarkdownStyleSheet to avoid rebuilding on every message
  static final _markdownStyleSheetCache = <ThemeData, MarkdownStyleSheet>{};

  // Cache for parsed markdown widgets
  static final _markdownWidgetCache = <String, MarkdownBody>{};

  String get _assistantName => widget.session.title;

  String _assistantSubtitle(ChatViewState state) =>
      state.isAssistantStreaming ? '正在输入…' : widget.session.subtitle;

  Builders get _chatBuilders => Builders(
    textMessageBuilder: _buildTextMessage,
    composerBuilder: _buildComposer,
    chatAnimatedListBuilder:
        (context, itemBuilder) => ChatAnimatedList(
          key: PageStorageKey('chat-list-${widget.session.id}'),
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
    debugPrint(
      '[alicechat.screen] ${jsonEncode({'tag': 'build', 'sessionId': state.backendSessionId, 'sessionLocalId': widget.session.id, 'isSubmitting': state.isSubmitting, 'isAssistantStreaming': state.isAssistantStreaming, 'pendingCount': state.pendingClientMessageIds.length, 'streamingCount': state.streamingMessageIds.length, 'messageCount': state.messages.length, 'lastEventSeq': state.lastEventSeq})}',
    );

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

    final effectiveComposerHeight =
        _composerHeight + MediaQuery.of(context).viewInsets.bottom;
    return Stack(
      children: [
        Chat(
          currentUserId: _currentUserId,
          resolveUser: _resolveUser,
          chatController: _chatController,
          onMessageSend: _handleSend,
          builders: _chatBuilders,
          backgroundColor: const Color(0xFFF6F7FB),
        ),
        if (_showJumpToBottom)
          Positioned(
            right: 16,
            bottom:
                state.isAssistantStreaming
                    ? effectiveComposerHeight +
                        _typingIndicatorTotalHeight +
                        _jumpButtonGap
                    : effectiveComposerHeight + _jumpButtonGap,
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
        if (state.isAssistantStreaming)
          Positioned(
            left: 12,
            right: 12,
            bottom:
                effectiveComposerHeight +
                _typingIndicatorTotalHeight +
                _jumpButtonGap,
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildHeaderAvatar(radius: 12),
                      const SizedBox(width: 8),
                      Text(
                        '$_assistantName 正在输入…',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF667085),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
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
    debugPrint(
      '[alicechat.screen] ${jsonEncode({'tag': 'handleStoreChanged', 'sessionId': state.backendSessionId, 'sessionLocalId': widget.session.id, 'isSubmitting': state.isSubmitting, 'isAssistantStreaming': state.isAssistantStreaming, 'pendingCount': state.pendingClientMessageIds.length, 'streamingCount': state.streamingMessageIds.length, 'messageCount': state.messages.length, 'lastEventSeq': state.lastEventSeq})}',
    );
    _applyMessagesIncrementally(state.messages);
  }

  void _applyMessagesIncrementally(List<core.TextMessage> messages) {
    final existingMessages = _chatController.messages.cast<core.TextMessage>();

    if (existingMessages.isEmpty) {
      _chatController.setMessages(messages);
    } else {
      final existingById = {
        for (final message in existingMessages) message.id: message,
      };
      final nextById = {for (final message in messages) message.id: message};

      final removed = existingMessages
          .where((message) => !nextById.containsKey(message.id))
          .toList(growable: false);
      for (final message in removed) {
        _chatController.removeMessage(message, animated: false);
      }

      for (var index = 0; index < messages.length; index++) {
        final next = messages[index];
        final existing = existingById[next.id];
        if (existing == null) {
          _chatController.insertMessage(next, index: index, animated: false);
        } else if (existing != next) {
          _chatController.updateMessage(existing, next);
        }
      }

      final currentIds = _chatController.messages.map((m) => m.id).toList();
      final nextIds = messages.map((m) => m.id).toList();
      final orderChanged =
          currentIds.length != nextIds.length ||
          currentIds.asMap().entries.any(
            (entry) => entry.value != nextIds[entry.key],
          );
      if (orderChanged) {
        _chatController.setMessages(messages, animated: false);
      }
    }

    _appliedMessageIds
      ..clear()
      ..addAll(messages.map((message) => message.id));
  }

  void _handleScroll() {
    if (!_chatListController.hasClients) return;
    final position = _chatListController.position;
    if (!position.hasContentDimensions) return;
    final offset = position.pixels;
    final maxExtent = position.maxScrollExtent;

    // 只有内容够长（可滚动）时才需要跳转按钮
    final canScroll = maxExtent > 600;
    final atBottom = offset <= 24;
    final shouldShowJump = canScroll && offset > 300 && !atBottom;
    if (_showJumpToBottom != shouldShowJump && mounted) {
      setState(() {
        _showJumpToBottom = shouldShowJump;
      });
    }

    if ((_lastSavedOffset - offset).abs() < 24 &&
        _lastSavedStickToBottom == atBottom) {
      return;
    }
    _lastSavedOffset = offset;
    _lastSavedStickToBottom = atBottom;
    if (mounted) {
      context.read<ChatSessionStore>().updateScrollState(
        widget.session,
        offset: offset,
        stickToBottom: atBottom,
      );
    }
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
    if (trimmed.isEmpty) return;
    _composerController.clear();
    await context.read<ChatSessionStore>().sendMessage(widget.session, trimmed);
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
                      ? SimpleTextMessage(
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
                                  ? Colors.white.withOpacity(0.72)
                                  : const Color(0xFF98A1B3),
                          fontSize: 11,
                        ),
                        topWidget: null,
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
        onLongPress: () => _showMessageActionSheet(context, message.text),
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
                    Text(
                      " · ",
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
                    _buildModelNameText(message.text),
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
          fontFamily: 'monospace',
          color: const Color(0xFF2B2F3A),
          height: 1.25,
        ) ??
        const TextStyle(
          fontFamily: 'monospace',
          color: Color(0xFF2B2F3A),
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
    BuildContext context,
    String text,
  ) async {
    final plainText = _stripModelNamePrefix(text).trim();
    if (plainText.isEmpty) return;

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
                  leading: const Icon(Icons.copy_rounded),
                  title: Text(
                    '复制',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop('copy'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (action != 'copy') return;
    await Clipboard.setData(ClipboardData(text: plainText));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制'),
        duration: Duration(milliseconds: 1200),
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
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
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

  Widget _buildModelNameText(String text) {
    final modelName = _extractModelName(text);
    if (modelName == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          " | ",
          style: const TextStyle(color: Color(0xFF98A1B3), fontSize: 11),
        ),
        Text(
          modelName,
          style: const TextStyle(color: Color(0xFF98A1B3), fontSize: 11),
        ),
      ],
    );
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
              return Row(
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
                      onPressed: null,
                      icon: const Icon(Icons.add_rounded),
                      color: const Color(0xFF98A1B3),
                      tooltip: '更多功能',
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
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        decoration: const InputDecoration(
                          hintText: '发消息…',
                          isDense: true,
                        ),
                        onSubmitted: (value) {
                          if (value.trim().isNotEmpty && !state.isSubmitting) {
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
                          state.isSubmitting
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
                          state.isSubmitting
                              ? null
                              : () {
                                final text = _composerController.text;
                                if (text.trim().isNotEmpty) {
                                  _handleSend(text);
                                }
                              },
                      icon:
                          state.isSubmitting
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
              );
            },
          ),
        ),
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
    _chatListController.removeListener(_handleScroll);
    _chatListController.dispose();
    _composerController.dispose();
    super.dispose();
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
