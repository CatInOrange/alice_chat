import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../../core/openclaw/openclaw_settings.dart';
import '../application/tavern_store.dart';
import '../domain/tavern_models.dart';
import 'tavern_chat_screen.dart';

class TavernScreen extends StatefulWidget {
  const TavernScreen({super.key});

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
        _serverBaseUrl = settings.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
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
      if (!mounted || message == null || message.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      context.read<TavernStore>().clearImportMessage();
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('酒馆'),
        actions: [
          IconButton(
            tooltip: '导入角色',
            onPressed: _isImporting ? null : _importCharacter,
            icon: _isImporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_upload_outlined),
          ),
          IconButton(
            tooltip: '更多',
            onPressed: () {},
            icon: const Icon(Icons.more_horiz),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: store.loadCharacters,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('最近会话', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (store.recentChats.isEmpty)
              const Card(
                child: ListTile(
                  title: Text('还没有 Tavern 会话'),
                  subtitle: Text('导入角色后可以直接开聊。'),
                ),
              )
            else
              ...store.recentChats.take(6).map(
                (chat) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: Text(chat.title),
                    subtitle: Text(chat.id),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openExistingChat(chat),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Text('角色', style: Theme.of(context).textTheme.titleMedium),
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
                  subtitle: Text('一期主路径是导入 JSON 角色卡。'),
                ),
              )
            else
              ...store.characters.map(
                (character) => Card(
                  child: ListTile(
                    leading: _buildAvatar(character.avatarPath),
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
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _importCharacter() async {
    final messenger = ScaffoldMessenger.of(context);
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
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
    final expected = source == 'png'
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
      messenger.showSnackBar(
        SnackBar(content: Text('导入失败：$exc')),
      );
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  Future<void> _startChatWithCharacter(TavernCharacter character) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final chat = await context.read<TavernStore>().createChatForCharacter(character);
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
      final character = await store.getCharacter(chat.characterId);
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

  Widget _buildAvatar(String avatarPath) {
    final trimmed = avatarPath.trim();
    if (trimmed.isEmpty) {
      return const CircleAvatar(child: Icon(Icons.person_outline));
    }
    if (trimmed.startsWith('/uploads/')) {
      final url = _serverBaseUrl == null || _serverBaseUrl!.isEmpty
          ? null
          : '$_serverBaseUrl$trimmed';
      if (url != null) {
        return CircleAvatar(
          backgroundImage: NetworkImage(url),
          onBackgroundImageError: (_, __) {},
        );
      }
    }
    final file = File(trimmed);
    if (file.existsSync()) {
      return CircleAvatar(backgroundImage: FileImage(file));
    }
    return const CircleAvatar(child: Icon(Icons.person_outline));
  }
}
