import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:uuid/uuid.dart';

import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../domain/chat_message.dart' as domain;
import '../domain/chat_session.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.session});

  final ChatSession session;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _uuid = const Uuid();
  final _currentUserId = 'user';

  late final core.InMemoryChatController _chatController;
  late final OpenClawHttpClient _client;

  bool _loading = true;
  bool _sending = false;
  String? _error;
  String? _sessionId;

  @override
  void initState() {
    super.initState();
    _chatController = core.InMemoryChatController();
    _client = OpenClawHttpClient(
      const OpenClawConfig(
        baseUrl: 'https://alice.newthu.com',
        modelId: 'bian',
        providerId: 'live2d-channel',
        agent: 'main',
        sessionName: 'alicechat:alice',
        bridgeUrl: 'ws://127.0.0.1:18800?token=yuanzhe-7611681-668128-zheyuan-012345',
      ),
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final sessionId = await _client.ensureSession(
        preferredName: widget.session.backendSessionId ?? widget.session.title,
      );
      final rawMessages = await _client.loadMessages(sessionId);
      final messages = rawMessages
          .map(domain.ChatMessage.fromBackend)
          .where((message) => message.text.trim().isNotEmpty)
          .toList()
          .reversed
          .toList();

      for (final message in messages) {
        await _chatController.insertMessage(
          core.TextMessage(
            id: message.id.isEmpty ? _uuid.v4() : message.id,
            authorId: message.authorId,
            createdAt: message.createdAt,
            text: message.text,
          ),
          animated: false,
        );
      }

      if (!mounted) return;
      setState(() {
        _sessionId = sessionId;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              backgroundImage: widget.session.avatarAssetPath != null
                  ? AssetImage(widget.session.avatarAssetPath!)
                  : null,
              child: widget.session.avatarAssetPath == null
                  ? Text(widget.session.title[0].toUpperCase())
                  : null,
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.session.title),
                Text(
                  widget.session.subtitle,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
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
                _error!,
                style: TextStyle(color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _bootstrap();
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        Chat(
          currentUserId: _currentUserId,
          resolveUser: _resolveUser,
          chatController: _chatController,
          onMessageSend: _handleSend,
        ),
        if (_sending)
          const Positioned(
            top: 12,
            right: 12,
            child: Card(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text('alice 正在回复...'),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _handleSend(String text) async {
    final sessionId = _sessionId;
    if (sessionId == null || text.trim().isEmpty || _sending) {
      return;
    }

    final userMessage = core.TextMessage(
      id: _uuid.v4(),
      authorId: _currentUserId,
      createdAt: DateTime.now(),
      text: text,
    );

    setState(() {
      _sending = true;
    });

    await _chatController.insertMessage(userMessage);

    try {
      final reply = await _client.sendMessage(sessionId: sessionId, text: text);
      if (!mounted) return;

      final assistantMessage = core.TextMessage(
        id: _uuid.v4(),
        authorId: 'assistant',
        createdAt: DateTime.now(),
        text: reply.isEmpty ? '收到啦。' : reply,
      );
      await _chatController.insertMessage(assistantMessage);

      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = error.toString();
      });
    }
  }

  Future<core.User> _resolveUser(String id) async {
    switch (id) {
      case 'assistant':
        return core.User(
          id: 'assistant',
          name: 'alice',
          imageSource: 'assets/avatars/alice.jpg',
        );
      case 'system':
        return core.User(id: 'system', name: 'System');
      default:
        return core.User(id: _currentUserId, name: 'You');
    }
  }
}
