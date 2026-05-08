import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

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

class _TavernRegexScript {
  const _TavernRegexScript({
    required this.scriptName,
    required this.findRegex,
    required this.replaceString,
    required this.placement,
    this.disabled = false,
    this.markdownOnly = false,
    this.promptOnly = false,
    this.runOnEdit = false,
    this.substituteRegex = 0,
    this.order = 0,
    this.minDepth,
    this.maxDepth,
    this.trimStrings = const <String>[],
  });

  final String scriptName;
  final String findRegex;
  final String replaceString;
  final List<dynamic> placement;
  final bool disabled;
  final bool markdownOnly;
  final bool promptOnly;
  final bool runOnEdit;
  final int substituteRegex;
  final int order;
  final int? minDepth;
  final int? maxDepth;
  final List<String> trimStrings;

  factory _TavernRegexScript.fromJson(Map<String, dynamic> json) {
    return _TavernRegexScript(
      scriptName: (json['scriptName'] ?? '').toString(),
      findRegex: (json['findRegex'] ?? '').toString(),
      replaceString: (json['replaceString'] ?? '').toString(),
      placement: ((json['placement'] as List?) ?? const <dynamic>[])
          .toList(growable: false),
      disabled: json['disabled'] == true,
      markdownOnly: json['markdownOnly'] == true,
      promptOnly: json['promptOnly'] == true,
      runOnEdit: json['runOnEdit'] == true,
      substituteRegex: (json['substituteRegex'] as num?)?.toInt() ?? 0,
      order: (json['order'] as num?)?.toInt() ?? 0,
      minDepth: (json['minDepth'] as num?)?.toInt(),
      maxDepth: (json['maxDepth'] as num?)?.toInt(),
      trimStrings: ((json['trimStrings'] as List?) ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }

  bool appliesToAiOutput({required bool isMarkdown, required int? depth}) {
    if (disabled || findRegex.isEmpty) return false;
    final placements = placement
        .map((item) => item is num ? item.toInt() : item.toString())
        .toList(growable: false);
    final hasAiOutput = placements.contains(1) || placements.contains('aiOutput');
    if (!hasAiOutput) return false;
    if (markdownOnly && !isMarkdown) return false;
    if (promptOnly) return false;
    if (depth != null) {
      if (minDepth != null && minDepth! >= -1 && depth < minDepth!) return false;
      if (maxDepth != null && maxDepth! >= 0 && depth > maxDepth!) return false;
    }
    return true;
  }
}

enum _AssistantRenderKind { markdown, narration, inlineNarration, complexHtml }

class _AssistantRenderPayload {
  const _AssistantRenderPayload({
    required this.kind,
    required this.content,
  });

  final _AssistantRenderKind kind;
  final String content;
}

class _InlineHtmlMessageView extends StatefulWidget {
  const _InlineHtmlMessageView({
    required this.html,
    required this.initialHeight,
  });

  final String html;
  final double initialHeight;

  @override
  State<_InlineHtmlMessageView> createState() => _InlineHtmlMessageViewState();
}

class _InlineHtmlMessageViewState extends State<_InlineHtmlMessageView> {
  static const String _heightProbeScript = '''
(() => {
  const doc = document.documentElement;
  const body = document.body;
  if (!doc || !body) return 320;
  return Math.max(
    body.scrollHeight || 0,
    body.offsetHeight || 0,
    doc.clientHeight || 0,
    doc.scrollHeight || 0,
    doc.offsetHeight || 0
  );
})()
''';

  late final WebViewController _controller;
  late double _height;

  @override
  void initState() {
    super.initState();
    _height = widget.initialHeight;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            unawaited(_syncHeight());
          },
        ),
      );
    unawaited(_controller.loadHtmlString(widget.html));
  }

  @override
  void didUpdateWidget(covariant _InlineHtmlMessageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      _height = widget.initialHeight;
      unawaited(_controller.loadHtmlString(widget.html));
    }
  }

  Future<void> _syncHeight() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        _heightProbeScript,
      );
      final nextHeight = _parseHeightResult(raw);
      if (!mounted || nextHeight == null) return;
      final clamped = nextHeight.clamp(220, 1200).toDouble();
      if ((clamped - _height).abs() < 8) return;
      setState(() {
        _height = clamped;
      });
    } catch (_) {
      // Keep heuristic height when JS probing is unavailable.
    }
  }

  double? _parseHeightResult(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    final text = raw.toString().trim();
    return double.tryParse(text.replaceAll('"', ''));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: _height,
          child: WebViewWidget(controller: _controller),
        ),
      ),
    );
  }
}

class _TavernCharacterProfilePage extends StatelessWidget {
  const _TavernCharacterProfilePage({
    required this.character,
    required this.serverBaseUrl,
    required this.onStartChat,
  });

