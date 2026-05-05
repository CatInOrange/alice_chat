import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/openclaw/openclaw_settings.dart';
import '../application/tavern_store.dart';
import '../domain/tavern_models.dart';

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
  String? _error;
  String? _serverBaseUrl;
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
        _serverBaseUrl = settings.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
        _character = character;
        _messages = messages;
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_character.name),
            if (_character.scenario.isNotEmpty)
              Text(
                _character.scenario,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
      body: Container(
        decoration: bg == null
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
                        child: _isSending
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
          child: Text(
            _character.firstMessage.isNotEmpty ? _character.firstMessage : '还没有消息，开始聊吧。',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(12),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final isUser = message.role == 'user';
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              color: isUser ? Theme.of(context).colorScheme.primaryContainer : null,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment:
                      isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    Text(
                      isUser ? '你' : _character.name,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 4),
                    SelectableText(message.content),
                  ],
                ),
              ),
            ),
          ),
        );
      },
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发送失败：$exc')),
      );
    }
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
