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

import '../../../../app/theme.dart';

class TavernChatScreen extends StatefulWidget {
  const TavernChatScreen({
    super.key,
    required this.chat,
    required this.character,
    this.embedded = false,
    this.onClose,
  });

  final TavernChat chat;
  final TavernCharacter character;
  final bool embedded;
  final VoidCallback? onClose;

  @override
  State<TavernChatScreen> createState() => _TavernChatScreenState();
}

enum _StyledTextSegmentKind { plain, narration, dialogue }

class _StyledTextSegment {
  const _StyledTextSegment(this.text)
    : kind = _StyledTextSegmentKind.plain,
      openMarker = '',
      closeMarker = '';

  const _StyledTextSegment.styled({
    required this.kind,
    required this.text,
    required this.openMarker,
    required this.closeMarker,
  });

  final _StyledTextSegmentKind kind;
  final String text;
  final String openMarker;
  final String closeMarker;

  bool get isNarration => kind == _StyledTextSegmentKind.narration;
  bool get isDialogue => kind == _StyledTextSegmentKind.dialogue;
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
      placement: ((json['placement'] as List?) ?? const <dynamic>[]).toList(
        growable: false,
      ),
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
    final hasAiOutput =
        placements.contains(1) || placements.contains('aiOutput');
    if (!hasAiOutput) return false;
    if (markdownOnly && !isMarkdown) return false;
    if (promptOnly) return false;
    if (depth != null) {
      if (minDepth != null && minDepth! >= -1 && depth < minDepth!) {
        return false;
      }
      if (maxDepth != null && maxDepth! >= 0 && depth > maxDepth!) {
        return false;
      }
    }
    return true;
  }
}

enum _AssistantRenderSegmentKind {
  markdown,
  narration,
  inlineStyled,
  complexHtml,
}

class _AssistantRenderSegment {
  const _AssistantRenderSegment({required this.kind, required this.content});

  final _AssistantRenderSegmentKind kind;
  final String content;
}

class _DebugDisplayItem {
  const _DebugDisplayItem({
    required this.title,
    required this.subtitle,
    required this.content,
    required this.kind,
  });

  final String title;
  final String? subtitle;
  final String content;
  final String kind;
}

class _PromptDebugBlockGroups {
  const _PromptDebugBlockGroups({
    required this.movableSections,
    required this.worldInfoInjections,
    required this.specialInjections,
    required this.otherBlocks,
  });

  final List<Map<String, dynamic>> movableSections;
  final List<Map<String, dynamic>> worldInfoInjections;
  final List<Map<String, dynamic>> specialInjections;
  final List<Map<String, dynamic>> otherBlocks;
}

class _PromptDebugMessageGroups {
  const _PromptDebugMessageGroups({
    required this.promptLayers,
    required this.history,
    required this.currentInput,
    required this.otherMessages,
  });

  final List<_DebugDisplayItem> promptLayers;
  final List<_DebugDisplayItem> history;
  final List<_DebugDisplayItem> currentInput;
  final List<_DebugDisplayItem> otherMessages;
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
  const root = document.getElementById('alicechat-inline-root');
  const doc = document.documentElement;
  const body = document.body;
  if (root) {
    return Math.max(
      root.scrollHeight || 0,
      root.offsetHeight || 0,
      root.getBoundingClientRect?.()?.height || 0,
    );
  }
  if (!doc || !body) return 320;
  return Math.max(
    body.scrollHeight || 0,
    body.offsetHeight || 0,
    body.getBoundingClientRect?.()?.height || 0,
    doc.scrollHeight || 0,
    doc.offsetHeight || 0,
    doc.getBoundingClientRect?.()?.height || 0
  );
})()
''';

  static const String _observerBootstrapScript = '''
