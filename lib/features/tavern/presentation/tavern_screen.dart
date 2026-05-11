import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../../core/openclaw/openclaw_settings.dart';
import '../application/tavern_store.dart';
import '../domain/tavern_models.dart';
import 'tavern_chat_screen.dart';
import 'tavern_ui_helpers.dart';

import '../../../../app/theme.dart';

const List<String> _worldbookPositions = <String>[
  'before_character',
  'after_character',
  'before_example_messages',
  'before_chat_history',
  'after_chat_history',
  'before_last_user',
  'at_depth',
];
const List<String> _storyPositions = <String>[
  'in_prompt',
  'at_depth',
  'before_last_user',
];
const List<String> _storyRoles = <String>['system', 'user', 'assistant'];
const List<_BuiltinPromptOrderOption> _builtinPromptOrderOptions =
    <_BuiltinPromptOrderOption>[
      _BuiltinPromptOrderOption(
        'main',
        '主提示词',
        icon: Icons.auto_awesome_outlined,
        colorValue: 0xFF7C4DFF,
      ),
      _BuiltinPromptOrderOption(
        'personaDescription',
        '用户人设',
        icon: Icons.person_outline,
        colorValue: 0xFF2563EB,
      ),
      _BuiltinPromptOrderOption(
        'charDescription',
        '角色描述',
        icon: Icons.badge_outlined,
        colorValue: 0xFF0F766E,
      ),
      _BuiltinPromptOrderOption(
        'charPersonality',
        '角色性格',
        icon: Icons.psychology_alt_outlined,
        colorValue: 0xFF9333EA,
      ),
      _BuiltinPromptOrderOption(
        'scenario',
        '场景设定',
        icon: Icons.landscape_outlined,
        colorValue: 0xFFEA580C,
      ),
      _BuiltinPromptOrderOption(
        'worldInfoBefore',
        '世界信息（前）',
        icon: Icons.public_outlined,
        colorValue: 0xFF0891B2,
      ),
      _BuiltinPromptOrderOption(
        'dialogueExamples',
        '示例对话',
        icon: Icons.forum_outlined,
        colorValue: 0xFF4F46E5,
      ),
      _BuiltinPromptOrderOption(
        'authorNote',
        '作者注入',
        icon: Icons.edit_note_outlined,
        colorValue: 0xFFDB2777,
      ),
      _BuiltinPromptOrderOption(
        'summaries',
        '剧情摘要',
        icon: Icons.summarize_outlined,
        colorValue: 0xFFCA8A04,
      ),
      _BuiltinPromptOrderOption(
        'chatHistory',
        '聊天历史',
        icon: Icons.history_outlined,
        colorValue: 0xFF475569,
      ),
      _BuiltinPromptOrderOption(
        'worldInfoAfter',
        '世界信息（后）',
        icon: Icons.travel_explore_outlined,
        colorValue: 0xFF0284C7,
      ),
      _BuiltinPromptOrderOption(
        'postHistoryInstructions',
        '历史后指令',
        icon: Icons.rule_folder_outlined,
        colorValue: 0xFFB45309,
      ),
    ];

class TavernScreen extends StatefulWidget {
  const TavernScreen({super.key, this.configOnly = false});

  final bool configOnly;

  @override
  State<TavernScreen> createState() => _TavernScreenState();
}

