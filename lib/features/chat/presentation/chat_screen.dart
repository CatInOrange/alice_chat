import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:uuid/uuid.dart';

import '../data/mock_chat_repository.dart';
import '../domain/chat_message.dart' as domain;

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _repo = MockChatRepository();
  final _currentUser = const core.User(id: 'user', name: 'You');
  final _assistantUser = const core.User(id: 'assistant', name: 'Alice');
  final _systemUser = const core.User(id: 'system', name: 'System');
  final _uuid = const Uuid();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AliceChat'),
      ),
      body: Chat(
        currentUserId: _currentUser.id,
        resolveUser: (id) => _resolveUser(id),
        messages: _mapMessages(_repo.messages),
        onMessageSend: _handleSend,
      ),
    );
  }

  Future<void> _handleSend(String text) async {
    setState(() {
      _repo.sendUserMessage(text);
    });
  }

  Future<core.User> _resolveUser(String id) async {
    switch (id) {
      case 'assistant':
        return _assistantUser;
      case 'system':
        return _systemUser;
      default:
        return _currentUser;
    }
  }

  List<core.Message> _mapMessages(List<domain.ChatMessage> messages) {
    return messages.map((message) {
      return core.TextMessage(
        id: message.id.isEmpty ? _uuid.v4() : message.id,
        authorId: message.authorId,
        createdAt: message.createdAt,
        text: message.text,
      );
    }).toList();
  }
}
