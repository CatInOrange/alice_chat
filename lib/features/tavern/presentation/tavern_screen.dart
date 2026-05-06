import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../../core/openclaw/openclaw_settings.dart';
import '../application/tavern_store.dart';
import '../domain/tavern_models.dart';
import 'tavern_chat_screen.dart';
import 'tavern_ui_helpers.dart';

const List<String> _promptBlockKinds = <String>[
  'system',
  'persona',
  'jailbreak',
  'character',
  'scenario',
  'example_messages',
  'world_info',
  'author_note',
  'custom',
];

const List<String> _promptBlockScopes = <String>[
  'global',
  'character',
  'chat',
  'preset',
];
const List<String> _promptBlockInjectionModes = <String>[
  'position',
  'depth',
  'static',
];
const List<String> _worldbookPositions = <String>[
  'before_character',
  'after_character',
  'before_example_messages',
  'before_chat_history',
  'before_last_user',
  'at_depth',
];
const List<String> _storyPositions = <String>[
  'in_prompt',
  'at_depth',
  'before_last_user',
];
const List<String> _storyRoles = <String>['system', 'user', 'assistant'];
const List<String> _promptOrderPositions = <String>[
  'before_system',
  'after_system',
  'before_character',
  'after_character',
  'before_example_messages',
  'after_example_messages',
  'before_chat_history',
  'after_chat_history',
  'before_last_user',
  'at_depth',
];
const List<_BuiltinPromptOrderOption> _builtinPromptOrderOptions =
    <_BuiltinPromptOrderOption>[
      _BuiltinPromptOrderOption('main', 'Main / System Prompt'),
      _BuiltinPromptOrderOption('worldInfoBefore', 'World Info Before History'),
      _BuiltinPromptOrderOption('charDescription', 'Character Description'),
      _BuiltinPromptOrderOption('charPersonality', 'Character Personality'),
      _BuiltinPromptOrderOption('scenario', 'Scenario'),
      _BuiltinPromptOrderOption('worldInfoAfter', 'World Info After Character'),
      _BuiltinPromptOrderOption('dialogueExamples', 'Dialogue Examples'),
      _BuiltinPromptOrderOption('chatHistory', 'Chat History'),
      _BuiltinPromptOrderOption('jailbreak', 'Post History Instructions'),
      _BuiltinPromptOrderOption('personaDescription', 'Persona Description'),
      _BuiltinPromptOrderOption('nsfw', 'NSFW Block'),
    ];

class TavernScreen extends StatefulWidget {
  const TavernScreen({super.key});

  @override
  State<TavernScreen> createState() => _TavernScreenState();
}

