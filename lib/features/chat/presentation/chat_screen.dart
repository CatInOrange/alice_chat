import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_chat_core/flutter_chat_core.dart' show Builders, TimeAndStatusPosition;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:provider/provider.dart';
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
  final _composerController = TextEditingController();

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
        baseUrl: 'http://43.156.5.177:8081',
        modelId: 'bian',
        providerId: 'alicechat-channel',
        agent: 'main',
        sessionName: 'alicechat',
        bridgeUrl: 'ws://127.0.0.1:18791?token=yuanzhe-7611681-668128-zheyuan-012345',
      ),
    );
    _bootstrap();
  }

  String get _assistantName => widget.session.title;

  String get _assistantSubtitle => _sending ? '正在输入…' : widget.session.subtitle;

  Builders get _chatBuilders => Builders(
    textMessageBuilder: _buildTextMessage,
    composerBuilder: _buildComposer,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        titleSpacing: 8,
        title: Row(
          children: [
            _buildHeaderAvatar(radius: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _assistantSubtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _sending
                          ? theme.colorScheme.primary
                          : const Color(0xFF98A1B3),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            height: 1,
            color: const Color(0xFFE7EAF3),
          ),
        ),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0xFFF6F7FB),
        ),
        child: _buildBody(),
      ),
    );
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

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0F1F2430),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                  style: TextStyle(color: Colors.grey[600], height: 1.45),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
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
          builders: _chatBuilders,
          backgroundColor: const Color(0xFFF6F7FB),
        ),
        if (_sending)
          Positioned(
            left: 12,
            right: 12,
            bottom: 14,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x121F2430),
                        blurRadius: 18,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildHeaderAvatar(radius: 12),
                      const SizedBox(width: 8),
                      Text(
                        '$_assistantName 正在输入…',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF667085),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
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

    _composerController.clear();
    await _chatController.insertMessage(userMessage);

    try {
      final reply = await _client.sendMessage(
        sessionId: sessionId,
        text: text,
        contactId: widget.session.contactId,
        userId: _sessionId,
      );
      if (!mounted) return;

      if (reply.isNotEmpty) {
        final assistantMessage = core.TextMessage(
          id: _uuid.v4(),
          authorId: 'assistant',
          createdAt: DateTime.now(),
          text: reply,
        );
        await _chatController.insertMessage(assistantMessage);
      }
    } catch (error) {
      if (!mounted) return;
      await _chatController.insertMessage(core.TextMessage(
        id: _uuid.v4(),
        authorId: 'assistant',
        createdAt: DateTime.now(),
        text: '❌ 发送失败: ${error.toString()}',
      ));
    }

    if (mounted) {
      setState(() {
        _sending = false;
      });
    }
  }

  Future<core.User> _resolveUser(String id) async {
    switch (id) {
      case 'assistant':
        return core.User(
          id: 'assistant',
          name: _assistantName,
          imageSource: widget.session.avatarAssetPath ?? 'assets/avatars/alice.jpg',
        );
      case 'system':
        return core.User(id: 'system', name: 'System');
      default:
        return core.User(id: _currentUserId, name: 'You');
    }
  }

  Widget _buildTextMessage(
    BuildContext context,
    core.TextMessage message,
    int index, {
    bool? isSentByMe,
    core.MessageGroupStatus? groupStatus,
  }) {
    final sentByMe = isSentByMe ?? false;
    final showAvatar = !sentByMe && (groupStatus == null || groupStatus.isLast);
    final maxWidth = MediaQuery.of(context).size.width * 0.72;
    final bubbleRadius = BorderRadius.only(
      topLeft: const Radius.circular(20),
      topRight: const Radius.circular(20),
      bottomLeft: Radius.circular(sentByMe ? 20 : 8),
      bottomRight: Radius.circular(sentByMe ? 8 : 20),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        groupStatus?.isFirst == true || groupStatus == null ? 10 : 3,
        12,
        groupStatus?.isLast == true || groupStatus == null ? 10 : 3,
      ),
      child: Row(
        mainAxisAlignment:
            sentByMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!sentByMe)
            SizedBox(
              width: 34,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: showAvatar
                    ? _buildHeaderAvatar(radius: 15)
                    : const SizedBox.shrink(),
              ),
            ),
          if (!sentByMe) const SizedBox(width: 8),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Column(
                crossAxisAlignment:
                    sentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (!sentByMe && (groupStatus?.isFirst ?? true))
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 6),
                      child: Text(
                        _assistantName,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF98A1B3),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  SimpleTextMessage(
                    message: message,
                    index: index,
                    showStatus: false,
                    timeAndStatusPosition: TimeAndStatusPosition.end,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    borderRadius: bubbleRadius,
                    sentBackgroundColor: const Color(0xFF7C4DFF),
                    receivedBackgroundColor: Colors.white,
                    sentTextStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                    receivedTextStyle:
                        Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: const Color(0xFF1F2430),
                          fontWeight: FontWeight.w500,
                        ),
                    timeStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: sentByMe
                          ? Colors.white.withOpacity(0.72)
                          : const Color(0xFF98A1B3),
                      fontSize: 11,
                    ),
                    topWidget: sentByMe
                        ? null
                        : const SizedBox(height: 0),
                  ),
                ],
              ),
            ),
          ),
          if (sentByMe) const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: const BoxDecoration(
          color: Color(0xFFF6F7FB),
          border: Border(
            top: BorderSide(color: Color(0xFFE7EAF3)),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: IconButton(
                onPressed: null,
                icon: const Icon(Icons.add_rounded),
                color: const Color(0xFF98A1B3),
                tooltip: '更多功能',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0A1F2430),
                      blurRadius: 14,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: TextField(
                  controller: _composerController,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(
                    hintText: '发消息…',
                    isDense: true,
                  ),
                  onSubmitted: (value) {
                    if (value.trim().isNotEmpty && !_sending) {
                      _handleSend(value);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(width: 10),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _sending
                    ? const Color(0xFFD7CCFF)
                    : theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(22),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x1A7C4DFF),
                    blurRadius: 16,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: IconButton(
                onPressed: _sending
                    ? null
                    : () {
                        final text = _composerController.text;
                        if (text.trim().isNotEmpty) {
                          _handleSend(text);
                        }
                      },
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.arrow_upward_rounded),
                color: Colors.white,
                tooltip: '发送',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderAvatar({double radius = 20}) {
    if (widget.session.avatarAssetPath != null) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: AssetImage(widget.session.avatarAssetPath!),
        backgroundColor: const Color(0xFFE9ECF5),
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFFE9ECF5),
      foregroundColor: const Color(0xFF5C667A),
      child: Text(
        widget.session.title.isEmpty ? '?' : widget.session.title[0].toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: radius * 0.9,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _composerController.dispose();
    super.dispose();
  }
}
