import 'package:uuid/uuid.dart';

import '../domain/chat_message.dart';

class MockChatRepository {
  MockChatRepository() : _messages = _seedMessages();

  final List<ChatMessage> _messages;
  final _uuid = const Uuid();

  List<ChatMessage> get messages => List.unmodifiable(_messages);

  void sendUserMessage(String text) {
    _messages.insert(
      0,
      ChatMessage(
        id: _uuid.v4(),
        text: text,
        authorId: 'user',
        role: ChatAuthorRole.user,
        createdAt: DateTime.now(),
      ),
    );

    _messages.insert(
      0,
      ChatMessage(
        id: _uuid.v4(),
        text: '收到啦，这里之后会接 OpenClaw 流式回复。',
        authorId: 'assistant',
        role: ChatAuthorRole.assistant,
        createdAt: DateTime.now(),
      ),
    );
  }

  static List<ChatMessage> _seedMessages() {
    return [
      ChatMessage(
        id: 'welcome',
        text: 'AliceChat 底座已准备好，下一步接 OpenClaw。',
        authorId: 'assistant',
        role: ChatAuthorRole.assistant,
        createdAt: DateTime.now(),
      ),
    ];
  }
}
