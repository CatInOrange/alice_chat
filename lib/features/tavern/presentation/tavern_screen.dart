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

  @override
  void initState() {
    super.initState();
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
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final store = context.watch<TavernStore>();

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
        actions: widget.configOnly
            ? null
            : [
                IconButton(
                  tooltip: '角色页',
                  onPressed: () => _showCharactersSheet(context, store),
                  icon: const Icon(Icons.account_box_outlined),
                ),
              ],
      ),
      body: RefreshIndicator(
        onRefresh: store.loadCharacters,
        child: widget.configOnly
            ? _buildConfigHubTab(context, store)
            : _buildChatsTab(context, store),
      ),
    );
  }

  Widget _buildChatsTab(BuildContext context, TavernStore store) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('最近会话', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          '进来先直接聊天。角色和配置都收进次级入口。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF667085),
          ),
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

  Future<void> _showCharactersSheet(BuildContext context, TavernStore store) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.92,
          child: StatefulBuilder(
            builder: (context, setModalState) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('角色页', style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 4),
                            Text(
                              '角色不在酒馆首页常驻，按一下再展开。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: _isImporting
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
                  child: Builder(
                    builder: (context) {
                      if (store.isLoading) {
                        return const Center(child: CircularProgressIndicator());
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
                                subtitle: Text('支持导入 JSON / PNG / CharX 角色卡。'),
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
                                    character.description.isNotEmpty ? character.description : character.scenario,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () async {
                                    await _showCharacterDetail(character);
                                    if (context.mounted) setModalState(() {});
                                  },
                                  onLongPress: () async {
                                    await _confirmDeleteCharacter(this.context, character);
                                    if (context.mounted) setModalState(() {});
                                  },
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
      ),
    );
  }

  Widget _buildConfigHubTab(BuildContext context, TavernStore store) {
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
        _settingsEntryCard(
          context,
          icon: Icons.auto_awesome_outlined,
          title: 'Presets',
          subtitle: '模型参数与采样配置',
          trailingText: '${store.presets.length}',
          onTap: () => _showPresetsManager(context, store),
        ),
        const SizedBox(height: 12),
        _settingsEntryCard(
          context,
          icon: Icons.reorder_outlined,
          title: '提示词管理',
          subtitle: '像 Native 一样管理内建段落与自定义提示词',
          trailingText: '${store.promptOrders.length}',
          onTap: () => _showPromptOrdersManager(context, store),
        ),
        const SizedBox(height: 12),
        _settingsEntryCard(
          context,
          icon: Icons.public_outlined,
          title: 'WorldBooks',
          subtitle: '世界书与条目管理，含 sticky / cooldown / delay',
          trailingText: '${store.worldBooks.length}',
          onTap: () => _showWorldBooksManager(context, store),
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
              title: Text('还没有提示词配置'),
              subtitle: Text('拖拽编排内建段落顺序，并按需新增自定义提示词。'),
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
                                  if (entry.preventRecursion)
                                    _chip('NoRecur', 'yes'),
                                  if (entry.recursive)
                                    _chip('Recursive', 'yes'),
                                  if (entry.sticky > 0)
                                    _chip('Sticky', '${entry.sticky}'),
                                  if (entry.cooldown > 0)
                                    _chip('Cooldown', '${entry.cooldown}'),
                                  if (entry.delay > 0)
                                    _chip('Delay', '${entry.delay}'),
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

  Widget _settingsEntryCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    String? trailingText,
  }) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (trailingText != null) ...[
              Text(
                trailingText,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: const Color(0xFF7D8596),
                ),
              ),
              const SizedBox(width: 8),
            ],
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: onTap,
      ),
    );
  }

  Future<void> _showPresetsManager(BuildContext context, TavernStore store) async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('Presets'),
            actions: [
              IconButton(
                tooltip: '刷新',
                onPressed: () => this.context.read<TavernStore>().loadHome(),
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
    await this.context.read<TavernStore>().loadHome();
  }

  Future<void> _showPromptOrdersManager(BuildContext context, TavernStore store) async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('提示词管理'),
            actions: [
              IconButton(
                tooltip: '新增自定义提示词',
                onPressed: () => _editPromptOrder(context),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          body: _buildPromptOrdersTab(context, store),
        ),
      ),
    );
    if (!mounted) return;
    await this.context.read<TavernStore>().loadHome();
  }

  Future<void> _showWorldBooksManager(BuildContext context, TavernStore store) async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
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
          body: _buildWorldBooksTab(context, store),
        ),
      ),
    );
    if (!mounted) return;
    await this.context.read<TavernStore>().loadHome();
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
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '把模型参数、Prompt Order 和注入策略收成可复用模板。列表先看用途，点进再看细节。',
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
            ...usedPresets.map((preset) => _buildPresetSummaryCard(context, store, preset)),
            const SizedBox(height: 18),
          ],
          if (idlePresets.isNotEmpty) ...[
            _managerSectionHeader(
              context,
              title: '其他 Presets',
              subtitle: '已保存但当前没有会话在使用。',
            ),
            const SizedBox(height: 10),
            ...idlePresets.map((preset) => _buildPresetSummaryCard(context, store, preset)),
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
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
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
    final promptOrderName = _promptOrderName(store, preset.promptOrderId);
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
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _presetSummaryLine(store, preset),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF6F7788),
                          ),
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
                    itemBuilder: (context) => const [
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
                  _compactInfoPill('Prompt Order · $promptOrderName'),
                  _compactInfoPill('Max ${preset.maxTokens > 0 ? preset.maxTokens : '默认'}'),
                  _compactInfoPill('Temp ${preset.temperature.toStringAsFixed(2)}'),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _presetStatePill(
                    usageCount > 0 ? '使用中 $usageCount 会话' : '当前未使用',
                    color: usageCount > 0 ? const Color(0xFF3FB950) : const Color(0xFF98A1B3),
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
                  const Icon(Icons.chevron_right, size: 18, color: Color(0xFF7C4DFF)),
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
      builder: (context) => SafeArea(
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
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
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
                      color: usageCount > 0 ? const Color(0xFF3FB950) : const Color(0xFF98A1B3),
                    ),
                    _presetStatePill(
                      'Prompt Order · ${_promptOrderName(store, preset.promptOrderId)}',
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
                    _infoRow('Provider', preset.provider.isEmpty ? '默认 / 未指定' : preset.provider),
                    _infoRow('Model', preset.model.isEmpty ? '默认 / 未指定' : preset.model),
                    _infoRow('Prompt Order', _promptOrderName(store, preset.promptOrderId)),
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
                    _compactInfoPill('Temp ${preset.temperature.toStringAsFixed(2)}'),
                    _compactInfoPill('TopP ${preset.topP.toStringAsFixed(2)}'),
                    _compactInfoPill('TopK ${preset.topK}'),
                    _compactInfoPill('MinP ${preset.minP.toStringAsFixed(2)}'),
                    _compactInfoPill('Typical ${preset.typicalP.toStringAsFixed(2)}'),
                    _compactInfoPill('Repeat ${preset.repetitionPenalty.toStringAsFixed(2)}'),
                    _compactInfoPill('MaxTokens ${preset.maxTokens > 0 ? preset.maxTokens : '默认'}'),
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
                        _compactInfoPill('Story ${preset.storyStringPosition}'),
                        _compactInfoPill('Role ${preset.storyStringRole}'),
                        _compactInfoPill('Depth ${preset.storyStringDepth}'),
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
                      _infoRow('Example Separator', preset.exampleSeparator),
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
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
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
    final orderName = _promptOrderName(store, preset.promptOrderId);
    final maxTokens = preset.maxTokens > 0 ? '${preset.maxTokens} tok' : '默认长度';
    return '${_presetModelLabel(preset)} · $orderName · $maxTokens';
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
      await store.importCharacterFile(
        filename: filename,
        bytes: bytes,
      );
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
      builder: (context) => SafeArea(
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
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.9,
          child: _CharacterDetailSheet(
            character: character,
            serverBaseUrl: _serverBaseUrl,
            onStartChat: () async {
              Navigator.of(context).pop();
              await _startChatWithCharacter(character);
            },
          ),
        ),
      ),
    );
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
      context: this.context,
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
    if (confirmed != true || !mounted) return;
    final doubleConfirmed = await showDialog<bool>(
      context: this.context,
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

  Future<void> _confirmDeleteWorldBook(
    BuildContext context,
    TavernWorldBook worldbook,
  ) async {
    if (!mounted) return;
    final store = context.read<TavernStore>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showModalBottomSheet<bool>(
      context: this.context,
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
      context: this.context,
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
      context: this.context,
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
    if (confirmed != true || !mounted) return;
    final doubleConfirmed = await showDialog<bool>(
      context: this.context,
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
                                      promptOrders.any((item) => item.id == promptOrderId)
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
                                const SizedBox(height: 8),
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

  Future<void> _editPromptOrder(
    BuildContext context, {
    TavernPromptOrder? promptOrder,
  }) async {
    final store = context.read<TavernStore>();
    final isCreate = promptOrder == null;
    final baseOrder = promptOrder ?? (store.promptOrders.isNotEmpty ? store.promptOrders.first : null);
    final nameController = TextEditingController(
      text: promptOrder?.name ?? baseOrder?.name ?? '默认提示词管理',
    );
    final items = <TavernPromptOrderItem>[
      ...(baseOrder?.items ?? const <TavernPromptOrderItem>[]),
    ]..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    bool saving = false;
    DateTime? lastReorderAt;

    bool shouldIgnoreTap() {
      final at = lastReorderAt;
      return at != null && DateTime.now().difference(at).inMilliseconds < 280;
    }

    Future<void> addCustomItem(StateSetter setModalState) async {
      final created = await _editPromptManagerCustomItem(context);
      if (created == null) return;
      setModalState(() {
        items.add(created.copyWith(orderIndex: items.length * 10));
      });
    }

    Future<void> editCustomItem(StateSetter setModalState, int index) async {
      final item = items[index];
      if (!item.isCustom) return;
      final updated = await _editPromptManagerCustomItem(context, item: item);
      if (updated == null) return;
      setModalState(() {
        items[index] = updated.copyWith(orderIndex: item.orderIndex);
      });
    }

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
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.88,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isCreate ? '新建提示词管理' : '编辑提示词管理',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '内建段落只负责移动和开关；自定义项才编辑内容。',
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '提示词项（拖拽即顺序）',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => addCustomItem(setModalState),
                        icon: const Icon(Icons.add),
                        label: const Text('新增自定义项'),
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
                          final moved = items.removeAt(oldIndex);
                          items.insert(newIndex, moved);
                          for (var i = 0; i < items.length; i += 1) {
                            items[i] = items[i].copyWith(orderIndex: i * 10);
                          }
                        });
                      },
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final isCustom = item.isCustom;
                        return Card(
                          key: ValueKey('${item.identifier}:${item.blockId}:${item.name}:$index'),
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            leading: ReorderableDragStartListener(
                              index: index,
                              child: const Icon(Icons.drag_indicator, size: 18),
                            ),
                            title: Text(
                              _promptOrderItemLabel(store, item),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isCustom
                                        ? '${item.role} · ${item.content.trim().isEmpty ? '未填写内容' : item.content.trim()}'
                                        : '内建段落',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      _compactInfoPill(isCustom ? '自定义' : '内建'),
                                      _compactInfoPill(item.enabled ? '已启用' : '已关闭'),
                                      if (isCustom) _compactInfoPill(item.role),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: item.enabled,
                                  onChanged: (value) {
                                    setModalState(() {
                                      items[index] = item.copyWith(enabled: value);
                                    });
                                  },
                                ),
                                if (isCustom)
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: '编辑',
                                    onPressed: () {
                                      if (shouldIgnoreTap()) return;
                                      editCustomItem(setModalState, index);
                                    },
                                    icon: const Icon(Icons.edit_outlined, size: 18),
                                  ),
                                if (isCustom)
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: '删除',
                                    onPressed: () {
                                      if (shouldIgnoreTap()) return;
                                      setModalState(() => items.removeAt(index));
                                    },
                                    icon: const Icon(Icons.delete_outline, size: 18),
                                  ),
                              ],
                            ),
                            onTap: () {
                              if (shouldIgnoreTap() || !isCustom) return;
                              editCustomItem(setModalState, index);
                            },
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
                                  final normalized = <Map<String, dynamic>>[];
                                  for (var i = 0; i < items.length; i += 1) {
                                    final current = items[i];
                                    normalized.add(
                                      current.copyWith(
                                        orderIndex: i * 10,
                                        position: itemPositionFor(current),
                                        depth: null,
                                        clearDepth: true,
                                        builtIn: current.identifier.isNotEmpty,
                                      ).toJson(),
                                    );
                                  }
                                  final payload = {
                                    'name': nameController.text.trim().isEmpty
                                        ? '默认提示词管理'
                                        : nameController.text.trim(),
                                    'items': normalized,
                                  };
                                  final targetPromptOrderId = promptOrder?.id ?? baseOrder?.id ?? '';
                                  if (isCreate || targetPromptOrderId.isEmpty) {
                                    await store.createPromptOrder(payload);
                                  } else {
                                    await store.updatePromptOrder(
                                      promptOrderId: targetPromptOrderId,
                                      payload: payload,
                                    );
                                  }
                                  if (context.mounted) {
                                    Navigator.of(context).pop(true);
                                  }
                                } catch (exc) {
                                  if (!context.mounted) return;
                                  setModalState(() => saving = false);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('${isCreate ? '创建' : '保存'}提示词管理失败：$exc')),
                                  );
                                }
                              },
                        child: saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
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
        SnackBar(content: Text(isCreate ? '提示词管理已创建' : '提示词管理已更新')),
      );
      await context.read<TavernStore>().loadHome();
    }
  }

  String itemPositionFor(TavernPromptOrderItem item) {
    if (item.position == 'at_depth') return 'at_depth';
    switch (item.identifier) {
      case 'main':
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
    String role = (item?.role ?? 'system').trim().isEmpty ? 'system' : (item?.role ?? 'system');

    final result = await showModalBottomSheet<TavernPromptOrderItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: StatefulBuilder(
            builder: (context, setModalState) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item == null ? '新增自定义提示词' : '编辑自定义提示词', style: Theme.of(context).textTheme.titleLarge),
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
                  value: _storyRoles.contains(role) ? role : 'system',
                  decoration: const InputDecoration(
                    labelText: 'Role',
                    border: OutlineInputBorder(),
                  ),
                  items: _storyRoles.map((value) => DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  )).toList(growable: false),
                  onChanged: (value) => setModalState(() => role = value ?? 'system'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentController,
                  minLines: 5,
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
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        Navigator.of(context).pop(
                          TavernPromptOrderItem(
                            identifier: '',
                            name: nameController.text.trim().isEmpty ? '未命名自定义项' : nameController.text.trim(),
                            role: role,
                            content: contentController.text,
                            enabled: item?.enabled ?? true,
                            orderIndex: item?.orderIndex ?? 0,
                            position: item?.position ?? 'after_chat_history',
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新 WorldBook 失败：$exc')),
      );
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
    bool preventRecursion = entry?.preventRecursion ?? false;
    String insertionPosition =
        entry?.insertionPosition ?? 'before_chat_history';
    int priority = entry?.priority ?? 0;
    int sticky = entry?.sticky ?? 0;
    int cooldown = entry?.cooldown ?? 0;
    int delay = entry?.delay ?? 0;
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
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Prevent Recursion'),
                            value: preventRecursion,
                            onChanged:
                                (value) => setModalState(
                                  () => preventRecursion = value,
                                ),
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
                          _intStepper(
                            context,
                            label: 'Sticky Turns',
                            value: sticky,
                            min: 0,
                            max: 20,
                            onChanged:
                                (value) => setModalState(() => sticky = value),
                          ),
                          const SizedBox(height: 12),
                          _intStepper(
                            context,
                            label: 'Cooldown Turns',
                            value: cooldown,
                            min: 0,
                            max: 20,
                            onChanged:
                                (value) =>
                                    setModalState(() => cooldown = value),
                          ),
                          const SizedBox(height: 12),
                          _intStepper(
                            context,
                            label: 'Delay Turns',
                            value: delay,
                            min: 0,
                            max: 20,
                            onChanged:
                                (value) => setModalState(() => delay = value),
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
                                              'preventRecursion':
                                                  preventRecursion,
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
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
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
                  _ImportStatChip(label: '来源', value: character.sourceType.toUpperCase()),
                  _ImportStatChip(label: '字段', value: '${summary.filledFieldCount}/${summary.totalFieldCount}'),
                  _ImportStatChip(label: '问候', value: '${character.alternateGreetings.length}'),
                  _ImportStatChip(label: 'Lore', value: summary.lorebookEntryCount > 0 ? '${summary.lorebookEntryCount} 条' : '无'),
                  _ImportStatChip(label: '资产', value: summary.assetSummaryLabel),
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
                        .map((item) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text('• $item'),
                            ))
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
                    _kv('Alternate Greetings', character.alternateGreetings.isEmpty ? '' : '${character.alternateGreetings.length} 条'),
                    _kv('Embedded Lorebook', summary.lorebookEntryCount > 0 ? '${summary.lorebookEntryCount} 条，已随角色导入' : ''),
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
                        if (character.creator.isNotEmpty) 'by ${character.creator}',
                        if (character.characterVersion.isNotEmpty) 'v${character.characterVersion}',
                        if (character.sourceType.isNotEmpty) character.sourceType.toUpperCase(),
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
                  children: character.tags.map((tag) => Chip(label: Text(tag))).toList(growable: false),
                ),
                const SizedBox(height: 16),
              ],
              _ImportSectionCard(title: '基础信息', icon: Icons.badge_outlined, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailBlock('Description', character.description),
                  _detailBlock('Personality', character.personality),
                  _detailBlock('Scenario', character.scenario),
                  _detailBlock('First Message', character.firstMessage),
                  _detailBlock('Example Dialogues', character.exampleDialogues),
                ],
              )),
              const SizedBox(height: 12),
              _ImportSectionCard(title: 'Prompt / Notes', icon: Icons.psychology_alt_outlined, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailBlock('System Prompt', character.systemPrompt),
                  _detailBlock('Post-History Instructions', character.postHistoryInstructions),
                  _detailBlock('Creator Notes', character.creatorNotes),
                ],
              )),
              const SizedBox(height: 12),
              _ImportSectionCard(title: '问候与 Lore', icon: Icons.auto_stories_outlined, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailBlock(
                    'Alternate Greetings',
                    character.alternateGreetings.isEmpty
                        ? ''
                        : character.alternateGreetings.asMap().entries.map((e) => '${e.key + 1}. ${e.value}').join('\n\n'),
                  ),
                  _detailBlock(
                    'Embedded Lorebook',
                    summary.lorebookEntryCount > 0
                        ? '检测到 ${summary.lorebookEntryCount} 条 embedded lorebook entries，已作为角色附带知识导入。'
                        : '',
                  ),
                ],
              )),
              const SizedBox(height: 12),
              _ImportSectionCard(title: '资产摘要', icon: Icons.perm_media_outlined, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailBlock('头像', character.avatarPath),
                  _detailBlock('CharX 资源', summary.assetDetailLabel),
                  _detailBlock('来源文件', character.sourceName),
                ],
              )),
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
    final book = character.metadata['cardData'] is Map
        ? (character.metadata['cardData'] as Map)['character_book']
        : character.metadata['character_book'];
    final entries = book is Map && book['entries'] is List ? (book['entries'] as List).length : 0;
    final charxAssets = character.metadata['charxAssets'];
    int sprites = 0;
    int backgrounds = 0;
    int misc = 0;
    if (charxAssets is Map) {
      sprites = (charxAssets['sprites'] as num?)?.toInt() ?? 0;
      backgrounds = (charxAssets['backgrounds'] as num?)?.toInt() ?? 0;
      misc = (charxAssets['misc'] as num?)?.toInt() ?? 0;
    }
    final assetSummary = sprites + backgrounds + misc > 0
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
  const _BuiltinPromptOrderOption(this.identifier, this.label);

  final String identifier;
  final String label;
}