(() => {
  if (window.__alicechatHeightObserverInstalled) return;
  window.__alicechatHeightObserverInstalled = true;

  const measure = () => {
    const root = document.getElementById('alicechat-inline-root');
    if (root) {
      return Math.max(
        root.scrollHeight || 0,
        root.offsetHeight || 0,
        root.getBoundingClientRect?.()?.height || 0,
      );
    }
    const doc = document.documentElement;
    const body = document.body;
    if (!doc || !body) return 0;
    return Math.max(
      body.scrollHeight || 0,
      body.offsetHeight || 0,
      body.getBoundingClientRect?.()?.height || 0,
      doc.scrollHeight || 0,
      doc.offsetHeight || 0,
      doc.getBoundingClientRect?.()?.height || 0,
    );
  };

  const notify = () => {
    try {
      const height = measure();
      if (!height) return;
      if (window.HeightObserver && typeof window.HeightObserver.postMessage === 'function') {
        window.HeightObserver.postMessage(String(height));
      }
    } catch (_) {}
  };

  const target = document.getElementById('alicechat-inline-root') || document.body;
  if (target) {
    new ResizeObserver(() => notify()).observe(target);
    new MutationObserver(() => notify()).observe(target, {
      childList: true,
      subtree: true,
      characterData: true,
      attributes: true,
    });
  }

  window.addEventListener('load', notify);
  setTimeout(notify, 60);
  setTimeout(notify, 220);
  setTimeout(notify, 600);
  notify();
})();
''';

  late final WebViewController _controller;
  late double _height;

  @override
  void initState() {
    super.initState();
    _height = widget.initialHeight;
    _controller =
        WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.transparent)
          ..addJavaScriptChannel(
            'HeightObserver',
            onMessageReceived: (message) {
              final nextHeight = _parseHeightResult(message.message);
              if (!mounted || nextHeight == null) return;
              final clamped = nextHeight.clamp(260, 1600).toDouble();
              if ((clamped - _height).abs() < 4) return;
              setState(() {
                _height = clamped;
              });
            },
          )
          ..setNavigationDelegate(
            NavigationDelegate(
              onPageFinished: (_) async {
                await _installHeightObservers();
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

  Future<void> _installHeightObservers() async {
    try {
      await _controller.runJavaScript(_observerBootstrapScript);
    } catch (_) {
      // Ignore observer injection failures and keep manual probes.
    }
  }

  Future<void> _syncHeight() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        _heightProbeScript,
      );
      final nextHeight = _parseHeightResult(raw);
      if (!mounted || nextHeight == null) return;
      final clamped = nextHeight.clamp(260, 1600).toDouble();
      if ((clamped - _height).abs() < 4) return;
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
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.10),
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
                      _profileBlock(
                        context,
                        'Description',
                        character.description,
                      ),
                      _profileBlock(
                        context,
                        'Personality',
                        character.personality,
                      ),
                      _profileBlock(context, 'Scenario', character.scenario),
                      _profileBlock(
                        context,
                        'First Message',
                        character.firstMessage,
                      ),
                      _profileBlock(
                        context,
                        'Example Dialogues',
                        character.exampleDialogues,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _profileSectionCard(
                    context,
                    title: 'Prompt / Notes',
                    icon: Icons.psychology_alt_outlined,
                    children: [
                      _profileBlock(
                        context,
                        'System Prompt',
                        character.systemPrompt,
                      ),
                      _profileBlock(
                        context,
                        'Post-History Instructions',
                        character.postHistoryInstructions,
                      ),
                      _profileBlock(
                        context,
                        'Creator Notes',
                        character.creatorNotes,
                      ),
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
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.5),
                      width: 2,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 18,
                        offset: Offset(0, 10),
                      ),
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
                        style: Theme.of(
                          context,
                        ).textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          shadows: const [
                            Shadow(color: Colors.black45, blurRadius: 10),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        character.scenario.isNotEmpty
                            ? character.scenario
                            : (character.description.isNotEmpty
                                ? character.description
                                : '查看角色设定与导入内容'),
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
    final visible = children
        .where((w) => w is! SizedBox)
        .toList(growable: false);
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
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
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
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _TavernChatScreenState extends State<TavernChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _isSendingNotifier = ValueNotifier(false);
  final ValueNotifier<TavernPromptDebug?> _latestPromptDebugNotifier =
      ValueNotifier<TavernPromptDebug?>(null);
  final Map<String, List<_AssistantRenderSegment>>
  _assistantRenderSegmentCache = <String, List<_AssistantRenderSegment>>{};
  bool _isLoading = true;
  bool _isRefreshing = false;
  int _sendEpoch = 0;
  List<Map<String, String>> _quickReplyConfigs =
      OpenClawSettingsStore.defaultTavernQuickReplies();
  bool _isLoadingDebug = false;
  bool _isLoadingContextState = false;
  bool _isGeneratingSceneImage = false;
  bool _didInitialScroll = false;
  bool _stickToBottom = true;
  String? _error;
  String? _serverBaseUrl;
  String? _selectedPresetId;
  String? _streamingAssistantMessageId;
  TavernMessage? _streamingAssistantMessage;
  final Set<String> _expandedThoughtMessageIds = <String>{};
  List<TavernMessage> _messages = const <TavernMessage>[];
  late TavernCharacter _character;
  late TavernChat _chat;

  bool get _isSending => _isSendingNotifier.value;
  TavernPromptDebug? get _latestPromptDebug => _latestPromptDebugNotifier.value;

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
    _isSendingNotifier.dispose();
    _latestPromptDebugNotifier.dispose();
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
        _assistantRenderSegmentCache.clear();
        _latestPromptDebugNotifier.value = cached.promptDebug;
        setState(() {
          _serverBaseUrl = settings.baseUrl.trim().replaceFirst(
            RegExp(r'/+$'),
            '',
          );
          _quickReplyConfigs = quickReplies;
          _chat = cached.chat ?? _chat;
          _character = cached.character ?? _character;
          _messages = cached.messages;
          _streamingAssistantMessage = null;
          _streamingAssistantMessageId = null;
          _selectedPresetId = _chat.presetId.isNotEmpty ? _chat.presetId : null;
          _isLoading = false;
          _isRefreshing = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scrollToBottom(animated: false, force: true);
          }
        });
        unawaited(_refreshFromServer(includeCharacter: false));
        return;
      }

      final messages = await store.listChatMessages(_chat.id, limit: 5);
      if (store.presets.isEmpty) {
        await store.loadPresets(notify: false);
      }
      if (!mounted) return;
      _assistantRenderSegmentCache.clear();
      setState(() {
        _serverBaseUrl = settings.baseUrl.trim().replaceFirst(
          RegExp(r'/+$'),
          '',
        );
        _quickReplyConfigs = quickReplies;
        _messages = messages;
        _streamingAssistantMessage = null;
        _streamingAssistantMessageId = null;
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

  Future<void> _refreshFromServer({bool includeCharacter = false}) async {
    final store = context.read<TavernStore>();
    try {
      final shouldKeepAtBottom = _stickToBottom || !_didInitialScroll;
      final futures = <Future<dynamic>>[
        store.getChat(_chat.id),
        store.listChatMessages(_chat.id, limit: 5),
      ];
      if (store.presets.isEmpty) {
        futures.add(store.loadPresets(notify: false));
      }
      if (includeCharacter) {
        futures.insert(0, store.getCharacter(_chat.characterId));
      }
      final results = await Future.wait(futures);
      if (!mounted) return;

      TavernCharacter character = _character;
      late final TavernChat chat;
      late final List<TavernMessage> messages;
      if (includeCharacter) {
        character = results[0] as TavernCharacter;
        chat = results[1] as TavernChat;
        messages = results[2] as List<TavernMessage>;
      } else {
        chat = results[0] as TavernChat;
        messages = results[1] as List<TavernMessage>;
      }

      _assistantRenderSegmentCache.clear();
      setState(() {
        _character = character;
        _chat = chat;
        _messages = messages;
        _streamingAssistantMessage = null;
        _streamingAssistantMessageId = null;
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
    final content = Container(
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
        color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.9),
        child: Column(
          children: [
            if (widget.embedded) _buildEmbeddedHeader(context),
            Expanded(child: _buildBody(context)),
            _buildContextStatusBar(),
            _buildQuickReplyBar(),
            if (_isRefreshing) const LinearProgressIndicator(minHeight: 2),
            _buildComposer(),
          ],
        ),
      ),
    );

    if (widget.embedded) {
      return content;
    }

    return Scaffold(
      appBar: AppBar(
        title: _buildHeaderTitle(context),
        actions: _buildHeaderActions(),
      ),
      body: content,
    );
  }

  List<Widget> _buildHeaderActions() {
    return [
      IconButton(
        tooltip: '场景图',
        onPressed: _showSceneImageSheet,
        icon:
            _isGeneratingSceneImage
                ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(Icons.image_outlined),
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
      if (widget.embedded && widget.onClose != null)
        IconButton(
          tooltip: '关闭聊天面板',
          onPressed: widget.onClose,
          icon: const Icon(Icons.close),
        ),
    ];
  }

  Widget _buildHeaderTitle(BuildContext context) {
    return Row(
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
    );
  }

  Widget _buildEmbeddedHeader(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            Expanded(child: _buildHeaderTitle(context)),
            ..._buildHeaderActions(),
          ],
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
    final hasStreamingAssistant = _streamingAssistantMessage != null;
    final visibleMessageCount =
        _messages.length + (hasStreamingAssistant ? 1 : 0);
    if (visibleMessageCount == 0) {
      final greeting =
          _character.firstMessage.isNotEmpty
              ? _character.firstMessage
              : '还没有消息，开始聊吧。';
      return ListView(
        controller: _scrollController,
        reverse: true,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        children: [_buildEphemeralGreetingBubble(greeting)],
      );
    }
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: visibleMessageCount,
      itemBuilder: (context, index) {
        final message =
            hasStreamingAssistant && index == 0
                ? _streamingAssistantMessage!
                : _messages[_messages.length -
                    1 -
                    index -
                    (hasStreamingAssistant ? 1 : 0)];
        final isUser = message.role == 'user';
        final bubbleMaxWidth = MediaQuery.of(context).size.width * 0.72;
        final bubble = ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: bubbleMaxWidth < 560 ? bubbleMaxWidth : 560,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: isUser ? const Color(0xFF7C4DFF) : Colors.white,
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
                    isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
                  if (!isUser && message.thought.trim().isNotEmpty) ...[
                    _buildThoughtBlock(message),
                    const SizedBox(height: 8),
                  ],
                  _buildMessageContent(message.content, isUser: isUser),
                  if (message.createdAt != null ||
                      (message.metadata['requestId'] ?? '')
                          .toString()
                          .isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if ((message.metadata['requestId'] ?? '')
                            .toString()
                            .isNotEmpty)
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

  Widget _buildThoughtBlock(TavernMessage message) {
    final thought = message.thought.trim();
    if (thought.isEmpty) return const SizedBox.shrink();
    final preset = _resolveSelectedPreset();
    if (preset?.showThinking != true) return const SizedBox.shrink();
    final expanded = _expandedThoughtMessageIds.contains(message.id);
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: const Color(0xFF7A7F8C),
      fontSize: desktopContentFontSize(
        (Theme.of(context).textTheme.bodySmall?.fontSize ?? 12) - 0.2,
      ),
      height: 1.45,
      fontStyle: FontStyle.italic,
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F7FB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE9E7F2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              setState(() {
                if (expanded) {
                  _expandedThoughtMessageIds.remove(message.id);
                } else {
                  _expandedThoughtMessageIds.add(message.id);
                }
              });
            },
            child: Row(
              children: [
                const Icon(
                  Icons.psychology_alt_outlined,
                  size: 14,
                  color: Color(0xFF9AA0AE),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Thinking',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: const Color(0xFF8C92A0),
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: const Color(0xFFA0A6B4),
                ),
              ],
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.fromLTRB(2, 0, 0, 0),
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: Color(0xFFD8DDE8), width: 2),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: SelectableText(thought, style: textStyle),
              ),
            ),
          ],
        ],
      ),
    );
  }

  TavernPreset? _resolveSelectedPreset() {
    final store = context.read<TavernStore>();
    final effectivePresetId = (_selectedPresetId ?? _chat.presetId).trim();
    TavernPreset? preset;
    if (effectivePresetId.isNotEmpty) {
      for (final item in store.presets) {
        if (item.id == effectivePresetId) {
          preset = item;
          break;
        }
      }
    }
    preset ??= store.presets.isNotEmpty ? store.presets.first : null;
    return preset;
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
              builder:
                  (context, value, child) => Opacity(
                    opacity: value.clamp(0, 1),
                    child: Transform.scale(
                      scale: value,
                      alignment: Alignment.topLeft,
                      child: child,
                    ),
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
                    border: Border.all(color: const Color(0xFFE9E2FF)),
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
                                style: Theme.of(
                                  context,
                                ).textTheme.labelMedium?.copyWith(
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
          fontSize: desktopContentFontSize(
            Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14,
          ),
          height: 1.35,
          fontWeight: FontWeight.w500,
        ),
        strong: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: textColor,
          fontSize: desktopContentFontSize(
            Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14,
          ),
          fontWeight: FontWeight.w700,
        ),
        em: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: textColor,
          fontSize: desktopContentFontSize(
            Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14,
          ),
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
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
      return _buildMarkdownText(normalized, textColor: Colors.white);
    }

    final segments = _assistantSegmentsFor(normalized);
    if (segments.isEmpty) return const SizedBox.shrink();
    if (segments.length == 1) {
      return _buildAssistantSegment(segments.first);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          _buildAssistantSegment(segments[i]),
          if (i != segments.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildAssistantSegment(_AssistantRenderSegment segment) {
    switch (segment.kind) {
      case _AssistantRenderSegmentKind.complexHtml:
        return _buildInlineHtmlContent(segment.content);
      case _AssistantRenderSegmentKind.narration:
        return _buildNarrationText(segment.content);
      case _AssistantRenderSegmentKind.inlineStyled:
        return _buildInlineStyledRichText(segment.content);
      case _AssistantRenderSegmentKind.markdown:
        return _buildMarkdownText(
          segment.content,
          textColor: const Color(0xFF1F2430),
        );
    }
  }

  List<_AssistantRenderSegment> _assistantSegmentsFor(String normalized) {
    final key = '${_character.id}\u0000$normalized';
    final cached = _assistantRenderSegmentCache[key];
    if (cached != null) {
      return cached;
    }
    final computed = List<_AssistantRenderSegment>.unmodifiable(
      _buildAssistantRenderSegments(normalized),
    );
    if (_assistantRenderSegmentCache.length >= 200) {
      _assistantRenderSegmentCache.remove(
        _assistantRenderSegmentCache.keys.first,
      );
    }
    _assistantRenderSegmentCache[key] = computed;
    return computed;
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
                fontSize: desktopContentFontSize(
                  Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14,
                ),
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
            TextSpan(
              text: inner,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: contentColor,
                fontSize: desktopContentFontSize(
                  Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14,
                ),
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w500,
                height: 1.45,
              ),
            ),
            TextSpan(
              text: close,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: bracketColor,
                fontSize: desktopContentFontSize(
                  Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14,
                ),
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

  Widget _buildInlineStyledRichText(String text) {
    final baseStyle =
        Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: const Color(0xFF1F2430),
          fontSize: desktopContentFontSize(
            Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14,
          ),
          height: 1.4,
          fontWeight: FontWeight.w500,
        ) ??
        TextStyle(
          color: const Color(0xFF1F2430),
          fontSize: desktopContentFontSize(14),
          height: 1.4,
          fontWeight: FontWeight.w500,
        );
    const narrationBracketColor = Color(0xFFB8A7E8);
    const narrationContentColor = Color(0xFF7B6D9D);
    const dialogueQuoteColor = Color(0xFFE0A0B8);
    const dialogueContentColor = Color(0xFF8D4F68);
    final spans = <InlineSpan>[];
    for (final segment in _parseStyledTextSegments(text)) {
      if (segment.kind == _StyledTextSegmentKind.plain) {
        spans.add(TextSpan(text: segment.text, style: baseStyle));
        continue;
      }
      if (segment.isNarration) {
        spans.add(
          TextSpan(
            text: segment.openMarker,
            style: baseStyle.copyWith(
              color: narrationBracketColor,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
        spans.add(
          TextSpan(
            text: segment.text,
            style: baseStyle.copyWith(
              color: narrationContentColor,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
        spans.add(
          TextSpan(
            text: segment.closeMarker,
            style: baseStyle.copyWith(
              color: narrationBracketColor,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
        continue;
      }
      spans.add(
        TextSpan(
          text: segment.openMarker,
          style: baseStyle.copyWith(
            color: dialogueQuoteColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      spans.add(
        TextSpan(
          text: segment.text,
          style: baseStyle.copyWith(
            color: dialogueContentColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      spans.add(
        TextSpan(
          text: segment.closeMarker,
          style: baseStyle.copyWith(
            color: dialogueQuoteColor,
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

  bool _containsStyledSegment(String text) {
    return RegExp(r'(\([^\n()]+\)|（[^\n（）]+）|“[^”\n]+”)').hasMatch(text);
  }

  bool _containsPotentialMarkdown(String text) {
    return RegExp(
      r'[`*_#\[\]~-]|^>|^\d+\.\s|^-\s',
      multiLine: true,
    ).hasMatch(text);
  }

  List<_AssistantRenderSegment> _buildAssistantRenderSegments(String text) {
    final rendered = _applyAssistantDisplayTransforms(text);
    final segments = <_AssistantRenderSegment>[];
    for (final chunk in _splitAssistantHtmlChunks(rendered)) {
      final content = chunk.trim();
      if (content.isEmpty) continue;
      if (_looksLikeComplexHtml(content)) {
        segments.add(
          _AssistantRenderSegment(
            kind: _AssistantRenderSegmentKind.complexHtml,
            content: content,
          ),
        );
        continue;
      }
      if (_isNarrationMessage(content)) {
        segments.add(
          _AssistantRenderSegment(
            kind: _AssistantRenderSegmentKind.narration,
            content: content,
          ),
        );
        continue;
      }
      if (!_containsPotentialMarkdown(content) &&
          _containsStyledSegment(content)) {
        segments.add(
          _AssistantRenderSegment(
            kind: _AssistantRenderSegmentKind.inlineStyled,
            content: content,
          ),
        );
        continue;
      }
      segments.add(
        _AssistantRenderSegment(
          kind: _AssistantRenderSegmentKind.markdown,
          content: content,
        ),
      );
    }
    return segments;
  }

  String _applyAssistantDisplayTransforms(String text) {
    var result = text.trim();
    if (result.isEmpty) return result;
    final scripts = _characterRegexScripts();
    if (scripts.isNotEmpty) {
      final sorted = [...scripts]..sort((a, b) => a.order.compareTo(b.order));
      for (final script in sorted) {
        final isMarkdown =
            script.markdownOnly || _containsPotentialMarkdown(result);
        if (!script.appliesToAiOutput(isMarkdown: isMarkdown, depth: null)) {
          continue;
        }
        result = _runRegexScript(script, result);
      }
    }
    return _unwrapFencedHtmlBlocks(result).trim();
  }

  List<String> _splitAssistantHtmlChunks(String text) {
    final chunks = <String>[];
    final pattern = RegExp(r'<html[\s\S]*?</html>', caseSensitive: false);
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        chunks.add(text.substring(cursor, match.start));
      }
      chunks.add(match.group(0) ?? '');
      cursor = match.end;
    }
    if (cursor < text.length) {
      chunks.add(text.substring(cursor));
    }
    return chunks.isEmpty ? <String>[text] : chunks;
  }

  List<_TavernRegexScript> _characterRegexScripts() {
    final raw = _character.extensions['regex_scripts'];
    if (raw is! List) return const <_TavernRegexScript>[];
    return raw
        .whereType<Map>()
        .map(
          (item) =>
              _TavernRegexScript.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
  }

  String _runRegexScript(_TavernRegexScript script, String input) {
    final regexString = _substituteRegexMacros(
      script.findRegex,
      script.substituteRegex,
    );
    final regex = _parseRegex(regexString);
    if (regex == null) return input;
    return input.replaceAllMapped(regex, (match) {
      var replacement = script.replaceString;
      replacement = replacement.replaceAll(
        RegExp(r'\{\{match\}\}', caseSensitive: false),
        match.group(0) ?? '',
      );
      final replacementLooksHtml = _looksLikeHtmlTemplate(replacement);
      for (var i = 0; i <= match.groupCount; i++) {
        final group = _filterTrimStrings(
          match.group(i) ?? '',
          script.trimStrings,
        );
        final safeGroup =
            replacementLooksHtml ? _formatHtmlReplacementText(group) : group;
        replacement = replacement.replaceAll('\$$i', safeGroup);
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
      result = result.replaceAll(
        RegExp(r'\{\{char\}\}', caseSensitive: false),
        RegExp.escape(charName),
      );
      result = result.replaceAll(
        RegExp(r'\{\{user\}\}', caseSensitive: false),
        RegExp.escape(userName),
      );
      return result;
    }
    result = result.replaceAll(
      RegExp(r'\{\{char\}\}', caseSensitive: false),
      charName,
    );
    result = result.replaceAll(
      RegExp(r'\{\{user\}\}', caseSensitive: false),
      userName,
    );
    return result;
  }

  String _resolvedUserDisplayName() {
    final personaId = _chat.personaId.trim();
    if (personaId.isNotEmpty) {
      final personas = context.read<TavernStore>().personas;
      for (final persona in personas) {
        if (persona.id == personaId && persona.name.trim().isNotEmpty) {
          return persona.name.trim();
        }
      }
    }

    final personaName = _chat.metadata['personaName'];
    if (personaName is String && personaName.trim().isNotEmpty) {
      return personaName.trim();
    }
    final personaDescription = _chat.metadata['personaDescription'];
    if (personaDescription is String && personaDescription.trim().isNotEmpty) {
      return personaDescription.trim();
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

  bool _looksLikeHtmlTemplate(String text) {
    return RegExp(
      r'<\s*(html|head|body|style|div|section|article|table|span)\b',
      caseSensitive: false,
    ).hasMatch(text);
  }

  String _formatHtmlReplacementText(String text) {
    final escaped = const HtmlEscape(HtmlEscapeMode.element).convert(text);
    return escaped
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\n\n', '<br><br>')
        .replaceAll('\n', '<br>');
  }

  String _unwrapFencedHtmlBlocks(String text) {
    return text.replaceAllMapped(
      RegExp(
        r'```(?:html)?\s*(<html[\s\S]*?</html>)\s*```',
        caseSensitive: false,
      ),
      (match) => match.group(1) ?? match.group(0) ?? '',
    );
  }

  bool _looksLikeComplexHtml(String text) {
    if (!RegExp(
      r'<\s*html[\s>]|<\s*style[\s>]|<\s*div[\s>]',
      caseSensitive: false,
    ).hasMatch(text)) {
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
    final wrappedHtml = _wrapInlineHtmlDocument(html);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: _InlineHtmlMessageView(
        html: wrappedHtml,
        initialHeight: _estimateInlineHtmlHeight(wrappedHtml),
      ),
    );
  }

  double _estimateInlineHtmlHeight(String html) {
    final lineCount = '\n'.allMatches(html).length + 1;
    final sectionCount =
        RegExp(
          r'class="([^"]*(sec-group|detail-row|log-box|mono-box|detail-grid|monitor-frame)[^"]*)"',
          caseSensitive: false,
        ).allMatches(html).length;
    final estimated = 220 + (lineCount * 2.4) + (sectionCount * 34);
    return estimated.clamp(260, 900).toDouble();
  }

  String _wrapInlineHtmlDocument(String html) {
    final trimmed = html.trim();
    final hasHtmlRoot = RegExp(
      r'<\s*html\b',
      caseSensitive: false,
    ).hasMatch(trimmed);
    if (hasHtmlRoot) {
      return trimmed
          .replaceFirst(RegExp(r'</head>', caseSensitive: false), '''
