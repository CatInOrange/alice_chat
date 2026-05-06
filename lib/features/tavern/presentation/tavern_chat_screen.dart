import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../../../../core/openclaw/openclaw_settings.dart';
import '../application/tavern_store.dart';
import '../domain/tavern_models.dart';
import 'tavern_ui_helpers.dart';

class TavernChatScreen extends StatefulWidget {
  const TavernChatScreen({
    super.key,
    required this.chat,
    required this.character,
  });

  final TavernChat chat;
  final TavernCharacter character;

  @override
  State<TavernChatScreen> createState() => _TavernChatScreenState();
}

class _NarrationSegment {
  const _NarrationSegment(this.text)
    : isNarration = false,
      openBracket = '',
      closeBracket = '';

  const _NarrationSegment.narration({
    required this.text,
    required this.openBracket,
    required this.closeBracket,
  }) : isNarration = true;

  final String text;
  final bool isNarration;
  final String openBracket;
  final String closeBracket;
}

class _TavernChatScreenState extends State<TavernChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _isSending = false;
  bool _isLoadingDebug = false;
  bool _didInitialScroll = false;
  bool _stickToBottom = true;
  String? _error;
  String? _serverBaseUrl;
  String? _selectedPresetId;
  String? _streamingAssistantMessageId;
  List<TavernMessage> _messages = const <TavernMessage>[];
  late TavernCharacter _character;
  late TavernChat _chat;

  @override
  void initState() {
    super.initState();
    _character = widget.character;
    _chat = widget.chat;
    _scrollController.addListener(_handleScrollChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScrollChanged);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final store = context.read<TavernStore>();
    try {
      final cached = await store.loadCachedChatSnapshot(_chat.id);
      final settings = await OpenClawSettingsStore.load();
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _serverBaseUrl = settings.baseUrl.trim().replaceFirst(
            RegExp(r'/+$'),
            '',
          );
          _chat = cached.chat ?? _chat;
          _character = cached.character ?? _character;
          _messages = cached.messages;
          _selectedPresetId = _chat.presetId.isNotEmpty ? _chat.presetId : null;
          _isLoading = false;
          _isRefreshing = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scrollToBottom(animated: false, force: true);
          }
        });
        unawaited(_refreshFromServer());
        return;
      }

      final messages = await store.listChatMessages(_chat.id);
      if (!mounted) return;
      setState(() {
        _serverBaseUrl = settings.baseUrl.trim().replaceFirst(
          RegExp(r'/+$'),
          '',
        );
        _messages = messages;
        _selectedPresetId = _chat.presetId.isNotEmpty ? _chat.presetId : null;
        _isLoading = false;
      });
      await store.saveChatSnapshot(
        chat: _chat,
        character: _character,
        messages: messages,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToBottom(animated: false, force: true);
        }
      });
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        _error = exc.toString();
        _isLoading = false;
        _isRefreshing = false;
      });
    }
  }

  Future<void> _refreshFromServer() async {
    final store = context.read<TavernStore>();
    try {
      final shouldKeepAtBottom = _stickToBottom || !_didInitialScroll;
      final results = await Future.wait([
        store.getCharacter(_chat.characterId),
        store.getChat(_chat.id),
        store.listChatMessages(_chat.id),
      ]);
      if (!mounted) return;
      final character = results[0] as TavernCharacter;
      final chat = results[1] as TavernChat;
      final messages = results[2] as List<TavernMessage>;
      setState(() {
        _character = character;
        _chat = chat;
        _messages = messages;
        _selectedPresetId = _chat.presetId.isNotEmpty ? _chat.presetId : null;
        _isRefreshing = false;
      });
      if (shouldKeepAtBottom) {
        _scrollToBottom(animated: false, force: true);
      }
      await store.saveChatSnapshot(
        chat: chat,
        character: character,
        messages: messages,
      );
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        _isRefreshing = false;
        _error ??= exc.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = _backgroundImageUrl();
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: '剧情摘要',
            onPressed: _showSummariesSheet,
            icon: Badge(
              isLabelVisible: _summaryItems().isNotEmpty,
              label: Text('${_summaryItems().length}'),
              child: const Icon(Icons.auto_stories_outlined),
            ),
          ),
          IconButton(
            tooltip: '会话设置',
            onPressed: _showChatOptions,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: 'Prompt Debug',
            onPressed: _showPromptDebug,
            icon:
                _isLoadingDebug
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.bug_report_outlined),
          ),
        ],
        title: Row(
          children: [
            buildTavernAvatar(
              avatarPath: _character.avatarPath,
              serverBaseUrl: _serverBaseUrl,
              radius: 18,
              useDefaultAssetFallback: true,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_character.name),
                  if (_character.scenario.isNotEmpty)
                    Text(
                      _character.scenario,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Container(
        decoration:
            bg == null
                ? null
                : BoxDecoration(
                  image: DecorationImage(
                    image: NetworkImage(bg),
                    fit: BoxFit.cover,
                    opacity: 0.18,
                  ),
                ),
        child: Container(
          color: Theme.of(
            context,
          ).scaffoldBackgroundColor.withValues(alpha: 0.9),
          child: Column(
            children: [
              Expanded(child: _buildBody(context)),
              _buildQuickActionsBar(),
              if (_isRefreshing)
                const LinearProgressIndicator(minHeight: 2),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          minLines: 1,
                          maxLines: 6,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _handleSend(),
                          decoration: const InputDecoration(
                            hintText: '和角色说点什么…',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _isSending ? null : _handleSend,
                        child:
                            _isSending
                                ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Text('发送'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if ((_error ?? '').isNotEmpty) {
      return Center(child: Text('加载失败：$_error'));
    }
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _buildMarkdownText(
            _character.firstMessage.isNotEmpty
                ? _character.firstMessage
                : '还没有消息，开始聊吧。',
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final actualIndex = _messages.length - 1 - index;
        final message = _messages[actualIndex];
        final isUser = message.role == 'user';
        final bubbleMaxWidth = MediaQuery.of(context).size.width * 0.72;
        final bubble = ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: bubbleMaxWidth < 560 ? bubbleMaxWidth : 560,
          ),
          child: Container(
            decoration: BoxDecoration(
              color:
                  isUser
                      ? const Color(0xFF7C4DFF)
                      : Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(isUser ? 20 : 8),
                bottomRight: Radius.circular(isUser ? 8 : 20),
              ),
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
                crossAxisAlignment:
                    isUser
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                children: [
                  Text(
                    isUser ? '你' : _character.name,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color:
                          isUser
                              ? Colors.white.withValues(alpha: 0.88)
                              : const Color(0xFF98A1B3),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _buildMessageContent(message.content, isUser: isUser),
                  if (message.createdAt != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        _formatMessageTime(message.createdAt!),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              isUser
                                  ? Colors.white.withValues(alpha: 0.72)
                                  : const Color(0xFF98A1B3),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
        if (isUser) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [bubble],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              buildTavernAvatar(
                avatarPath: _character.avatarPath,
                serverBaseUrl: _serverBaseUrl,
                radius: 18,
                useDefaultAssetFallback: true,
              ),
              const SizedBox(width: 10),
              Flexible(child: bubble),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMarkdownText(String text, {Color? textColor}) {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      return const SizedBox.shrink();
    }
    return MarkdownBody(
      data: normalized,
      selectable: true,
      softLineBreak: true,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: textColor,
          height: 1.35,
          fontWeight: FontWeight.w500,
        ),
        strong: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: textColor,
          fontWeight: FontWeight.w700,
        ),
        em: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: textColor,
          fontStyle: FontStyle.italic,
        ),
        code: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: textColor,
          backgroundColor: const Color(0xFFF1EEFF),
        ),
        codeblockDecoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        blockquoteDecoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      onTapLink: (_, href, __) {},
    );
  }

  Widget _buildMessageContent(String text, {required bool isUser}) {
    final normalized = text.trim();
    if (normalized.isEmpty) return const SizedBox.shrink();
    if (!isUser && _isNarrationMessage(normalized)) {
      return _buildNarrationText(normalized);
    }
    if (!isUser &&
        !_containsPotentialMarkdown(normalized) &&
        _containsNarrationSegment(normalized)) {
      return _buildInlineNarrationRichText(normalized);
    }
    return _buildMarkdownText(
      normalized,
      textColor: isUser ? Colors.white : const Color(0xFF1F2430),
    );
  }

  Widget _buildNarrationText(String text) {
    final trimmed = text.trim();
    final isCn = trimmed.startsWith('（') && trimmed.endsWith('）');
    final open = isCn ? '（' : '(';
    final close = isCn ? '）' : ')';
    final inner = trimmed.substring(1, trimmed.length - 1).trim();
    const bracketColor = Color(0xFFB8A7E8);
    const contentColor = Color(0xFF7B6D9D);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F1FF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: open,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: bracketColor,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
            TextSpan(
              text: inner,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: contentColor,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w500,
                height: 1.45,
              ),
            ),
            TextSpan(
              text: close,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: bracketColor,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInlineNarrationRichText(String text) {
    final baseStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: const Color(0xFF1F2430),
          height: 1.4,
          fontWeight: FontWeight.w500,
        ) ??
        const TextStyle(
          color: Color(0xFF1F2430),
          height: 1.4,
          fontWeight: FontWeight.w500,
        );
    const bracketColor = Color(0xFFB8A7E8);
    const contentColor = Color(0xFF7B6D9D);
    final spans = <InlineSpan>[];
    for (final segment in _parseNarrationSegments(text)) {
      if (!segment.isNarration) {
        spans.add(TextSpan(text: segment.text, style: baseStyle));
        continue;
      }
      spans.add(
        TextSpan(
          text: segment.openBracket,
          style: baseStyle.copyWith(
            color: bracketColor,
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      spans.add(
        TextSpan(
          text: segment.text,
          style: baseStyle.copyWith(
            color: contentColor,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
      spans.add(
        TextSpan(
          text: segment.closeBracket,
          style: baseStyle.copyWith(
            color: bracketColor,
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return Text.rich(TextSpan(children: spans));
  }

  bool _isNarrationMessage(String text) {
    final trimmed = text.trim();
    return (trimmed.startsWith('(') && trimmed.endsWith(')')) ||
        (trimmed.startsWith('（') && trimmed.endsWith('）'));
  }

  bool _containsNarrationSegment(String text) {
    return RegExp(r'(\([^\n()]+\)|（[^\n（）]+）)').hasMatch(text);
  }

  bool _containsPotentialMarkdown(String text) {
    return RegExp(r'[`*_#\[\]~-]|^>|^\d+\.\s|^-\s', multiLine: true)
        .hasMatch(text);
  }

  List<_NarrationSegment> _parseNarrationSegments(String text) {
    final pattern = RegExp(r'(\([^\n()]+\)|（[^\n（）]+）)');
    final segments = <_NarrationSegment>[];
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        segments.add(
          _NarrationSegment(text.substring(cursor, match.start)),
        );
      }
      final raw = match.group(0) ?? '';
      if (raw.length >= 2) {
        segments.add(
          _NarrationSegment.narration(
            text: raw.substring(1, raw.length - 1),
            openBracket: raw.substring(0, 1),
            closeBracket: raw.substring(raw.length - 1),
          ),
        );
      } else {
        segments.add(_NarrationSegment(raw));
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      segments.add(_NarrationSegment(text.substring(cursor)));
    }
    return segments;
  }

  String _formatMessageTime(DateTime time) {
    final local = time.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _handleSend() async {
    return _sendText(_inputController.text.trim());
  }

  Future<void> _sendQuickAction(String text) async {
    await _sendText(text, replaceComposer: false);
  }

  Future<void> _sendText(String text, {bool replaceComposer = true}) async {
    if (text.isEmpty || _isSending) return;
    FocusScope.of(context).unfocus();
    if (replaceComposer) {
      _inputController.clear();
    }

    final optimisticUserMessage = TavernMessage(
      id: 'local_user_${DateTime.now().microsecondsSinceEpoch}',
      chatId: _chat.id,
      role: 'user',
      content: text,
      createdAt: DateTime.now(),
    );

    setState(() {
      _isSending = true;
      _messages = [..._messages, optimisticUserMessage];
      _streamingAssistantMessageId = null;
    });
    unawaited(_persistSnapshot());
    _scrollToBottom();

    try {
      TavernMessage? persistedUserMessage;

      await context.read<TavernStore>().streamMessage(
        chatId: _chat.id,
        text: text,
        presetId: _selectedPresetId ?? '',
        onEvent: (event, data) {
          if (!mounted) return;
          switch (event) {
            case 'start':
              final rawMessage = data['userMessage'];
              if (rawMessage is Map) {
                final parsed = TavernMessage.fromJson(
                  Map<String, dynamic>.from(rawMessage),
                );
                persistedUserMessage = parsed;
                setState(() {
                  _messages = _messages
                      .where((item) => item.id != optimisticUserMessage.id)
                      .toList(growable: true)
                    ..add(parsed);
                });
                unawaited(_persistSnapshot());
                _scrollToBottom();
              }
              break;
            case 'delta':
              final delta = (data['delta'] ?? '').toString();
              if (delta.isEmpty) return;
              final messageId = (data['messageId'] ?? '').toString().trim();
              final assistantId =
                  messageId.isNotEmpty
                      ? messageId
                      : (_streamingAssistantMessageId ??
                          'stream_assistant_${DateTime.now().microsecondsSinceEpoch}');
              final existingIndex = _messages.indexWhere(
                (item) => item.id == assistantId,
              );
              final nextContent =
                  existingIndex >= 0
                      ? '${_messages[existingIndex].content}$delta'
                      : delta;
              final nextMessage = TavernMessage(
                id: assistantId,
                chatId: _chat.id,
                role: 'assistant',
                content: nextContent,
                createdAt: DateTime.now(),
              );
              setState(() {
                _streamingAssistantMessageId = assistantId;
                if (existingIndex >= 0) {
                  final nextMessages = [..._messages];
                  nextMessages[existingIndex] = nextMessage;
                  _messages = nextMessages;
                } else {
                  _messages = [..._messages, nextMessage];
                }
              });
              unawaited(_persistSnapshot());
              _scrollToBottom();
              break;
            case 'final':
              final rawAssistant = data['assistantMessage'];
              if (rawAssistant is Map) {
                final finalizedAssistantMessage = TavernMessage.fromJson(
                  Map<String, dynamic>.from(rawAssistant),
                );
                final existingIndex = _messages.indexWhere(
                  (item) =>
                      item.id == finalizedAssistantMessage.id ||
                      item.id == _streamingAssistantMessageId,
                );
                setState(() {
                  final nextMessages = [..._messages];
                  if (persistedUserMessage != null) {
                    final userIndex = nextMessages.indexWhere(
                      (item) =>
                          item.id == optimisticUserMessage.id ||
                          item.id == persistedUserMessage!.id,
                    );
                    if (userIndex >= 0) {
                      nextMessages[userIndex] = persistedUserMessage!;
                    }
                  }
                  if (existingIndex >= 0) {
                    nextMessages[existingIndex] = finalizedAssistantMessage;
                  } else {
                    nextMessages.add(finalizedAssistantMessage);
                  }
                  _messages = nextMessages;
                  _streamingAssistantMessageId = null;
                });
                unawaited(_persistSnapshot());
                unawaited(_refreshChatMetaOnly());
                _scrollToBottom();
              }
              break;
            case 'error':
              throw Exception((data['error'] ?? 'unknown error').toString());
          }
        },
      );
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        _messages = _messages
            .where((item) => item.id != _streamingAssistantMessageId)
            .toList(growable: false);
        _streamingAssistantMessageId = null;
      });
      unawaited(_persistSnapshot());
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('发送失败：$exc')));
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  Future<void> _persistSnapshot() async {
    await context.read<TavernStore>().saveChatSnapshot(
      chat: _chat,
      character: _character,
      messages: _messages,
    );
  }

  Future<void> _refreshChatMetaOnly() async {
    try {
      final refreshed = await context.read<TavernStore>().getChat(_chat.id);
      if (!mounted) return;
      setState(() {
        _chat = refreshed;
      });
      await _persistSnapshot();
    } catch (_) {}
  }

  List<Map<String, dynamic>> _summaryItems() {
    final metadata = _chat.metadata;
    final raw = metadata['summaries'];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => (item['content'] ?? '').toString().trim().isNotEmpty)
        .toList(growable: false);
  }

  Widget _buildQuickActionsBar() {
    final actions = <({IconData icon, String label, String text})>[
      (
        icon: Icons.play_arrow_rounded,
        label: '推进剧情',
        text: '请继续推进当前剧情，保持人物设定一致，并自然引出下一步发展。',
      ),
      (
        icon: Icons.favorite_outline,
        label: '强化互动',
        text: '请延续当前氛围，增强人物互动与情绪张力，但不要脱离现有剧情。',
      ),
      (
        icon: Icons.explore_outlined,
        label: '制造转折',
        text: '请在不破坏角色设定的前提下，为当前剧情加入一个自然的新转折或新信息。',
      ),
    ];

    return SizedBox(
      height: 44,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, index) {
          final item = actions[index];
          return ActionChip(
            avatar: Icon(item.icon, size: 16),
            label: Text(item.label),
            onPressed: _isSending ? null : () => _sendQuickAction(item.text),
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemCount: actions.length,
      ),
    );
  }

  Future<void> _showSummariesSheet() async {
    if (_isLoadingDebug) return;
    setState(() => _isLoadingDebug = true);
    try {
      final debug = await context.read<TavernStore>().getPromptDebug(_chat.id);
      final summaries = _summaryItems().reversed.toList(growable: false);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.76,
            maxChildSize: 0.94,
            minChildSize: 0.38,
            builder: (context, controller) => DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '剧情摘要',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                summaries.isEmpty
                                    ? '当前还没有可用摘要'
                                    : '共 ${summaries.length} 条，新的在前',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '刷新',
                          onPressed: () async {
                            Navigator.of(context).pop();
                            await _refreshChatMetaOnly();
                            if (!mounted) return;
                            await _showSummariesSheet();
                          },
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                  ),
                  const TabBar(
                    tabs: [
                      Tab(text: '闭环状态'),
                      Tab(text: '摘要内容'),
                    ],
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildSummaryClosureTab(debug: debug, summaries: summaries, controller: controller),
                        _buildSummaryContentTab(summaries: summaries, controller: controller),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } catch (exc) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加载剧情摘要失败：$exc')));
    } finally {
      if (mounted) {
        setState(() => _isLoadingDebug = false);
      }
    }
  }

  Widget _buildSummaryClosureTab({
    required TavernPromptDebug debug,
    required List<Map<String, dynamic>> summaries,
    required ScrollController controller,
  }) {
    final metadata = _chat.metadata;
    final summarySettings =
        metadata['summarySettings'] is Map
            ? Map<String, dynamic>.from(metadata['summarySettings'] as Map)
            : const <String, dynamic>{};
    final injectLatestOnly = summarySettings['injectLatestOnly'] != false;
    final useRecentAfterLatest =
        summarySettings['useRecentMessagesAfterLatest'] != false;
    final summaryBlocks = debug.blocks
        .where((block) => (block['kind'] ?? '').toString() == 'summary')
        .toList(growable: false);
    final latestSummaryBlock = summaryBlocks.cast<Map<String, dynamic>?>().firstWhere(
          (block) =>
              ((block?['meta'] as Map?)?['summaryTier'] ?? '').toString() ==
              'latest',
          orElse: () => summaryBlocks.isNotEmpty ? summaryBlocks.last : null,
        );
    final latestSummaryMeta = latestSummaryBlock?['meta'] is Map
        ? Map<String, dynamic>.from(latestSummaryBlock!['meta'] as Map)
        : const <String, dynamic>{};
    final latestSummary = summaries.isNotEmpty ? summaries.first : null;
    final latestSummaryId =
        (latestSummaryMeta['summaryId'] ?? latestSummary?['id'] ?? '-').toString();
    final latestSummaryEndMessageId =
        (latestSummary?['endMessageId'] ?? '-').toString();
    final latestSummaryEndMessageIndex = latestSummary?['endMessageIndex'];
    final recentStartIndex = latestSummaryEndMessageIndex is num
        ? latestSummaryEndMessageIndex.toInt() + 1
        : null;
    final contextUsage = debug.contextUsage;
    final trimPlan = contextUsage['meta'] is Map
        ? (((contextUsage['meta'] as Map)['trimPlan'] as Map?) ?? const <String, dynamic>{})
        : const <String, dynamic>{};
    final suggestedCuts = ((trimPlan['suggestedCuts'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);

    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _summaryMetaChip('注入模式', injectLatestOnly ? '仅最新摘要' : '多摘要'),
            _summaryMetaChip('历史模式', useRecentAfterLatest ? '摘要后新消息' : '全历史'),
            _summaryMetaChip('已注入摘要块', '${summaryBlocks.length}'),
            _summaryMetaChip('Prompt 消息', '${debug.summary['messageCount'] ?? debug.messages.length}'),
          ],
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: '当前生效摘要',
          subtitle: latestSummary == null
              ? '当前还没有生成摘要，系统仍主要依赖完整历史。'
              : '当前应以这条摘要作为长程记忆入口。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoRow('摘要 ID', latestSummaryId),
              _infoRow('截止消息 ID', latestSummaryEndMessageId),
              _infoRow(
                '截止消息序号',
                latestSummaryEndMessageIndex?.toString() ?? '-',
              ),
              _infoRow(
                'Recent 起点',
                recentStartIndex?.toString() ?? '未截断',
              ),
              if (latestSummary != null) ...[
                const SizedBox(height: 10),
                Text(
                  (latestSummary['content'] ?? '').toString().trim(),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        _sectionCard(
          title: '上下文预算',
          subtitle: '看这轮 prompt 有没有接近上限，以及系统建议裁哪里。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoRow('总 Token', '${contextUsage['totalTokens'] ?? '-'}'),
              _infoRow('最大上下文', '${contextUsage['maxContext'] ?? '-'}'),
              _infoRow(
                '超限 Token',
                '${trimPlan['overLimitTokens'] ?? debug.summary['overLimitTokens'] ?? 0}',
              ),
              _infoRow(
                '建议裁剪数',
                '${suggestedCuts.length}',
              ),
              if (suggestedCuts.isNotEmpty) ...[
                const SizedBox(height: 10),
                ...suggestedCuts.map(
                  (cut) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '• ${(cut['component'] ?? cut['label'] ?? cut['mode'] ?? 'cut').toString()} · ${(cut['suggestedTrimTokens'] ?? 0)} tok${cut['lastResort'] == true ? ' · last-resort' : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryContentTab({
    required List<Map<String, dynamic>> summaries,
    required ScrollController controller,
  }) {
    if (summaries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '还没有生成摘要。\n继续聊一会儿，系统后面会逐步沉淀剧情。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.all(16),
      itemBuilder: (context, index) {
        final item = summaries[index];
        final createdAt = _tryParseDateTime(item['createdAt']);
        final endIndex = item['endMessageIndex'];
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _summaryMetaChip('ID', (item['id'] ?? '-').toString()),
                  if (endIndex != null) _summaryMetaChip('截至消息', '$endIndex'),
                  if (createdAt != null)
                    _summaryMetaChip('时间', _formatSummaryTime(createdAt)),
                  _summaryMetaChip('来源', (item['source'] ?? 'auto').toString()),
                ],
              ),
              const SizedBox(height: 10),
              SelectableText(
                (item['content'] ?? '').toString().trim(),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
            ],
          ),
        );
      },
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemCount: summaries.length,
    );
  }

  Widget _sectionCard({
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          if ((subtitle ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4),
            ),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  Widget _summaryMetaChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label · $value',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }

  DateTime? _tryParseDateTime(Object? raw) {
    if (raw == null) return null;
    return DateTime.tryParse(raw.toString())?.toLocal();
  }

  String _formatSummaryTime(DateTime time) {
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }

  Future<void> _showChatOptions() async {
    final messenger = ScaffoldMessenger.of(context);
    final store = context.read<TavernStore>();
    final presets = store.presets;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('会话设置', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value:
                    presets.any((item) => item.id == _selectedPresetId)
                        ? _selectedPresetId
                        : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Preset',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String>(
                    value: '',
                    child: Text('跟随默认 Preset'),
                  ),
                  ...presets.map(
                    (preset) => DropdownMenuItem<String>(
                      value: preset.id,
                      child: Text(
                        preset.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged:
                    presets.isEmpty
                        ? null
                        : (value) async {
                          final next = (value ?? '').isEmpty ? null : value;
                          Navigator.of(context).pop();
                          setState(() {
                            _selectedPresetId = next;
                          });
                          try {
                            final updated = await this.context
                                .read<TavernStore>()
                                .updateChat(
                                  chatId: _chat.id,
                                  payload: {'presetId': next ?? ''},
                                );
                            if (!mounted) return;
                            setState(() {
                              _chat = updated;
                            });
                          } catch (exc) {
                            if (!mounted) return;
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('保存会话 Preset 失败：$exc'),
                              ),
                            );
                          }
                        },
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.sticky_note_2_outlined),
                title: const Text('Author Note'),
                subtitle: Text(
                  _chat.authorNoteEnabled ? '已启用 · depth ${_chat.authorNoteDepth}' : '未启用',
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _editAuthorNote();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _backgroundImageUrl() {
    final metadata = _character.metadata;
    final charxAssets = metadata['charxAssets'];
    if (charxAssets is! Map) return null;
    final paths = charxAssets['paths'];
    if (paths is! Map) return null;
    final backgrounds = paths['backgrounds'];
    if (backgrounds is! List || backgrounds.isEmpty) return null;
    final first = backgrounds.first?.toString() ?? '';
    if (first.isEmpty || !first.startsWith('/uploads/')) return null;
    final base = (_serverBaseUrl ?? '').trim();
    if (base.isEmpty) return null;
    return '$base$first';
  }

  Future<void> _editAuthorNote() async {
    final noteController = TextEditingController(text: _chat.authorNote);
    bool enabled = _chat.authorNoteEnabled;
    int depth = _chat.authorNoteDepth;
    bool saving = false;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setModalState) => SafeArea(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 16,
                      bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Author Note',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('启用'),
                            value: enabled,
                            onChanged:
                                (value) => setModalState(() => enabled = value),
                          ),
                          Text(
                            'Depth: $depth',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          Slider(
                            value: depth.toDouble(),
                            min: 0,
                            max: 12,
                            divisions: 12,
                            label: '$depth',
                            onChanged:
                                (value) =>
                                    setModalState(() => depth = value.round()),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: noteController,
                            minLines: 4,
                            maxLines: 10,
                            decoration: const InputDecoration(
                              labelText: '内容',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed:
                                    saving
                                        ? null
                                        : () =>
                                            Navigator.of(context).pop(false),
                                child: const Text('取消'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed:
                                    saving
                                        ? null
                                        : () async {
                                          setModalState(() => saving = true);
                                          try {
                                            final updated = await context
                                                .read<TavernStore>()
                                                .updateChat(
                                                  chatId: _chat.id,
                                                  payload: {
                                                    'authorNoteEnabled':
                                                        enabled,
                                                    'authorNote':
                                                        noteController.text,
                                                    'authorNoteDepth': depth,
                                                  },
                                                );
                                            if (!context.mounted) return;
                                            Navigator.of(context).pop(true);
                                            setState(() {
                                              _chat = updated;
                                            });
                                          } catch (exc) {
                                            if (!context.mounted) return;
                                            setModalState(() => saving = false);
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '保存 Author Note 失败：$exc',
                                                ),
                                              ),
                                            );
                                          }
                                        },
                                child:
                                    saving
                                        ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                        : const Text('保存'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
          ),
    );

    noteController.dispose();

    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Author Note 已更新')));
    }
  }

  Future<void> _showPromptDebug() async {
    if (_isLoadingDebug) return;
    setState(() => _isLoadingDebug = true);
    try {
      final debug = await context.read<TavernStore>().getPromptDebug(_chat.id);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder:
            (context) => DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.78,
              maxChildSize: 0.95,
              minChildSize: 0.42,
              builder:
                  (context, controller) => DefaultTabController(
                    length: 5,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Prompt Debug',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _debugChip(
                                    'Preset',
                                    debug.presetId.isEmpty
                                        ? '默认'
                                        : debug.presetId,
                                  ),
                                  _debugChip(
                                    'PromptOrder',
                                    debug.promptOrderId.isEmpty
                                        ? '未设置'
                                        : debug.promptOrderId,
                                  ),
                                  _debugChip(
                                    'Blocks',
                                    '${debug.summary['blockCount'] ?? debug.blocks.length}',
                                  ),
                                  _debugChip(
                                    'Messages',
                                    '${debug.summary['messageCount'] ?? debug.messages.length}',
                                  ),
                                  _debugChip(
                                    'Matched WI',
                                    '${debug.summary['matchedWorldbookCount'] ?? debug.matchedWorldbookEntries.length}',
                                  ),
                                  _debugChip(
                                    'Rejected WI',
                                    '${debug.summary['rejectedWorldbookCount'] ?? debug.rejectedWorldbookEntries.length}',
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const TabBar(
                          isScrollable: true,
                          tabs: [
                            Tab(text: 'Summary'),
                            Tab(text: 'Messages'),
                            Tab(text: 'Blocks'),
                            Tab(text: 'World Info'),
                            Tab(text: 'Runtime'),
                          ],
                        ),
                        Expanded(
                          child: TabBarView(
                            children: [
                              _buildDebugSummaryTab(debug),
                              _buildDebugMessagesTab(debug),
                              _buildDebugBlocksTab(debug),
                              _buildDebugWorldInfoTab(debug),
                              _buildDebugRuntimeTab(debug),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
            ),
      );
    } catch (exc) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加载 Prompt Debug 失败：$exc')));
    } finally {
      if (mounted) {
        setState(() => _isLoadingDebug = false);
      }
    }
  }

  Widget _buildDebugSummaryTab(TavernPromptDebug debug) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (debug.renderedStoryString.isNotEmpty) ...[
          Text(
            'Rendered Story String',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          SelectableText(debug.renderedStoryString),
          const SizedBox(height: 16),
        ],
        if (debug.renderedExamples.isNotEmpty) ...[
          Text(
            'Rendered Examples',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          SelectableText(debug.renderedExamples),
          const SizedBox(height: 16),
        ],
        if (debug.depthInserts.isNotEmpty) ...[
          Text('Depth Inserts', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          ...debug.depthInserts.map(
            (item) => Card(
              child: ListTile(
                title: Text(
                  (item['name'] ?? item['kind'] ?? 'depth').toString(),
                ),
                subtitle: Text(
                  'depth=${item['depth'] ?? '-'} · position=${item['position'] ?? '-'}',
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (debug.characterLoreBindings.isNotEmpty) ...[
          Text(
            'Character Lore Bindings',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          ...debug.characterLoreBindings.map(
            (item) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(item.toString()),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDebugMessagesTab(TavernPromptDebug debug) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: debug.messages
          .map(
            (message) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${message['role'] ?? 'unknown'} · ${(message['meta'] is Map) ? ((message['meta'] as Map)['kind'] ?? '-') : '-'}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    if (message['meta'] != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        message['meta'].toString(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 8),
                    SelectableText((message['content'] ?? '').toString()),
                  ],
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildDebugBlocksTab(TavernPromptDebug debug) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: debug.blocks
          .map(
            (block) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${block['name'] ?? '-'} · ${block['position'] ?? '-'} · ${block['role'] ?? '-'}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'kind=${block['kind'] ?? '-'} depth=${block['depth'] ?? '-'} source=${block['source'] ?? '-'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    SelectableText((block['content'] ?? '').toString()),
                  ],
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildDebugWorldInfoTab(TavernPromptDebug debug) {
    final metadata = _chat.metadata;
    final runtime = metadata['worldbookRuntime'] is Map
        ? Map<String, dynamic>.from(metadata['worldbookRuntime'] as Map)
        : const <String, dynamic>{};
    final entriesMap = runtime['entries'] is Map
        ? Map<String, dynamic>.from(runtime['entries'] as Map)
        : const <String, dynamic>{};

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionCard(
          title: 'Runtime 状态',
          subtitle: '这里展示每条 lore 当前是否处于 sticky / cooldown / delay 中。',
          child: entriesMap.isEmpty
              ? const Text('当前没有运行中的 WorldBook 状态。')
              : Column(
                  children: entriesMap.entries.map((entry) {
                    final state = entry.value is Map
                        ? Map<String, dynamic>.from(entry.value as Map)
                        : const <String, dynamic>{};
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _summaryMetaChip('Entry', entry.key),
                            _summaryMetaChip(
                              'Sticky',
                              '${state['stickyRemaining'] ?? 0}',
                            ),
                            _summaryMetaChip(
                              'Cooldown',
                              '${state['cooldownRemaining'] ?? 0}',
                            ),
                            _summaryMetaChip(
                              'Delay',
                              '${state['delayRemaining'] ?? 0}',
                            ),
                            _summaryMetaChip(
                              'Pending',
                              state['pendingActivation'] == true ? 'Yes' : 'No',
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(growable: false),
                ),
        ),
        const SizedBox(height: 16),
        Text('Matched', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (debug.matchedWorldbookEntries.isEmpty)
          const Text('无命中的 World Info')
        else
          ...debug.matchedWorldbookEntries.map(
            (entry) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${entry['id'] ?? '-'} · ${(entry['_matchMeta'] is Map) ? ((entry['_matchMeta'] as Map)['corpus'] ?? '-') : '-'}',
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _summaryMetaChip('Priority', '${entry['priority'] ?? '-'}'),
                        _summaryMetaChip('Position', '${entry['insertionPosition'] ?? '-'}'),
                        if (entry['_matchMeta'] is Map && ((entry['_matchMeta'] as Map)['kind'] ?? '').toString().isNotEmpty)
                          _summaryMetaChip('命中原因', ((entry['_matchMeta'] as Map)['kind'] ?? '-').toString()),
                        if (entry['_matchMeta'] is Map && ((entry['_matchMeta'] as Map)['state'] is Map))
                          _summaryMetaChip('Runtime', '已参与'),
                      ],
                    ),
                    if (entry['_matchMeta'] is Map && ((entry['_matchMeta'] as Map)['state'] is Map)) ...[
                      const SizedBox(height: 6),
                      Text(
                        'state=${((entry['_matchMeta'] as Map)['state'] as Map).toString()}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 8),
                    SelectableText((entry['content'] ?? '').toString()),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text('Rejected', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (debug.rejectedWorldbookEntries.isEmpty)
          const Text('无 rejected World Info')
        else
          ...debug.rejectedWorldbookEntries.map(
            (entry) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${((entry['entry'] as Map?)?['id'] ?? '-')} · ${_worldInfoRejectReasonLabel((entry['reason'] ?? '-').toString())}',
                    ),
                    const SizedBox(height: 6),
                    if ((entry['state'] is Map))
                      Text(
                        'state=${(entry['state'] as Map).toString()}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (entry['details'] != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        entry['details'].toString(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _worldInfoRejectReasonLabel(String reason) {
    switch (reason) {
      case 'cooldown_active':
        return '冷却中';
      case 'delay_scheduled':
        return '已延迟排队';
      case 'prevent_recursion_blocked':
        return '递归被阻止';
      default:
        return reason;
    }
  }

  Widget _buildDebugRuntimeTab(TavernPromptDebug debug) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: debug.runtimeContext.entries
          .map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.key,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 2),
                  SelectableText('${entry.value}'),
                ],
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _debugChip(String label, String value) {
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text('$label: $value'),
    );
  }

  void _handleScrollChanged() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    _stickToBottom = position.pixels <= 80;
  }

  void _scrollToBottom({bool animated = true, bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients || !mounted) return;
      if (!force && !_stickToBottom && _didInitialScroll) return;
      const target = 0.0;
      _didInitialScroll = true;
      if (animated) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }
}
