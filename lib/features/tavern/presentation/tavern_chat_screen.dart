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

class _TavernChatScreenState extends State<TavernChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _isSending = false;
  bool _isLoadingDebug = false;
  String? _error;
  String? _serverBaseUrl;
  String? _selectedPresetId;
  List<TavernMessage> _messages = const <TavernMessage>[];
  late TavernCharacter _character;
  late TavernChat _chat;

  @override
  void initState() {
    super.initState();
    _character = widget.character;
    _chat = widget.chat;
    _bootstrap();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final store = context.read<TavernStore>();
    try {
      final settings = await OpenClawSettingsStore.load();
      final character = await store.getCharacter(_chat.characterId);
      final messages = await store.listChatMessages(_chat.id);
      if (!mounted) return;
      setState(() {
        _serverBaseUrl = settings.baseUrl.trim().replaceFirst(
          RegExp(r'/+$'),
          '',
        );
        _character = character;
        _messages = messages;
        _selectedPresetId = _chat.presetId.isNotEmpty ? _chat.presetId : null;
        _isLoading = false;
      });
      _scrollToBottom();
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        _error = exc.toString();
        _isLoading = false;
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
              _buildCompactInfoBar(context),
              Expanded(child: _buildBody(context)),
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
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final isUser = message.role == 'user';
        final bubble = ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            color:
                isUser
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surface,
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment:
                    isUser
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                children: [
                  Text(
                    isUser ? '你' : _character.name,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 6),
                  _buildMarkdownText(message.content),
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
              children: [
                Flexible(child: bubble),
              ],
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
              ),
              const SizedBox(width: 10),
              Flexible(child: bubble),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMarkdownText(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      return const SizedBox.shrink();
    }
    return MarkdownBody(
      data: normalized,
      selectable: true,
      softLineBreak: true,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: Theme.of(context).textTheme.bodyMedium,
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

  Future<void> _handleSend() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _isSending) return;
    FocusScope.of(context).unfocus();
    setState(() => _isSending = true);
    _inputController.clear();
    try {
      final response = await context.read<TavernStore>().sendMessage(
        chatId: _chat.id,
        text: text,
        presetId: _selectedPresetId ?? '',
      );
      final userMessage = TavernMessage.fromJson(
        Map<String, dynamic>.from(response['userMessage'] as Map),
      );
      final assistantMessage = TavernMessage.fromJson(
        Map<String, dynamic>.from(response['assistantMessage'] as Map),
      );
      if (!mounted) return;
      setState(() {
        _messages = [..._messages, userMessage, assistantMessage];
        _isSending = false;
      });
      _scrollToBottom();
    } catch (exc) {
      if (!mounted) return;
      setState(() => _isSending = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('发送失败：$exc')));
    }
  }

  Widget _buildCompactInfoBar(BuildContext context) {
    final store = context.watch<TavernStore>();
    final effectivePreset = _effectivePreset(store);
    final presetLabel = effectivePreset?.name ?? '默认 Preset';
    final promptOrderLabel = _promptOrderLabel(store, effectivePreset);
    return Material(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
      child: InkWell(
        onTap: _showChatOptions,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              const Icon(Icons.tune, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$presetLabel · $promptOrderLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.expand_more, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showChatOptions() async {
    final messenger = ScaffoldMessenger.of(context);
    final store = context.read<TavernStore>();
    final presets = store.presets;
    final effectivePreset = _effectivePreset(store);
    final providerLabel = _providerLabel(effectivePreset);
    final promptOrderLabel = _promptOrderLabel(store, effectivePreset);
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
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _debugChip('Provider', providerLabel),
                  _debugChip('PromptOrder', promptOrderLabel),
                  if (effectivePreset != null) ...[
                    _debugChip('Story', effectivePreset.storyStringPosition),
                    _debugChip('Role', effectivePreset.storyStringRole),
                    _debugChip('Depth', '${effectivePreset.storyStringDepth}'),
                  ],
                ],
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

  TavernPreset? _effectivePreset(TavernStore store) {
    if (store.presets.isEmpty) return null;
    if (_selectedPresetId != null && _selectedPresetId!.isNotEmpty) {
      for (final preset in store.presets) {
        if (preset.id == _selectedPresetId) return preset;
      }
    }
    final chatPresetId = _chat.presetId.trim();
    if (chatPresetId.isNotEmpty) {
      for (final preset in store.presets) {
        if (preset.id == chatPresetId) return preset;
      }
    }
    return store.presets.first;
  }

  String _providerLabel(TavernPreset? preset) {
    if (preset == null) return '未配置';
    final provider = preset.provider.trim();
    final model = preset.model.trim();
    if (provider.isEmpty && model.isEmpty) return '未配置';
    if (provider.isEmpty) return model;
    if (model.isEmpty) return provider;
    return '$provider · $model';
  }

  String _promptOrderLabel(TavernStore store, TavernPreset? preset) {
    if (preset == null) return '未设置';
    final promptOrderId = preset.promptOrderId.trim();
    if (promptOrderId.isEmpty) return '未设置';
    for (final item in store.promptOrders) {
      if (item.id == promptOrderId) return item.name;
    }
    return promptOrderId;
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
                    const SizedBox(height: 4),
                    Text(
                      'priority=${entry['priority'] ?? '-'} position=${entry['insertionPosition'] ?? '-'}',
                    ),
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
                      '${((entry['entry'] as Map?)?['id'] ?? '-')} · ${entry['reason'] ?? '-'}',
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 80,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }
}