<style>
html, body {
  margin: 0 !important;
  padding: 0 !important;
  background: transparent !important;
  width: auto !important;
  min-width: 0 !important;
  max-width: 100% !important;
  height: auto !important;
  min-height: 0 !important;
}
body {
  overflow-x: hidden !important;
  overflow-y: hidden !important;
  -webkit-text-size-adjust: 100%;
  font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif !important;
}
#alicechat-inline-root {
  display: block;
  width: 100%;
  max-width: 100%;
  height: auto !important;
  min-height: 0 !important;
  overflow: hidden;
}
#alicechat-inline-root, #alicechat-inline-root * {
  box-sizing: border-box;
}
.monitor-frame, .container, .card, .panel, .monitor-frame * {
  box-sizing: border-box;
  max-width: 100%;
}
.monitor-frame, .container, .card, .panel {
  width: 100% !important;
  height: auto !important;
  min-height: 0 !important;
  margin: 0 !important;
}
.monitor-frame {
  font-size: clamp(11px, 3vw, 13px);
  line-height: 1.45;
}
.monitor-frame .title, .monitor-frame .header, .monitor-frame .headline {
  font-size: clamp(15px, 4.4vw, 19px) !important;
  line-height: 1.2 !important;
}
.monitor-frame .value, .monitor-frame .metric, .monitor-frame .percent {
  font-size: clamp(18px, 5vw, 28px) !important;
}
.detail-row, .log-box, .mono-box, .status-line, .detail-grid, .sec-group {
  word-break: break-word;
  overflow-wrap: anywhere;
}
.log-box, .mono-box, .detail-value, .detail-row, .status-line {
  white-space: pre-wrap;
}
</style>
</head>''')
          .replaceFirst(
            RegExp(r'<body([^>]*)>', caseSensitive: false),
            '<body\$1><div id="alicechat-inline-root">',
          )
          .replaceFirst(
            RegExp(r'</body>', caseSensitive: false),
            '</div></body>',
          );
    }
    return '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
html, body {
  margin: 0 !important;
  padding: 0 !important;
  background: transparent;
  color: #1f2430;
  font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
  width: auto !important;
  min-width: 0 !important;
  max-width: 100% !important;
  height: auto !important;
  min-height: 0 !important;
}
body {
  overflow-x: hidden !important;
  overflow-y: hidden !important;
  -webkit-text-size-adjust: 100%;
}
#alicechat-inline-root {
  display: block;
  width: 100%;
  max-width: 100%;
  height: auto !important;
  min-height: 0 !important;
  overflow: hidden;
}
#alicechat-inline-root, #alicechat-inline-root * {
  box-sizing: border-box;
}
.monitor-frame, .container, .card, .panel, .monitor-frame * {
  box-sizing: border-box;
  max-width: 100%;
}
.monitor-frame, .container, .card, .panel {
  width: 100% !important;
  height: auto !important;
  min-height: 0 !important;
  margin: 0 !important;
}
.monitor-frame {
  font-size: clamp(11px, 3vw, 13px);
  line-height: 1.45;
}
.monitor-frame .title, .monitor-frame .header, .monitor-frame .headline {
  font-size: clamp(15px, 4.4vw, 19px) !important;
  line-height: 1.2 !important;
}
.monitor-frame .value, .monitor-frame .metric, .monitor-frame .percent {
  font-size: clamp(18px, 5vw, 28px) !important;
}
.detail-row, .log-box, .mono-box, .status-line, .detail-grid, .sec-group {
  word-break: break-word;
  overflow-wrap: anywhere;
}
.log-box, .mono-box, .detail-value, .detail-row, .status-line {
  white-space: pre-wrap;
}
</style>
</head>
<body>
<div id="alicechat-inline-root">
$trimmed
</div>
</body>
</html>
''';
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
    text = text.replaceAll(
      RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
      '',
    );
    text = text.replaceAll(
      RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
      '',
    );
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

  List<_StyledTextSegment> _parseStyledTextSegments(String text) {
    final pattern = RegExp(r'(\([^\n()]+\)|（[^\n（）]+）|“[^”\n]+”)');
    final segments = <_StyledTextSegment>[];
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        segments.add(_StyledTextSegment(text.substring(cursor, match.start)));
      }
      final raw = match.group(0) ?? '';
      if (raw.length >= 2) {
        final open = raw.substring(0, 1);
        final close = raw.substring(raw.length - 1);
        final kind =
            (open == '“' && close == '”')
                ? _StyledTextSegmentKind.dialogue
                : _StyledTextSegmentKind.narration;
        segments.add(
          _StyledTextSegment.styled(
            kind: kind,
            text: raw.substring(1, raw.length - 1),
            openMarker: open,
            closeMarker: close,
          ),
        );
      } else {
        segments.add(_StyledTextSegment(raw));
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      segments.add(_StyledTextSegment(text.substring(cursor)));
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
    final fg =
        isUser ? Colors.white.withValues(alpha: 0.72) : const Color(0xFF98A1B3);
    final bg =
        isUser ? Colors.white.withValues(alpha: 0.10) : const Color(0xFFF4F6FA);
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
              fontSize: desktopAdjustedFontSize(10),
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
        builder:
            (_) => _TavernCharacterProfilePage(
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
    await context.read<TavernStore>().loadRecentChats();
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
      builder:
          (context) => SafeArea(
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
                    trailing:
                        persona.isDefault
                            ? const Chip(label: Text('默认'))
                            : null,
                    onTap: () => Navigator.of(context).pop(persona.id),
                  ),
                ),
              ],
            ),
          ),
    );
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
      _isSendingNotifier.value = isSending;
    }

    _isSendingNotifier.value = true;
    setState(() {
      if (showUserMessage) {
        _messages = [..._messages, optimisticUserMessage];
      }
      _streamingAssistantMessageId = null;
      _streamingAssistantMessage = null;
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
                    final nextMessages = _messages.toList(growable: true);
                    final optimisticIndex = nextMessages.indexWhere(
                      (item) => item.id == optimisticUserMessage.id,
                    );
                    if (optimisticIndex >= 0) {
                      nextMessages[optimisticIndex] = parsed;
                    } else {
                      nextMessages.add(parsed);
                    }
                    _messages = nextMessages;
                  });
                  unawaited(_persistSnapshot());
                  _scrollToBottom();
                }
              } else if (showUserMessage) {
                unawaited(_persistSnapshot());
              }
              break;
            case 'delta':
            case 'thought_delta':
              final chunk =
                  (data['delta'] ?? data['thought_delta'] ?? '').toString();
              if (chunk.isEmpty) return;
              final messageId = (data['messageId'] ?? '').toString().trim();
              final assistantId =
                  messageId.isNotEmpty
                      ? messageId
                      : (_streamingAssistantMessageId ??
                          'stream_assistant_${DateTime.now().microsecondsSinceEpoch}');
              final previousContent =
                  _streamingAssistantMessage?.id == assistantId
                      ? _streamingAssistantMessage!.content
                      : '';
              final previousThought =
                  _streamingAssistantMessage?.id == assistantId
                      ? _streamingAssistantMessage!.thought
                      : '';
              final nextMessage = TavernMessage(
                id: assistantId,
                chatId: _chat.id,
                role: 'assistant',
                content:
                    event == 'delta'
                        ? '$previousContent$chunk'
                        : previousContent,
                thought:
                    event == 'thought_delta'
                        ? '$previousThought$chunk'
                        : previousThought,
                createdAt: DateTime.now(),
              );
              setState(() {
                _streamingAssistantMessageId = assistantId;
                _streamingAssistantMessage = nextMessage;
                if (event == 'thought_delta' &&
                    nextMessage.thought.isNotEmpty) {
                  _expandedThoughtMessageIds.add(assistantId);
                }
              });
              _scrollToBottom();
              break;
            case 'final':
              final rawAssistant = data['assistantMessage'];
              if (rawAssistant is Map) {
                final finalizedAssistantMessage = TavernMessage.fromJson(
                  Map<String, dynamic>.from(rawAssistant),
                );
                setState(() {
                  _expandedThoughtMessageIds.remove(
                    finalizedAssistantMessage.id,
                  );
                  final nextMessages = _messages.toList(growable: true);
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
                  nextMessages.removeWhere(
                    (item) =>
                        item.id == finalizedAssistantMessage.id ||
                        item.id == _streamingAssistantMessageId,
                  );
                  nextMessages.add(finalizedAssistantMessage);
                  _messages = nextMessages;
                  _streamingAssistantMessage = null;
                  _streamingAssistantMessageId = null;
                });
                final rawPromptDebug = data['promptDebug'];
                final promptDebug =
                    rawPromptDebug is Map
                        ? TavernPromptDebug.fromJson(
                          Map<String, dynamic>.from(rawPromptDebug),
                        )
                        : null;
                if (promptDebug != null) {
                  _latestPromptDebugNotifier.value = promptDebug;
                }
                settleSendState(isSending: false);
                unawaited(_persistSnapshot());
                unawaited(_refreshChatMetaOnly());
                unawaited(_refreshContextState());
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
        _streamingAssistantMessage = null;
        _streamingAssistantMessageId = null;
      });
      unawaited(_persistSnapshot());
      unawaited(_refreshFromServer(includeCharacter: false));
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

  Map<String, dynamic> _sceneImageMeta() {
    final raw = _chat.metadata['sceneImage'];
    if (raw is! Map) return const <String, dynamic>{};
    return Map<String, dynamic>.from(raw);
  }

  Future<void> _generateSceneImage() async {
    if (_isGeneratingSceneImage) return;
    setState(() {
      _isGeneratingSceneImage = true;
      final metadata = Map<String, dynamic>.from(_chat.metadata);
      final sceneImage = Map<String, dynamic>.from(
        (metadata['sceneImage'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      );
      sceneImage['status'] = 'generating';
      sceneImage.remove('error');
      metadata['sceneImage'] = sceneImage;
      _chat = TavernChat.fromJson({..._chat.toJson(), 'metadata': metadata});
    });
    try {
      final updated = await context.read<TavernStore>().generateSceneImage(
        _chat.id,
      );
      if (!mounted) return;
      setState(() {
        _chat = updated;
      });
      await _persistSnapshot();
    } catch (exc) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('生成场景图失败：$exc')));
      await _refreshChatMetaOnly();
    } finally {
      if (mounted) {
        setState(() => _isGeneratingSceneImage = false);
      }
    }
  }

  Future<void> _showSceneImageSheet() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> refreshSheet() async {
              setSheetState(() {});
              await _refreshChatMetaOnly();
              if (!mounted) return;
              setSheetState(() {});
            }

            Future<void> generateInsideSheet() async {
              setSheetState(() {});
              await _generateSceneImage();
              if (!mounted) return;
              setSheetState(() {});
            }

            final meta = _sceneImageMeta();
            final status = (meta['status'] ?? '').toString();
            final prompt =
                (meta['displayPrompt'] ?? meta['prompt'] ?? '')
                    .toString()
                    .trim();
            final error = (meta['error'] ?? '').toString().trim();
            final imageUrl = buildTavernImageUrl(
              path: (meta['imageUrl'] ?? '').toString(),
              serverBaseUrl: _serverBaseUrl,
            );
            final loading = status == 'generating' || _isGeneratingSceneImage;
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  24 + MediaQuery.of(sheetContext).viewInsets.bottom,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '场景图',
                              style:
                                  Theme.of(sheetContext).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            tooltip: '刷新',
                            onPressed: loading ? null : refreshSheet,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          width: double.infinity,
                          constraints: const BoxConstraints(minHeight: 260),
                          color:
                              Theme.of(
                                sheetContext,
                              ).colorScheme.surfaceContainerHighest,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (imageUrl != null)
                                Image.network(
                                  imageUrl,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  errorBuilder:
                                      (_, __, ___) =>
                                          _buildSceneImageEmptyState(
                                            label: '图片加载失败',
                                            icon: Icons.broken_image_outlined,
                                          ),
                                )
                              else
                                _buildSceneImageEmptyState(
                                  label:
                                      loading
                                          ? '正在生成场景图…'
                                          : status == 'error'
                                          ? '最近一次生成失败'
                                          : '还没有生成场景图',
                                  icon:
                                      loading
                                          ? Icons.hourglass_top_outlined
                                          : status == 'error'
                                          ? Icons.error_outline
                                          : Icons.image_outlined,
                                  loading: loading,
                                ),
                              if (loading && imageUrl != null)
                                Container(
                                  width: double.infinity,
                                  height: double.infinity,
                                  color: Colors.black.withValues(alpha: 0.18),
                                  alignment: Alignment.center,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.58,
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: const [
                                        SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.2,
                                            color: Colors.white,
                                          ),
                                        ),
                                        SizedBox(width: 10),
                                        Text(
                                          '正在生成新图片…',
                                          style: TextStyle(color: Colors.white),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (error.isNotEmpty && !loading) ...[
                        Text(
                          '错误：$error',
                          style: Theme.of(
                            sheetContext,
                          ).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(sheetContext).colorScheme.error,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (prompt.isNotEmpty) ...[
                        Text(
                          '场景文本',
                          style: Theme.of(sheetContext).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        SelectableText(prompt),
                        const SizedBox(height: 16),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: loading ? null : refreshSheet,
                              icon: const Icon(Icons.refresh),
                              label: const Text('刷新状态'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: loading ? null : generateInsideSheet,
                              icon:
                                  loading
                                      ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: Colors.white,
                                        ),
                                      )
                                      : const Icon(Icons.auto_awesome_outlined),
                              label: Text(imageUrl == null ? '生成图片' : '重新生成'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    unawaited(_refreshChatMetaOnly());
  }

  Widget _buildSceneImageEmptyState({
    required String label,
    required IconData icon,
    bool loading = false,
  }) {
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              )
            else
              Icon(icon, size: 36),
            const SizedBox(height: 12),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Future<void> _refreshContextState() async {
    if (_isLoadingContextState) return;
    _isLoadingContextState = true;
    try {
      final debug = await context.read<TavernStore>().getPromptDebug(_chat.id);
      if (!mounted) return;
      _latestPromptDebugNotifier.value = debug;
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

  List<Map<String, dynamic>> _longTermMemoryItems() {
    final metadata = _chat.metadata;
    final rawMemory =
        metadata['longTermMemory'] is Map
            ? Map<String, dynamic>.from(metadata['longTermMemory'] as Map)
            : const <String, dynamic>{};
    final rawItems = rawMemory['items'];
    if (rawItems is! List) return const <Map<String, dynamic>>[];
    final items = rawItems
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => (item['content'] ?? '').toString().trim().isNotEmpty)
        .toList(growable: false);
    items.sort((a, b) {
      final aActive = a['active'] != false ? 1 : 0;
      final bActive = b['active'] != false ? 1 : 0;
      if (aActive != bActive) return bActive.compareTo(aActive);
      final aPriority = (a['priority'] as num?)?.toInt() ?? 0;
      final bPriority = (b['priority'] as num?)?.toInt() ?? 0;
      if (aPriority != bPriority) return bPriority.compareTo(aPriority);
      final aUpdated = (a['updatedAt'] as num?)?.toDouble() ?? 0;
      final bUpdated = (b['updatedAt'] as num?)?.toDouble() ?? 0;
      return bUpdated.compareTo(aUpdated);
    });
    return items;
  }

  Future<void> _saveLongTermMemoryItems(List<Map<String, dynamic>> items) async {
    final metadata = Map<String, dynamic>.from(_chat.metadata);
    final existing =
        metadata['longTermMemory'] is Map
            ? Map<String, dynamic>.from(metadata['longTermMemory'] as Map)
            : <String, dynamic>{};
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    metadata['longTermMemory'] = {
      'version': (existing['version'] as num?)?.toInt() ?? 1,
      'updatedAt': now,
      'items': items,
    };
    final updated = await context.read<TavernStore>().updateChat(
      chatId: _chat.id,
      payload: {'metadata': metadata},
    );
    if (!mounted) return;
    setState(() {
      _chat = updated;
    });
    await _persistSnapshot();
  }

  Future<Map<String, dynamic>?> _editLongTermMemoryItem({
    Map<String, dynamic>? initial,
  }) async {
    final categories = <String>[
      'relationship',
      'identity',
      'preference',
      'promise',
      'world_state',
      'unresolved_thread',
      'boundary',
      'note',
    ];
    final contentController = TextEditingController(
      text: (initial?['content'] ?? '').toString(),
    );
    String category = (initial?['category'] ?? 'note').toString();
    if (!categories.contains(category)) category = 'note';
    int priority = ((initial?['priority'] as num?)?.toInt() ?? 3).clamp(1, 5);
    double confidence =
        ((initial?['confidence'] as num?)?.toDouble() ?? 0.8).clamp(0.0, 1.0);
    bool active = initial?['active'] != false;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: Text(initial == null ? '新增长期记忆' : '编辑长期记忆'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<String>(
                      value: category,
                      decoration: const InputDecoration(labelText: '类别'),
                      items: categories
                          .map(
                            (item) => DropdownMenuItem<String>(
                              value: item,
                              child: Text(item),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() => category = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: contentController,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: '内容',
                        hintText: '例如：Character promised to return to the lake scene.',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('优先级：$priority'),
                    Slider(
                      value: priority.toDouble(),
                      min: 1,
                      max: 5,
                      divisions: 4,
                      label: '$priority',
                      onChanged: (value) => setDialogState(
                        () => priority = value.round().clamp(1, 5),
                      ),
                    ),
                    Text('置信度：${confidence.toStringAsFixed(2)}'),
                    Slider(
                      value: confidence,
                      min: 0,
                      max: 1,
                      divisions: 20,
                      label: confidence.toStringAsFixed(2),
                      onChanged: (value) => setDialogState(() => confidence = value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active'),
                      subtitle: const Text('关闭后保留记录，但默认不注入 prompt'),
                      value: active,
                      onChanged: (value) => setDialogState(() => active = value),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final content = contentController.text.trim();
                    if (content.isEmpty) return;
                    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
                    Navigator.of(dialogContext).pop({
                      'id': (initial?['id'] ?? 'ltm_${DateTime.now().microsecondsSinceEpoch}').toString(),
                      'category': category,
                      'content': content,
                      'priority': priority,
                      'confidence': confidence,
                      'active': active,
                      'createdAt': (initial?['createdAt'] as num?)?.toDouble() ?? now,
                      'updatedAt': now,
                      'sourceSummaryIds': List<String>.from((initial?['sourceSummaryIds'] as List?) ?? const <String>[]),
                      'sourceMessageIds': List<String>.from((initial?['sourceMessageIds'] as List?) ?? const <String>[]),
                    });
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    contentController.dispose();
    return result;
  }

  List<Map<String, String>> _quickReplies() {
    return _quickReplyConfigs;
  }

  Map<String, int> _contextBreakdown(TavernPromptDebug debug) {
    final usage = debug.contextUsage;
    final parts = <String, int>{
      'summary': 0,
      'long_term_memory': 0,
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
      final name =
          (map['name'] ?? map['label'] ?? map['component'] ?? '')
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
      if (key.contains('long term memory') || key.contains('long_term_memory')) {
        parts['long_term_memory'] = parts['long_term_memory']! + tokens;
      } else if (key.contains('summary')) {
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
        'key': 'long_term_memory',
        'label': 'Memory',
        'tokens': parts['long_term_memory'] ?? 0,
        'color': const Color(0xFF10B981),
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
          return {...item, 'ratio': total > 0 ? tokens / total : 0.0};
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
          children: segments
              .map((segment) {
                final ratio = (segment['ratio'] as double?) ?? 0.0;
                final color = segment['color'] as Color;
                return Expanded(
                  flex: ((ratio * 1000).round()).clamp(1, 1000),
                  child: Container(color: color),
                );
              })
              .toList(growable: false),
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
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickReplyBar() {
    final items = _quickReplies();
    return ValueListenableBuilder<bool>(
      valueListenable: _isSendingNotifier,
      builder:
          (context, isSending, _) => SizedBox(
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
                      isSending ? null : () => _sendSilentQuickReply(item),
                );
              },
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemCount: items.length + 1,
            ),
          ),
    );
  }

  Widget _buildContextStatusTag() {
    return ValueListenableBuilder<TavernPromptDebug?>(
      valueListenable: _latestPromptDebugNotifier,
      builder: (context, debug, _) {
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
                            Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
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
                    fontSize: desktopAdjustedFontSize(10),
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
      },
    );
  }

  Widget _buildContextStatusBar() {
    return const SizedBox.shrink();
  }

  Widget _buildComposer() {
    return ValueListenableBuilder<bool>(
      valueListenable: _isSendingNotifier,
      builder:
          (context, isSending, _) => SafeArea(
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
                    onPressed: isSending ? null : _handleSend,
                    child:
                        isSending
                            ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : const Text('发送'),
                  ),
                ],
              ),
            ),
          ),
    );
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
      final trimPlan =
          contextUsage['meta'] is Map
              ? (((contextUsage['meta'] as Map)['trimPlan'] as Map?) ??
                  const <String, dynamic>{})
              : const <String, dynamic>{};
      final overLimit = (trimPlan['overLimitTokens'] as num?)?.toInt() ?? 0;
      final summarySettings =
          _chat.metadata['summarySettings'] is Map
              ? Map<String, dynamic>.from(
                _chat.metadata['summarySettings'] as Map,
              )
              : const <String, dynamic>{};
      final injectLatestOnly = summarySettings['injectLatestOnly'] == true;
      final useRecentAfterLatest =
          summarySettings['useRecentMessagesAfterLatest'] != false;
      final summaryBlocks =
          debug.blocks
              .where((b) => (b['kind'] ?? '').toString() == 'summary')
              .length;
      final matchedLore = debug.matchedWorldbookEntries.length;
      final rejectedLore = debug.rejectedWorldbookEntries.length;
      final suggestedCuts =
          ((trimPlan['suggestedCuts'] as List?) ?? const <dynamic>[])
              .whereType<Map>()
              .length;
      final color =
          overLimit > 0
              ? Colors.red
              : percent >= 85
              ? Colors.orange
              : percent >= 65
              ? Colors.amber
              : Colors.green;
      final segments = _contextSegments(debug);
      final rawComponents = ((contextUsage['components'] as List?) ??
              (contextUsage['breakdown'] as List?) ??
              const <dynamic>[])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);

      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder:
            (context) => SafeArea(
              child: DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.72,
                maxChildSize: 0.92,
                minChildSize: 0.42,
                builder:
                    (context, controller) => ListView(
                      controller: controller,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        Text(
                          '上下文使用',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '这里优先展示最近一次真实生成所使用的上下文统计；若你打开完整 Debug，再按当前配置即时重算。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).dividerColor.withValues(alpha: 0.3),
                            ),
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
                                        backgroundColor:
                                            Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              color,
                                            ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    maxContext > 0
                                        ? '${percent.toStringAsFixed(0)}%'
                                        : '-',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall?.copyWith(
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
                                  _summaryMetaChip(
                                    '摘要',
                                    summaryBlocks > 0
                                        ? (injectLatestOnly
                                            ? '最新摘要接管'
                                            : '多摘要接管')
                                        : '未接管',
                                  ),
                                  _summaryMetaChip(
                                    '历史模式',
                                    useRecentAfterLatest ? '摘要后 recent' : '全历史',
                                  ),
                                  _summaryMetaChip(
                                    'Lore',
                                    '$matchedLore 命中 / $rejectedLore 拦截',
                                  ),
                                  _summaryMetaChip(
                                    '裁剪',
                                    overLimit > 0 ? '超限 $overLimit tok' : '无超限',
                                  ),
                                  _summaryMetaChip(
                                    '模式',
                                    _chat.authorNoteEnabled ? 'AN 开' : 'AN 关',
                                  ),
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
                          subtitle:
                              rawComponents.isEmpty
                                  ? '这次没有拿到可拆分组件。'
                                  : '当前 prompt 里各部分实际占用。',
                          child:
                              rawComponents.isEmpty
                                  ? Text(
                                    '暂无 context component。',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  )
                                  : Column(
                                    children: rawComponents
                                        .map((item) {
                                          final label =
                                              (item['name'] ??
                                                      item['label'] ??
                                                      item['component'] ??
                                                      'component')
                                                  .toString();
                                          final kind =
                                              (item['meta'] is Map
                                                      ? ((item['meta']
                                                              as Map)['kind'] ??
                                                          '')
                                                      : '')
                                                  .toString();
                                          final tokens =
                                              (item['tokenCount'] as num?)
                                                  ?.toInt() ??
                                              (item['tokens'] as num?)
                                                  ?.toInt() ??
                                              (item['estimatedTokens'] as num?)
                                                  ?.toInt() ??
                                              0;
                                          final percent =
                                              totalTokens > 0
                                                  ? (tokens / totalTokens * 100)
                                                  : 0.0;
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 10,
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        label,
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .labelLarge
                                                            ?.copyWith(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                            ),
                                                      ),
                                                    ),
                                                    Text(
                                                      '${_formatCompactTokenCount(tokens)} · ${percent.toStringAsFixed(percent >= 10 ? 0 : 1)}%',
                                                      style:
                                                          Theme.of(context)
                                                              .textTheme
                                                              .labelMedium,
                                                    ),
                                                  ],
                                                ),
                                                if (kind.isNotEmpty) ...[
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    kind,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          color:
                                                              Theme.of(
                                                                context,
                                                              ).hintColor,
                                                        ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          );
                                        })
                                        .toList(growable: false),
                                  ),
                        ),
                        const SizedBox(height: 12),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(
                            Icons.auto_awesome_motion_outlined,
                          ),
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
                          subtitle: Text(
                            _summaryItems().isEmpty ? '当前还没有摘要' : '查看已生成的剧情摘要',
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            _showSummariesSheet();
                          },
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.bug_report_outlined),
                          title: const Text('Prompt Debug'),
                          subtitle: const Text(
                            '查看完整 prompt / worldbook / runtime 明细',
                          ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加载上下文使用失败：$exc')));
    } finally {
      if (mounted) {
        setState(() => _isLoadingDebug = false);
      }
    }
  }

  Future<void> _showLongTermMemorySheet() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setSheetState) {
              List<Map<String, dynamic>> items = _longTermMemoryItems();

              Future<void> refreshItems() async {
                await _refreshChatMetaOnly();
                if (!mounted) return;
                setSheetState(() {});
              }

              Future<void> saveItems(List<Map<String, dynamic>> nextItems) async {
                await _saveLongTermMemoryItems(nextItems);
                if (!mounted) return;
                setSheetState(() {});
              }

              return SafeArea(
                child: DraggableScrollableSheet(
                  expand: false,
                  initialChildSize: 0.78,
                  maxChildSize: 0.94,
                  minChildSize: 0.34,
                  builder:
                      (context, controller) => Column(
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
                                        '长期记忆',
                                        style: Theme.of(context).textTheme.titleLarge,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        items.isEmpty
                                            ? '当前还没有长期记忆条目'
                                            : '共 ${items.length} 条，可直接手动维护',
                                        style: Theme.of(context).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: '新增',
                                  onPressed: () async {
                                    final created = await _editLongTermMemoryItem();
                                    if (created == null) return;
                                    final next = <Map<String, dynamic>>[
                                      created,
                                      ...items,
                                    ];
                                    await saveItems(next);
                                  },
                                  icon: const Icon(Icons.add),
                                ),
                                IconButton(
                                  tooltip: '刷新',
                                  onPressed: refreshItems,
                                  icon: const Icon(Icons.refresh),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: items.isEmpty
                                ? Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '还没有长期记忆条目。',
                                            textAlign: TextAlign.center,
                                            style: Theme.of(context).textTheme.bodyMedium,
                                          ),
                                          const SizedBox(height: 12),
                                          FilledButton.icon(
                                            onPressed: () async {
                                              final created = await _editLongTermMemoryItem();
                                              if (created == null) return;
                                              await saveItems([created]);
                                            },
                                            icon: const Icon(Icons.add),
                                            label: const Text('新增一条'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    controller: controller,
                                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                                    itemCount: items.length,
                                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                                    itemBuilder: (context, index) {
                                      final item = items[index];
                                      final category = (item['category'] ?? 'note').toString();
                                      final content = (item['content'] ?? '').toString().trim();
                                      final active = item['active'] != false;
                                      final priority = (item['priority'] as num?)?.toInt() ?? 0;
                                      final confidence = (item['confidence'] as num?)?.toDouble();
                                      final pinned = priority >= 5;
                                      return Container(
                                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).colorScheme.surface,
                                          borderRadius: BorderRadius.circular(18),
                                          border: Border.all(
                                            color: Theme.of(context).dividerColor.withValues(alpha: 0.28),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    category,
                                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                                      fontWeight: FontWeight.w800,
                                                    ),
                                                  ),
                                                ),
                                                if (pinned)
                                                  Padding(
                                                    padding: const EdgeInsets.only(right: 8),
                                                    child: Icon(
                                                      Icons.push_pin,
                                                      size: 18,
                                                      color: Theme.of(context).colorScheme.primary,
                                                    ),
                                                  ),
                                                if (!active)
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                    decoration: BoxDecoration(
                                                      color: Colors.grey.withValues(alpha: 0.12),
                                                      borderRadius: BorderRadius.circular(999),
                                                    ),
                                                    child: Text(
                                                      'inactive',
                                                      style: Theme.of(context).textTheme.labelSmall,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            Text(content, style: Theme.of(context).textTheme.bodyMedium),
                                            const SizedBox(height: 10),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                _metaChip('priority $priority'),
                                                if (confidence != null)
                                                  _metaChip('conf ${confidence.toStringAsFixed(2)}'),
                                              ],
                                            ),
                                            const SizedBox(height: 12),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                OutlinedButton.icon(
                                                  onPressed: () async {
                                                    final edited = await _editLongTermMemoryItem(initial: item);
                                                    if (edited == null) return;
                                                    final next = items
                                                        .map((entry) => entry['id'] == item['id'] ? edited : entry)
                                                        .toList(growable: false);
                                                    await saveItems(next);
                                                  },
                                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                                  label: const Text('编辑'),
                                                ),
                                                OutlinedButton.icon(
                                                  onPressed: () async {
                                                    final next = items
                                                        .map(
                                                          (entry) => entry['id'] == item['id']
                                                              ? {
                                                                  ...entry,
                                                                  'active': !(entry['active'] != false),
                                                                  'updatedAt': DateTime.now().millisecondsSinceEpoch / 1000.0,
                                                                }
                                                              : entry,
                                                        )
                                                        .toList(growable: false);
                                                    await saveItems(next);
                                                  },
                                                  icon: Icon(
                                                    active ? Icons.pause_circle_outline : Icons.play_circle_outline,
                                                    size: 18,
                                                  ),
                                                  label: Text(active ? '失效' : '启用'),
                                                ),
                                                OutlinedButton.icon(
                                                  onPressed: pinned
                                                      ? null
                                                      : () async {
                                                          final next = items
                                                              .map(
                                                                (entry) => entry['id'] == item['id']
                                                                    ? {
                                                                        ...entry,
                                                                        'priority': 5,
                                                                        'updatedAt': DateTime.now().millisecondsSinceEpoch / 1000.0,
                                                                      }
                                                                    : entry,
                                                              )
                                                              .toList(growable: false);
                                                          await saveItems(next);
                                                        },
                                                  icon: const Icon(Icons.push_pin_outlined, size: 18),
                                                  label: const Text('置顶'),
                                                ),
                                                OutlinedButton.icon(
                                                  style: OutlinedButton.styleFrom(
                                                    foregroundColor: Theme.of(context).colorScheme.error,
                                                  ),
                                                  onPressed: () async {
                                                    final confirmed = await showDialog<bool>(
                                                      context: context,
                                                      builder: (dialogContext) => AlertDialog(
                                                        title: const Text('删除长期记忆'),
                                                        content: const Text('确定删除这条长期记忆吗？此操作不可恢复。'),
                                                        actions: [
                                                          TextButton(
                                                            onPressed: () => Navigator.of(dialogContext).pop(false),
                                                            child: const Text('取消'),
                                                          ),
                                                          FilledButton(
                                                            onPressed: () => Navigator.of(dialogContext).pop(true),
                                                            child: const Text('删除'),
                                                          ),
                                                        ],
                                                      ),
                                                    );
                                                    if (confirmed != true) return;
                                                    final next = items
                                                        .where((entry) => entry['id'] != item['id'])
                                                        .toList(growable: false);
                                                    await saveItems(next);
                                                  },
                                                  icon: const Icon(Icons.delete_outline, size: 18),
                                                  label: const Text('删除'),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                ),
              );
            },
          ),
    );
  }

  Widget _metaChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall),
    );
  }

  Future<void> _showSummariesSheet() async {
    final summaries = _summaryItems().reversed.toList(growable: false);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder:
          (context) => SafeArea(
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.76,
              maxChildSize: 0.94,
              minChildSize: 0.38,
              builder:
                  (context, controller) => Column(
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
                                    style:
                                        Theme.of(context).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    summaries.isEmpty
                                        ? '当前还没有可用摘要'
                                        : '共 ${summaries.length} 条，新的在前',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
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
                      const Divider(height: 1),
                      Expanded(
                        child: _buildSummaryContentTab(
                          summaries: summaries,
                          controller: controller,
                        ),
                      ),
                    ],
                  ),
            ),
          ),
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
    final theme = Theme.of(context);
    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemBuilder: (context, index) {
        final item = summaries[index];
        final createdAt = _tryParseDateTime(item['createdAt']);
        final endIndex = item['endMessageIndex'];
        final content = (item['content'] ?? '').toString().trim();
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.28),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '摘要 ${summaries.length - index}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          createdAt != null
                              ? _formatSummaryTime(createdAt)
                              : '时间未知',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF667085),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if ((item['source'] ?? '').toString().trim().isNotEmpty)
                    _summaryMetaChip(
                      '来源',
                      (item['source'] ?? 'auto').toString(),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Divider(
                height: 1,
                color: theme.dividerColor.withValues(alpha: 0.22),
              ),
              const SizedBox(height: 14),
              _buildMarkdownText(content),
              const SizedBox(height: 14),
              Divider(
                height: 1,
                color: theme.dividerColor.withValues(alpha: 0.18),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _summaryMetaChip('ID', (item['id'] ?? '-').toString()),
                  if (endIndex != null) _summaryMetaChip('截至消息', '$endIndex'),
                ],
              ),
            ],
          ),
        );
      },
      separatorBuilder:
          (_, __) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Divider(
                    color: theme.dividerColor.withValues(alpha: 0.12),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Icon(
                    Icons.auto_stories_outlined,
                    size: 16,
                    color: theme.hintColor.withValues(alpha: 0.6),
                  ),
                ),
                Expanded(
                  child: Divider(
                    color: theme.dividerColor.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
          ),
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
            onPressed:
                value <= min
                    ? null
                    : () => onChanged((value - effectiveStep).clamp(min, max)),
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
            onPressed:
                value >= max
                    ? null
                    : () => onChanged((value + effectiveStep).clamp(min, max)),
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
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(height: 1.4),
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
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
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
      builder:
          (context) => SafeArea(
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
                  leading: const Icon(Icons.image_outlined),
                  title: const Text('场景图'),
                  subtitle: const Text('查看当前场景图，没生成也可以从这里进入'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).pop();
                    _showSceneImageSheet();
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
                    _showGenerationConfigSheet(
                      presets: presets,
                      messenger: messenger,
                    );
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
                  subtitle: Text(
                    _summaryItems().isEmpty ? '当前还没有摘要' : '只查看已生成摘要内容',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).pop();
                    _showSummariesSheet();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.psychology_alt_outlined),
                  title: const Text('长期记忆'),
                  subtitle: Text(
                    _longTermMemoryItems().isEmpty
                        ? '当前还没有长期记忆条目'
                        : '查看已保存的长期记忆条目',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).pop();
                    _showLongTermMemorySheet();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bug_report_outlined),
                  title: const Text('Prompt Debug'),
                  subtitle: const Text('WorldBook runtime、原始明细'),
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

  Future<void> _showGenerationConfigSheet({
    required List<TavernPreset> presets,
    required ScaffoldMessengerState messenger,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder:
          (context) => SafeArea(
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
                  subtitle: Text(
                    _chat.authorNoteEnabled
                        ? '已启用 · depth ${_chat.authorNoteDepth}'
                        : '未启用',
                  ),
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
    final current =
        currentMetadata['summarySettings'] is Map
            ? Map<String, dynamic>.from(
              currentMetadata['summarySettings'] as Map,
            )
            : <String, dynamic>{};
    bool enabled = current['enabled'] != false;
    bool injectLatestOnly = current['injectLatestOnly'] == true;
    bool useRecentAfterLatest =
        current['useRecentMessagesAfterLatest'] != false;
    double triggerRatio =
        ((current['triggerRatio'] as num?)?.toDouble() ??
                (current['threshold'] as num?)?.toDouble() ??
                0.8)
            .clamp(0.5, 0.98);
    double targetRatio =
        ((current['targetRatio'] as num?)?.toDouble() ?? 0.68)
            .clamp(0.3, 0.95);
    bool longTermMemoryEnabled = current['longTermMemoryEnabled'] != false;
    int maxInjectedLongTermItems =
        (current['maxInjectedLongTermItems'] as num?)?.toInt() ?? 8;
    int maxInjectedLongTermTokens =
        (current['maxInjectedLongTermTokens'] as num?)?.toInt() ?? 800;
    int minMessages = (current['minMessages'] as num?)?.toInt() ?? 8;
    int recentMessageWindow =
        (current['recentMessageWindow'] as num?)?.toInt() ?? 24;
    int recentTokenWindow =
        (current['recentTokenWindow'] as num?)?.toInt() ?? 3500;
    int chunkMinMessages =
        (current['chunkMinMessages'] as num?)?.toInt() ?? 8;
    int chunkMaxMessages =
        (current['chunkMaxMessages'] as num?)?.toInt() ?? 16;
    int chunkTargetTokens =
        (current['chunkTargetTokens'] as num?)?.toInt() ?? 1800;
    int maxInjectedSummaries =
        (current['maxInjectedSummaries'] as num?)?.toInt() ?? 3;
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
                            '上下文 / 摘要策略',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('自动总结'),
                            subtitle: const Text('只在 assistant 完成后触发，影响下一轮'),
                            value: enabled,
                            onChanged:
                                (value) => setModalState(() => enabled = value),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('仅注入最新摘要'),
                            subtitle: const Text('开启后只注入最新 chunk；关闭后注入最近多个 chunk'),
                            value: injectLatestOnly,
                            onChanged:
                                (value) => setModalState(
                                  () => injectLatestOnly = value,
                                ),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('仅保留最新摘要后的 recent history'),
                            subtitle: const Text(
                              '开启后，历史主要由 summary + recent 组成',
                            ),
                            value: useRecentAfterLatest,
                            onChanged:
                                (value) => setModalState(
                                  () => useRecentAfterLatest = value,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text('触发阈值：${triggerRatio.toStringAsFixed(2)}'),
                          Slider(
                            value: triggerRatio,
                            min: 0.5,
                            max: 0.98,
                            divisions: 24,
                            label: triggerRatio.toStringAsFixed(2),
                            onChanged:
                                (value) => setModalState(() {
                                  triggerRatio = value;
                                  if (targetRatio >= triggerRatio) {
                                    targetRatio = (triggerRatio - 0.02).clamp(0.3, 0.95);
                                  }
                                }),
                          ),
                          Text('回落目标：${targetRatio.toStringAsFixed(2)}'),
                          Slider(
                            value: targetRatio.clamp(0.3, triggerRatio - 0.02),
                            min: 0.3,
                            max: (triggerRatio - 0.02).clamp(0.32, 0.96),
                            divisions: 33,
                            label: targetRatio.toStringAsFixed(2),
                            onChanged:
                                (value) => setModalState(() => targetRatio = value),
                          ),
                          _intStepper(
                            context,
                            label: '最少历史消息数',
                            value: minMessages,
                            min: 2,
                            max: 64,
                            onChanged:
                                (value) =>
                                    setModalState(() => minMessages = value),
                          ),
                          _intStepper(
                            context,
                            label: '最近原文保护消息数',
                            value: recentMessageWindow,
                            min: 0,
                            max: 128,
                            onChanged:
                                (value) => setModalState(
                                  () => recentMessageWindow = value,
                                ),
                          ),
                          _intStepper(
                            context,
                            label: '最近原文保护 Token',
                            value: recentTokenWindow,
                            min: 0,
                            max: 12000,
                            step: 100,
                            onChanged:
                                (value) => setModalState(
                                  () => recentTokenWindow = value,
                                ),
                          ),
                          _intStepper(
                            context,
                            label: 'Chunk 最少消息数',
                            value: chunkMinMessages,
                            min: 1,
                            max: 64,
                            onChanged:
                                (value) => setModalState(() {
                                  chunkMinMessages = value;
                                  if (chunkMaxMessages < chunkMinMessages) {
                                    chunkMaxMessages = chunkMinMessages;
                                  }
                                }),
                          ),
                          _intStepper(
                            context,
                            label: 'Chunk 最多消息数',
                            value: chunkMaxMessages,
                            min: chunkMinMessages,
                            max: 96,
                            onChanged:
                                (value) => setModalState(
                                  () => chunkMaxMessages = value,
                                ),
                          ),
                          _intStepper(
                            context,
                            label: 'Chunk 目标 Token',
                            value: chunkTargetTokens,
                            min: 64,
                            max: 8192,
                            step: 64,
                            onChanged:
                                (value) => setModalState(
                                  () => chunkTargetTokens = value,
                                ),
                          ),
                          _intStepper(
                            context,
                            label: '最多注入摘要块数',
                            value: maxInjectedSummaries,
                            min: 1,
                            max: 12,
                            onChanged:
                                (value) => setModalState(
                                  () => maxInjectedSummaries = value,
                                ),
                          ),
                          const SizedBox(height: 8),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('启用长期记忆注入'),
                            subtitle: const Text('Phase 1 先支持静态注入与基础展示'),
                            value: longTermMemoryEnabled,
                            onChanged:
                                (value) => setModalState(
                                  () => longTermMemoryEnabled = value,
                                ),
                          ),
                          _intStepper(
                            context,
                            label: '长期记忆最多注入条数',
                            value: maxInjectedLongTermItems,
                            min: 1,
                            max: 32,
                            onChanged:
                                (value) => setModalState(
                                  () => maxInjectedLongTermItems = value,
                                ),
                          ),
                          _intStepper(
                            context,
                            label: '长期记忆最多注入 Token',
                            value: maxInjectedLongTermTokens,
                            min: 64,
                            max: 4096,
                            step: 64,
                            onChanged:
                                (value) => setModalState(
                                  () => maxInjectedLongTermTokens = value,
                                ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color:
                                  Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '说明：当前策略会优先保护最近原文窗口，只从最远端按 chunk 做摘要压缩；触线后会持续压缩到回落目标附近。新 summary 和 worldbook runtime 更新会在回复完成后写回，并影响下一轮。',
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(height: 1.45),
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
                                            final nextMetadata =
                                                Map<String, dynamic>.from(
                                                  currentMetadata,
                                                );
                                            nextMetadata['summarySettings'] = {
                                              ...current,
                                              'enabled': enabled,
                                              'injectLatestOnly':
                                                  injectLatestOnly,
                                              'useRecentMessagesAfterLatest':
                                                  useRecentAfterLatest,
                                              'triggerRatio': double.parse(
                                                triggerRatio.toStringAsFixed(2),
                                              ),
                                              'threshold': double.parse(
                                                triggerRatio.toStringAsFixed(2),
                                              ),
                                              'targetRatio': double.parse(
                                                targetRatio.toStringAsFixed(2),
                                              ),
                                              'minMessages': minMessages,
                                              'recentMessageWindow': recentMessageWindow,
                                              'recentTokenWindow': recentTokenWindow,
                                              'chunkMinMessages': chunkMinMessages,
                                              'chunkMaxMessages': chunkMaxMessages,
                                              'chunkTargetTokens': chunkTargetTokens,
                                              'maxInjectedSummaries': maxInjectedSummaries,
                                              'longTermMemoryEnabled': longTermMemoryEnabled,
                                              'maxInjectedLongTermItems': maxInjectedLongTermItems,
                                              'maxInjectedLongTermTokens': maxInjectedLongTermTokens,
                                            };
                                            final updated = await context
                                                .read<TavernStore>()
                                                .updateChat(
                                                  chatId: _chat.id,
                                                  payload: {
                                                    'metadata': nextMetadata,
                                                  },
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
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text('保存上下文策略失败：$exc'),
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

    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('上下文 / 摘要策略已更新')));
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
                                '默认优先显示最近一次真实请求实际使用的 Prompt；只有没有真实记录时，才回退到当前配置预览。',
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
                                  _debugChip(
                                    '数据来源',
                                    debug.sourceLabel == 'last_real_request'
                                        ? '真实请求'
                                        : '预览重算',
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
          ...debug.depthInserts.map((item) {
            final block =
                item['block'] is Map
                    ? Map<String, dynamic>.from(item['block'] as Map)
                    : const <String, dynamic>{};
            return Card(
              child: ListTile(
                title: Text(
                  (block['name'] ?? block['kind'] ?? item['kind'] ?? 'depth')
                      .toString(),
                ),
                subtitle: Text(
                  'depth=${item['depth'] ?? block['depth'] ?? '-'} · position=${block['position'] ?? item['position'] ?? '-'}',
                ),
              ),
            );
          }),
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
    final groupedMessages = _groupDebugMessagesForDisplay(debug.messages);
    final categories = _groupPromptDebugMessages(groupedMessages);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionCard(
          title: 'Prompt Layers',
          subtitle: 'system / example / world info / author note 等插入层。',
          child: _buildDebugMessageList(
            categories.promptLayers,
            emptyText: '无额外 prompt layers',
          ),
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: 'Chat History',
          subtitle: '历史消息区，可能夹带 at-depth 注入切分后的多个 history 段。',
          child: _buildDebugMessageList(categories.history, emptyText: '无历史消息'),
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: 'Current Input',
          subtitle: '当前轮请求输入，位于历史与注入层之后。',
          child: _buildDebugMessageList(
            categories.currentInput,
            emptyText: '无当前输入',
          ),
        ),
        if (categories.otherMessages.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionCard(
            title: 'Other Messages',
            subtitle: '暂未归类的 message 片段。',
            child: _buildDebugMessageList(
              categories.otherMessages,
              emptyText: '无',
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDebugMessageList(
    List<_DebugDisplayItem> messages, {
    required String emptyText,
  }) {
    if (messages.isEmpty) {
      return Text(emptyText);
    }
    return Column(
      children: messages
          .map(
            (message) => _buildDebugContentCard(
              title: message.title,
              subtitle: message.subtitle,
              content: message.content,
              initiallyExpanded:
                  !_shouldCollapseDebugContent(
                    kind: message.kind,
                    content: message.content,
                  ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildDebugBlocksTab(TavernPromptDebug debug) {
    final groups = _groupPromptDebugBlocks(debug.blocks);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionCard(
          title: 'Movable Sections',
          subtitle: '这里是 Prompt Order 真正参与排序的普通 section。',
          child: _buildDebugBlockList(
            groups.movableSections,
            emptyText: '无普通 section blocks',
          ),
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: 'World Info Injections',
          subtitle: '这里是命中的世界书条目按 insertion position 注入后的独立 blocks。',
          child: _buildDebugBlockList(
            groups.worldInfoInjections,
            emptyText: '无世界书注入 blocks',
          ),
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: 'Special Injections',
          subtitle: '这里是 author note / depth 等不走普通 Prompt Order 拖拽语义的特殊注入。',
          child: _buildDebugBlockList(
            groups.specialInjections,
            emptyText: '无特殊注入 blocks',
          ),
        ),
        if (groups.otherBlocks.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionCard(
            title: 'Other Blocks',
            subtitle: '保底分组，用来承接暂未归类的 blocks。',
            child: _buildDebugBlockList(groups.otherBlocks, emptyText: '无'),
          ),
        ],
      ],
    );
  }

  Widget _buildDebugBlockList(
    List<Map<String, dynamic>> blocks, {
    required String emptyText,
  }) {
    if (blocks.isEmpty) {
      return Text(emptyText);
    }
    return Column(
      children: blocks
          .map(
            (block) => _buildDebugContentCard(
              title:
                  '${block['name'] ?? '-'} · ${block['position'] ?? '-'} · ${block['role'] ?? '-'}',
              subtitle:
                  'kind=${block['kind'] ?? '-'} depth=${block['depth'] ?? '-'} source=${block['source'] ?? '-'}',
              content: (block['content'] ?? '').toString(),
              initiallyExpanded:
                  !_shouldCollapseDebugContent(
                    kind: (block['kind'] ?? '').toString(),
                    content: (block['content'] ?? '').toString(),
                  ),
            ),
          )
          .toList(growable: false),
    );
  }

  _PromptDebugBlockGroups _groupPromptDebugBlocks(
    List<Map<String, dynamic>> blocks,
  ) {
    final movableSections = <Map<String, dynamic>>[];
    final worldInfoInjections = <Map<String, dynamic>>[];
    final specialInjections = <Map<String, dynamic>>[];
    final otherBlocks = <Map<String, dynamic>>[];

    for (final block in blocks) {
      final source = (block['source'] ?? '').toString();
      final kind = (block['kind'] ?? '').toString();
      final name = (block['name'] ?? '').toString();
      final position = (block['position'] ?? '').toString();

      if (source == 'worldbook' && name.startsWith('worldbook:')) {
        worldInfoInjections.add(block);
        continue;
      }
      if (kind == 'author_note' || position == 'at_depth') {
        specialInjections.add(block);
        continue;
      }
      if (source == 'worldbook' &&
          (name == 'world_info_before' || name == 'world_info_after')) {
        movableSections.add(block);
        continue;
      }
      if (source == 'builtin' ||
          source == 'character' ||
          source == 'persona' ||
          source == 'summary' ||
          source == 'runtime') {
        movableSections.add(block);
        continue;
      }
      otherBlocks.add(block);
    }

    return _PromptDebugBlockGroups(
      movableSections: movableSections,
      worldInfoInjections: worldInfoInjections,
      specialInjections: specialInjections,
      otherBlocks: otherBlocks,
    );
  }

  _PromptDebugMessageGroups _groupPromptDebugMessages(
    List<_DebugDisplayItem> messages,
  ) {
    final promptLayers = <_DebugDisplayItem>[];
    final history = <_DebugDisplayItem>[];
    final currentInput = <_DebugDisplayItem>[];
    final otherMessages = <_DebugDisplayItem>[];

    for (final message in messages) {
      if (message.kind == 'chat_history') {
        history.add(message);
        continue;
      }
      if (message.kind == 'current_user_input') {
        currentInput.add(message);
        continue;
      }
      if (message.kind.isNotEmpty) {
        promptLayers.add(message);
        continue;
      }
      otherMessages.add(message);
    }

    return _PromptDebugMessageGroups(
      promptLayers: promptLayers,
      history: history,
      currentInput: currentInput,
      otherMessages: otherMessages,
    );
  }

  List<_DebugDisplayItem> _groupDebugMessagesForDisplay(
    List<Map<String, dynamic>> messages,
  ) {
    final items = <_DebugDisplayItem>[];
    final historyBuffer = <String>[];
    String? historySubtitle;

    void flushHistory() {
      if (historyBuffer.isEmpty) return;
      items.add(
        _DebugDisplayItem(
          title: 'history · chat_history',
          subtitle: historySubtitle,
          content: historyBuffer.join('\n\n'),
          kind: 'chat_history',
        ),
      );
      historyBuffer.clear();
      historySubtitle = null;
    }

    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final meta =
          message['meta'] is Map
              ? Map<String, dynamic>.from(message['meta'] as Map)
              : const <String, dynamic>{};
      final kind = (meta['kind'] ?? '').toString();
      final role = (message['role'] ?? 'unknown').toString();
      final content = (message['content'] ?? '').toString();
      final isLastMessage = i == messages.length - 1;
      final isFinalCurrentUser =
          isLastMessage && meta.isEmpty && role == 'user';
      final isHistoryMessage =
          !isFinalCurrentUser &&
          meta.isEmpty &&
          (role == 'user' || role == 'assistant' || role == 'system');
      final isChatHistoryBlock = kind == 'chat_history';

      if (isChatHistoryBlock || isHistoryMessage) {
        historySubtitle ??=
            isChatHistoryBlock ? meta.toString() : 'grouped rendered history';
        historyBuffer.add('[$role]\n$content');
        continue;
      }

      flushHistory();
      items.add(
        _DebugDisplayItem(
          title:
              isFinalCurrentUser
                  ? 'current user · request input'
                  : '$role · ${kind.isEmpty ? '-' : kind}',
          subtitle:
              isFinalCurrentUser
                  ? 'latest user input appended after history/injections'
                  : message['meta']?.toString(),
          content: content,
          kind: isFinalCurrentUser ? 'current_user_input' : kind,
        ),
      );
    }

    flushHistory();
    return items;
  }

  bool _shouldCollapseDebugContent({
    required String kind,
    required String content,
  }) {
    final normalizedKind = kind.trim().toLowerCase();
    if (normalizedKind.contains('chat_history') ||
        normalizedKind == 'history' ||
        normalizedKind.endsWith('_history')) {
      return true;
    }
    return content.length > 800 || '\n'.allMatches(content).length > 12;
  }

  Widget _buildDebugContentCard({
    required String title,
    String? subtitle,
    required String content,
    bool initiallyExpanded = true,
  }) {
    return Card(
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        title: Text(title, style: Theme.of(context).textTheme.labelMedium),
        subtitle:
            subtitle == null || subtitle.isEmpty
                ? null
                : Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(content),
          ),
        ],
      ),
    );
  }

  Widget _buildDebugWorldInfoTab(TavernPromptDebug debug) {
    final runtime = debug.worldbookRuntime;
    final entriesMap =
        runtime['entries'] is Map
            ? Map<String, dynamic>.from(runtime['entries'] as Map)
            : const <String, dynamic>{};

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionCard(
          title: 'Runtime 状态',
          subtitle: '这里展示每条 lore 当前是否处于 sticky / cooldown / delay 中。',
          child:
              entriesMap.isEmpty
                  ? const Text('当前没有运行中的 WorldBook 状态。')
                  : Column(
                    children: entriesMap.entries
                        .map((entry) {
                          final state =
                              entry.value is Map
                                  ? Map<String, dynamic>.from(
                                    entry.value as Map,
                                  )
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
                                    state['pendingActivation'] == true
                                        ? 'Yes'
                                        : 'No',
                                  ),
                                ],
                              ),
                            ),
                          );
                        })
                        .toList(growable: false),
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
                        _summaryMetaChip(
                          'Priority',
                          '${entry['priority'] ?? '-'}',
                        ),
                        _summaryMetaChip(
                          'Position',
                          '${entry['insertionPosition'] ?? '-'}',
                        ),
                        if (entry['_matchMeta'] is Map &&
                            ((entry['_matchMeta'] as Map)['kind'] ?? '')
                                .toString()
                                .isNotEmpty)
                          _summaryMetaChip(
                            '命中来源',
                            ((entry['_matchMeta'] as Map)['kind'] ?? '-')
                                .toString(),
                          ),
                        if (entry['_matchMeta'] is Map &&
                            ((entry['_matchMeta'] as Map)['corpus'] ?? '')
                                .toString()
                                .isNotEmpty)
                          _summaryMetaChip(
                            '扫描范围',
                            ((entry['_matchMeta'] as Map)['corpus'] ?? '-')
                                .toString(),
                          ),
                        if (entry['_matchMeta'] is Map &&
                            ((entry['_matchMeta'] as Map)['score'] != null))
                          _summaryMetaChip(
                            'Score',
                            '${(entry['_matchMeta'] as Map)['score']}',
                          ),
                        if (entry['_matchMeta'] is Map &&
                            ((entry['_matchMeta'] as Map)['runtimeState']
                                is Map))
                          _summaryMetaChip('Runtime', '已参与'),
                      ],
                    ),
                    if (entry['_matchMeta'] is Map) ...[
                      const SizedBox(height: 6),
                      Text(
                        _buildMatchedWorldInfoExplanation(
                          Map<String, dynamic>.from(entry['_matchMeta'] as Map),
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (entry['_matchMeta'] is Map &&
                        ((entry['_matchMeta'] as Map)['runtimeState']
                            is Map)) ...[
                      const SizedBox(height: 6),
                      Text(
                        'state=${((entry['_matchMeta'] as Map)['runtimeState'] as Map).toString()}',
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
                    Text(
                      _buildRejectedWorldInfoExplanation(entry),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if ((entry['state'] is Map)) ...[
                      const SizedBox(height: 4),
                      Text(
                        'state=${(entry['state'] as Map).toString()}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (entry['details'] != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'details=${entry['details']}',
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
      case 'disabled':
        return '已禁用';
      case 'empty_content':
        return '内容为空';
      case 'character_filter_not_matched':
        return '角色过滤未命中';
      case 'character_filter_excluded':
        return '被角色过滤排除';
      case 'no_primary_keys':
        return '缺少主关键词';
      case 'primary_keys_not_matched':
        return '主关键词未命中';
      case 'secondary_keys_not_matched':
        return '次关键词未命中';
      case 'delayed_until_recursion':
        return '递归前暂缓';
      case 'delayed_until_recursion_level':
        return '等待递归层级';
      case 'group_already_selected':
        return '同组已选中其他条目';
      case 'group_override_loser':
        return '组内比较落败';
      case 'group_not_selected':
        return '组内未被选中';
      case 'probability_failed':
        return '概率判定未通过';
      case 'budget_exceeded':
        return '超出预算';
      case 'recursive_match_not_resolved':
        return '递归匹配未收敛';
      case 'trimmed_by_total_context_budget':
        return '被总上下文预算裁掉';
      default:
        return reason;
    }
  }

  String _buildMatchedWorldInfoExplanation(Map<String, dynamic> matchMeta) {
    final kind = (matchMeta['kind'] ?? '-').toString();
    final corpus = (matchMeta['corpus'] ?? '-').toString();
    final score = matchMeta['score'];
    final pass = matchMeta['pass'];
    final primary =
        matchMeta['primary'] is Map
            ? Map<String, dynamic>.from(matchMeta['primary'] as Map)
            : const <String, dynamic>{};
    final secondary =
        matchMeta['secondary'] is Map
            ? Map<String, dynamic>.from(matchMeta['secondary'] as Map)
            : const <String, dynamic>{};
    final hasRuntime = matchMeta['runtimeState'] is Map;
    final primaryHits = ((primary['hits'] as List?) ?? const []).length;
    final secondaryHits = ((secondary['hits'] as List?) ?? const []).length;
    return '命中原因：$kind；扫描范围：$corpus；递归轮次：${pass ?? '-'}；主关键词命中：$primaryHits；次关键词命中：$secondaryHits；匹配分：${score ?? '-'}${hasRuntime ? '；带有运行时状态参与' : ''}';
  }

  String _buildRejectedWorldInfoExplanation(Map<String, dynamic> entry) {
    final reasonCode = (entry['reason'] ?? '-').toString();
    final reason = _worldInfoRejectReasonLabel(reasonCode);
    final details =
        entry['details'] is Map
            ? Map<String, dynamic>.from(entry['details'] as Map)
            : null;
    final state = entry['state'];
    final buffer = StringBuffer('拒绝原因：$reason');
    final detailsText = _formatRejectedWorldInfoDetails(reasonCode, details);
    if (detailsText.isNotEmpty) {
      buffer.write('；$detailsText');
    }
    if (state is Map && state.isNotEmpty) {
      buffer.write('；运行时状态存在');
    }
    return buffer.toString();
  }

  String _formatRejectedWorldInfoDetails(
    String reasonCode,
    Map<String, dynamic>? details,
  ) {
    if (details == null || details.isEmpty) return '';
    switch (reasonCode) {
      case 'probability_failed':
        return '掷骰=${details['roll'] ?? '-'}，概率阈值=${details['probability'] ?? '-'}';
      case 'budget_exceeded':
      case 'trimmed_by_total_context_budget':
        return '已用 tokens=${details['usedTokens'] ?? '-'}，条目 tokens=${details['entryTokens'] ?? details['suggestedTrimTokens'] ?? '-'}，预算=${details['worldbookTokenBudget'] ?? details['maxContext'] ?? '-'}';
      case 'primary_keys_not_matched':
      case 'secondary_keys_not_matched':
        return '匹配模式=${details['mode'] ?? '-'}，命中=${((details['hits'] as List?) ?? const []).length} / 测试=${((details['tested'] as List?) ?? const []).length}';
      case 'delayed_until_recursion':
        return '目标递归层级=${details['level'] ?? '-'}';
      case 'delayed_until_recursion_level':
        return '目标递归层级=${details['level'] ?? '-'}，当前层级=${details['currentLevel'] ?? '-'}';
      case 'delay_scheduled':
        return '命中后需延迟 ${details['delay'] ?? '-'} 轮激活';
      case 'character_filter_not_matched':
      case 'character_filter_excluded':
        return '角色=${details['characterName'] ?? '-'}，nameHit=${details['nameHit'] ?? false}，tagHit=${details['tagHit'] ?? false}';
      default:
        return details.toString();
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
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> value)
  onSave;

  @override
  State<_TavernJsonMapEditorPage> createState() =>
      _TavernJsonMapEditorPageState();
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$exc')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