class _TavernScreenState extends State<TavernScreen>
    with AutomaticKeepAliveClientMixin {
  final ImagePicker _picker = ImagePicker();
  bool _isImporting = false;
  String? _serverBaseUrl;
  bool _configHubPrimed = false;
  TavernChat? _selectedDesktopChat;
  TavernCharacter? _selectedDesktopCharacter;
  final Set<String> _expandedWorldBookIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      context.read<TavernStore>().loadLandingData();
      final settings = await OpenClawSettingsStore.load();
      if (!mounted) return;
      setState(() {
        _serverBaseUrl = settings.baseUrl.trim().replaceFirst(
          RegExp(r'/+$'),
          '',
        );
      });
    });
  }

  @override
  bool get wantKeepAlive => true;

  double _desktopChatListWidth(double width) {
    final ideal = width * 0.32;
    if (ideal < 320) return 320;
    if (ideal > 420) return 420;
    return ideal;
  }

  bool _useDesktopChatLayoutForWidth(double width) {
    if (widget.configOnly) return false;
    const detailMinWidth = 520.0;
    const gapWidth = 20.0;
    return width >= _desktopChatListWidth(width) + gapWidth + detailMinWidth;
  }

  void _selectDesktopChat(TavernChat chat, TavernCharacter character) {
    setState(() {
      _selectedDesktopChat = chat;
      _selectedDesktopCharacter = character;
    });
  }

  void _clearDesktopChatSelection() {
    setState(() {
      _selectedDesktopChat = null;
      _selectedDesktopCharacter = null;
    });
  }

  double _lastLayoutWidth = 0;

  bool get _useDesktopLayoutNow {
    final width =
        _lastLayoutWidth > 0
            ? _lastLayoutWidth
            : MediaQuery.of(context).size.width;
    return _useDesktopChatLayoutForWidth(width);
  }

  void _syncDesktopSelection(TavernStore store) {
    if (widget.configOnly || store.recentChats.isEmpty) {
      if (_selectedDesktopChat != null || _selectedDesktopCharacter != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _clearDesktopChatSelection();
        });
      }
      return;
    }

    final selectedChat = _selectedDesktopChat;
    final current =
        selectedChat == null
            ? null
            : store.recentChats
                .where((chat) => chat.id == selectedChat.id)
                .firstOrNull;
    final nextChat = current ?? store.recentChats.first;
    final nextCharacter = store.characters.cast<TavernCharacter?>().firstWhere(
      (item) => item?.id == nextChat.characterId,
      orElse: () => null,
    );
    if (nextCharacter == null) {
      return;
    }
    if (_selectedDesktopChat?.id == nextChat.id &&
        _selectedDesktopCharacter?.id == nextCharacter.id) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _selectDesktopChat(nextChat, nextCharacter);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Consumer<TavernStore>(
      builder: (context, store, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final message = store.lastImportMessage;
          final importResult = store.lastImportResult;
          if (!mounted) return;
          if (message != null && message.isNotEmpty) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(message)));
          }
          if (importResult != null) {
            _showImportReport(importResult);
          }
          if ((message != null && message.isNotEmpty) || importResult != null) {
            context.read<TavernStore>().clearImportMessage();
          }
        });

        return Scaffold(
          appBar: AppBar(
            title: Text(widget.configOnly ? '酒馆配置' : '酒馆'),
            actions:
                widget.configOnly
                    ? null
                    : [
                      IconButton(
                        tooltip: '角色页',
                        onPressed: () => _showCharactersSheet(context),
                        icon: const Icon(Icons.account_box_outlined),
                      ),
                    ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              _lastLayoutWidth = constraints.maxWidth;
              final useDesktopLayout = _useDesktopChatLayoutForWidth(
                constraints.maxWidth,
              );
              if (useDesktopLayout) {
                _syncDesktopSelection(store);
              }
              if (widget.configOnly) {
                return RefreshIndicator(
                  onRefresh: store.loadConfigHubData,
                  child: _ConfigHubTab(
                    serverBaseUrl: _serverBaseUrl,
                    configHubPrimed: _configHubPrimed,
                    onPrime: () {
                      _configHubPrimed = true;
                      context.read<TavernStore>().loadConfigHubData();
                    },
                    onShowPresetsManager:
                        () => _showPresetsManager(context, store),
                    onShowPromptManager:
                        () => _showPromptManager(context, store),
                    onShowWorldBooksManager:
                        () => _showWorldBooksManager(context, store),
                    onShowPersonasManager:
                        () => _showPersonasManager(context, store),
                    onShowGlobalVariablesManager:
                        () => _showGlobalVariablesManager(context, store),
                    onShowQuickReplySettings:
                        () => _showQuickReplySettings(context),
                  ),
                );
              }
              if (useDesktopLayout) {
                return _buildDesktopChatsLayout(
                  context,
                  store,
                  constraints.maxWidth,
                );
              }
              return RefreshIndicator(
                onRefresh: store.loadLandingData,
                child: _ChatsTab(
                  serverBaseUrl: _serverBaseUrl,
                  selectedChatId: _selectedDesktopChat?.id,
                  onOpenChat: _openExistingChat,
                  onConfirmDeleteChat:
                      (chat, character) =>
                          _confirmDeleteChat(context, chat, character),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildDesktopChatsLayout(
    BuildContext context,
    TavernStore store,
    double availableWidth,
  ) {
    final selectedChat = _selectedDesktopChat;
    final selectedCharacter = _selectedDesktopCharacter;
    final listWidth = _desktopChatListWidth(availableWidth);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          SizedBox(
            width: listWidth,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.12),
                ),
              ),
              child: _ChatsTab(
                serverBaseUrl: _serverBaseUrl,
                selectedChatId: selectedChat?.id,
                onOpenChat: _openDesktopChatFromList,
                onConfirmDeleteChat:
                    (chat, character) =>
                        _confirmDeleteChat(context, chat, character),
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child:
                selectedChat != null && selectedCharacter != null
                    ? ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).dividerColor.withValues(alpha: 0.12),
                          ),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: TavernChatScreen(
                          key: ValueKey('desktop-chat-${selectedChat.id}'),
                          chat: selectedChat,
                          character: selectedCharacter,
                          embedded: true,
                          onClose: _clearDesktopChatSelection,
                        ),
                      ),
                    )
                    : _buildDesktopEmptyChatState(context),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopEmptyChatState(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.12),
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.forum_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 14),
              Text(
                '选择一个酒馆会话',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                '桌面端现在会直接在右侧打开聊天，不再整页跳转。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF667085),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCharactersSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder:
          (context) => SafeArea(
            child: FractionallySizedBox(
              heightFactor: 0.92,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '角色页',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '角色不在酒馆首页常驻，按一下再展开。',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        FilledButton.icon(
                          onPressed:
                              _isImporting
                                  ? null
                                  : () async {
                                    Navigator.of(context).pop();
                                    await _importCharacter();
                                  },
                          icon: const Icon(Icons.file_upload_outlined),
                          label: const Text('导入'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Consumer<TavernStore>(
                      builder: (context, store, _) {
                        if (store.isLoading) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if ((store.error ?? '').isNotEmpty) {
                          return ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              Card(
                                child: ListTile(
                                  leading: const Icon(Icons.error_outline),
                                  title: const Text('加载角色失败'),
                                  subtitle: Text(store.error!),
                                ),
                              ),
                            ],
                          );
                        }
                        if (store.characters.isEmpty) {
                          return ListView(
                            padding: const EdgeInsets.all(16),
                            children: const [
                              Card(
                                child: ListTile(
                                  title: Text('还没有角色'),
                                  subtitle: Text(
                                    '支持导入 JSON / PNG / CharX 角色卡。',
                                  ),
                                ),
                              ),
                            ],
                          );
                        }
                        return ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                          children: store.characters
                              .map(
                                (character) => Card(
                                  child: ListTile(
                                    leading: buildTavernAvatar(
                                      avatarPath: character.avatarPath,
                                      serverBaseUrl: _serverBaseUrl,
                                      useDefaultAssetFallback: true,
                                    ),
                                    title: Text(character.name),
                                    subtitle: Text(
                                      character.description.isNotEmpty
                                          ? character.description
                                          : character.scenario,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap:
                                        () => _showCharacterDetail(character),
                                    onLongPress:
                                        () => _confirmDeleteCharacter(
                                          this.context,
                                          character,
                                        ),
                                  ),
                                ),
                              )
                              .toList(growable: false),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  Future<void> _showPresetsManager(
    BuildContext context,
    TavernStore store,
  ) async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(
        builder:
            (_) => Scaffold(
              appBar: AppBar(
                title: const Text('Presets'),
                actions: [
                  IconButton(
                    tooltip: '刷新',
                    onPressed:
                        () => this.context.read<TavernStore>().loadPresets(),
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: '新增 Preset',
                    onPressed: () => _editPreset(context),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              body: _buildPresetsTab(context, store),
            ),
      ),
    );
    if (!mounted) return;
    await this.context.read<TavernStore>().loadPresets();
  }

  Future<void> _showWorldBooksManager(
    BuildContext context,
    TavernStore store,
  ) async {
    for (final book in store.worldBooks) {
      if (store.worldBookEntriesOf(book.id).isEmpty &&
          !store.isLoadingWorldBookEntries(book.id)) {
        store
            .loadWorldBookEntries(book.id)
            .catchError((_) => const <TavernWorldBookEntry>[]);
      }
    }
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(
        builder:
            (_) => Scaffold(
              appBar: AppBar(
                title: const Text('WorldBooks'),
                actions: [
                  IconButton(
                    tooltip: '新增 WorldBook',
                    onPressed: () => _editWorldBook(context),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              body: Consumer<TavernStore>(
                builder:
                    (context, liveStore, _) =>
                        _buildWorldBooksTab(context, liveStore),
              ),
            ),
      ),
    );
    if (!mounted) return;
    await this.context.read<TavernStore>().loadWorldBooks();
  }

  Future<void> _showPromptManager(
    BuildContext context,
    TavernStore store,
  ) async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(
        builder:
            (_) => _PromptManagerPage(
              promptOrder:
                  store.promptOrders.isNotEmpty
                      ? store.promptOrders.first
                      : null,
              buildItems: _buildPromptManagerItems,
              builtinOptionFor: _builtinOptionFor,
              itemLabelBuilder: (item) => _promptOrderItemLabel(store, item),
              itemPositionFor: itemPositionFor,
              editCustomItem:
                  (pageContext, {item}) =>
                      _editPromptManagerCustomItem(pageContext, item: item),
            ),
      ),
    );
    if (!mounted) return;
    await this.context.read<TavernStore>().loadConfigOptions();
  }

  Future<void> _showPersonasManager(
    BuildContext context,
    TavernStore store,
  ) async {
    await store.loadPersonas();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => _SimpleJsonListManagerPage(
              title: 'Personas',
              items: store.personas
                  .map((item) => item.toJson())
                  .toList(growable: false),
              emptyText: '还没有 persona，可新增默认人设。',
              onCreate: (payload) => store.createPersona(payload),
              onUpdate:
                  (id, payload) =>
                      store.updatePersona(personaId: id, payload: payload),
              onDelete: (id) => store.deletePersona(id),
              defaultCreatePayload: const {
                'name': 'User',
                'description': '',
                'isDefault': false,
              },
            ),
      ),
    );
    if (!mounted) return;
    await this.context.read<TavernStore>().loadConfigOptions();
  }

  Future<void> _showGlobalVariablesManager(
    BuildContext context,
    TavernStore store,
  ) async {
    await store.loadGlobalVariables();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => _JsonMapEditorPage(
              title: 'Global Variables',
              initialValue: store.globalVariables,
              onSave: (value) => store.updateGlobalVariables(value),
            ),
      ),
    );
    if (!mounted) return;
    await this.context.read<TavernStore>().loadConfigOptions();
  }

  Future<void> _showQuickReplySettings(BuildContext context) async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(builder: (_) => const _QuickReplySettingsPage()),
    );
  }

  Widget _buildWorldBooksTab(BuildContext context, TavernStore store) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF8F7FF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE7E3F8)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('WorldBooks', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      '先看世界书本身；点开后，再看里面的关键词条目。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF667085),
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: () => _editWorldBook(context),
                icon: const Icon(Icons.add),
                label: const Text('新增'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (store.worldBooks.isEmpty)
          const Card(
            child: ListTile(
              title: Text('还没有 WorldBook'),
              subtitle: Text('先建一本书，再往里填关键词和正文内容。'),
            ),
          )
        else
          ...store.worldBooks.map((book) {
            final entries = store.worldBookEntriesOf(book.id);
            final isLoading = store.isLoadingWorldBookEntries(book.id);
            final isUpdating = store.isUpdatingWorldBook(book.id);
            final error = store.worldBookEntriesErrorOf(book.id) ?? '';
            final hasLoaded = store.hasLoadedWorldBookEntries(book.id);
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: Color(0xFFE8EAF2)),
              ),
              child: GestureDetector(
                onLongPress: () => _confirmDeleteWorldBook(context, book),
                behavior: HitTestBehavior.opaque,
                child: ExpansionTile(
                  key: PageStorageKey<String>('worldbook-${book.id}'),
                  initiallyExpanded: _expandedWorldBookIds.contains(book.id),
                  tilePadding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                  childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  minTileHeight: 0,
                  dense: true,
                  onExpansionChanged: (expanded) {
                    setState(() {
                      if (expanded) {
                        _expandedWorldBookIds.add(book.id);
                      } else {
                        _expandedWorldBookIds.remove(book.id);
                      }
                    });
                    if (expanded && !hasLoaded && !isLoading) {
                      context.read<TavernStore>().loadWorldBookEntries(book.id);
                    }
                  },
                  leading: IgnorePointer(
                    ignoring: isUpdating,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: isUpdating ? 0.55 : 1,
                      child: Switch.adaptive(
                        value: book.enabled,
                        onChanged:
                            (value) => _toggleWorldBook(context, book, value),
                      ),
                    ),
                  ),
                  title: Text(
                    book.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.description.trim().isNotEmpty
                              ? book.description.trim()
                              : (book.isGlobal ? '所有会话可见' : '仅绑定角色可见'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF667085),
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            _softMetaChip(book.isGlobal ? '全局' : '角色绑定'),
                            _softMetaChip(book.enabled ? '启用' : '停用'),
                            if (isUpdating)
                              _softMetaChip('保存中')
                            else if (entries.isNotEmpty)
                              _softMetaChip('${entries.length} 条')
                            else if (isLoading)
                              _softMetaChip('加载中')
                            else if (error.isNotEmpty)
                              _softMetaChip('加载失败')
                            else if (hasLoaded)
                              _softMetaChip('空书')
                            else
                              _softMetaChip('点开看条目'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'WorldBook 操作',
                    padding: EdgeInsets.zero,
                    onSelected: (value) {
                      switch (value) {
                        case 'entry':
                          _editWorldBookEntry(context, worldbook: book);
                          break;
                        case 'edit':
                          _editWorldBook(context, worldbook: book);
                          break;
                        case 'delete':
                          _confirmDeleteWorldBook(context, book);
                          break;
                      }
                    },
                    itemBuilder:
                        (context) => const [
                          PopupMenuItem<String>(
                            value: 'entry',
                            child: Text('新增条目'),
                          ),
                          PopupMenuItem<String>(
                            value: 'edit',
                            child: Text('编辑 WorldBook'),
                          ),
                          PopupMenuItem<String>(
                            value: 'delete',
                            child: Text('删除 WorldBook'),
                          ),
                        ],
                  ),
                  children: [
                    if (isLoading)
                      const _WorldBookInfoBanner(
                        icon: Icons.hourglass_top_rounded,
                        text: '正在读取这本书的条目内容…',
                      )
                    else if (error.isNotEmpty)
                      _WorldBookInfoBanner(
                        icon: Icons.error_outline,
                        text: '条目加载失败：$error',
                        trailing: TextButton.icon(
                          onPressed:
                              () => context
                                  .read<TavernStore>()
                                  .loadWorldBookEntries(book.id),
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                      )
                    else if (hasLoaded && entries.isEmpty)
                      const _WorldBookInfoBanner(
                        icon: Icons.notes_outlined,
                        text: '还没有条目。先加关键词，再写注入内容。',
                      )
                    else if (!hasLoaded)
                      const _WorldBookInfoBanner(
                        icon: Icons.menu_book_outlined,
                        text: '展开后加载条目内容。',
                      )
                    else
                      ...entries.map(
                        (entry) =>
                            _buildWorldBookEntryPreview(context, book, entry),
                      ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildPresetsTab(BuildContext context, TavernStore store) {
    final usedPresets = store.presets
        .where((preset) => _presetUsageCount(store, preset.id) > 0)
        .toList(growable: false);
    final idlePresets = store.presets
        .where((preset) => _presetUsageCount(store, preset.id) == 0)
        .toList(growable: false);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF6F3FF),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5DDFC)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C4DFF).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_outlined,
                      color: Color(0xFF7C4DFF),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Preset Manager',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '把模型参数和注入策略收成可复用模板。列表先看用途，点进再看细节。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _compactInfoPill('共 ${store.presets.length} 套'),
                  _compactInfoPill('使用中 ${usedPresets.length}'),
                  _compactInfoPill('空闲 ${idlePresets.length}'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (store.presets.isEmpty)
          const Card(
            child: ListTile(
              title: Text('还没有 Preset'),
              subtitle: Text('可以创建多套模型参数和 Prompt 组合。'),
            ),
          )
        else ...[
          if (usedPresets.isNotEmpty) ...[
            _managerSectionHeader(
              context,
              title: '当前被会话使用',
              subtitle: '这些 Preset 正在至少一个 Tavern 会话里生效。',
            ),
            const SizedBox(height: 10),
            ...usedPresets.map(
              (preset) => _buildPresetSummaryCard(context, store, preset),
            ),
            const SizedBox(height: 18),
          ],
          if (idlePresets.isNotEmpty) ...[
            _managerSectionHeader(
              context,
              title: '其他 Presets',
              subtitle: '已保存但当前没有会话在使用。',
            ),
            const SizedBox(height: 10),
            ...idlePresets.map(
              (preset) => _buildPresetSummaryCard(context, store, preset),
            ),
          ],
        ],
      ],
    );
  }

  Widget _managerSectionHeader(
    BuildContext context, {
    required String title,
    required String subtitle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildPresetSummaryCard(
    BuildContext context,
    TavernStore store,
    TavernPreset preset,
  ) {
    final usageCount = _presetUsageCount(store, preset.id);
    final promptOrderName = '全局提示词管理';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showPresetDetailsSheet(context, store, preset),
        child: Padding(
          padding: const EdgeInsets.all(14),
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
                          preset.name,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _presetSummaryLine(store, preset),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: const Color(0xFF6F7788)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  PopupMenuButton<String>(
                    tooltip: 'Preset 操作',
                    onSelected: (value) {
                      switch (value) {
                        case 'detail':
                          _showPresetDetailsSheet(context, store, preset);
                          break;
                        case 'duplicate':
                          _duplicatePreset(context, preset);
                          break;
                        case 'edit':
                          _editPreset(context, preset: preset);
                          break;
                      }
                    },
                    itemBuilder:
                        (context) => const [
                          PopupMenuItem<String>(
                            value: 'detail',
                            child: Text('查看详情'),
                          ),
                          PopupMenuItem<String>(
                            value: 'duplicate',
                            child: Text('复制一份'),
                          ),
                          PopupMenuItem<String>(
                            value: 'edit',
                            child: Text('编辑'),
                          ),
                        ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _compactInfoPill(_presetModelLabel(preset)),
                  _compactInfoPill(promptOrderName),
                  _compactInfoPill(
                    'Out ${preset.maxTokens > 0 ? _formatTokenKLabel(preset.maxTokens) : '默认'}',
                  ),
                  _compactInfoPill(
                    'Ctx ${preset.contextLength > 0 ? _formatTokenKLabel(preset.contextLength) : '默认'}',
                  ),
                  _compactInfoPill(
                    'Temp ${preset.temperature.toStringAsFixed(2)}',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _presetStatePill(
                    usageCount > 0 ? '使用中 $usageCount 会话' : '当前未使用',
                    color:
                        usageCount > 0
                            ? const Color(0xFF3FB950)
                            : const Color(0xFF98A1B3),
                  ),
                  const SizedBox(width: 8),
                  if (preset.stopSequences.isNotEmpty)
                    _presetStatePill(
                      'Stop ${preset.stopSequences.length}',
                      color: const Color(0xFFFFB020),
                    ),
                  const Spacer(),
                  Text(
                    '查看详情',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: const Color(0xFF7C4DFF),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: Color(0xFF7C4DFF),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPresetDetailsSheet(
    BuildContext context,
    TavernStore store,
    TavernPreset preset,
  ) async {
    final usageCount = _presetUsageCount(store, preset.id);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder:
          (context) => SafeArea(
            child: FractionallySizedBox(
              heightFactor: 0.88,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              preset.name,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _presetSummaryLine(store, preset),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '复制 Preset',
                        onPressed: () => _duplicatePreset(this.context, preset),
                        icon: const Icon(Icons.copy_outlined),
                      ),
                      IconButton(
                        tooltip: '编辑 Preset',
                        onPressed: () {
                          Navigator.of(context).pop();
                          _editPreset(this.context, preset: preset);
                        },
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _presetSectionCard(
                    context,
                    title: '状态',
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _presetStatePill(
                          usageCount > 0 ? '使用中 $usageCount 会话' : '当前未使用',
                          color:
                              usageCount > 0
                                  ? const Color(0xFF3FB950)
                                  : const Color(0xFF98A1B3),
                        ),
                        _presetStatePill(
                          '全局提示词管理',
                          color: const Color(0xFF7C4DFF),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _presetSectionCard(
                    context,
                    title: '基础',
                    child: Column(
                      children: [
                        _infoRow(
                          'Provider',
                          preset.provider.isEmpty
                              ? '默认 / 未指定'
                              : preset.provider,
                        ),
                        _infoRow(
                          'Model',
                          preset.model.isEmpty ? '默认 / 未指定' : preset.model,
                        ),
                        _infoRow('提示词管理', '全局默认'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _presetSectionCard(
                    context,
                    title: '采样参数',
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _compactInfoPill(
                          'Temp ${preset.temperature.toStringAsFixed(2)}',
                        ),
                        _compactInfoPill(
                          'TopP ${preset.topP.toStringAsFixed(2)}',
                        ),
                        _compactInfoPill('TopK ${preset.topK}'),
                        _compactInfoPill(
                          'MinP ${preset.minP.toStringAsFixed(2)}',
                        ),
                        _compactInfoPill(
                          'Typical ${preset.typicalP.toStringAsFixed(2)}',
                        ),
                        _compactInfoPill(
                          'Repeat ${preset.repetitionPenalty.toStringAsFixed(2)}',
                        ),
                        _compactInfoPill(
                          'MaxOut ${preset.maxTokens > 0 ? _formatTokenKLabel(preset.maxTokens) : '默认'}',
                        ),
                        _compactInfoPill(
                          'Context ${preset.contextLength > 0 ? _formatTokenKLabel(preset.contextLength) : '默认'}',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _presetSectionCard(
                    context,
                    title: 'Prompt 注入',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _compactInfoPill(
                              'Story ${preset.storyStringPosition}',
                            ),
                            _compactInfoPill('Role ${preset.storyStringRole}'),
                            _compactInfoPill(
                              'Depth ${preset.storyStringDepth}',
                            ),
                          ],
                        ),
                        if (preset.storyString.trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            preset.storyString,
                            maxLines: 6,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                        if (preset.chatStart.trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          _infoRow('Chat Start', preset.chatStart),
                        ],
                        if (preset.exampleSeparator.trim().isNotEmpty) ...[
                          _infoRow(
                            'Example Separator',
                            preset.exampleSeparator,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (preset.stopSequences.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _presetSectionCard(
                      context,
                      title: 'Stop Sequences',
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: preset.stopSequences
                            .map((item) => _compactInfoPill(item))
                            .toList(growable: false),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
    );
  }

  Widget _presetSectionCard(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _presetStatePill(String text, {required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF6F7788),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  int _presetUsageCount(TavernStore store, String presetId) {
    if (presetId.isEmpty) return 0;
    return store.recentChats.where((chat) => chat.presetId == presetId).length;
  }

  String _presetModelLabel(TavernPreset preset) {
    if (preset.model.isNotEmpty) return preset.model;
    if (preset.provider.isNotEmpty) return preset.provider;
    return '默认模型';
  }

  String _presetSummaryLine(TavernStore store, TavernPreset preset) {
    final maxTokens =
        preset.maxTokens > 0 ? _formatTokenKLabel(preset.maxTokens) : '默认输出';
    final contextLength =
        preset.contextLength > 0
            ? _formatTokenKLabel(preset.contextLength)
            : '默认上下文';
    return '${_presetModelLabel(preset)} · 输出 $maxTokens · 上下文 $contextLength';
  }

  Future<void> _importCharacter() async {
    final messenger = ScaffoldMessenger.of(context);
    final source = await showModalBottomSheet<String>(
      context: context,
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: const Text('导入 PNG 角色卡'),
                  onTap: () => Navigator.of(context).pop('png'),
                ),
                ListTile(
                  leading: const Icon(Icons.data_object_outlined),
                  title: const Text('导入 JSON 角色卡'),
                  onTap: () => Navigator.of(context).pop('json'),
                ),
                ListTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: const Text('导入 CharX'),
                  onTap: () => Navigator.of(context).pop('charx'),
                ),
              ],
            ),
          ),
    );
    if (!mounted || source == null) return;

    String filename;
    late final Uint8List bytes;
    final expected =
        source == 'png'
            ? '.png'
            : source == 'json'
            ? '.json'
            : '.charx';

    if (source == 'png') {
      final file = await _picker.pickImage(source: ImageSource.gallery);
      if (!mounted || file == null) return;
      filename = file.name;
      bytes = await file.readAsBytes();
    } else {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [expected.substring(1)],
        withData: true,
      );
      if (!mounted || result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      if (picked.bytes == null) {
        messenger.showSnackBar(const SnackBar(content: Text('读取文件失败')));
        return;
      }
      filename = picked.name;
      bytes = picked.bytes!;
    }

    final lower = filename.toLowerCase();
    if (!lower.endsWith(expected)) {
      messenger.showSnackBar(SnackBar(content: Text('请选择 $expected 文件')));
      return;
    }

    if (!mounted) return;
    final store = context.read<TavernStore>();

    try {
      setState(() => _isImporting = true);
      await store.importCharacterFile(filename: filename, bytes: bytes);
      if (!mounted) return;
    } catch (exc) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$exc')));
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  Future<void> _showImportReport(TavernCharacterImportResult result) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder:
          (context) => SafeArea(
            child: FractionallySizedBox(
              heightFactor: 0.88,
              child: _CharacterImportReportSheet(
                character: result.character,
                warnings: result.warnings,
                serverBaseUrl: _serverBaseUrl,
                onStartChat: () async {
                  Navigator.of(context).pop();
                  await _startChatWithCharacter(result.character);
                },
                onViewDetail: () async {
                  Navigator.of(context).pop();
                  await _showCharacterDetail(result.character);
                },
              ),
            ),
          ),
    );
  }

  Future<void> _showCharacterDetail(TavernCharacter character) async {
    final latestCharacter = await context.read<TavernStore>().getCharacter(
      character.id,
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder:
          (context) => SafeArea(
            child: FractionallySizedBox(
              heightFactor: 0.9,
              child: _CharacterDetailSheet(
                character: latestCharacter,
                serverBaseUrl: _serverBaseUrl,
                onStartChat: () async {
                  Navigator.of(context).pop();
                  await _startChatWithCharacter(latestCharacter);
                },
              ),
            ),
          ),
    );
  }

  Future<void> _startChatWithCharacter(TavernCharacter character) async {
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
      if (_useDesktopLayoutNow) {
        _selectDesktopChat(chat, character);
        await context.read<TavernStore>().loadRecentChats();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TavernChatScreen(chat: chat, character: character),
        ),
      );
      if (!mounted) return;
      await context.read<TavernStore>().loadRecentChats();
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

  Future<void> _openDesktopChatFromList(TavernChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final store = context.read<TavernStore>();
      final cached = store.peekChatSnapshot(chat.id);
      final character =
          cached?.character ?? await store.getCharacter(chat.characterId);
      if (!mounted) return;
      _selectDesktopChat(chat, character);
    } catch (exc) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('打开会话失败：$exc')));
    }
  }

  Future<void> _openExistingChat(TavernChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final store = context.read<TavernStore>();
      final cached = store.peekChatSnapshot(chat.id);
      final character =
          cached?.character ?? await store.getCharacter(chat.characterId);
      if (!mounted) return;
      if (_useDesktopLayoutNow) {
        _selectDesktopChat(chat, character);
        await store.loadRecentChats();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TavernChatScreen(chat: chat, character: character),
        ),
      );
      if (!mounted) return;
      await store.loadRecentChats();
    } catch (exc) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('打开会话失败：$exc')));
    }
  }

  Future<void> _confirmDeleteChat(
    BuildContext context,
    TavernChat chat,
    TavernCharacter? character,
  ) async {
    if (!mounted) return;
    final store = context.read<TavernStore>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showModalBottomSheet<bool>(
      context: this.context,
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: const Text('删除会话'),
                  subtitle: Text(character?.name ?? chat.title),
                  onTap: () => Navigator.of(context).pop(true),
                ),
                const ListTile(leading: Icon(Icons.close), title: Text('取消')),
              ],
            ),
          ),
    );
    if (confirmed != true || !mounted) return;
    final doubleConfirmed = await showDialog<bool>(
      context: this.context,
      builder:
          (context) => AlertDialog(
            title: const Text('确认删除会话？'),
            content: Text(
              '删除后，该会话里的消息也会一并移除。\n\n${character?.name ?? chat.title}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (doubleConfirmed != true || !mounted) return;
    try {
      await store.deleteChat(chat.id);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('会话已删除')));
    } catch (exc) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('删除会话失败：$exc')));
    }
  }

  Future<void> _confirmDeleteWorldBook(
    BuildContext context,
    TavernWorldBook worldbook,
  ) async {
    if (!mounted) return;
    final store = context.read<TavernStore>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showModalBottomSheet<bool>(
      context: this.context,
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: const Text('删除 WorldBook'),
                  subtitle: Text(worldbook.name),
                  onTap: () => Navigator.of(context).pop(true),
                ),
                const ListTile(leading: Icon(Icons.close), title: Text('取消')),
              ],
            ),
          ),
    );
    if (confirmed != true || !mounted) return;
    final doubleConfirmed = await showDialog<bool>(
      context: this.context,
      builder:
          (context) => AlertDialog(
            title: const Text('确认删除 WorldBook？'),
            content: Text('删除后，该世界书下的条目也会一并移除。\n\n${worldbook.name}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (doubleConfirmed != true || !mounted) return;
    try {
      await store.deleteWorldBook(worldbook.id);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('WorldBook 已删除')));
    } catch (exc) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('删除 WorldBook 失败：$exc')));
    }
  }

  Future<void> _confirmDeleteCharacter(
    BuildContext context,
    TavernCharacter character,
  ) async {
    if (!mounted) return;
    final store = context.read<TavernStore>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showModalBottomSheet<bool>(
      context: this.context,
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: const Text('删除角色'),
                  subtitle: Text(character.name),
                  onTap: () => Navigator.of(context).pop(true),
                ),
                const ListTile(leading: Icon(Icons.close), title: Text('取消')),
              ],
            ),
          ),
    );
    if (confirmed != true || !mounted) return;
    final doubleConfirmed = await showDialog<bool>(
      context: this.context,
      builder:
          (context) => AlertDialog(
            title: const Text('确认删除角色？'),
            content: Text('删除角色后，会连带删除该角色下的所有会话与消息。\n\n${character.name}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (doubleConfirmed != true || !mounted) return;
    try {
      await store.deleteCharacter(character.id);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('角色已删除')));
    } catch (exc) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('删除角色失败：$exc')));
    }
  }

  Future<void> _duplicatePreset(
    BuildContext context,
    TavernPreset preset,
  ) async {
    try {
      await context.read<TavernStore>().createPreset({
        'name': '${preset.name} Copy',
        'provider': preset.provider,
        'model': preset.model,
        'temperature': preset.temperature,
        'topP': preset.topP,
        'topK': preset.topK,
        'minP': preset.minP,
        'typicalP': preset.typicalP,
        'repetitionPenalty': preset.repetitionPenalty,
        'maxTokens': preset.maxTokens,
        'contextLength': preset.contextLength,
        'thinkingEnabled': preset.thinkingEnabled,
        'thinkingBudget': preset.thinkingBudget,
        'reasoningEffort': preset.reasoningEffort,
        'stopSequences': preset.stopSequences,
        'storyString': preset.storyString,
        'chatStart': preset.chatStart,
        'exampleSeparator': preset.exampleSeparator,
        'storyStringPosition': preset.storyStringPosition,
        'storyStringDepth': preset.storyStringDepth,
        'storyStringRole': preset.storyStringRole,
      });
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Preset 已复制')));
    } catch (exc) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('复制 Preset 失败：$exc')));
    }
  }

  Future<void> _editPreset(BuildContext context, {TavernPreset? preset}) async {
    final store = context.read<TavernStore>();
    final providers = store.providers;
    final isCreate = preset == null;
    final existingPreset = preset;
    final nameController = TextEditingController(
      text: existingPreset?.name ?? '',
    );
    final modelController = TextEditingController(text: preset?.model ?? '');
    final storyController = TextEditingController(
      text: preset?.storyString ?? '',
    );
    final chatStartController = TextEditingController(
      text: preset?.chatStart ?? '',
    );
    final exampleController = TextEditingController(
      text: preset?.exampleSeparator ?? '',
    );
    final stopController = TextEditingController(
      text: (preset?.stopSequences ?? const <String>[]).join('\n'),
    );
    String providerId = preset?.provider ?? '';
    String storyPosition = preset?.storyStringPosition ?? 'in_prompt';
    String storyRole = preset?.storyStringRole ?? 'system';
    double temperature = preset?.temperature ?? 1;
    double topP = preset?.topP ?? 1;
    double frequencyPenalty = preset?.frequencyPenalty ?? 0;
    double presencePenalty = preset?.presencePenalty ?? 0;
    double topA = preset?.topA ?? 0;
    double minP = preset?.minP ?? 0;
    double typicalP = preset?.typicalP ?? 1;
    double repetitionPenalty = preset?.repetitionPenalty ?? 1;
    int topK = preset?.topK ?? 0;
    int maxTokens = preset?.maxTokens ?? 8192;
    int contextLength = preset?.contextLength ?? 200000;
    int storyDepth = preset?.storyStringDepth ?? 1;
    bool thinkingEnabled = preset?.thinkingEnabled ?? false;
    bool showThinking = preset?.showThinking ?? false;
    int thinkingBudget = preset?.thinkingBudget ?? 0;
    String reasoningEffort =
        (preset?.reasoningEffort ?? '').isNotEmpty
            ? preset!.reasoningEffort
            : 'medium';
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
                            isCreate
                                ? '新建 Preset'
                                : '编辑 Preset：${existingPreset?.name ?? ''}',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '按 Native 的思路，把 Preset 当成可复用模板来管理。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 16),
                          _presetSectionCard(
                            context,
                            title: '基础',
                            child: Column(
                              children: [
                                TextField(
                                  controller: nameController,
                                  decoration: const InputDecoration(
                                    labelText: '名称',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                DropdownButtonFormField<String>(
                                  value:
                                      providers.any(
                                            (item) => item.id == providerId,
                                          )
                                          ? providerId
                                          : null,
                                  decoration: const InputDecoration(
                                    labelText: 'Provider',
                                    border: OutlineInputBorder(),
                                  ),
                                  items: [
                                    const DropdownMenuItem<String>(
                                      value: '',
                                      child: Text('默认 / 未指定'),
                                    ),
                                    ...providers.map(
                                      (provider) => DropdownMenuItem<String>(
                                        value: provider.id,
                                        child: Text(
                                          provider.label.isEmpty
                                              ? provider.id
                                              : provider.label,
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged:
                                      (value) => setModalState(
                                        () => providerId = value ?? '',
                                      ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: modelController,
                                  decoration: const InputDecoration(
                                    labelText: 'Model',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8F7FC),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: const Color(0xFFE9E5F4),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: const [
                                      Text(
                                        '提示词管理',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      SizedBox(height: 4),
                                      Text(
                                        'Preset 不再单独绑定 Prompt Order；统一使用全局提示词管理。',
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _presetSectionCard(
                            context,
                            title: 'Prompt 注入',
                            child: Column(
                              children: [
                                TextField(
                                  controller: storyController,
                                  minLines: 4,
                                  maxLines: 8,
                                  decoration: const InputDecoration(
                                    labelText: 'Story String',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: chatStartController,
                                  minLines: 1,
                                  maxLines: 4,
                                  decoration: const InputDecoration(
                                    labelText: 'Chat Start',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: exampleController,
                                  minLines: 1,
                                  maxLines: 4,
                                  decoration: const InputDecoration(
                                    labelText: 'Example Separator',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: stopController,
                                  minLines: 2,
                                  maxLines: 5,
                                  decoration: const InputDecoration(
                                    labelText: 'Stop Sequences（每行一个）',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: DropdownButtonFormField<String>(
                                        value: storyPosition,
                                        decoration: const InputDecoration(
                                          labelText: 'Story Position',
                                          border: OutlineInputBorder(),
                                        ),
                                        items: _storyPositions
                                            .map(
                                              (item) =>
                                                  DropdownMenuItem<String>(
                                                    value: item,
                                                    child: Text(item),
                                                  ),
                                            )
                                            .toList(growable: false),
                                        onChanged:
                                            (value) => setModalState(
                                              () =>
                                                  storyPosition =
                                                      value ?? 'in_prompt',
                                            ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: DropdownButtonFormField<String>(
                                        value: storyRole,
                                        decoration: const InputDecoration(
                                          labelText: 'Story Role',
                                          border: OutlineInputBorder(),
                                        ),
                                        items: _storyRoles
                                            .map(
                                              (item) =>
                                                  DropdownMenuItem<String>(
                                                    value: item,
                                                    child: Text(item),
                                                  ),
                                            )
                                            .toList(growable: false),
                                        onChanged:
                                            (value) => setModalState(
                                              () =>
                                                  storyRole = value ?? 'system',
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                _intStepper(
                                  context,
                                  label: 'Story Depth',
                                  value: storyDepth,
                                  min: 0,
                                  max: 12,
                                  onChanged:
                                      (value) => setModalState(
                                        () => storyDepth = value,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _presetSectionCard(
                            context,
                            title: 'Thinking / Reasoning',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('启用 Thinking'),
                                  subtitle: const Text(
                                    '先支持 DeepSeek。开启后会向上游发送 thinking 参数。',
                                  ),
                                  value: thinkingEnabled,
                                  onChanged:
                                      (value) => setModalState(
                                        () => thinkingEnabled = value,
                                      ),
                                ),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('显示 Thinking'),
                                  subtitle: const Text(
                                    '仅在当前流式回复期间临时显示，不写入历史消息。',
                                  ),
                                  value: showThinking,
                                  onChanged:
                                      (value) => setModalState(
                                        () => showThinking = value,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                DropdownButtonFormField<String>(
                                  value:
                                      const [
                                            'low',
                                            'medium',
                                            'high',
                                          ].contains(reasoningEffort)
                                          ? reasoningEffort
                                          : 'medium',
                                  decoration: const InputDecoration(
                                    labelText: 'Reasoning Effort',
                                    border: OutlineInputBorder(),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'low',
                                      child: Text('low'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'medium',
                                      child: Text('medium'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'high',
                                      child: Text('high'),
                                    ),
                                  ],
                                  onChanged:
                                      thinkingEnabled
                                          ? (value) => setModalState(
                                            () =>
                                                reasoningEffort =
                                                    value ?? 'medium',
                                          )
                                          : null,
                                ),
                                const SizedBox(height: 12),
                                _tokenSliderField(
                                  context,
                                  label: 'Thinking Budget',
                                  value: thinkingBudget,
                                  min: 0,
                                  max: 32768,
                                  step: 256,
                                  helperText:
                                      '0 表示不额外指定，交给上游默认值。当前优先对 DeepSeek 生效。',
                                  onChanged:
                                      thinkingEnabled
                                          ? (value) {
                                            setModalState(
                                              () => thinkingBudget = value,
                                            );
                                          }
                                          : (_) {},
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _presetSectionCard(
                            context,
                            title: '采样参数',
                            child: Column(
                              children: [
                                _sliderField(
                                  context,
                                  label: 'Temperature',
                                  value: temperature,
                                  min: 0,
                                  max: 2,
                                  divisions: 20,
                                  onChanged:
                                      (value) => setModalState(
                                        () => temperature = value,
                                      ),
                                ),
                                _sliderField(
                                  context,
                                  label: 'Top P',
                                  value: topP,
                                  min: 0,
                                  max: 1,
                                  divisions: 20,
                                  onChanged:
                                      (value) =>
                                          setModalState(() => topP = value),
                                ),
                                _sliderField(
                                  context,
                                  label: 'Frequency Penalty',
                                  value: frequencyPenalty,
                                  min: -2,
                                  max: 2,
                                  divisions: 40,
                                  onChanged:
                                      (value) => setModalState(
                                        () => frequencyPenalty = value,
                                      ),
                                ),
                                _sliderField(
                                  context,
                                  label: 'Presence Penalty',
                                  value: presencePenalty,
                                  min: -2,
                                  max: 2,
                                  divisions: 40,
                                  onChanged:
                                      (value) => setModalState(
                                        () => presencePenalty = value,
                                      ),
                                ),
                                _sliderField(
                                  context,
                                  label: 'Top A',
                                  value: topA,
                                  min: 0,
                                  max: 1,
                                  divisions: 20,
                                  onChanged:
                                      (value) =>
                                          setModalState(() => topA = value),
                                ),
                                _sliderField(
                                  context,
                                  label: 'Min P',
                                  value: minP,
                                  min: 0,
                                  max: 1,
                                  divisions: 20,
                                  onChanged:
                                      (value) =>
                                          setModalState(() => minP = value),
                                ),
                                _sliderField(
                                  context,
                                  label: 'Typical P',
                                  value: typicalP,
                                  min: 0,
                                  max: 1,
                                  divisions: 20,
                                  onChanged:
                                      (value) =>
                                          setModalState(() => typicalP = value),
                                ),
                                _sliderField(
                                  context,
                                  label: 'Repetition Penalty',
                                  value: repetitionPenalty,
                                  min: 0.5,
                                  max: 2,
                                  divisions: 30,
                                  onChanged:
                                      (value) => setModalState(
                                        () => repetitionPenalty = value,
                                      ),
                                ),
                                _intStepper(
                                  context,
                                  label: 'Top K',
                                  value: topK,
                                  min: 0,
                                  max: 200,
                                  onChanged:
                                      (value) =>
                                          setModalState(() => topK = value),
                                ),
                                _tokenSliderField(
                                  context,
                                  label: 'Max Output Tokens',
                                  value: maxTokens,
                                  min: 0,
                                  max: 1000000,
                                  step: 1000,
                                  helperText:
                                      '控制单次回复最多可生成多少 token。0 表示交给服务端默认值。',
                                  onChanged:
                                      (value) => setModalState(
                                        () => maxTokens = value,
                                      ),
                                ),
                                const SizedBox(height: 12),
                                _tokenSliderField(
                                  context,
                                  label: 'Context Length',
                                  value: contextLength,
                                  min: 0,
                                  max: 1000000,
                                  step: 1000,
                                  helperText:
                                      '控制上下文窗口上限。DeepSeek 文档当前标注 v4-flash / v4-pro 支持 1M context。',
                                  onChanged:
                                      (value) => setModalState(
                                        () => contextLength = value,
                                      ),
                                ),
                              ],
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
                                            final payload = {
                                              'name':
                                                  nameController.text
                                                          .trim()
                                                          .isEmpty
                                                      ? (isCreate
                                                          ? '未命名 Preset'
                                                          : (existingPreset
                                                                  ?.name ??
                                                              '未命名 Preset'))
                                                      : nameController.text
                                                          .trim(),
                                              'provider': providerId,
                                              'model':
                                                  modelController.text.trim(),
                                              'storyString':
                                                  storyController.text,
                                              'chatStart':
                                                  chatStartController.text,
                                              'exampleSeparator':
                                                  exampleController.text,
                                              'storyStringPosition':
                                                  storyPosition,
                                              'storyStringRole': storyRole,
                                              'storyStringDepth': storyDepth,
                                              'temperature': temperature,
                                              'topP': topP,
                                              'frequencyPenalty':
                                                  frequencyPenalty,
                                              'presencePenalty':
                                                  presencePenalty,
                                              'topA': topA,
                                              'topK': topK,
                                              'minP': minP,
                                              'typicalP': typicalP,
                                              'repetitionPenalty':
                                                  repetitionPenalty,
                                              'maxTokens': maxTokens,
                                              'contextLength': contextLength,
                                              'thinkingEnabled':
                                                  thinkingEnabled,
                                              'showThinking': showThinking,
                                              'thinkingBudget': thinkingBudget,
                                              'reasoningEffort':
                                                  reasoningEffort,
                                              'stopSequences': stopController
                                                  .text
                                                  .split('\n')
                                                  .map((item) => item.trim())
                                                  .where(
                                                    (item) => item.isNotEmpty,
                                                  )
                                                  .toList(growable: false),
                                            };
                                            if (isCreate) {
                                              await store.createPreset(payload);
                                            } else {
                                              await store.updatePreset(
                                                presetId:
                                                    existingPreset?.id ?? '',
                                                payload: payload,
                                              );
                                            }
                                            if (context.mounted) {
                                              Navigator.of(context).pop(true);
                                            }
                                          } catch (exc) {
                                            if (!context.mounted) return;
                                            setModalState(() => saving = false);
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '${isCreate ? '创建' : '保存'} Preset 失败：$exc',
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
                                        : Text(isCreate ? '创建' : '保存'),
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

    nameController.dispose();
    modelController.dispose();
    storyController.dispose();
    chatStartController.dispose();
    exampleController.dispose();
    stopController.dispose();

    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isCreate ? 'Preset 已创建' : 'Preset 已更新')),
      );
      await context.read<TavernStore>().loadPresets();
    }
  }

  List<TavernPromptOrderItem> _buildPromptManagerItems(
    List<TavernPromptOrderItem> rawItems,
  ) {
    final normalized = <TavernPromptOrderItem>[];
    final byIdentifier = <String, TavernPromptOrderItem>{};
    for (final item in rawItems) {
      if (item.identifier.isNotEmpty) {
        byIdentifier[item.identifier] = item;
      }
    }
    for (var i = 0; i < _builtinPromptOrderOptions.length; i += 1) {
      final option = _builtinPromptOrderOptions[i];
      final existing = byIdentifier[option.identifier];
      normalized.add(
        (existing ??
                TavernPromptOrderItem(
                  identifier: option.identifier,
                  enabled: true,
                  builtIn: true,
                  orderIndex: i * 10,
                ))
            .copyWith(
              identifier: option.identifier,
              name: option.label,
              builtIn: true,
              role: 'system',
              content: '',
              orderIndex: existing?.orderIndex ?? i * 10,
            ),
      );
    }
    final customItems =
        rawItems.where((item) => item.isCustom).toList()
          ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    normalized.addAll(customItems);
    normalized.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    for (var i = 0; i < normalized.length; i += 1) {
      normalized[i] = normalized[i].copyWith(orderIndex: i * 10);
    }
    return normalized;
  }

  String itemPositionFor(TavernPromptOrderItem item) {
    if (item.position == 'at_depth' || item.identifier == 'authorNote') {
      return 'at_depth';
    }
    switch (item.identifier) {
      case 'main':
        return 'after_system';
      case 'personaDescription':
        return 'after_system';
      case 'charDescription':
      case 'charPersonality':
        return 'before_character';
      case 'scenario':
      case 'worldInfoAfter':
        return 'after_character';
      case 'dialogueExamples':
        return 'before_example_messages';
      case 'worldInfoBefore':
      case 'summaries':
        return 'before_chat_history';
      case 'chatHistory':
        return 'before_last_user';
      case 'postHistoryInstructions':
        return 'after_chat_history';
      default:
        return item.position.isEmpty ? 'after_chat_history' : item.position;
    }
  }

  Future<TavernPromptOrderItem?> _editPromptManagerCustomItem(
    BuildContext context, {
    TavernPromptOrderItem? item,
  }) async {
    final nameController = TextEditingController(text: item?.name ?? '');
    final contentController = TextEditingController(text: item?.content ?? '');
    String role =
        (item?.role ?? 'system').trim().isEmpty
            ? 'system'
            : (item?.role ?? 'system');

    final result = await showModalBottomSheet<TavernPromptOrderItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder:
          (context) => SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 8,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: StatefulBuilder(
                builder:
                    (context, setModalState) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item == null ? '新增自定义提示词' : '编辑自定义提示词',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: nameController,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: '名称',
                            hintText: '例如：回复风格约束',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          value: _storyRoles.contains(role) ? role : 'system',
                          decoration: const InputDecoration(
                            labelText: 'Role',
                            border: OutlineInputBorder(),
                          ),
                          items: _storyRoles
                              .map(
                                (value) => DropdownMenuItem<String>(
                                  value: value,
                                  child: Text(value),
                                ),
                              )
                              .toList(growable: false),
                          onChanged:
                              (value) =>
                                  setModalState(() => role = value ?? 'system'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: contentController,
                          minLines: 8,
                          maxLines: 14,
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
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('取消'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () {
                                Navigator.of(context).pop(
                                  TavernPromptOrderItem(
                                    identifier: '',
                                    name:
                                        nameController.text.trim().isEmpty
                                            ? '自定义提示词'
                                            : nameController.text.trim(),
                                    role: role,
                                    content: contentController.text,
                                    enabled: item?.enabled ?? true,
                                    orderIndex: item?.orderIndex ?? 0,
                                    position:
                                        item?.position ?? 'after_chat_history',
                                    builtIn: false,
                                  ),
                                );
                              },
                              child: const Text('保存'),
                            ),
                          ],
                        ),
                      ],
                    ),
              ),
            ),
          ),
    );

    nameController.dispose();
    contentController.dispose();
    return result;
  }

  Future<void> _toggleWorldBook(
    BuildContext context,
    TavernWorldBook worldbook,
    bool enabled,
  ) async {
    try {
      await context.read<TavernStore>().updateWorldBook(
        worldbookId: worldbook.id,
        payload: {'enabled': enabled},
      );
    } catch (exc) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('更新 WorldBook 失败：$exc')));
    }
  }

  Future<void> _editWorldBook(
    BuildContext context, {
    TavernWorldBook? worldbook,
  }) async {
    final isCreate = worldbook == null;
    final existingWorldbook = worldbook;
    final store = context.read<TavernStore>();
    final nameController = TextEditingController(
      text: existingWorldbook?.name ?? '',
    );
    final descriptionController = TextEditingController(
      text: worldbook?.description ?? '',
    );
    bool enabled = worldbook?.enabled ?? true;
    String scope = worldbook?.scope ?? 'local';
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
                        children: [
                          Text(
                            isCreate ? '新建 WorldBook' : '编辑 WorldBook',
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
                          SegmentedButton<String>(
                            segments: const [
                              ButtonSegment<String>(
                                value: 'local',
                                label: Text('非全局'),
                                icon: Icon(Icons.person_outline),
                              ),
                              ButtonSegment<String>(
                                value: 'global',
                                label: Text('全局'),
                                icon: Icon(Icons.public_outlined),
                              ),
                            ],
                            selected: <String>{scope},
                            onSelectionChanged: (value) {
                              final next =
                                  value.isEmpty ? 'local' : value.first;
                              setModalState(() => scope = next);
                            },
                          ),
                          const SizedBox(height: 12),
                          Text(
                            scope == 'global'
                                ? '全局世界书会对所有会话可见。'
                                : '非全局世界书默认只对绑定角色可见；角色卡导入的书也属于这一类。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: nameController,
                            decoration: const InputDecoration(
                              labelText: '名称',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: descriptionController,
                            minLines: 3,
                            maxLines: 6,
                            decoration: const InputDecoration(
                              labelText: '描述',
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
                                            final payload = {
                                              'name':
                                                  nameController.text
                                                          .trim()
                                                          .isEmpty
                                                      ? '未命名世界书'
                                                      : nameController.text
                                                          .trim(),
                                              'description':
                                                  descriptionController.text,
                                              'scope': scope,
                                              'enabled': enabled,
                                            };
                                            if (isCreate) {
                                              await store.createWorldBook(
                                                payload,
                                              );
                                            } else {
                                              await store.updateWorldBook(
                                                worldbookId:
                                                    existingWorldbook?.id ?? '',
                                                payload: payload,
                                              );
                                            }
                                            if (context.mounted) {
                                              Navigator.of(context).pop(true);
                                            }
                                          } catch (exc) {
                                            if (!context.mounted) return;
                                            setModalState(() => saving = false);
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '${isCreate ? '创建' : '保存'} WorldBook 失败：$exc',
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
                                        : Text(isCreate ? '创建' : '保存'),
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

    nameController.dispose();
    descriptionController.dispose();

    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isCreate ? 'WorldBook 已创建' : 'WorldBook 已更新')),
      );
      await context.read<TavernStore>().loadWorldBooks();
    }
  }

  Future<void> _editWorldBookEntry(
    BuildContext context, {
    required TavernWorldBook worldbook,
    TavernWorldBookEntry? entry,
  }) async {
    final isCreate = entry == null;
    final existingEntry = entry;
    final store = context.read<TavernStore>();
    final keysController = TextEditingController(
      text: (existingEntry?.keys ?? const <String>[]).join('\n'),
    );
    final secondaryController = TextEditingController(
      text: (entry?.secondaryKeys ?? const <String>[]).join('\n'),
    );
    final contentController = TextEditingController(text: entry?.content ?? '');
    final groupController = TextEditingController(text: entry?.groupName ?? '');
    final characterNamesController = TextEditingController(
      text: (entry?.characterFilterNames ?? const <String>[]).join('\n'),
    );
    final characterTagsController = TextEditingController(
      text: (entry?.characterFilterTags ?? const <String>[]).join('\n'),
    );
    bool enabled = entry?.enabled ?? true;
    bool recursive = entry?.recursive ?? false;
    bool constant = entry?.constant ?? false;
    bool preventRecursion = entry?.preventRecursion ?? false;
    bool caseSensitive = entry?.caseSensitive ?? false;
    bool matchWholeWords = entry?.matchWholeWords ?? false;
    bool matchCharacterDescription = entry?.matchCharacterDescription ?? false;
    bool matchCharacterPersonality = entry?.matchCharacterPersonality ?? false;
    bool matchScenario = entry?.matchScenario ?? false;
    bool useGroupScoring = entry?.useGroupScoring ?? false;
    bool groupOverride = entry?.groupOverride ?? false;
    bool ignoreBudget = entry?.ignoreBudget ?? false;
    bool characterFilterExclude = entry?.characterFilterExclude ?? false;
    String secondaryLogic = entry?.secondaryLogic ?? 'and_any';
    String insertionPosition =
        entry?.insertionPosition ?? 'before_chat_history';
    int priority = entry?.priority ?? 0;
    int scanDepth = entry?.scanDepth ?? 0;
    int groupWeight = entry?.groupWeight ?? 100;
    int delayUntilRecursion = entry?.delayUntilRecursion ?? 0;
    int probability = entry?.probability ?? 100;
    int sticky = entry?.sticky ?? 0;
    int cooldown = entry?.cooldown ?? 0;
    int delay = entry?.delay ?? 0;
    bool saving = false;
    bool showAdvanced =
        existingEntry != null && _entryUsesAdvancedOptions(existingEntry);

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
                        children: [
                          Text(
                            isCreate
                                ? '新建 WorldBook Entry'
                                : '编辑 WorldBook Entry',
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
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('常驻注入'),
                            subtitle: const Text('打开后，不等关键词命中也会持续注入。'),
                            value: constant,
                            onChanged:
                                (value) =>
                                    setModalState(() => constant = value),
                          ),
                          TextField(
                            controller: keysController,
                            minLines: 2,
                            maxLines: 5,
                            decoration: const InputDecoration(
                              labelText: '关键词（每行一个）',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: contentController,
                            minLines: 5,
                            maxLines: 12,
                            decoration: const InputDecoration(
                              labelText: '内容',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: insertionPosition,
                            decoration: const InputDecoration(
                              labelText: '插入位置',
                              border: OutlineInputBorder(),
                            ),
                            items: _worldbookPositions
                                .map(
                                  (item) => DropdownMenuItem<String>(
                                    value: item,
                                    child: Text(item),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged:
                                (value) => setModalState(
                                  () =>
                                      insertionPosition =
                                          value ?? 'before_chat_history',
                                ),
                          ),
                          const SizedBox(height: 12),
                          _intStepper(
                            context,
                            label: '优先级',
                            value: priority,
                            min: -20,
                            max: 50,
                            onChanged:
                                (value) =>
                                    setModalState(() => priority = value),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed:
                                () => setModalState(
                                  () => showAdvanced = !showAdvanced,
                                ),
                            icon: Icon(
                              showAdvanced ? Icons.expand_less : Icons.tune,
                            ),
                            label: Text(showAdvanced ? '收起高级设置' : '展开高级设置'),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '大多数情况下，下面这些兼容参数都用不上。只有你真的在做复杂触发逻辑时再碰它们。',
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(
                              color: const Color(0xFF667085),
                              height: 1.45,
                            ),
                          ),
                          if (showAdvanced) ...[
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF8FAFC),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: const Color(0xFFE2E8F0),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '高级兼容参数',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 12),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('允许递归触发'),
                                    value: recursive,
                                    onChanged:
                                        (value) => setModalState(
                                          () => recursive = value,
                                        ),
                                  ),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('禁止重复连锁'),
                                    value: preventRecursion,
                                    onChanged:
                                        (value) => setModalState(
                                          () => preventRecursion = value,
                                        ),
                                  ),
                                  TextField(
                                    controller: secondaryController,
                                    minLines: 2,
                                    maxLines: 5,
                                    decoration: const InputDecoration(
                                      labelText: '副关键词（每行一个）',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  DropdownButtonFormField<String>(
                                    value: secondaryLogic,
                                    decoration: const InputDecoration(
                                      labelText: '副关键词逻辑',
                                      border: OutlineInputBorder(),
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'and_any',
                                        child: Text('AND ANY'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'and_all',
                                        child: Text('AND ALL'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'not_any',
                                        child: Text('NOT ANY'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'not_all',
                                        child: Text('NOT ALL'),
                                      ),
                                    ],
                                    onChanged:
                                        (value) => setModalState(
                                          () =>
                                              secondaryLogic =
                                                  value ?? 'and_any',
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('区分大小写'),
                                    value: caseSensitive,
                                    onChanged:
                                        (value) => setModalState(
                                          () => caseSensitive = value,
                                        ),
                                  ),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('仅匹配完整单词'),
                                    value: matchWholeWords,
                                    onChanged:
                                        (value) => setModalState(
                                          () => matchWholeWords = value,
                                        ),
                                  ),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('扫描角色描述'),
                                    value: matchCharacterDescription,
                                    onChanged:
                                        (value) => setModalState(
                                          () =>
                                              matchCharacterDescription = value,
                                        ),
                                  ),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('扫描角色性格'),
                                    value: matchCharacterPersonality,
                                    onChanged:
                                        (value) => setModalState(
                                          () =>
                                              matchCharacterPersonality = value,
                                        ),
                                  ),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('扫描场景设定'),
                                    value: matchScenario,
                                    onChanged:
                                        (value) => setModalState(
                                          () => matchScenario = value,
                                        ),
                                  ),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('启用组评分'),
                                    value: useGroupScoring,
                                    onChanged:
                                        (value) => setModalState(
                                          () => useGroupScoring = value,
                                        ),
                                  ),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('组覆盖'),
                                    value: groupOverride,
                                    onChanged:
                                        (value) => setModalState(
                                          () => groupOverride = value,
                                        ),
                                  ),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('忽略预算限制'),
                                    value: ignoreBudget,
                                    onChanged:
                                        (value) => setModalState(
                                          () => ignoreBudget = value,
                                        ),
                                  ),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('角色过滤排除模式'),
                                    subtitle: const Text(
                                      '关闭=仅这些角色/标签生效；开启=排除这些角色/标签',
                                    ),
                                    value: characterFilterExclude,
                                    onChanged:
                                        (value) => setModalState(
                                          () => characterFilterExclude = value,
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  _intStepper(
                                    context,
                                    label: '扫描深度（0 = 最近聊天全部）',
                                    value: scanDepth,
                                    min: 0,
                                    max: 50,
                                    onChanged:
                                        (value) => setModalState(
                                          () => scanDepth = value,
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  _intStepper(
                                    context,
                                    label: '组权重',
                                    value: groupWeight,
                                    min: 1,
                                    max: 10000,
                                    onChanged:
                                        (value) => setModalState(
                                          () => groupWeight = value,
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  _intStepper(
                                    context,
                                    label: '递归前延迟',
                                    value: delayUntilRecursion,
                                    min: 0,
                                    max: 20,
                                    onChanged:
                                        (value) => setModalState(
                                          () => delayUntilRecursion = value,
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  _intStepper(
                                    context,
                                    label: '触发概率 %',
                                    value: probability,
                                    min: 0,
                                    max: 100,
                                    onChanged:
                                        (value) => setModalState(
                                          () => probability = value,
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  _intStepper(
                                    context,
                                    label: '持续生效轮数',
                                    value: sticky,
                                    min: 0,
                                    max: 20,
                                    onChanged:
                                        (value) =>
                                            setModalState(() => sticky = value),
                                  ),
                                  const SizedBox(height: 12),
                                  _intStepper(
                                    context,
                                    label: '冷却轮数',
                                    value: cooldown,
                                    min: 0,
                                    max: 20,
                                    onChanged:
                                        (value) => setModalState(
                                          () => cooldown = value,
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  _intStepper(
                                    context,
                                    label: '延迟生效轮数',
                                    value: delay,
                                    min: 0,
                                    max: 20,
                                    onChanged:
                                        (value) =>
                                            setModalState(() => delay = value),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: groupController,
                                    decoration: const InputDecoration(
                                      labelText: '分组名',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: characterNamesController,
                                    minLines: 1,
                                    maxLines: 4,
                                    decoration: const InputDecoration(
                                      labelText: '角色过滤名称（每行一个）',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: characterTagsController,
                                    minLines: 1,
                                    maxLines: 4,
                                    decoration: const InputDecoration(
                                      labelText: '角色过滤标签（每行一个）',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
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
                                            final payload = {
                                              'keys': keysController.text
                                                  .split('\n')
                                                  .map((item) => item.trim())
                                                  .where(
                                                    (item) => item.isNotEmpty,
                                                  )
                                                  .toList(growable: false),
                                              'secondaryKeys':
                                                  secondaryController.text
                                                      .split('\n')
                                                      .map(
                                                        (item) => item.trim(),
                                                      )
                                                      .where(
                                                        (item) =>
                                                            item.isNotEmpty,
                                                      )
                                                      .toList(growable: false),
                                              'content': contentController.text,
                                              'enabled': enabled,
                                              'priority': priority,
                                              'recursive': recursive,
                                              'constant': constant,
                                              'preventRecursion':
                                                  preventRecursion,
                                              'secondaryLogic': secondaryLogic,
                                              'scanDepth': scanDepth,
                                              'caseSensitive': caseSensitive,
                                              'matchWholeWords':
                                                  matchWholeWords,
                                              'matchCharacterDescription':
                                                  matchCharacterDescription,
                                              'matchCharacterPersonality':
                                                  matchCharacterPersonality,
                                              'matchScenario': matchScenario,
                                              'useGroupScoring':
                                                  useGroupScoring,
                                              'groupWeight': groupWeight,
                                              'groupOverride': groupOverride,
                                              'delayUntilRecursion':
                                                  delayUntilRecursion,
                                              'probability': probability,
                                              'ignoreBudget': ignoreBudget,
                                              'characterFilterNames':
                                                  characterNamesController.text
                                                      .split('\n')
                                                      .map(
                                                        (item) => item.trim(),
                                                      )
                                                      .where(
                                                        (item) =>
                                                            item.isNotEmpty,
                                                      )
                                                      .toList(growable: false),
                                              'characterFilterTags':
                                                  characterTagsController.text
                                                      .split('\n')
                                                      .map(
                                                        (item) => item.trim(),
                                                      )
                                                      .where(
                                                        (item) =>
                                                            item.isNotEmpty,
                                                      )
                                                      .toList(growable: false),
                                              'characterFilterExclude':
                                                  characterFilterExclude,
                                              'sticky': sticky,
                                              'cooldown': cooldown,
                                              'delay': delay,
                                              'insertionPosition':
                                                  insertionPosition,
                                              'groupName':
                                                  groupController.text.trim(),
                                            };
                                            if (isCreate) {
                                              await store.createWorldBookEntry(
                                                worldbookId: worldbook.id,
                                                payload: payload,
                                              );
                                            } else {
                                              await store.updateWorldBookEntry(
                                                worldbookId: worldbook.id,
                                                entryId:
                                                    existingEntry?.id ?? '',
                                                payload: payload,
                                              );
                                            }
                                            if (context.mounted) {
                                              Navigator.of(context).pop(true);
                                            }
                                          } catch (exc) {
                                            if (!context.mounted) return;
                                            setModalState(() => saving = false);
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '${isCreate ? '创建' : '保存'}条目失败：$exc',
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
                                        : Text(isCreate ? '创建' : '保存'),
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

    keysController.dispose();
    secondaryController.dispose();
    contentController.dispose();
    groupController.dispose();

    if (saved == true && context.mounted) {
      final refreshedStore = context.read<TavernStore>();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isCreate ? 'WorldBook 条目已创建' : 'WorldBook 条目已更新'),
        ),
      );
      await refreshedStore.loadWorldBookEntries(worldbook.id);
      if (!context.mounted) return;
      await refreshedStore.loadWorldBooks();
    }
  }

  _BuiltinPromptOrderOption? _builtinOptionFor(String identifier) {
    for (final option in _builtinPromptOrderOptions) {
      if (option.identifier == identifier) return option;
    }
    return null;
  }

  String _promptOrderItemLabel(TavernStore store, TavernPromptOrderItem item) {
    if (item.identifier.isNotEmpty) {
      final option = _builtinOptionFor(item.identifier);
      if (option != null) return option.label;
      return item.identifier;
    }
    if (item.name.trim().isNotEmpty) return item.name.trim();
    final contentPreview = item.content
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (contentPreview.isNotEmpty) {
      return contentPreview.length <= 18
          ? contentPreview
          : '${contentPreview.substring(0, 18)}…';
    }
    if (item.blockId.isNotEmpty) {
      for (final block in store.promptBlocks) {
        if (block.id == item.blockId) return block.name;
      }
      return item.blockId;
    }
    return '未命名自定义项';
  }

  Widget _compactInfoPill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: desktopAdjustedFontSize(11),
          fontWeight: FontWeight.w600,
          color: Color(0xFF475569),
        ),
      ),
    );
  }

  Widget _sliderField(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ${value.toStringAsFixed(2)}',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
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
    return Row(
      children: [
        Expanded(
          child: Text(
            '$label: $value',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        IconButton(
          onPressed:
              value <= min
                  ? null
                  : () => onChanged((value - step).clamp(min, max)),
          icon: const Icon(Icons.remove_circle_outline),
        ),
        IconButton(
          onPressed:
              value >= max
                  ? null
                  : () => onChanged((value + step).clamp(min, max)),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }

  Widget _buildWorldBookEntryPreview(
    BuildContext context,
    TavernWorldBook worldbook,
    TavernWorldBookEntry entry,
  ) {
    final theme = Theme.of(context);
    final keywordText = entry.keys.isEmpty ? '无关键词' : entry.keys.join(' / ');
    final summary = _entryPositionLabel(entry.insertionPosition);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE6EAF4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  keywordText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF111827),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '编辑条目',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                padding: EdgeInsets.zero,
                onPressed:
                    () => _editWorldBookEntry(
                      context,
                      worldbook: worldbook,
                      entry: entry,
                    ),
                icon: const Icon(Icons.edit_outlined, size: 17),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.content.trim().isEmpty ? '（空内容）' : entry.content.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF667085),
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _softMetaChip(summary),
              _softMetaChip('P${entry.priority}'),
              _softMetaChip(entry.enabled ? '启用' : '停用'),
              if (entry.constant) _softMetaChip('常驻'),
              if (_entryUsesAdvancedOptions(entry)) _softMetaChip('高级'),
            ],
          ),
        ],
      ),
    );
  }

  bool _entryUsesAdvancedOptions(TavernWorldBookEntry? entry) {
    if (entry == null) return false;
    return entry.secondaryKeys.isNotEmpty ||
        entry.secondaryLogic != 'and_any' ||
        entry.recursive ||
        entry.preventRecursion ||
        entry.caseSensitive ||
        entry.matchWholeWords ||
        entry.matchCharacterDescription ||
        entry.matchCharacterPersonality ||
        entry.matchScenario ||
        entry.useGroupScoring ||
        entry.groupWeight != 100 ||
        entry.groupOverride ||
        entry.delayUntilRecursion > 0 ||
        entry.probability != 100 ||
        entry.ignoreBudget ||
        entry.characterFilterNames.isNotEmpty ||
        entry.characterFilterTags.isNotEmpty ||
        entry.characterFilterExclude ||
        entry.sticky > 0 ||
        entry.cooldown > 0 ||
        entry.delay > 0 ||
        entry.groupName.trim().isNotEmpty ||
        entry.scanDepth > 0;
  }

  String _entryPositionLabel(String raw) {
    switch (raw) {
      case 'before_character':
        return '角色信息前';
      case 'after_character':
        return '角色信息后';
      case 'before_example_messages':
        return '示例对话前';
      case 'before_chat_history':
        return '聊天历史前';
      case 'after_chat_history':
        return '聊天历史后';
      case 'before_last_user':
        return '最后一条用户消息前';
      case 'at_depth':
        return '按深度插入';
      default:
        return raw;
    }
  }

  Widget _softMetaChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: desktopAdjustedFontSize(12),
          fontWeight: FontWeight.w600,
          color: Color(0xFF475467),
        ),
      ),
    );
  }

  Widget _tokenSliderField(
    BuildContext context, {
    required String label,
    required int value,
    required int min,
    required int max,
    required int step,
    String? helperText,
    required ValueChanged<int> onChanged,
  }) {
    final safeValue = value.clamp(min, max);
    final divisions = ((max - min) ~/ step).clamp(1, 1000000);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ${_formatTokenKLabel(safeValue)}',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        Slider(
          value: safeValue.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: divisions,
          label: _formatTokenKLabel(safeValue),
          onChanged: (next) {
            final rounded = ((next / step).round() * step).clamp(min, max);
            onChanged(rounded);
          },
        ),
        if (helperText != null && helperText.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              helperText,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  String _formatTokenKLabel(int value) {
    if (value <= 0) {
      return '默认';
    }
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(value % 1000000 == 0 ? 0 : 1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(value % 1000 == 0 ? 0 : 1)}K';
    }
    return '$value';
  }
}

class _WorldBookInfoBanner extends StatelessWidget {
  const _WorldBookInfoBanner({
    required this.icon,
    required this.text,
    this.trailing,
  });

  final IconData icon;
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF667085)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF475467),
                height: 1.45,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

class _CharacterImportReportSheet extends StatelessWidget {
  const _CharacterImportReportSheet({
    required this.character,
    required this.warnings,
    required this.serverBaseUrl,
    required this.onStartChat,
    required this.onViewDetail,
  });

  final TavernCharacter character;
  final List<String> warnings;
  final String? serverBaseUrl;
  final Future<void> Function() onStartChat;
  final Future<void> Function() onViewDetail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = _CharacterImportSummary.fromCharacter(character);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Row(
            children: [
              buildTavernAvatar(
                avatarPath: character.avatarPath,
                serverBaseUrl: serverBaseUrl,
                useDefaultAssetFallback: true,
                radius: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('导入完成', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      character.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ImportStatChip(
                    label: '来源',
                    value: character.sourceType.toUpperCase(),
                  ),
                  _ImportStatChip(
                    label: '字段',
                    value:
                        '${summary.filledFieldCount}/${summary.totalFieldCount}',
                  ),
                  _ImportStatChip(
                    label: '问候',
                    value: '${character.alternateGreetings.length}',
                  ),
                  _ImportStatChip(
                    label: 'Lore',
                    value:
                        summary.lorebookEntryCount > 0
                            ? '${summary.lorebookEntryCount} 条'
                            : '无',
                  ),
                  _ImportStatChip(
                    label: '资产',
                    value: summary.assetSummaryLabel,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (warnings.isNotEmpty) ...[
                _ImportSectionCard(
                  title: '导入警告',
                  icon: Icons.warning_amber_rounded,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: warnings
                        .map(
                          (item) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text('• $item'),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              _ImportSectionCard(
                title: '导入摘要',
                icon: Icons.fact_check_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('名称', character.name),
                    _kv('首句', character.firstMessage),
                    _kv('System Prompt', character.systemPrompt),
                    _kv('Post-History', character.postHistoryInstructions),
                    _kv('Creator Notes', character.creatorNotes),
                    _kv(
                      'Alternate Greetings',
                      character.alternateGreetings.isEmpty
                          ? ''
                          : '${character.alternateGreetings.length} 条',
                    ),
                    _kv(
                      'Embedded Lorebook',
                      summary.lorebookEntryCount > 0
                          ? '${summary.lorebookEntryCount} 条，已随角色导入'
                          : '',
                    ),
                    _kv('CharX 资产', summary.assetDetailLabel),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _ImportSectionCard(
                title: '下一步',
                icon: Icons.rocket_launch_outlined,
                child: Text(
                  '你现在可以直接开始聊天，也可以先打开角色详情检查 system prompt、问候语、embedded lorebook 和资产摘要。',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onViewDetail,
                  child: const Text('查看详情'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: onStartChat,
                  child: const Text('开始聊天'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _kv(String label, String value) {
    if (value.trim().isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text('• $label：未提供'),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text('• $label：$value'),
    );
  }
}

class _CharacterDetailSheet extends StatelessWidget {
  const _CharacterDetailSheet({
    required this.character,
    required this.serverBaseUrl,
    required this.onStartChat,
  });

  final TavernCharacter character;
  final String? serverBaseUrl;
  final Future<void> Function() onStartChat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = _CharacterImportSummary.fromCharacter(character);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Row(
            children: [
              buildTavernAvatar(
                avatarPath: character.avatarPath,
                serverBaseUrl: serverBaseUrl,
                useDefaultAssetFallback: true,
                radius: 32,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(character.name, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (character.creator.isNotEmpty)
                          'by ${character.creator}',
                        if (character.characterVersion.isNotEmpty)
                          'v${character.characterVersion}',
                        if (character.sourceType.isNotEmpty)
                          character.sourceType.toUpperCase(),
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              if (character.tags.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: character.tags
                      .map((tag) => Chip(label: Text(tag)))
                      .toList(growable: false),
                ),
                const SizedBox(height: 16),
              ],
              _ImportSectionCard(
                title: '基础信息',
                icon: Icons.badge_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _detailBlock('Description', character.description),
                    _detailBlock('Personality', character.personality),
                    _detailBlock('Scenario', character.scenario),
                    _detailBlock('First Message', character.firstMessage),
                    _detailBlock(
                      'Example Dialogues',
                      character.exampleDialogues,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _ImportSectionCard(
                title: 'Prompt / Notes',
                icon: Icons.psychology_alt_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _detailBlock('System Prompt', character.systemPrompt),
                    _detailBlock(
                      'Post-History Instructions',
                      character.postHistoryInstructions,
                    ),
                    _detailBlock('Creator Notes', character.creatorNotes),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _ImportSectionCard(
                title: '问候与 Lore',
                icon: Icons.auto_stories_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _detailBlock(
                      'Alternate Greetings',
                      character.alternateGreetings.isEmpty
                          ? ''
                          : character.alternateGreetings
                              .asMap()
                              .entries
                              .map((e) => '${e.key + 1}. ${e.value}')
                              .join('\n\n'),
                    ),
                    _detailBlock(
                      'Embedded Lorebook',
                      summary.lorebookEntryCount > 0
                          ? '检测到 ${summary.lorebookEntryCount} 条 embedded lorebook entries，已作为角色附带知识导入。'
                          : '',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _ImportSectionCard(
                title: '资产摘要',
                icon: Icons.perm_media_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _detailBlock('头像', character.avatarPath),
                    _detailBlock('CharX 资源', summary.assetDetailLabel),
                    _detailBlock('来源文件', character.sourceName),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onStartChat,
              child: const Text('用这个角色开始聊天'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _detailBlock(String title, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(value),
        ],
      ),
    );
  }
}

class _ImportSectionCard extends StatelessWidget {
  const _ImportSectionCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _ImportStatChip extends StatelessWidget {
  const _ImportStatChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text('$label：$value'));
  }
}

class _CharacterImportSummary {
  const _CharacterImportSummary({
    required this.filledFieldCount,
    required this.totalFieldCount,
    required this.lorebookEntryCount,
    required this.assetSummaryLabel,
    required this.assetDetailLabel,
  });

  final int filledFieldCount;
  final int totalFieldCount;
  final int lorebookEntryCount;
  final String assetSummaryLabel;
  final String assetDetailLabel;

  factory _CharacterImportSummary.fromCharacter(TavernCharacter character) {
    final fields = <String>[
      character.description,
      character.personality,
      character.scenario,
      character.firstMessage,
      character.exampleDialogues,
      character.systemPrompt,
      character.postHistoryInstructions,
      character.creatorNotes,
      if (character.alternateGreetings.isNotEmpty) 'alt',
      if (character.tags.isNotEmpty) 'tags',
      if (character.avatarPath.isNotEmpty) 'avatar',
    ];
    final book =
        character.metadata['cardData'] is Map
            ? (character.metadata['cardData'] as Map)['character_book']
            : character.metadata['character_book'];
    final entries =
        book is Map && book['entries'] is List
            ? (book['entries'] as List).length
            : 0;
    final charxAssets = character.metadata['charxAssets'];
    int sprites = 0;
    int backgrounds = 0;
    int misc = 0;
    if (charxAssets is Map) {
      sprites = (charxAssets['sprites'] as num?)?.toInt() ?? 0;
      backgrounds = (charxAssets['backgrounds'] as num?)?.toInt() ?? 0;
      misc = (charxAssets['misc'] as num?)?.toInt() ?? 0;
    }
    final assetSummary =
        sprites + backgrounds + misc > 0
            ? '${sprites + backgrounds + misc} 项'
            : (character.avatarPath.isNotEmpty ? '仅头像' : '无');
    final parts = <String>[];
    if (character.avatarPath.isNotEmpty) parts.add('头像已导入');
    if (sprites > 0) parts.add('$sprites 个 sprite');
    if (backgrounds > 0) parts.add('$backgrounds 个背景');
    if (misc > 0) parts.add('$misc 个附加资源');
    return _CharacterImportSummary(
      filledFieldCount: fields.where((item) => item.trim().isNotEmpty).length,
      totalFieldCount: 11,
      lorebookEntryCount: entries,
      assetSummaryLabel: assetSummary,
      assetDetailLabel: parts.isEmpty ? '未检测到附加资源' : parts.join('，'),
    );
  }
}

class _BuiltinPromptOrderOption {
  const _BuiltinPromptOrderOption(
    this.identifier,
    this.label, {
    required this.icon,
    required this.colorValue,
  });

  final String identifier;
  final String label;
  final IconData icon;
  final int colorValue;
}

class _PromptManagerPage extends StatefulWidget {
  const _PromptManagerPage({
    required this.promptOrder,
    required this.buildItems,
    required this.builtinOptionFor,
    required this.itemLabelBuilder,
    required this.itemPositionFor,
    required this.editCustomItem,
  });

  final TavernPromptOrder? promptOrder;
  final List<TavernPromptOrderItem> Function(List<TavernPromptOrderItem>)
  buildItems;
  final _BuiltinPromptOrderOption? Function(String identifier) builtinOptionFor;
  final String Function(TavernPromptOrderItem item) itemLabelBuilder;
  final String Function(TavernPromptOrderItem item) itemPositionFor;
  final Future<TavernPromptOrderItem?> Function(
    BuildContext context, {
    TavernPromptOrderItem? item,
  })
  editCustomItem;

  @override
  State<_PromptManagerPage> createState() => _PromptManagerPageState();
}

class _PromptManagerPageState extends State<_PromptManagerPage> {
  late List<TavernPromptOrderItem> _items;
  bool _saving = false;
  DateTime? _lastReorderAt;

  @override
  void initState() {
    super.initState();
    _items = <TavernPromptOrderItem>[
      ...widget.buildItems(
        widget.promptOrder?.items ?? const <TavernPromptOrderItem>[],
      ),
    ];
  }

  bool _shouldIgnoreTap() {
    final at = _lastReorderAt;
    return at != null && DateTime.now().difference(at).inMilliseconds < 280;
  }

  Future<void> _addCustomItem() async {
    final created = await widget.editCustomItem(context);
    if (created == null) return;
    setState(() {
      _items.add(created.copyWith(orderIndex: _items.length * 10));
    });
  }

  Future<void> _editCustomItemAt(int index) async {
    final item = _items[index];
    if (!item.isCustom) return;
    final updated = await widget.editCustomItem(context, item: item);
    if (updated == null) return;
    setState(() {
      _items[index] = updated.copyWith(orderIndex: item.orderIndex);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final store = context.read<TavernStore>();
      final normalized = <Map<String, dynamic>>[];
      for (var i = 0; i < _items.length; i += 1) {
        final current = _items[i];
        normalized.add(
          current
              .copyWith(
                orderIndex: i * 10,
                position: widget.itemPositionFor(current),
                depth: current.identifier == 'authorNote' ? 4 : null,
                clearDepth: current.identifier != 'authorNote',
                builtIn: current.identifier.isNotEmpty,
              )
              .toJson(),
        );
      }
      final payload = {'name': '默认提示词管理', 'items': normalized};
      final targetPromptOrderId = widget.promptOrder?.id ?? '';
      if (targetPromptOrderId.isEmpty) {
        await store.createPromptOrder(payload);
      } else {
        await store.updatePromptOrder(
          promptOrderId: targetPromptOrderId,
          payload: payload,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('提示词管理已更新')));
    } catch (exc) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存提示词管理失败：$exc')));
      setState(() => _saving = false);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('提示词管理'),
        actions: [
          IconButton(
            tooltip: '新增自定义项',
            onPressed: _saving ? null : _addCustomItem,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: _items.length,
            onReorder:
                _saving
                    ? (_, __) {}
                    : (oldIndex, newIndex) {
                      setState(() {
                        _lastReorderAt = DateTime.now();
                        if (newIndex > oldIndex) newIndex -= 1;
                        final moved = _items.removeAt(oldIndex);
                        _items.insert(newIndex, moved);
                        for (var i = 0; i < _items.length; i += 1) {
                          _items[i] = _items[i].copyWith(orderIndex: i * 10);
                        }
                      });
                    },
            itemBuilder: (context, index) {
              final item = _items[index];
              final option = widget.builtinOptionFor(item.identifier);
              final isCustom = item.isCustom;
              final accent =
                  isCustom
                      ? const Color(0xFF64748B)
                      : Color(option?.colorValue ?? 0xFF7C4DFF);
              final tileColor = Color(
                option?.colorValue ?? 0xFF7C4DFF,
              ).withValues(alpha: isCustom ? 0.08 : 0.12);
              return Card(
                key: ValueKey(
                  '${item.identifier}:${item.blockId}:${item.name}:$index',
                ),
                margin: const EdgeInsets.only(bottom: 10),
                color: tileColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ReorderableDragStartListener(
                        index: index,
                        child: Icon(
                          Icons.drag_indicator,
                          size: 18,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          option?.icon ?? Icons.notes_outlined,
                          size: 18,
                          color: accent,
                        ),
                      ),
                    ],
                  ),
                  title: Text(
                    widget.itemLabelBuilder(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _PromptTag(text: isCustom ? '自定义' : '内建'),
                        if (isCustom) _PromptTag(text: item.role),
                      ],
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: item.enabled,
                        onChanged:
                            _saving
                                ? null
                                : (value) {
                                  setState(() {
                                    _items[index] = item.copyWith(
                                      enabled: value,
                                    );
                                  });
                                },
                      ),
                      if (isCustom)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '编辑',
                          onPressed:
                              _saving || _shouldIgnoreTap()
                                  ? null
                                  : () => _editCustomItemAt(index),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                        ),
                      if (isCustom)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '删除',
                          onPressed:
                              _saving || _shouldIgnoreTap()
                                  ? null
                                  : () {
                                    setState(() => _items.removeAt(index));
                                  },
                          icon: const Icon(Icons.delete_outline, size: 18),
                        ),
                    ],
                  ),
                  onTap:
                      _saving || _shouldIgnoreTap() || !isCustom
                          ? null
                          : () => _editCustomItemAt(index),
                ),
              );
            },
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child:
                _saving
                    ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Text('保存'),
          ),
        ),
      ),
    );
  }
}

class _PromptTag extends StatelessWidget {
  const _PromptTag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: desktopAdjustedFontSize(11),
          fontWeight: FontWeight.w600,
          color: Color(0xFF475569),
        ),
      ),
    );
  }
}

class _QuickReplySettingsPage extends StatefulWidget {
  const _QuickReplySettingsPage();

  @override
  State<_QuickReplySettingsPage> createState() =>
      _QuickReplySettingsPageState();
}

class _QuickReplySettingsPageState extends State<_QuickReplySettingsPage> {
  late final List<_QuickReplyDraft> _drafts;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _drafts = OpenClawSettingsStore.defaultTavernQuickReplies()
        .map(_QuickReplyDraft.fromMap)
        .toList(growable: false);
    _load();
  }

  Future<void> _load() async {
    final loaded = await OpenClawSettingsStore.loadTavernQuickReplies();
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < _drafts.length && i < loaded.length; i++) {
        _drafts[i].labelController.text =
            loaded[i]['label'] ?? _drafts[i].labelController.text;
        _drafts[i].instructionController.text =
            loaded[i]['instruction'] ?? _drafts[i].instructionController.text;
      }
    });
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final items = _drafts.map((draft) => draft.toMap()).toList(growable: false);
    final hasEmpty = items.any(
      (item) =>
          (item['label'] ?? '').trim().isEmpty ||
          (item['instruction'] ?? '').trim().isEmpty,
    );
    if (hasEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('按钮文案和隐藏引导词都不能为空')));
      return;
    }
    setState(() => _isSaving = true);
    try {
      await OpenClawSettingsStore.saveTavernQuickReplies(items);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('快速回复配置已保存')));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _resetDefaults() {
    final defaults = OpenClawSettingsStore.defaultTavernQuickReplies();
    setState(() {
      for (var i = 0; i < _drafts.length && i < defaults.length; i++) {
        _drafts[i].labelController.text = defaults[i]['label'] ?? '';
        _drafts[i].instructionController.text =
            defaults[i]['instruction'] ?? '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('快速回复'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _resetDefaults,
            child: const Text('恢复默认'),
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemBuilder: (context, index) {
          final draft = _drafts[index];
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          draft.modeLabel,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: '复制引导词',
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(
                              text: draft.instructionController.text,
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('${draft.modeLabel} 引导词已复制'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy_all_outlined),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: draft.labelController,
                    decoration: const InputDecoration(
                      labelText: '按钮文案',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: draft.instructionController,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '隐藏引导词',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemCount: _drafts.length,
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(
            onPressed: _isSaving ? null : _save,
            child: Text(_isSaving ? '保存中…' : '保存'),
          ),
        ),
      ),
    );
  }
}

class _QuickReplyDraft {
  _QuickReplyDraft({
    required this.mode,
    required this.modeLabel,
    required this.labelController,
    required this.instructionController,
  });

  factory _QuickReplyDraft.fromMap(Map<String, String> map) {
    final mode = map['mode'] ?? '';
    return _QuickReplyDraft(
      mode: mode,
      modeLabel: _modeLabel(mode),
      labelController: TextEditingController(text: map['label'] ?? ''),
      instructionController: TextEditingController(
        text: map['instruction'] ?? '',
      ),
    );
  }

  final String mode;
  final String modeLabel;
  final TextEditingController labelController;
  final TextEditingController instructionController;

  Map<String, String> toMap() {
    return {
      'mode': mode,
      'label': labelController.text.trim(),
      'instruction': instructionController.text.trim(),
    };
  }

  void dispose() {
    labelController.dispose();
    instructionController.dispose();
  }

  static String _modeLabel(String mode) {
    switch (mode) {
      case 'continue':
        return '继续';
      case 'twist':
        return '转折';
      case 'describe':
        return '描写';
      default:
        return mode;
    }
  }
}

class _JsonMapEditorPage extends StatefulWidget {
  const _JsonMapEditorPage({
    required this.title,
    required this.initialValue,
    required this.onSave,
  });

  final String title;
  final Map<String, dynamic> initialValue;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> value)
  onSave;

  @override
  State<_JsonMapEditorPage> createState() => _JsonMapEditorPageState();
}

class _JsonMapEditorPageState extends State<_JsonMapEditorPage> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: JsonEncoder.withIndent('  ').convert(widget.initialValue),
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
            hintText: '{\n  "key": "value"\n}',
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

class _ChatsTab extends StatelessWidget {
  const _ChatsTab({
    required this.serverBaseUrl,
    required this.onOpenChat,
    required this.onConfirmDeleteChat,
    this.selectedChatId,
  });

  final String? serverBaseUrl;
  final String? selectedChatId;
  final Future<void> Function(TavernChat chat) onOpenChat;
  final Future<void> Function(TavernChat chat, TavernCharacter? character)
  onConfirmDeleteChat;

  @override
  Widget build(BuildContext context) {
    return Consumer<TavernStore>(
      builder: (context, store, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('最近会话', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '进来先直接聊天。角色和配置都收进次级入口。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF667085)),
            ),
            const SizedBox(height: 8),
            if (store.recentChats.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.chat_bubble_outline),
                  title: Text('还没有 Tavern 会话'),
                  subtitle: Text('去角色页选择角色后就能开始聊天。'),
                ),
              )
            else
              ...store.recentChats.take(20).map((chat) {
                final character = store.characters
                    .cast<TavernCharacter?>()
                    .firstWhere(
                      (item) => item?.id == chat.characterId,
                      orElse: () => null,
                    );
                final subtitle =
                    chat.title.trim().isNotEmpty
                        ? chat.title
                        : (character?.name.isNotEmpty == true
                            ? character!.name
                            : chat.id);
                return Card(
                  child: ListTile(
                    selected: selectedChatId == chat.id,
                    selectedTileColor: const Color(0xFFF3EEFF),
                    leading: buildTavernAvatar(
                      avatarPath: character?.avatarPath ?? '',
                      serverBaseUrl: serverBaseUrl,
                      useDefaultAssetFallback: true,
                    ),
                    title: Text(character?.name ?? '未知角色'),
                    subtitle: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onOpenChat(chat),
                    onLongPress: () => onConfirmDeleteChat(chat, character),
                  ),
                );
              }),
          ],
        );
      },
    );
  }
}

class _ConfigHubTab extends StatelessWidget {
  const _ConfigHubTab({
    required this.serverBaseUrl,
    required this.configHubPrimed,
    required this.onPrime,
    required this.onShowPresetsManager,
    required this.onShowPromptManager,
    required this.onShowWorldBooksManager,
    required this.onShowPersonasManager,
    required this.onShowGlobalVariablesManager,
    required this.onShowQuickReplySettings,
  });

  final String? serverBaseUrl;
  final bool configHubPrimed;
  final VoidCallback onPrime;
  final VoidCallback onShowPresetsManager;
  final VoidCallback onShowPromptManager;
  final VoidCallback onShowWorldBooksManager;
  final VoidCallback onShowPersonasManager;
  final VoidCallback onShowGlobalVariablesManager;
  final VoidCallback onShowQuickReplySettings;

  @override
  Widget build(BuildContext context) {
    return Consumer<TavernStore>(
      builder: (context, store, _) {
        if (!configHubPrimed &&
            store.presets.isEmpty &&
            store.worldBooks.isEmpty &&
            store.promptOrders.isEmpty &&
            !store.isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            onPrime();
          });
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('配置中心', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              '把不常改的 Tavern 能力都收进这里，聊天页保持干净。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            _ConfigEntryCard(
              icon: Icons.auto_awesome_outlined,
              title: 'Presets',
              subtitle: '模型参数与采样配置',
              trailingText: '${store.presets.length}',
              onTap: onShowPresetsManager,
            ),
            const SizedBox(height: 12),
            _ConfigEntryCard(
              icon: Icons.reorder_outlined,
              title: '提示词管理',
              subtitle: '像 Native 一样管理内建段落与自定义提示词',
              trailingText: '${store.promptOrders.length}',
              onTap: onShowPromptManager,
            ),
            const SizedBox(height: 12),
            _ConfigEntryCard(
              icon: Icons.public_outlined,
              title: 'WorldBooks',
              subtitle: '管理世界书范围（全局/非全局）与条目触发规则',
              trailingText: '${store.worldBooks.length}',
              onTap: onShowWorldBooksManager,
            ),
            const SizedBox(height: 12),
            _ConfigEntryCard(
              icon: Icons.person_outline,
              title: 'Personas',
              subtitle: '管理用户人设，决定 {{user}} / {{persona}} 的来源',
              trailingText: '${store.personas.length}',
              onTap: onShowPersonasManager,
            ),
            const SizedBox(height: 12),
            _ConfigEntryCard(
              icon: Icons.data_object_outlined,
              title: 'Variables',
              subtitle: '查看和编辑全局变量（global vars）',
              trailingText: '${store.globalVariables.length}',
              onTap: onShowGlobalVariablesManager,
            ),
            const SizedBox(height: 12),
            _ConfigEntryCard(
              icon: Icons.flash_on_outlined,
              title: '快速回复',
              subtitle: '配置继续 / 转折 / 描写的按钮文案与隐藏引导词',
              trailingText: '3',
              onTap: onShowQuickReplySettings,
            ),
          ],
        );
      },
    );
  }
}

class _CompactInfoPill extends StatelessWidget {
  const _CompactInfoPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: desktopAdjustedFontSize(11),
          fontWeight: FontWeight.w600,
          color: Color(0xFF475569),
        ),
      ),
    );
  }
}

class _ConfigEntryCard extends StatelessWidget {
  const _ConfigEntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailingText,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String trailingText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFFF6F3FF),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: const Color(0xFF7C4DFF)),
        ),
        title: Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CompactInfoPill(text: trailingText),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _SimpleJsonListManagerPage extends StatelessWidget {
  const _SimpleJsonListManagerPage({
    required this.title,
    required this.items,
    required this.emptyText,
    required this.onCreate,
    required this.onUpdate,
    required this.onDelete,
    required this.defaultCreatePayload,
  });

  final String title;
  final List<Map<String, dynamic>> items;
  final String emptyText;
  final Future<dynamic> Function(Map<String, dynamic> payload) onCreate;
  final Future<dynamic> Function(String id, Map<String, dynamic> payload)
  onUpdate;
  final Future<void> Function(String id) onDelete;
  final Map<String, dynamic> defaultCreatePayload;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed:
                () => _openEditor(context, initial: defaultCreatePayload),
          ),
        ],
      ),
      body:
          items.isEmpty
              ? Center(child: Text(emptyText))
              : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final id = (item['id'] ?? '').toString();
                  final title = (item['name'] ?? id).toString();
                  final subtitle = (item['description'] ?? '').toString();
                  return Card(
                    child: ListTile(
                      title: Text(title),
                      subtitle:
                          subtitle.isEmpty
                              ? null
                              : Text(
                                subtitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                      trailing:
                          item['isDefault'] == true
                              ? const Chip(label: Text('默认'))
                              : null,
                      onTap: () => _openEditor(context, id: id, initial: item),
                      onLongPress: () async {
                        await onDelete(id);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                  );
                },
              ),
    );
  }

  Future<void> _openEditor(
    BuildContext context, {
    String id = '',
    required Map<String, dynamic> initial,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => _JsonMapEditorPage(
              title: id.isEmpty ? '新增$title' : '编辑$title',
              initialValue: initial,
              onSave: (value) async {
                if (id.isEmpty) {
                  await onCreate(value);
                } else {
                  await onUpdate(id, value);
                }
                return value;
              },
            ),
      ),
    );
  }
}
