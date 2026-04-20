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

  factory ChatMessage.fromBackend(Map<String, dynamic> json) {
    final roleValue = (json['role'] ?? '').toString();
    final role = switch (roleValue) {
      'assistant' => ChatAuthorRole.assistant,
      'system' => ChatAuthorRole.system,
      _ => ChatAuthorRole.user,
    };

    final createdRaw = json['createdAt'];
    DateTime createdAt = DateTime.now();
    if (createdRaw is num) {
      final value = createdRaw.toDouble();
      createdAt = DateTime.fromMillisecondsSinceEpoch(
        value < 1000000000000 ? (value * 1000).round() : value.round(),
      );
    }

    return ChatMessage(
      id: (json['id'] ?? '').toString(),
      text: (json['text'] ?? '').toString(),
      authorId: role == ChatAuthorRole.assistant
          ? 'assistant'
          : role == ChatAuthorRole.system
              ? 'system'
              : 'user',
      role: role,
      createdAt: createdAt,
    );
  }
}