  final TavernCharacter character;
  final String? serverBaseUrl;
  final Future<void> Function() onStartChat;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            stretch: true,
            title: Text(
              character.name,
              style: const TextStyle(
                shadows: [Shadow(color: Colors.black54, blurRadius: 12)],
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: _buildHeroBackground(context),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (character.tags.isNotEmpty) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: character.tags
                          .map(
                            (tag) => Chip(
                              label: Text(tag),
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.10),
                            ),
                          )
                          .toList(growable: false),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Wrap(
                    spacing: 14,
                    runSpacing: 8,
                    children: [
                      if (character.creator.isNotEmpty)
                        _metaInfo(
                          context,
                          Icons.person_outline,
                          'by ${character.creator}',
                        ),
                      if (character.characterVersion.isNotEmpty)
                        _metaInfo(
                          context,
                          Icons.update_outlined,
                          'v${character.characterVersion}',
                        ),
                      if (character.sourceType.isNotEmpty)
                        _metaInfo(
                          context,
                          Icons.inventory_2_outlined,
                          character.sourceType.toUpperCase(),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _profileSectionCard(
                    context,
                    title: '基础信息',
                    icon: Icons.badge_outlined,
                    children: [
                      _profileBlock(context, 'Description', character.description),
                      _profileBlock(context, 'Personality', character.personality),
                      _profileBlock(context, 'Scenario', character.scenario),
                      _profileBlock(context, 'First Message', character.firstMessage),
                      _profileBlock(context, 'Example Dialogues', character.exampleDialogues),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _profileSectionCard(
                    context,
                    title: 'Prompt / Notes',
                    icon: Icons.psychology_alt_outlined,
                    children: [
                      _profileBlock(context, 'System Prompt', character.systemPrompt),
                      _profileBlock(context, 'Post-History Instructions', character.postHistoryInstructions),
                      _profileBlock(context, 'Creator Notes', character.creatorNotes),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _profileSectionCard(
                    context,
                    title: '问候与 Lore',
                    icon: Icons.auto_stories_outlined,
                    children: [
                      _profileBlock(
                        context,
                        'Alternate Greetings',
                        character.alternateGreetings.isEmpty
                            ? ''
                            : character.alternateGreetings
                                  .asMap()
                                  .entries
                                  .map((e) => '${e.key + 1}. ${e.value}')
                                  .join('\n\n'),
                      ),
                      _profileBlock(context, '来源文件', character.sourceName),
                    ],
                  ),
                  const SizedBox(height: 96),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: onStartChat,
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('开始聊天'),
      ),
    );
  }

  Widget _buildHeroBackground(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        buildTavernAvatar(
          avatarPath: character.avatarPath,
          serverBaseUrl: serverBaseUrl,
          useDefaultAssetFallback: true,
          radius: 0,
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.12),
                Colors.black.withValues(alpha: 0.22),
                Colors.black.withValues(alpha: 0.55),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 72),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 2),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 18, offset: Offset(0, 10)),
                    ],
                  ),
                  child: buildTavernAvatar(
                    avatarPath: character.avatarPath,
                    serverBaseUrl: serverBaseUrl,
                    useDefaultAssetFallback: true,
                    radius: 42,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        character.name,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          shadows: const [Shadow(color: Colors.black45, blurRadius: 10)],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        character.scenario.isNotEmpty
                            ? character.scenario
                            : (character.description.isNotEmpty ? character.description : '查看角色设定与导入内容'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.92),
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _metaInfo(BuildContext context, IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: const Color(0xFF98A1B3)),
        const SizedBox(width: 4),
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF667085),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _profileSectionCard(
    BuildContext context, {
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    final visible = children.where((w) => w is! SizedBox).toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...visible,
          ],
        ),
      ),
    );
  }

  Widget _profileBlock(BuildContext context, String title, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _TavernChatScreenState extends State<TavernChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _isSending = false;
  int _sendEpoch = 0;
  List<Map<String, String>> _quickReplyConfigs =
      OpenClawSettingsStore.defaultTavernQuickReplies();
  bool _isLoadingDebug = false;
  bool _isLoadingContextState = false;
  bool _didInitialScroll = false;
  bool _stickToBottom = true;
  String? _error;
  String? _serverBaseUrl;
  String? _selectedPresetId;
  String? _streamingAssistantMessageId;
  TavernPromptDebug? _latestPromptDebug;
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
      final quickReplies = await OpenClawSettingsStore.loadTavernQuickReplies();
      if (cached != null) {
        setState(() {
          _serverBaseUrl = settings.baseUrl.trim().replaceFirst(
            RegExp(r'/+$'),
            '',
          );
          _quickReplyConfigs = quickReplies;
          _chat = cached.chat ?? _chat;
          _character = cached.character ?? _character;
          _messages = cached.messages;
          _latestPromptDebug = cached.promptDebug;
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
        _quickReplyConfigs = quickReplies;
        _messages = messages;
        _selectedPresetId = _chat.presetId.isNotEmpty ? _chat.presetId : null;
        _isLoading = false;
      });
      await store.saveChatSnapshot(
        chat: _chat,
        character: _character,
        messages: messages,
        promptDebug: _latestPromptDebug,
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
        promptDebug: _latestPromptDebug,
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
            tooltip: '角色页',
            onPressed: _openCharacterProfilePage,
            icon: const Icon(Icons.account_box_outlined),
          ),
          IconButton(
            tooltip: '会话变量',
            onPressed: _showChatVariablesEditor,
            icon: const Icon(Icons.data_object_outlined),
          ),
          IconButton(
            tooltip: '剧情摘要',
            onPressed: _showSummariesSheet,
            icon: const Icon(Icons.auto_stories_outlined),
          ),
          IconButton(
            tooltip: '会话设置',
            onPressed: _showChatOptions,
            icon:
                _isLoadingDebug
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.tune),
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
              _buildContextStatusBar(),
              _buildQuickReplyBar(),
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
      final greeting = _character.firstMessage.isNotEmpty
          ? _character.firstMessage
          : '还没有消息，开始聊吧。';
      return ListView(
        controller: _scrollController,
        reverse: true,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        children: [
          _buildEphemeralGreetingBubble(greeting),
        ],
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
                  if (message.createdAt != null || (message.metadata['requestId'] ?? '').toString().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if ((message.metadata['requestId'] ?? '').toString().isNotEmpty)
                          _messageMetaPill(
                            isUser: isUser,
                            icon: Icons.link_outlined,
                            label: 'Req',
                          ),
                        if (message.createdAt != null)
                          _messageMetaPill(
                            isUser: isUser,
                            icon: Icons.schedule_outlined,
                            label: _formatMessageTime(message.createdAt!),
                          ),
                      ],
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

  Widget _buildEphemeralGreetingBubble(String greeting) {
    final bubbleMaxWidth = MediaQuery.of(context).size.width * 0.72;
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
          Flexible(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.96, end: 1),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              builder: (context, value, child) => Opacity(
                opacity: value.clamp(0, 1),
                child: Transform.scale(scale: value, alignment: Alignment.topLeft, child: child),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: bubbleMaxWidth < 560 ? bubbleMaxWidth : 560,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.98),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                      bottomLeft: Radius.circular(8),
                      bottomRight: Radius.circular(20),
                    ),
                    border: Border.all(
                      color: const Color(0xFFE9E2FF),
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
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _character.name,
                                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: const Color(0xFF98A1B3),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            _messageMetaPill(
                              isUser: false,
                              icon: Icons.waving_hand_rounded,
                              label: 'Greeting',
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        _buildMessageContent(greeting, isUser: false),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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
    if (isUser) {
      return _buildMarkdownText(
        normalized,
        textColor: Colors.white,
      );
    }

    final payload = _buildAssistantRenderPayload(normalized);
    switch (payload.kind) {
      case _AssistantRenderKind.complexHtml:
        return _buildInlineHtmlContent(payload.content);
      case _AssistantRenderKind.narration:
        return _buildNarrationText(payload.content);
      case _AssistantRenderKind.inlineNarration:
        return _buildInlineNarrationRichText(payload.content);
      case _AssistantRenderKind.markdown:
        return _buildMarkdownText(
          payload.content,
          textColor: const Color(0xFF1F2430),
        );
    }
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

  _AssistantRenderPayload _buildAssistantRenderPayload(String text) {
    final rendered = _applyAssistantDisplayTransforms(text);
    if (_looksLikeComplexHtml(rendered)) {
      return _AssistantRenderPayload(
        kind: _AssistantRenderKind.complexHtml,
        content: rendered,
      );
    }
    if (_isNarrationMessage(rendered)) {
      return _AssistantRenderPayload(
        kind: _AssistantRenderKind.narration,
        content: rendered,
      );
    }
    if (!_containsPotentialMarkdown(rendered) &&
        _containsNarrationSegment(rendered)) {
      return _AssistantRenderPayload(
        kind: _AssistantRenderKind.inlineNarration,
        content: rendered,
      );
    }
    return _AssistantRenderPayload(
      kind: _AssistantRenderKind.markdown,
      content: rendered,
    );
  }

  String _applyAssistantDisplayTransforms(String text) {
    var result = text.trim();
    if (result.isEmpty) return result;
    final scripts = _characterRegexScripts();
    if (scripts.isNotEmpty) {
      final depth = _messages.length;
      final sorted = [...scripts]..sort((a, b) => a.order.compareTo(b.order));
      for (final script in sorted) {
        final isMarkdown = script.markdownOnly || _containsPotentialMarkdown(result);
        if (!script.appliesToAiOutput(isMarkdown: isMarkdown, depth: depth)) {
          continue;
        }
        result = _runRegexScript(script, result);
      }
    }
    return _stripWrappedCodeFenceHtml(result).trim();
  }

  List<_TavernRegexScript> _characterRegexScripts() {
    final raw = _character.extensions['regex_scripts'];
    if (raw is! List) return const <_TavernRegexScript>[];
    return raw
        .whereType<Map>()
        .map((item) => _TavernRegexScript.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  String _runRegexScript(_TavernRegexScript script, String input) {
    final regexString = _substituteRegexMacros(script.findRegex, script.substituteRegex);
    final regex = _parseRegex(regexString);
    if (regex == null) return input;
    return input.replaceAllMapped(regex, (match) {
      var replacement = script.replaceString;
      replacement = replacement.replaceAll(RegExp(r'\{\{match\}\}', caseSensitive: false), match.group(0) ?? '');
      for (var i = 0; i <= match.groupCount; i++) {
        final group = _filterTrimStrings(match.group(i) ?? '', script.trimStrings);
        replacement = replacement.replaceAll('\$$i', group);
      }
      replacement = _substituteRegexMacros(replacement, 0);
      return replacement;
    });
  }

  RegExp? _parseRegex(String regexString) {
    if (regexString.isEmpty) return null;
    try {
      if (regexString.startsWith('/')) {
        final lastSlash = regexString.lastIndexOf('/');
        if (lastSlash > 0) {
          final pattern = regexString.substring(1, lastSlash);
          final flags = regexString.substring(lastSlash + 1);
          return RegExp(
            pattern,
            caseSensitive: !flags.contains('i'),
            multiLine: flags.contains('m'),
            dotAll: flags.contains('s'),
            unicode: flags.contains('u'),
          );
        }
      }
      return RegExp(regexString, dotAll: true, multiLine: true);
    } catch (_) {
      return null;
    }
  }

  String _substituteRegexMacros(String input, int substituteMode) {
    var result = input;
    final charName = _character.name;
    final userName = _resolvedUserDisplayName();
    if (substituteMode == 2) {
      result = result.replaceAll(RegExp(r'\{\{char\}\}', caseSensitive: false), RegExp.escape(charName));
      result = result.replaceAll(RegExp(r'\{\{user\}\}', caseSensitive: false), RegExp.escape(userName));
      return result;
    }
    result = result.replaceAll(RegExp(r'\{\{char\}\}', caseSensitive: false), charName);
    result = result.replaceAll(RegExp(r'\{\{user\}\}', caseSensitive: false), userName);
    return result;
  }

  String _resolvedUserDisplayName() {
    final personaDescription = _chat.metadata['personaDescription'];
    if (personaDescription is String && personaDescription.trim().isNotEmpty) {
      return personaDescription.trim();
    }
    final personaName = _chat.metadata['personaName'];
    if (personaName is String && personaName.trim().isNotEmpty) {
      return personaName.trim();
    }
    return 'User';
  }

  String _filterTrimStrings(String input, List<String> trimStrings) {
    var result = input;
    for (final trim in trimStrings) {
      result = result.replaceAll(trim, '');
    }
    return result;
  }

  String _stripWrappedCodeFenceHtml(String text) {
    final match = RegExp(r'^```\s*(<html[\s\S]*?</html>)\s*```$', caseSensitive: false)
        .firstMatch(text.trim());
    return match?.group(1) ?? text;
  }

  bool _looksLikeComplexHtml(String text) {
    if (!RegExp(r'<\s*html[\s>]|<\s*style[\s>]|<\s*div[\s>]', caseSensitive: false)
        .hasMatch(text)) {
      return false;
    }
    final complexPatterns = <RegExp>[
      RegExp(r'<\s*html[\s>]', caseSensitive: false),
      RegExp(r'<\s*style[\s>]', caseSensitive: false),
      RegExp(r'display\s*:\s*flex', caseSensitive: false),
      RegExp(r'display\s*:\s*grid', caseSensitive: false),
      RegExp(r'box-shadow\s*:', caseSensitive: false),
      RegExp(r'transition\s*:', caseSensitive: false),
      RegExp(r'transform\s*:', caseSensitive: false),
      RegExp(r'animation\s*:', caseSensitive: false),
      RegExp(r'@keyframes', caseSensitive: false),
      RegExp(r'linear-gradient', caseSensitive: false),
    ];
    return complexPatterns.any((pattern) => pattern.hasMatch(text));
  }

  Widget _buildInlineHtmlContent(String html) {
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return _buildMarkdownText(
        _fallbackHtmlToReadableText(html),
        textColor: const Color(0xFF1F2430),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: _InlineHtmlMessageView(
        html: html,
        initialHeight: _estimateInlineHtmlHeight(html),
      ),
    );
  }

  double _estimateInlineHtmlHeight(String html) {
    final lineCount = '\n'.allMatches(html).length + 1;
    final sectionCount = RegExp(r'class="(sec-group|detail-row|log-box|mono-box)"', caseSensitive: false)
        .allMatches(html)
        .length;
    final estimated = 180 + (lineCount * 1.8) + (sectionCount * 28);
    return estimated.clamp(220, 560).toDouble();
  }

  String _fallbackHtmlToReadableText(String html) {
    var text = html;
    text = text.replaceAllMapped(
      RegExp(r'<br\s*/?>', caseSensitive: false),
      (_) => '\n',
    );
    text = text.replaceAllMapped(
      RegExp(r'</(div|p|section|article|tr|li|h[1-6])>', caseSensitive: false),
      (_) => '\n',
    );
    text = text.replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
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

  Widget _messageMetaPill({
    required bool isUser,
    required IconData icon,
    required String label,
  }) {
    final fg = isUser
        ? Colors.white.withValues(alpha: 0.72)
        : const Color(0xFF98A1B3);
    final bg = isUser
        ? Colors.white.withValues(alpha: 0.10)
        : const Color(0xFFF4F6FA);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: fg,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openCharacterProfilePage() async {
    final TavernCharacter currentCharacter = _character;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _TavernCharacterProfilePage(
          character: currentCharacter,
          serverBaseUrl: _serverBaseUrl,
          onStartChat: () async {
            Navigator.of(context).pop();
            await _startFreshChatFromProfile(currentCharacter);
          },
        ),
      ),
    );
    if (!mounted) return;
    await context.read<TavernStore>().loadHome();
  }

  Future<void> _startFreshChatFromProfile(TavernCharacter character) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final personaId = await _pickPersonaForNewChat();
      if (!mounted) return;
      if (personaId == null) return;
      final chat = await context.read<TavernStore>().createChatForCharacter(
        character,
        personaId: personaId,
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => TavernChatScreen(chat: chat, character: character),
        ),
      );
    } catch (exc) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('创建会话失败：$exc')));
    }
  }

  Future<String?> _pickPersonaForNewChat() async {
    final store = context.read<TavernStore>();
    if (store.personas.isEmpty) {
      await store.loadPersonas();
      if (!mounted) return null;
    }
    final personas = store.personas;
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('不指定 Persona'),
              subtitle: const Text('使用默认 persona / fallback User'),
              onTap: () => Navigator.of(context).pop(''),
            ),
            ...personas.map(
              (persona) => ListTile(
                title: Text(persona.name),
                subtitle: Text(
                  persona.description.isEmpty ? '无描述' : persona.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: persona.isDefault ? const Chip(label: Text('默认')) : null,
                onTap: () => Navigator.of(context).pop(persona.id),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showChatVariablesEditor() async {
    final store = context.read<TavernStore>();
    try {
      final values = await store.loadChatVariables(_chat.id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _TavernJsonMapEditorPage(
            title: '会话变量',
            initialValue: values,
            onSave: (value) => store.updateChatVariables(
              chatId: _chat.id,
              values: value,
            ),
          ),
        ),
      );
      if (!mounted) return;
      await _refreshFromServer();
    } catch (exc) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载会话变量失败：$exc')),
      );
    }
  }

  Future<void> _handleSend() async {
    return _sendText(_inputController.text.trim());
  }

  Future<void> _sendSilentQuickReply(Map<String, String> item) async {
    final instruction = (item['instruction'] ?? '').trim();
    if (instruction.isEmpty) return;
    return _sendText(
      instruction,
      replaceComposer: false,
      showUserMessage: false,
      instructionMode: (item['mode'] ?? '').trim(),
      hiddenInstruction: instruction,
      suppressUserMessage: true,
    );
  }

  Future<void> _sendText(
    String text, {
    bool replaceComposer = true,
    bool showUserMessage = true,
    String instructionMode = '',
    String hiddenInstruction = '',
    bool suppressUserMessage = false,
  }) async {
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

    final sendEpoch = ++_sendEpoch;

    void settleSendState({required bool isSending}) {
      if (!mounted || sendEpoch != _sendEpoch) return;
      setState(() {
        _isSending = isSending;
      });
    }

    setState(() {
      _isSending = true;
      if (showUserMessage) {
        _messages = [..._messages, optimisticUserMessage];
      }
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
        instructionMode: instructionMode,
        hiddenInstruction: hiddenInstruction,
        suppressUserMessage: suppressUserMessage,
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
                if (showUserMessage) {
                  setState(() {
                    _messages = _messages
                        .where((item) => item.id != optimisticUserMessage.id)
                        .toList(growable: true)
                      ..add(parsed);
                  });
                  unawaited(_persistSnapshot());
                  _scrollToBottom();
                }
              } else if (showUserMessage) {
                unawaited(_persistSnapshot());
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
                  if (showUserMessage && persistedUserMessage != null) {
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
                final rawPromptDebug = data['promptDebug'];
                final promptDebug = rawPromptDebug is Map
                    ? TavernPromptDebug.fromJson(Map<String, dynamic>.from(rawPromptDebug))
                    : null;
                setState(() {
                  if (promptDebug != null) {
                    _latestPromptDebug = promptDebug;
                  }
                });
                settleSendState(isSending: false);
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
      settleSendState(isSending: false);
      if (!mounted) return;
      setState(() {
        _messages = _messages
            .where((item) => item.id != _streamingAssistantMessageId)
            .toList(growable: false);
        _streamingAssistantMessageId = null;
      });
      unawaited(_persistSnapshot());
      unawaited(_refreshFromServer());
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('流式连接中断，正在同步结果…')));
    } finally {
      settleSendState(isSending: false);
    }
  }

  Future<void> _persistSnapshot() async {
    await context.read<TavernStore>().saveChatSnapshot(
      chat: _chat,
      character: _character,
      messages: _messages,
      promptDebug: _latestPromptDebug,
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

  Future<void> _refreshContextState() async {
    if (_isLoadingContextState) return;
    _isLoadingContextState = true;
    try {
      final debug = await context.read<TavernStore>().getPromptDebug(_chat.id);
      if (!mounted) return;
      setState(() {
        _latestPromptDebug = debug;
      });
    } catch (_) {
      // keep stale state quietly
    } finally {
      _isLoadingContextState = false;
    }
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

  List<Map<String, String>> _quickReplies() {
    return _quickReplyConfigs;
  }

  Map<String, int> _contextBreakdown(TavernPromptDebug debug) {
    final usage = debug.contextUsage;
    final parts = <String, int>{
      'summary': 0,
      'world_info': 0,
      'chat_history': 0,
      'author_note': 0,
      'prompt': 0,
      'user_input': 0,
      'others': 0,
    };

    final rawComponents =
        (usage['components'] as List?) ??
        (usage['breakdown'] as List?) ??
        const <dynamic>[];
    for (final item in rawComponents.whereType<Map>()) {
      final map = Map<String, dynamic>.from(item);
      final name = (map['name'] ?? map['label'] ?? map['component'] ?? '')
          .toString()
          .toLowerCase();
      final kind = (map['kind'] ?? map['type'] ?? '').toString().toLowerCase();
      final tokens =
          (map['tokenCount'] as num?)?.toInt() ??
          (map['tokens'] as num?)?.toInt() ??
          (map['estimatedTokens'] as num?)?.toInt() ??
          0;
      if (tokens <= 0) continue;
      final key = '$name $kind';
      if (key.contains('summary')) {
        parts['summary'] = parts['summary']! + tokens;
      } else if (key.contains('world info') || key.contains('lore')) {
        parts['world_info'] = parts['world_info']! + tokens;
      } else if (key.contains('chat history') ||
          key.contains('history') ||
          key.contains('message')) {
        parts['chat_history'] = parts['chat_history']! + tokens;
      } else if (key.contains('author')) {
        parts['author_note'] = parts['author_note']! + tokens;
      } else if (key.contains('user input')) {
        parts['user_input'] = parts['user_input']! + tokens;
      } else if (key.contains('prompt section') ||
          key.contains('system') ||
          key.contains('persona') ||
          key.contains('scenario') ||
          key.contains('character') ||
          key.contains('example') ||
          key.contains('prompt')) {
        parts['prompt'] = parts['prompt']! + tokens;
      } else {
        parts['others'] = parts['others']! + tokens;
      }
    }

    return parts;
  }

  List<Map<String, dynamic>> _contextSegments(TavernPromptDebug debug) {
    final parts = _contextBreakdown(debug);
    final total = parts.values.fold<int>(0, (sum, value) => sum + value);
    final segments = <Map<String, dynamic>>[
      {
        'key': 'prompt',
        'label': 'Prompt',
        'tokens': parts['prompt'] ?? 0,
        'color': const Color(0xFF7C4DFF),
      },
      {
        'key': 'chat_history',
        'label': 'History',
        'tokens': parts['chat_history'] ?? 0,
        'color': const Color(0xFF4F8CFF),
      },
      {
        'key': 'summary',
        'label': 'Summary',
        'tokens': parts['summary'] ?? 0,
        'color': const Color(0xFF14B8A6),
      },
      {
        'key': 'world_info',
        'label': 'Lore',
        'tokens': parts['world_info'] ?? 0,
        'color': const Color(0xFFFFB020),
      },
      {
        'key': 'author_note',
        'label': 'AN',
        'tokens': parts['author_note'] ?? 0,
        'color': const Color(0xFFFF6B6B),
      },
      {
        'key': 'user_input',
        'label': 'Input',
        'tokens': parts['user_input'] ?? 0,
        'color': const Color(0xFF3FB950),
      },
      {
        'key': 'others',
        'label': 'Other',
        'tokens': parts['others'] ?? 0,
        'color': const Color(0xFF98A1B3),
      },
    ];
    return segments
        .where((item) => (item['tokens'] as int) > 0)
        .map((item) {
          final tokens = item['tokens'] as int;
          return {
            ...item,
            'ratio': total > 0 ? tokens / total : 0.0,
          };
        })
        .toList(growable: false);
  }

  String _formatCompactTokenCount(int count) {
    if (count >= 1000000) {
      final value = count / 1000000;
      return value >= 10
          ? '${value.toStringAsFixed(0)}M'
          : '${value.toStringAsFixed(1)}M';
    }
    if (count >= 1000) {
      final value = count / 1000;
      return value >= 10
          ? '${value.toStringAsFixed(0)}K'
          : '${value.toStringAsFixed(1)}K';
    }
    return '$count';
  }

  double _contextUsagePercent(int totalTokens, int maxContext) {
    if (maxContext <= 0) return 0.0;
    return (totalTokens / maxContext) * 100;
  }

  double _contextUsageProgress(int totalTokens, int maxContext) {
    if (maxContext <= 0) return 0.0;
    return (totalTokens / maxContext).clamp(0.0, 1.0).toDouble();
  }

  Widget _buildSegmentBar(
    List<Map<String, dynamic>> segments, {
    double height = 8,
  }) {
    if (segments.isEmpty) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: height,
        child: Row(
          children: segments.map((segment) {
            final ratio = (segment['ratio'] as double?) ?? 0.0;
            final color = segment['color'] as Color;
            return Expanded(
              flex: ((ratio * 1000).round()).clamp(1, 1000),
              child: Container(color: color),
            );
          }).toList(growable: false),
        ),
      ),
    );
  }

  Widget _contextLegendChip({
    required String label,
    required int tokens,
    required Color color,
    double? ratio,
  }) {
    final percent =
        ratio == null
            ? null
            : (ratio * 100).toStringAsFixed(ratio >= 0.1 ? 0 : 1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            percent == null
                ? '$label · ${_formatCompactTokenCount(tokens)}'
                : '$label · ${_formatCompactTokenCount(tokens)} · $percent%',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickReplyBar() {
    final items = _quickReplies();
    return SizedBox(
      height: 40,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, index) {
          if (index == items.length) {
            return _buildContextStatusTag();
          }
          final item = items[index];
          return ActionChip(
            visualDensity: VisualDensity.compact,
            label: Text(item['label'] ?? ''),
            onPressed:
                _isSending
                    ? null
                    : () => _sendSilentQuickReply(item),
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemCount: items.length + 1,
      ),
    );
  }

  Widget _buildContextStatusTag() {
    final debug = _latestPromptDebug;
    if (debug == null) {
      return ActionChip(
        visualDensity: VisualDensity.compact,
        avatar: const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: const Text('Context'),
        onPressed: null,
      );
    }
    final usage = debug.contextUsage;
    final totalTokens = (usage['totalTokens'] as num?)?.toInt() ?? 0;
    final maxContext = (usage['maxContext'] as num?)?.toInt() ?? 0;
    final trimPlan =
        usage['meta'] is Map
            ? (((usage['meta'] as Map)['trimPlan'] as Map?) ??
                const <String, dynamic>{})
            : const <String, dynamic>{};
    final overLimit = (trimPlan['overLimitTokens'] as num?)?.toInt() ?? 0;
    final percent = _contextUsagePercent(totalTokens, maxContext);
    final progress = _contextUsageProgress(totalTokens, maxContext);
    final color =
        overLimit > 0
            ? Colors.red
            : percent >= 85
            ? Colors.orange
            : percent >= 65
            ? Colors.amber
            : Colors.green;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _showContextUsageSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: Stack(
                children: [
                  CircularProgressIndicator(
                    value: 1,
                    strokeWidth: 2,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                  ),
                  CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${_formatCompactTokenCount(totalTokens)} / ${_formatCompactTokenCount(maxContext)}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '(${percent.toStringAsFixed(0)}%)',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color.withValues(alpha: 0.8),
                fontSize: 10,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.info_outline,
              size: 12,
              color: color.withValues(alpha: 0.65),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContextStatusBar() {
    return const SizedBox.shrink();
  }

  Future<void> _showContextUsageSheet() async {
    if (_isLoadingDebug) return;
    setState(() => _isLoadingDebug = true);
    try {
      final debug = await context.read<TavernStore>().getPromptDebug(_chat.id);
      if (!mounted) return;

      final contextUsage = debug.contextUsage;
      final totalTokens = (contextUsage['totalTokens'] as num?)?.toInt() ?? 0;
      final maxContext = (contextUsage['maxContext'] as num?)?.toInt() ?? 0;
      final percent = _contextUsagePercent(totalTokens, maxContext);
      final progress = _contextUsageProgress(totalTokens, maxContext);
      final trimPlan = contextUsage['meta'] is Map
          ? (((contextUsage['meta'] as Map)['trimPlan'] as Map?) ?? const <String, dynamic>{})
          : const <String, dynamic>{};
      final overLimit = (trimPlan['overLimitTokens'] as num?)?.toInt() ?? 0;
      final summarySettings = _chat.metadata['summarySettings'] is Map
          ? Map<String, dynamic>.from(_chat.metadata['summarySettings'] as Map)
          : const <String, dynamic>{};
      final injectLatestOnly = summarySettings['injectLatestOnly'] != false;
      final useRecentAfterLatest = summarySettings['useRecentMessagesAfterLatest'] != false;
      final summaryBlocks = debug.blocks.where((b) => (b['kind'] ?? '').toString() == 'summary').length;
      final matchedLore = debug.matchedWorldbookEntries.length;
      final rejectedLore = debug.rejectedWorldbookEntries.length;
      final suggestedCuts = ((trimPlan['suggestedCuts'] as List?) ?? const <dynamic>[]).whereType<Map>().length;
      final color = overLimit > 0
          ? Colors.red
          : percent >= 85
              ? Colors.orange
              : percent >= 65
                  ? Colors.amber
                  : Colors.green;
      final segments = _contextSegments(debug);
      final rawComponents = ((contextUsage['components'] as List?) ?? (contextUsage['breakdown'] as List?) ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);

      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.72,
            maxChildSize: 0.92,
            minChildSize: 0.42,
            builder: (context, controller) => ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text('上下文使用', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  '这里优先展示最近一次真实生成所使用的上下文统计；若你打开完整 Debug，再按当前配置即时重算。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(99),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 8,
                                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                                valueColor: AlwaysStoppedAnimation<Color>(color),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            maxContext > 0 ? '${percent.toStringAsFixed(0)}%' : '-',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: color,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _infoRow('总 Token', '$totalTokens'),
                      _infoRow('最大上下文', '$maxContext'),
                      _infoRow('超限 Token', '$overLimit'),
                      _infoRow('建议裁剪数', '$suggestedCuts'),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _sectionCard(
                  title: '当前策略 / 状态',
                  subtitle: '仿照 Native，把总量之外的结构也拆开看。',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _summaryMetaChip('摘要', summaryBlocks > 0 ? (injectLatestOnly ? '最新摘要接管' : '多摘要接管') : '未接管'),
                          _summaryMetaChip('历史模式', useRecentAfterLatest ? '摘要后 recent' : '全历史'),
                          _summaryMetaChip('Lore', '$matchedLore 命中 / $rejectedLore 拦截'),
                          _summaryMetaChip('裁剪', overLimit > 0 ? '超限 $overLimit tok' : '无超限'),
                          _summaryMetaChip('模式', _chat.authorNoteEnabled ? 'AN 开' : 'AN 关'),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildSegmentBar(segments),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: segments
                            .map(
                              (segment) => _contextLegendChip(
                                label: segment['label'] as String,
                                tokens: segment['tokens'] as int,
                                color: segment['color'] as Color,
                                ratio: segment['ratio'] as double?,
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _sectionCard(
                  title: 'Context 明细',
                  subtitle: rawComponents.isEmpty ? '这次没有拿到可拆分组件。' : '当前 prompt 里各部分实际占用。',
                  child: rawComponents.isEmpty
                      ? Text(
                          '暂无 context component。',
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      : Column(
                          children: rawComponents.map((item) {
                            final label = (item['name'] ?? item['label'] ?? item['component'] ?? 'component').toString();
                            final kind = (item['meta'] is Map ? ((item['meta'] as Map)['kind'] ?? '') : '').toString();
                            final tokens = (item['tokenCount'] as num?)?.toInt() ?? (item['tokens'] as num?)?.toInt() ?? (item['estimatedTokens'] as num?)?.toInt() ?? 0;
                            final percent = totalTokens > 0 ? (tokens / totalTokens * 100) : 0.0;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          label,
                                          style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                      Text(
                                        '${_formatCompactTokenCount(tokens)} · ${percent.toStringAsFixed(percent >= 10 ? 0 : 1)}%',
                                        style: Theme.of(context).textTheme.labelMedium,
                                      ),
                                    ],
                                  ),
                                  if (kind.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      kind,
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          }).toList(growable: false),
                        ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.auto_awesome_motion_outlined),
                  title: const Text('上下文 / 摘要策略'),
                  subtitle: const Text('自动总结、注入模式、recent 历史保留'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _editContextSummarySettings();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.auto_stories_outlined),
                  title: const Text('剧情摘要'),
                  subtitle: Text(_summaryItems().isEmpty ? '当前还没有摘要' : '查看已生成的剧情摘要'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _showSummariesSheet();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bug_report_outlined),
                  title: const Text('Prompt Debug'),
                  subtitle: const Text('查看完整 prompt / worldbook / runtime 明细'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _showPromptDebug();
                  },
                ),
              ],
            ),
          ),
        ),
      );
    } catch (exc) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载上下文使用失败：$exc')),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoadingDebug = false);
      }
    }
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

  Widget _intStepper(
    BuildContext context, {
    required String label,
    required int value,
    required int min,
    required int max,
    int step = 1,
    required ValueChanged<int> onChanged,
  }) {
    final effectiveStep = step <= 0 ? 1 : step;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.titleSmall),
          ),
          IconButton(
            onPressed: value <= min ? null : () => onChanged((value - effectiveStep).clamp(min, max)),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            onPressed: value >= max ? null : () => onChanged((value + effectiveStep).clamp(min, max)),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
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
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          children: [
            Text('会话设置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              '聊天页只保留聊天本身；不常改的能力都收进这里。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.account_box_outlined),
              title: const Text('角色页'),
              subtitle: const Text('查看角色详情、问候语、导入内容'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).pop();
                _openCharacterProfilePage();
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tune_outlined),
              title: const Text('生成配置'),
              subtitle: Text(
                _selectedPresetId == null || _selectedPresetId!.isEmpty
                    ? '当前跟随默认 Preset'
                    : '当前 Preset 已单独指定',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).pop();
                _showGenerationConfigSheet(presets: presets, messenger: messenger);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.analytics_outlined),
              title: const Text('上下文统计'),
              subtitle: const Text('Context usage、摘要状态、裁剪情况'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).pop();
                _showContextUsageSheet();
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.auto_stories_outlined),
              title: const Text('剧情摘要'),
              subtitle: Text(_summaryItems().isEmpty ? '当前还没有摘要' : '查看已生成摘要与闭环状态'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).pop();
                _showSummariesSheet();
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('高级 / Prompt 调试'),
              subtitle: const Text('Prompt Debug、WorldBook runtime、原始明细'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).pop();
                _showAdvancedToolsSheet();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showGenerationConfigSheet({
    required List<TavernPreset> presets,
    required ScaffoldMessengerState messenger,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          children: [
            Text('生成配置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              '把常改项收成二级菜单，不在聊天主界面常驻。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: presets.any((item) => item.id == _selectedPresetId) ? _selectedPresetId : null,
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
                    child: Text(preset.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: presets.isEmpty
                  ? null
                  : (value) async {
                      final next = (value ?? '').isEmpty ? null : value;
                      Navigator.of(context).pop();
                      setState(() {
                        _selectedPresetId = next;
                      });
                      try {
                        final updated = await this.context.read<TavernStore>().updateChat(
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
                          SnackBar(content: Text('保存会话 Preset 失败：$exc')),
                        );
                      }
                    },
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.auto_awesome_motion_outlined),
              title: const Text('上下文 / 摘要策略'),
              subtitle: const Text('自动总结、注入模式、recent 历史保留'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).pop();
                _editContextSummarySettings();
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sticky_note_2_outlined),
              title: const Text('Author Note'),
              subtitle: Text(_chat.authorNoteEnabled ? '已启用 · depth ${_chat.authorNoteDepth}' : '未启用'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).pop();
                _editAuthorNote();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAdvancedToolsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          children: [
            Text('高级 / 调试', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              '这些都不该打断聊天，只在你需要时再进。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Prompt Debug'),
              subtitle: const Text('完整 prompt / worldbook / runtime 明细'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).pop();
                _showPromptDebug();
              },
            ),
          ],
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

  Future<void> _editContextSummarySettings() async {
    final currentMetadata = Map<String, dynamic>.from(_chat.metadata);
    final current = currentMetadata['summarySettings'] is Map
        ? Map<String, dynamic>.from(currentMetadata['summarySettings'] as Map)
        : <String, dynamic>{};
    bool enabled = current['enabled'] != false;
    bool injectLatestOnly = current['injectLatestOnly'] != false;
    bool useRecentAfterLatest = current['useRecentMessagesAfterLatest'] != false;
    double threshold = ((current['threshold'] as num?)?.toDouble() ?? 0.8).clamp(0.5, 0.98);
    int minMessages = (current['minMessages'] as num?)?.toInt() ?? 8;
    int minNewMessages = (current['minNewMessages'] as num?)?.toInt() ?? 4;
    int minNewTokens = (current['minNewTokens'] as num?)?.toInt() ?? 192;
    bool saving = false;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
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
                  Text('上下文 / 摘要策略', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动总结'),
                    subtitle: const Text('只在 assistant 完成后触发，影响下一轮'),
                    value: enabled,
                    onChanged: (value) => setModalState(() => enabled = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('仅注入最新摘要'),
                    subtitle: const Text('关闭后可让更老的摘要也参与 prompt'),
                    value: injectLatestOnly,
                    onChanged: (value) => setModalState(() => injectLatestOnly = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('仅保留最新摘要后的 recent history'),
                    subtitle: const Text('开启后，历史主要由 summary + recent 组成'),
                    value: useRecentAfterLatest,
                    onChanged: (value) => setModalState(() => useRecentAfterLatest = value),
                  ),
                  const SizedBox(height: 8),
                  Text('总结触发阈值：${threshold.toStringAsFixed(2)}'),
                  Slider(
                    value: threshold,
                    min: 0.5,
                    max: 0.98,
                    divisions: 24,
                    label: threshold.toStringAsFixed(2),
                    onChanged: (value) => setModalState(() => threshold = value),
                  ),
                  _intStepper(
                    context,
                    label: '最少历史消息数',
                    value: minMessages,
                    min: 2,
                    max: 64,
                    onChanged: (value) => setModalState(() => minMessages = value),
                  ),
                  _intStepper(
                    context,
                    label: '最少新增消息数',
                    value: minNewMessages,
                    min: 1,
                    max: 32,
                    onChanged: (value) => setModalState(() => minNewMessages = value),
                  ),
                  _intStepper(
                    context,
                    label: '最少新增 Token',
                    value: minNewTokens,
                    min: 32,
                    max: 2048,
                    step: 32,
                    onChanged: (value) => setModalState(() => minNewTokens = value),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '说明：本轮生成使用“本轮开始前的上下文状态 + 当前输入”。新 summary 和 worldbook runtime 更新会在回复完成后写回，并影响下一轮。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.45),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: saving ? null : () => Navigator.of(context).pop(false),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: saving
                            ? null
                            : () async {
                                setModalState(() => saving = true);
                                try {
                                  final nextMetadata = Map<String, dynamic>.from(currentMetadata);
                                  nextMetadata['summarySettings'] = {
                                    ...current,
                                    'enabled': enabled,
                                    'injectLatestOnly': injectLatestOnly,
                                    'useRecentMessagesAfterLatest': useRecentAfterLatest,
                                    'threshold': double.parse(threshold.toStringAsFixed(2)),
                                    'minMessages': minMessages,
                                    'minNewMessages': minNewMessages,
                                    'minNewTokens': minNewTokens,
                                  };
                                  final updated = await context.read<TavernStore>().updateChat(
                                    chatId: _chat.id,
                                    payload: {'metadata': nextMetadata},
                                  );
                                  if (!context.mounted) return;
                                  setState(() {
                                    _chat = updated;
                                  });
                                  unawaited(_refreshContextState());
                                  Navigator.of(context).pop(true);
                                } catch (exc) {
                                  if (!context.mounted) return;
                                  setModalState(() => saving = false);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('保存上下文策略失败：$exc')),
                                  );
                                }
                              },
                        child: saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
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

    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('上下文 / 摘要策略已更新')),
      );
    }
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
                    length: 6,
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
                              Text(
                                '这里会按当前配置实时重算。想看真正要喂给模型的内容，先看「Final Prompt」。',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _debugChip(
                                    'World Info 命中',
                                    '${debug.summary['matchedWorldbookCount'] ?? debug.matchedWorldbookEntries.length}',
                                  ),
                                  _debugChip(
                                    'World Info 拒绝',
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
                            Tab(text: 'Details'),
                            Tab(text: 'Final Prompt'),
                            Tab(text: 'Source Blocks'),
                            Tab(text: 'World Info'),
                            Tab(text: 'Runtime Vars'),
                            Tab(text: 'Macros'),
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
                              _buildDebugMacrosTab(debug),
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
        if (debug.resolvedPersona.isNotEmpty) ...[
          Text(
            'Resolved Persona',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          SelectableText(debug.resolvedPersona.toString()),
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

  Widget _buildDebugMacrosTab(TavernPromptDebug debug) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Macro Effects', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (debug.macroEffects.isEmpty)
          const Text('无副作用宏提交')
        else
          ...debug.macroEffects.map(
            (item) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(item.toString()),
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text('Unknown Macros', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (debug.unknownMacros.isEmpty)
          const Text('无 unknown macros')
        else
          ...debug.unknownMacros.map(
            (item) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(item),
              ),
            ),
          ),
      ],
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

class _TavernJsonMapEditorPage extends StatefulWidget {
  const _TavernJsonMapEditorPage({
    required this.title,
    required this.initialValue,
    required this.onSave,
  });

  final String title;
  final Map<String, dynamic> initialValue;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> value) onSave;

  @override
  State<_TavernJsonMapEditorPage> createState() => _TavernJsonMapEditorPageState();
}

class _TavernJsonMapEditorPageState extends State<_TavernJsonMapEditorPage> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(widget.initialValue),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving ? const Text('保存中...') : const Text('保存'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _controller,
          expands: true,
          maxLines: null,
          minLines: null,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '{\n  "favor": 3\n}',
          ),
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      ),
    );
  }

  Future<void> _save() async {
    try {
      final decoded = jsonDecode(_controller.text);
      if (decoded is! Map) {
        throw const FormatException('必须是 JSON object');
      }
      setState(() => _saving = true);
      await widget.onSave(Map<String, dynamic>.from(decoded));
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (exc) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$exc')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
