enum ChatAuthorRole { user, assistant, system }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.text,
    required this.authorId,
    required this.role,
    required this.createdAt,
  });

  final String id;
  final String text;
  final String authorId;
  final ChatAuthorRole role;
  final DateTime createdAt;
}
