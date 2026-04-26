enum ChatAuthorRole { user, assistant, system }

class ChatAttachment {
  const ChatAttachment({
    required this.id,
    required this.kind,
    required this.url,
    this.mimeType,
    this.name,
    this.width,
    this.height,
    this.size,
    this.durationMs,
    this.status,
    this.meta = const {},
  });

  final String id;
  final String kind;
  final String url;
  final String? mimeType;
  final String? name;
  final double? width;
  final double? height;
  final int? size;
  final int? durationMs;
  final String? status;
  final Map<String, dynamic> meta;

  factory ChatAttachment.fromBackend(Map<String, dynamic> json) {
    double? toDouble(dynamic value) =>
        value is num ? value.toDouble() : double.tryParse('${value ?? ''}');
    int? toInt(dynamic value) =>
        value is num ? value.toInt() : int.tryParse('${value ?? ''}');
    return ChatAttachment(
      id: (json['id'] ?? '').toString(),
      kind: (json['kind'] ?? 'file').toString(),
      url: (json['url'] ?? json['data'] ?? '').toString(),
      mimeType: (json['mimeType'] ?? json['mime_type'])?.toString(),
      name: (json['name'] ?? json['filename'])?.toString(),
      width: toDouble(json['width']),
      height: toDouble(json['height']),
      size: toInt(json['size']),
      durationMs: toInt(json['durationMs']),
      status: json['status']?.toString(),
      meta:
          (json['meta'] is Map)
              ? Map<String, dynamic>.from(json['meta'] as Map)
              : const {},
    );
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.text,
    required this.authorId,
    required this.role,
    required this.createdAt,
    this.modelName,
    this.attachments = const [],
  });

  final String id;
  final String text;
  final String authorId;
  final ChatAuthorRole role;
  final DateTime createdAt;
  final String? modelName;
  final List<ChatAttachment> attachments;

  bool get hasVisibleContent =>
      text.trim().isNotEmpty || attachments.isNotEmpty;

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

    String text = (json['text'] ?? '').toString();
    String? modelName;
    if (role == ChatAuthorRole.assistant && text.startsWith('[')) {
      final bracketEnd = text.indexOf(']');
      if (bracketEnd > 1) {
        modelName = text.substring(1, bracketEnd);
      }
    }

    final rawAttachments = (json['attachments'] as List<dynamic>? ?? const []);
    final attachments = rawAttachments
        .whereType<Map>()
        .map(
          (item) => ChatAttachment.fromBackend(Map<String, dynamic>.from(item)),
        )
        .where((item) => item.url.trim().isNotEmpty)
        .toList(growable: false);

    return ChatMessage(
      id: (json['id'] ?? '').toString(),
      text: text,
      authorId:
          role == ChatAuthorRole.assistant
              ? 'assistant'
              : role == ChatAuthorRole.system
              ? 'system'
              : 'user',
      role: role,
      createdAt: createdAt,
      modelName: modelName,
      attachments: attachments,
    );
  }
}
