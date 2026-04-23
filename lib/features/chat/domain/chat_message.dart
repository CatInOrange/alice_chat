enum ChatAuthorRole { user, assistant, system }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.text,
    required this.authorId,
    required this.role,
    required this.createdAt,
    this.modelName,
  });

  final String id;
  final String text;
  final String authorId;
  final ChatAuthorRole role;
  final DateTime createdAt;
  final String? modelName;

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

    // Extract [ModelName] prefix for assistant messages (keep original text intact)
    String text = (json['text'] ?? '').toString();
    String? modelName;
    if (role == ChatAuthorRole.assistant && text.startsWith('[')) {
      final bracketEnd = text.indexOf(']');
      if (bracketEnd > 1) {
        modelName = text.substring(1, bracketEnd);
        // Don't modify text - keep [ModelName] prefix for UI to parse
      }
    }

    return ChatMessage(
      id: (json['id'] ?? '').toString(),
      text: text,
      authorId: role == ChatAuthorRole.assistant
          ? 'assistant'
          : role == ChatAuthorRole.system
              ? 'system'
              : 'user',
      role: role,
      createdAt: createdAt,
      modelName: modelName,
    );
  }
}