class _TavernScreenState extends State<TavernScreen>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  final ImagePicker _picker = ImagePicker();
  late final TabController _tabController;
  bool _isImporting = false;
  String? _serverBaseUrl;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      context.read<TavernStore>().loadCharacters();
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
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final store = context.watch<TavernStore>();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final message = store.lastImportMessage;
      if (!mounted || message == null || message.isEmpty) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      context.read<TavernStore>().clearImportMessage();
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('酒馆'),
        actions: [
          IconButton(
            tooltip: '新建 Preset',
            onPressed: () => _editPreset(context),
            icon: const Icon(Icons.add_circle_outline),
          ),
          IconButton(
            tooltip: '导入角色',
            onPressed: _isImporting ? null : _importCharacter,
            icon:
                _isImporting
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.file_upload_outlined),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(text: '会话'),
            Tab(text: '角色'),
            Tab(text: 'Presets'),
            Tab(text: 'Prompt Blocks'),
            Tab(text: 'Prompt Order'),
            Tab(text: 'WorldBooks'),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: store.loadCharacters,
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildChatsTab(context, store),
            _buildCharactersTab(context, store),
            _buildPresetsTab(context, store),
            _buildPromptBlocksTab(context, store),
            _buildPromptOrdersTab(context, store),
            _buildWorldBooksTab(context, store),
          ],
        ),
      ),
    );
  }

  Widget _buildChatsTab(BuildContext context, TavernStore store) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('最近会话', style: Theme.of(context).textTheme.titleMedium),
            ),
            TextButton.icon(
              onPressed: () => _tabController.animateTo(1),
              icon: const Icon(Icons.people_outline),
              label: const Text('去角色页'),
            ),
          ],
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
          ...store.recentChats.take(20).map(
            (chat) {
              final character = store.characters.cast<TavernCharacter?>().firstWhere(
                (item) => item?.id == chat.characterId,
                orElse: () => null,
              );
              final subtitle = chat.title.trim().isNotEmpty
                  ? chat.title
                  : (character?.name.isNotEmpty == true ? character!.name : chat.id);
              return Card(
                child: ListTile(
                  leading: buildTavernAvatar(
                    avatarPath: character?.avatarPath ?? '',
                    serverBaseUrl: _serverBaseUrl,
                    useDefaultAssetFallback: true,
                  ),
                  title: Text(character?.name ?? '未知角色'),
                  subtitle: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openExistingChat(chat),
                  onLongPress: () => _confirmDeleteChat(context, chat, character),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildCharactersTab(BuildContext context, TavernStore store) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('角色', style: Theme.of(context).textTheme.titleMedium),
            ),
            TextButton.icon(
              onPressed: _isImporting ? null : _importCharacter,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('导入'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (store.isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if ((store.error ?? '').isNotEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: const Text('加载角色失败'),
              subtitle: Text(store.error!),
            ),
          )
        else if (store.characters.isEmpty)
          const Card(
            child: ListTile(
              title: Text('还没有角色'),
              subtitle: Text('支持导入 JSON / PNG / CharX 角色卡。'),
            ),
          )
        else
          ...store.characters.map(
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
                onTap: () => _startChatWithCharacter(character),
                onLongPress: () => _confirmDeleteCharacter(context, character),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPresetsTab(BuildContext context, TavernStore store) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Presets',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            FilledButton.icon(
              onPressed: () => _editPreset(context),
              icon: const Icon(Icons.add),
              label: const Text('新增'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (store.presets.isEmpty)
          const Card(
            child: ListTile(
              title: Text('还没有 Preset'),
              subtitle: Text('可以创建多套模型参数和 Prompt 组合。'),
            ),
          )
        else
          ...store.presets.map(
            (preset) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            preset.name,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        IconButton(
                          tooltip: '复制 Preset',
                          onPressed: () => _duplicatePreset(context, preset),
                          icon: const Icon(Icons.copy_outlined),
                        ),
                        IconButton(
                          tooltip: '编辑 Preset',
                          onPressed: () => _editPreset(context, preset: preset),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _chip(
                          'Provider',
                          preset.provider.isEmpty ? '默认' : preset.provider,
                        ),
                        _chip(
                          'Model',
                          preset.model.isEmpty ? '默认' : preset.model,
                        ),
                        _chip(
                          'Prompt Order',
                          _promptOrderName(store, preset.promptOrderId),
                        ),
                        _chip('Temp', preset.temperature.toStringAsFixed(2)),
                        _chip('TopP', preset.topP.toStringAsFixed(2)),
                        _chip('TopK', '${preset.topK}'),
                        _chip('MinP', preset.minP.toStringAsFixed(2)),
                        _chip('TypicalP', preset.typicalP.toStringAsFixed(2)),
                        _chip(
                          'Repeat',
                          preset.repetitionPenalty.toStringAsFixed(2),
                        ),
                        _chip('MaxTokens', '${preset.maxTokens}'),
                        _chip('Story', preset.storyStringPosition),
                        _chip('Role', preset.storyStringRole),
                        _chip('Depth', '${preset.storyStringDepth}'),
                      ],
                    ),
                    if (preset.stopSequences.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Stop Sequences: ${preset.stopSequences.join(' · ')}',
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

  Widget _buildPromptBlocksTab(BuildContext context, TavernStore store) {
    final blocks = [...store.promptBlocks]..sort((a, b) {
      final enabledCmp = (b.enabled ? 1 : 0).compareTo(a.enabled ? 1 : 0);
      if (enabledCmp != 0) return enabledCmp;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Prompt Blocks',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            FilledButton.icon(
              onPressed: () => _editPromptBlock(context),
              icon: const Icon(Icons.add),
              label: const Text('新增'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (blocks.isEmpty)
          const Card(
            child: ListTile(
              title: Text('还没有 Prompt Block'),
              subtitle: Text('这里可以管理 system/persona/jailbreak/custom 等内容块。'),
            ),
          )
        else
          ...blocks.map(
            (block) => Card(
              child: ListTile(
                onLongPress: () => _confirmDeletePromptBlock(context, block),
                leading: Switch(
                  value: block.enabled,
                  onChanged:
                      (value) => _togglePromptBlock(context, block, value),
                ),
                title: Text(block.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _chip('Kind', block.kind),
                        _chip('Mode', block.injectionMode),
                        _chip('Scope', block.roleScope),
                        if (block.depth != null)
                          _chip('Depth', '${block.depth}'),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      block.content,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                trailing: IconButton(
                  tooltip: '编辑 Block',
                  onPressed: () => _editPromptBlock(context, block: block),
                  icon: const Icon(Icons.edit_outlined),
                ),
                isThreeLine: true,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPromptOrdersTab(BuildContext context, TavernStore store) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Prompt Order',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            FilledButton.icon(
              onPressed: () => _editPromptOrder(context),
              icon: const Icon(Icons.add),
              label: const Text('新增'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (store.promptOrders.isEmpty)
          const Card(
            child: ListTile(
              title: Text('还没有 Prompt Order'),
              subtitle: Text('拖拽编排内置块和自定义 Prompt Block 的顺序。'),
            ),
          )
        else
          ...store.promptOrders.map(
            (order) => Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  minTileHeight: 56,
                  title: Text(
                    order.name,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${order.items.length} 项',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF7D8596),
                      ),
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '编辑 Prompt Order',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _editPromptOrder(context, promptOrder: order),
                        icon: const Icon(Icons.edit_outlined, size: 20),
                      ),
                      const Icon(Icons.expand_more, size: 20),
                    ],
                  ),
                  children: [
                    if (order.items.isEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(4, 2, 4, 2),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text('暂无 items'),
                        ),
                      )
                    else
                      ...order.items.asMap().entries.map(
                        (entry) => _buildPromptOrderCompactRow(
                          context,
                          store,
                          entry.value,
                          index: entry.key,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildWorldBooksTab(BuildContext context, TavernStore store) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'WorldBooks',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            FilledButton.icon(
              onPressed: () => _editWorldBook(context),
              icon: const Icon(Icons.add),
              label: const Text('新增'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (store.worldBooks.isEmpty)
          const Card(
            child: ListTile(
              title: Text('还没有 WorldBook'),
              subtitle: Text('这里管理世界书和关键词条目。'),
            ),
          )
        else
          ...store.worldBooks.map(
            (book) => Card(
              child: GestureDetector(
                onLongPress: () => _confirmDeleteWorldBook(context, book),
                behavior: HitTestBehavior.opaque,
                child: ExpansionTile(
                  initiallyExpanded: false,
                  onExpansionChanged: (expanded) {
                  if (expanded && store.worldBookEntriesOf(book.id).isEmpty) {
                    context.read<TavernStore>().loadWorldBookEntries(book.id);
                  }
                },
                leading: Switch(
                  value: book.enabled,
                  onChanged: (value) => _toggleWorldBook(context, book, value),
                ),
                title: Text(book.name),
                subtitle: Text(
                  book.description.isEmpty ? '无描述' : book.description,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '新增条目',
                      onPressed:
                          () => _editWorldBookEntry(context, worldbook: book),
                      icon: const Icon(Icons.note_add_outlined),
                    ),
                    IconButton(
                      tooltip: '编辑 WorldBook',
                      onPressed: () => _editWorldBook(context, worldbook: book),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: '删除 WorldBook',
                      onPressed: () => _confirmDeleteWorldBook(context, book),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
                children: [
                  ...store
                      .worldBookEntriesOf(book.id)
                      .map(
                        (entry) => ListTile(
                          title: Text(
                            entry.keys.isEmpty
                                ? '(无关键词)'
                                : entry.keys.join(', '),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _chip('Priority', '${entry.priority}'),
                                  _chip('Pos', entry.insertionPosition),
                                  _chip(
                                    'Enabled',
                                    entry.enabled ? 'on' : 'off',
                                  ),
                                  if (entry.constant) _chip('Constant', 'yes'),
                                  if (entry.recursive)
                                    _chip('Recursive', 'yes'),
                                  if (entry.groupName.isNotEmpty)
                                    _chip('Group', entry.groupName),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                entry.content,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            tooltip: '编辑条目',
                            onPressed:
                                () => _editWorldBookEntry(
                                  context,
                                  worldbook: book,
                                  entry: entry,
                                ),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          isThreeLine: true,
                        ),
                      ),
                  if (store.worldBookEntriesOf(book.id).isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('还没有条目'),
                      ),
                    ),
                ],
                ),
              ),
            ),
          ),
      ],
    );
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
      final character = await store.importCharacterFile(
        filename: filename,
        bytes: bytes,
      );
      if (!mounted) return;
      await _startChatWithCharacter(character);
    } catch (exc) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$exc')));
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  Future<void> _startChatWithCharacter(TavernCharacter character) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final chat = await context.read<TavernStore>().createChatForCharacter(
        character,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TavernChatScreen(chat: chat, character: character),
        ),
      );
      if (!mounted) return;
      await context.read<TavernStore>().loadHome();
    } catch (exc) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('创建会话失败：$exc')));
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
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TavernChatScreen(chat: chat, character: character),
        ),
      );
      if (!mounted) return;
      await store.loadHome();
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
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('删除会话'),
              subtitle: Text(character?.name ?? chat.title),
              onTap: () => Navigator.of(context).pop(true),
            ),
            const ListTile(
              leading: Icon(Icons.close),
              title: Text('取消'),
            ),
          ],
        ),
      ),
    );
    // ignore: use_build_context_synchronously
    if (confirmed != true || !mounted) return;
    final doubleConfirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除会话？'),
        content: Text('删除后，该会话里的消息也会一并移除。\n\n${character?.name ?? chat.title}'),
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

  Future<void> _confirmDeletePromptBlock(
    BuildContext context,
    TavernPromptBlock block,
  ) async {
    if (!mounted) return;
    final store = context.read<TavernStore>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('删除 Prompt Block'),
              subtitle: Text(block.name),
              onTap: () => Navigator.of(context).pop(true),
            ),
            const ListTile(
              leading: Icon(Icons.close),
              title: Text('取消'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final doubleConfirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除 Prompt Block？'),
        content: Text('删除后，会从所有 Prompt Order 中移除该块引用。\n\n${block.name}'),
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
      await store.deletePromptBlock(block.id);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Prompt Block 已删除')));
    } catch (exc) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('删除 Prompt Block 失败：$exc')));
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
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('删除 WorldBook'),
              subtitle: Text(worldbook.name),
              onTap: () => Navigator.of(context).pop(true),
            ),
            const ListTile(
              leading: Icon(Icons.close),
              title: Text('取消'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final doubleConfirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('删除角色'),
              subtitle: Text(character.name),
              onTap: () => Navigator.of(context).pop(true),
            ),
            const ListTile(
              leading: Icon(Icons.close),
              title: Text('取消'),
            ),
          ],
        ),
      ),
    );
    // ignore: use_build_context_synchronously
    if (confirmed != true || !mounted) return;
    final doubleConfirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
        'stopSequences': preset.stopSequences,
        'promptOrderId': preset.promptOrderId,
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
    final promptOrders = store.promptOrders;
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
    String promptOrderId =
        preset?.promptOrderId ??
        (promptOrders.isNotEmpty ? promptOrders.first.id : '');
    String storyPosition = preset?.storyStringPosition ?? 'in_prompt';
    String storyRole = preset?.storyStringRole ?? 'system';
    double temperature = preset?.temperature ?? 1;
    double topP = preset?.topP ?? 1;
    double minP = preset?.minP ?? 0;
    double typicalP = preset?.typicalP ?? 1;
    double repetitionPenalty = preset?.repetitionPenalty ?? 1;
    int topK = preset?.topK ?? 0;
    int maxTokens = preset?.maxTokens ?? 0;
    int storyDepth = preset?.storyStringDepth ?? 1;
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
                          const SizedBox(height: 12),
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
                                providers.any((item) => item.id == providerId)
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
                          DropdownButtonFormField<String>(
                            value:
                                promptOrders.any(
                                      (item) => item.id == promptOrderId,
                                    )
                                    ? promptOrderId
                                    : null,
                            decoration: const InputDecoration(
                              labelText: 'Prompt Order',
                              border: OutlineInputBorder(),
                            ),
                            items: promptOrders
                                .map(
                                  (order) => DropdownMenuItem<String>(
                                    value: order.id,
                                    child: Text(order.name),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged:
                                promptOrders.isEmpty
                                    ? null
                                    : (value) => setModalState(
                                      () => promptOrderId = value ?? '',
                                    ),
                          ),
                          const SizedBox(height: 12),
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
                                        (item) => DropdownMenuItem<String>(
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
                                        (item) => DropdownMenuItem<String>(
                                          value: item,
                                          child: Text(item),
                                        ),
                                      )
                                      .toList(growable: false),
                                  onChanged:
                                      (value) => setModalState(
                                        () => storyRole = value ?? 'system',
                                      ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _sliderField(
                            context,
                            label: 'Temperature',
                            value: temperature,
                            min: 0,
                            max: 2,
                            divisions: 20,
                            onChanged:
                                (value) =>
                                    setModalState(() => temperature = value),
                          ),
                          _sliderField(
                            context,
                            label: 'Top P',
                            value: topP,
                            min: 0,
                            max: 1,
                            divisions: 20,
                            onChanged:
                                (value) => setModalState(() => topP = value),
                          ),
                          _sliderField(
                            context,
                            label: 'Min P',
                            value: minP,
                            min: 0,
                            max: 1,
                            divisions: 20,
                            onChanged:
                                (value) => setModalState(() => minP = value),
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
                                (value) => setModalState(() => topK = value),
                          ),
                          _intStepper(
                            context,
                            label: 'Max Tokens',
                            value: maxTokens,
                            min: 0,
                            max: 32000,
                            step: 128,
                            onChanged:
                                (value) =>
                                    setModalState(() => maxTokens = value),
                          ),
                          _intStepper(
                            context,
                            label: 'Story Depth',
                            value: storyDepth,
                            min: 0,
                            max: 12,
                            onChanged:
                                (value) =>
                                    setModalState(() => storyDepth = value),
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
                                              'promptOrderId': promptOrderId,
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
                                              'topK': topK,
                                              'minP': minP,
                                              'typicalP': typicalP,
                                              'repetitionPenalty':
                                                  repetitionPenalty,
                                              'maxTokens': maxTokens,
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
      await context.read<TavernStore>().loadHome();
    }
  }

  Future<void> _togglePromptBlock(
    BuildContext context,
    TavernPromptBlock block,
    bool enabled,
  ) async {
    try {
      await context.read<TavernStore>().updatePromptBlock(
        blockId: block.id,
        payload: {'enabled': enabled},
      );
    } catch (exc) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('更新 Prompt Block 失败：$exc')));
    }
  }

  Future<void> _editPromptBlock(
    BuildContext context, {
    TavernPromptBlock? block,
  }) async {
    final isCreate = block == null;
    final existingBlock = block;
    final store = context.read<TavernStore>();
    final nameController = TextEditingController(
      text: existingBlock?.name ?? '',
    );
    final contentController = TextEditingController(text: block?.content ?? '');
    String kind = block?.kind ?? 'custom';
    String scope = block?.roleScope ?? 'global';
    String injectionMode = block?.injectionMode ?? 'position';
    bool enabled = block?.enabled ?? true;
    int depth = block?.depth ?? 4;
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
                            isCreate ? '新建 Prompt Block' : '编辑 Prompt Block',
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
                          TextField(
                            controller: nameController,
                            decoration: const InputDecoration(
                              labelText: '名称',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: kind,
                                  decoration: const InputDecoration(
                                    labelText: 'Kind',
                                    border: OutlineInputBorder(),
                                  ),
                                  items: _promptBlockKinds
                                      .map(
                                        (item) => DropdownMenuItem<String>(
                                          value: item,
                                          child: Text(item),
                                        ),
                                      )
                                      .toList(growable: false),
                                  onChanged:
                                      (value) => setModalState(
                                        () => kind = value ?? 'custom',
                                      ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: scope,
                                  decoration: const InputDecoration(
                                    labelText: 'Role Scope',
                                    border: OutlineInputBorder(),
                                  ),
                                  items: _promptBlockScopes
                                      .map(
                                        (item) => DropdownMenuItem<String>(
                                          value: item,
                                          child: Text(item),
                                        ),
                                      )
                                      .toList(growable: false),
                                  onChanged:
                                      (value) => setModalState(
                                        () => scope = value ?? 'global',
                                      ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: injectionMode,
                            decoration: const InputDecoration(
                              labelText: 'Injection Mode',
                              border: OutlineInputBorder(),
                            ),
                            items: _promptBlockInjectionModes
                                .map(
                                  (item) => DropdownMenuItem<String>(
                                    value: item,
                                    child: Text(item),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged:
                                (value) => setModalState(
                                  () => injectionMode = value ?? 'position',
                                ),
                          ),
                          if (injectionMode == 'depth') ...[
                            const SizedBox(height: 12),
                            _intStepper(
                              context,
                              label: 'Depth',
                              value: depth,
                              min: 0,
                              max: 12,
                              onChanged:
                                  (value) => setModalState(() => depth = value),
                            ),
                          ],
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
                                                      ? '未命名 Prompt Block'
                                                      : nameController.text
                                                          .trim(),
                                              'enabled': enabled,
                                              'content': contentController.text,
                                              'kind': kind,
                                              'injectionMode': injectionMode,
                                              'depth':
                                                  injectionMode == 'depth'
                                                      ? depth
                                                      : null,
                                              'roleScope': scope,
                                            };
                                            if (isCreate) {
                                              await store.createPromptBlock(
                                                payload,
                                              );
                                            } else {
                                              await store.updatePromptBlock(
                                                blockId:
                                                    existingBlock?.id ?? '',
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
                                                  '${isCreate ? '创建' : '保存'} Prompt Block 失败：$exc',
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
    contentController.dispose();

    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isCreate ? 'Prompt Block 已创建' : 'Prompt Block 已更新'),
        ),
      );
      await context.read<TavernStore>().loadHome();
    }
  }

  Future<void> _editPromptOrder(
    BuildContext context, {
    TavernPromptOrder? promptOrder,
  }) async {
    final store = context.read<TavernStore>();
    final isCreate = promptOrder == null;
    final existingPromptOrder = promptOrder;
    final nameController = TextEditingController(
      text: existingPromptOrder?.name ?? '',
    );
    final List<TavernPromptOrderItem> items = [
      ...(promptOrder?.items ?? const <TavernPromptOrderItem>[]),
    ]..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    bool saving = false;
    DateTime? lastReorderAt;

    bool shouldIgnoreTap() {
      final at = lastReorderAt;
      if (at == null) return false;
      return DateTime.now().difference(at).inMilliseconds < 280;
    }

    Future<void> addItem(StateSetter setModalState) async {
      final selected = await showModalBottomSheet<TavernPromptOrderItem>(
        context: context,
        builder:
            (context) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(title: Text('内置语义块')),
                  ..._builtinPromptOrderOptions.map(
                    (option) => ListTile(
                      leading: const Icon(Icons.auto_awesome_outlined),
                      title: Text(option.label),
                      subtitle: Text(option.identifier),
                      onTap:
                          () => Navigator.of(context).pop(
                            TavernPromptOrderItem(
                              identifier: option.identifier,
                              enabled: true,
                              orderIndex: items.length * 10,
                              position: 'after_system',
                            ),
                          ),
                    ),
                  ),
                  const Divider(),
                  const ListTile(title: Text('自定义 Prompt Blocks')),
                  ...store.promptBlocks.map(
                    (block) => ListTile(
                      leading: const Icon(Icons.notes_outlined),
                      title: Text(block.name),
                      subtitle: Text('${block.kind} · ${block.injectionMode}'),
                      onTap:
                          () => Navigator.of(context).pop(
                            TavernPromptOrderItem(
                              blockId: block.id,
                              enabled: block.enabled,
                              orderIndex: items.length * 10,
                              position:
                                  block.injectionMode == 'depth'
                                      ? 'at_depth'
                                      : 'after_system',
                              depth:
                                  block.injectionMode == 'depth'
                                      ? (block.depth ?? 4)
                                      : null,
                            ),
                          ),
                    ),
                  ),
                ],
              ),
            ),
      );
      if (selected == null) return;
      setModalState(() {
        items.add(selected.copyWith(orderIndex: items.length * 10));
      });
    }

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
                    child: SizedBox(
                      height: MediaQuery.of(context).size.height * 0.85,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isCreate ? '新建 Prompt Order' : '编辑 Prompt Order',
                            style: Theme.of(context).textTheme.titleLarge,
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
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Items（可拖拽排序）',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () => addItem(setModalState),
                                icon: const Icon(Icons.add),
                                label: const Text('添加 item'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ReorderableListView.builder(
                              buildDefaultDragHandles: false,
                              itemCount: items.length,
                              onReorder: (oldIndex, newIndex) {
                                setModalState(() {
                                  lastReorderAt = DateTime.now();
                                  if (newIndex > oldIndex) newIndex -= 1;
                                  final item = items.removeAt(oldIndex);
                                  items.insert(newIndex, item);
                                  for (var i = 0; i < items.length; i += 1) {
                                    items[i] = items[i].copyWith(
                                      orderIndex: i * 10,
                                    );
                                  }
                                });
                              },
                              itemBuilder: (context, index) {
                                final item = items[index];
                                final label = _promptOrderItemLabel(
                                  store,
                                  item,
                                );
                                return Card(
                                  key: ValueKey(
                                    '${item.identifier}:${item.blockId}:$index',
                                  ),
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            ReorderableDragStartListener(
                                              index: index,
                                              child: const Padding(
                                                padding: EdgeInsets.symmetric(horizontal: 2),
                                                child: Icon(
                                                  Icons.drag_indicator,
                                                  size: 18,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    label,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style:
                                                        Theme.of(
                                                          context,
                                                        ).textTheme.titleSmall,
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Wrap(
                                                    spacing: 6,
                                                    runSpacing: 6,
                                                    children: [
                                                      _chip('Pos', item.position),
                                                      if (item.position == 'at_depth')
                                                        _chip('Depth', '${item.depth ?? 0}'),
                                                      _chip(
                                                        'State',
                                                        item.enabled ? 'on' : 'off',
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                            Switch(
                                              materialTapTargetSize:
                                                  MaterialTapTargetSize.shrinkWrap,
                                              value: item.enabled,
                                              onChanged:
                                                  (value) {
                                                    if (shouldIgnoreTap()) return;
                                                    setModalState(() {
                                                      items[index] = item.copyWith(
                                                        enabled: value,
                                                      );
                                                    });
                                                  },
                                            ),
                                            IconButton(
                                              visualDensity: VisualDensity.compact,
                                              onPressed: () {
                                                if (shouldIgnoreTap()) return;
                                                setModalState(() => items.removeAt(index));
                                              },
                                              icon: const Icon(
                                                Icons.delete_outline,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: DropdownButtonFormField<
                                                String
                                              >(
                                                isDense: true,
                                                value:
                                                    _promptOrderPositions
                                                            .contains(
                                                              item.position,
                                                            )
                                                        ? item.position
                                                        : _promptOrderPositions
                                                            .first,
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: 'Position',
                                                      border:
                                                          OutlineInputBorder(),
                                                    ),
                                                items: _promptOrderPositions
                                                    .map(
                                                      (position) =>
                                                          DropdownMenuItem<
                                                            String
                                                          >(
                                                            value: position,
                                                            child: Text(
                                                              position,
                                                              overflow: TextOverflow.ellipsis,
                                                            ),
                                                          ),
                                                    )
                                                    .toList(growable: false),
                                                onChanged:
                                                    (
                                                      value,
                                                    ) => setModalState(() {
                                                      items[index] = item.copyWith(
                                                        position:
                                                            value ??
                                                            'after_system',
                                                        clearDepth:
                                                            (value ??
                                                                'after_system') !=
                                                            'at_depth',
                                                      );
                                                    }),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            SizedBox(
                                              width: 92,
                                              child: TextFormField(
                                                initialValue:
                                                    '${item.depth ?? ''}',
                                                enabled:
                                                    item.position == 'at_depth',
                                                keyboardType:
                                                    TextInputType.number,
                                                decoration:
                                                    const InputDecoration(
                                                      isDense: true,
                                                      labelText: 'Depth',
                                                      border:
                                                          OutlineInputBorder(),
                                                    ),
                                                onChanged:
                                                    (value) =>
                                                        items[index] = item
                                                            .copyWith(
                                                              depth:
                                                                  int.tryParse(
                                                                    value,
                                                                  ) ??
                                                                  item.depth ??
                                                                  0,
                                                            ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
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
                                            final normalized =
                                                <Map<String, dynamic>>[];
                                            for (
                                              var i = 0;
                                              i < items.length;
                                              i += 1
                                            ) {
                                              normalized.add(
                                                items[i]
                                                    .copyWith(
                                                      orderIndex: i * 10,
                                                    )
                                                    .toJson(),
                                              );
                                            }
                                            final payload = {
                                              'name':
                                                  nameController.text
                                                          .trim()
                                                          .isEmpty
                                                      ? '未命名 Prompt Order'
                                                      : nameController.text
                                                          .trim(),
                                              'items': normalized,
                                            };
                                            if (isCreate) {
                                              await store.createPromptOrder(
                                                payload,
                                              );
                                            } else {
                                              await store.updatePromptOrder(
                                                promptOrderId:
                                                    existingPromptOrder?.id ??
                                                    '',
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
                                                  '${isCreate ? '创建' : '保存'} Prompt Order 失败：$exc',
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

    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isCreate ? 'Prompt Order 已创建' : 'Prompt Order 已更新'),
        ),
      );
      await context.read<TavernStore>().loadHome();
    }
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
      await context.read<TavernStore>().loadHome();
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
    bool enabled = entry?.enabled ?? true;
    bool recursive = entry?.recursive ?? false;
    bool constant = entry?.constant ?? false;
    String insertionPosition =
        entry?.insertionPosition ?? 'before_chat_history';
    int priority = entry?.priority ?? 0;
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
                            title: const Text('Constant（始终注入）'),
                            value: constant,
                            onChanged:
                                (value) =>
                                    setModalState(() => constant = value),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Recursive'),
                            value: recursive,
                            onChanged:
                                (value) =>
                                    setModalState(() => recursive = value),
                          ),
                          TextField(
                            controller: keysController,
                            minLines: 2,
                            maxLines: 5,
                            decoration: const InputDecoration(
                              labelText: 'Keys（每行一个）',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: secondaryController,
                            minLines: 2,
                            maxLines: 5,
                            decoration: const InputDecoration(
                              labelText: 'Secondary Keys（每行一个）',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: insertionPosition,
                            decoration: const InputDecoration(
                              labelText: 'Insertion Position',
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
                            label: 'Priority',
                            value: priority,
                            min: -20,
                            max: 50,
                            onChanged:
                                (value) =>
                                    setModalState(() => priority = value),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: groupController,
                            decoration: const InputDecoration(
                              labelText: 'Group Name',
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
      await refreshedStore.loadHome();
    }
  }

  String _promptOrderName(TavernStore store, String promptOrderId) {
    if (promptOrderId.isEmpty) return '未设置';
    for (final order in store.promptOrders) {
      if (order.id == promptOrderId) return order.name;
    }
    return promptOrderId;
  }

  Widget _buildPromptOrderCompactRow(
    BuildContext context,
    TavernStore store,
    TavernPromptOrderItem item, {
    required int index,
  }) {
    final enabledColor = item.enabled
        ? const Color(0xFF7C4DFF)
        : const Color(0xFFB7BFCE);
    final theme = Theme.of(context);
    return Container(
      margin: EdgeInsets.only(bottom: index == 0 ? 0 : 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F7FC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE9E5F4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              item.enabled ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16,
              color: enabledColor,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _promptOrderItemLabel(store, item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _compactInfoPill(_promptOrderItemSourceLabel(item)),
                    _compactInfoPill(_promptOrderPositionLabel(item.position)),
                    if (item.depth != null) _compactInfoPill('深度 ${item.depth}'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _promptOrderItemLabel(TavernStore store, TavernPromptOrderItem item) {
    if (item.identifier.isNotEmpty) {
      for (final option in _builtinPromptOrderOptions) {
        if (option.identifier == item.identifier) return option.label;
      }
      return item.identifier;
    }
    if (item.blockId.isNotEmpty) {
      for (final block in store.promptBlocks) {
        if (block.id == item.blockId) return block.name;
      }
      return item.blockId;
    }
    return '未命名 item';
  }

  String _promptOrderItemSourceLabel(TavernPromptOrderItem item) {
    if (item.identifier.isNotEmpty) return '内置';
    if (item.blockId.isNotEmpty) return 'Prompt Block';
    return '自定义';
  }

  String _promptOrderPositionLabel(String position) {
    switch (position) {
      case 'after_system':
        return '系统后';
      case 'before_chat_history':
        return '历史前';
      case 'after_chat_history':
        return '历史后';
      case 'in_chat':
        return '消息中';
      case 'at_depth':
        return '指定深度';
      default:
        return position;
    }
  }

  Widget _compactInfoPill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE4DFF2)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          height: 1.1,
          color: Color(0xFF6F7788),
          fontWeight: FontWeight.w500,
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

  Widget _chip(String label, String value) {
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text('$label: $value'),
    );
  }

}

class _BuiltinPromptOrderOption {
  const _BuiltinPromptOrderOption(this.identifier, this.label);

  final String identifier;
  final String label;
}
