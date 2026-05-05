class TavernCharacter {
  const TavernCharacter({
    required this.id,
    required this.name,
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMessage = '',
    this.exampleDialogues = '',
    this.avatarPath = '',
    this.tags = const <String>[],
    this.alternateGreetings = const <String>[],
    this.creatorNotes = '',
    this.systemPrompt = '',
    this.postHistoryInstructions = '',
    this.creator = '',
    this.characterVersion = '',
    this.extensions = const <String, dynamic>{},
    this.sourceType = 'json',
    this.sourceName = '',
    this.metadata = const <String, dynamic>{},
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMessage;
  final String exampleDialogues;
  final String avatarPath;
  final List<String> tags;
  final List<String> alternateGreetings;
  final String creatorNotes;
  final String systemPrompt;
  final String postHistoryInstructions;
  final String creator;
  final String characterVersion;
  final Map<String, dynamic> extensions;
  final String sourceType;
  final String sourceName;
  final Map<String, dynamic> metadata;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory TavernCharacter.fromJson(Map<String, dynamic> json) {
    return TavernCharacter(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      personality: (json['personality'] ?? '').toString(),
      scenario: (json['scenario'] ?? '').toString(),
      firstMessage: (json['firstMessage'] ?? '').toString(),
      exampleDialogues: (json['exampleDialogues'] ?? '').toString(),
      avatarPath: (json['avatarPath'] ?? '').toString(),
      tags: ((json['tags'] as List?) ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
      alternateGreetings: ((json['alternateGreetings'] as List?) ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
      creatorNotes: (json['creatorNotes'] ?? '').toString(),
      systemPrompt: (json['systemPrompt'] ?? '').toString(),
      postHistoryInstructions: (json['postHistoryInstructions'] ?? '').toString(),
      creator: (json['creator'] ?? '').toString(),
      characterVersion: (json['characterVersion'] ?? '').toString(),
      extensions: Map<String, dynamic>.from(
        (json['extensions'] as Map?) ?? const <String, dynamic>{},
      ),
      sourceType: (json['sourceType'] ?? 'json').toString(),
      sourceName: (json['sourceName'] ?? '').toString(),
      metadata: Map<String, dynamic>.from(
        (json['metadata'] as Map?) ?? const <String, dynamic>{},
      ),
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }
}

class TavernChat {
  const TavernChat({
    required this.id,
    required this.characterId,
    required this.title,
    this.presetId = '',
    this.personaId = '',
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String characterId;
  final String title;
  final String presetId;
  final String personaId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory TavernChat.fromJson(Map<String, dynamic> json) {
    return TavernChat(
      id: (json['id'] ?? '').toString(),
      characterId: (json['characterId'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      presetId: (json['presetId'] ?? '').toString(),
      personaId: (json['personaId'] ?? '').toString(),
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }
}

class TavernMessage {
  const TavernMessage({
    required this.id,
    required this.chatId,
    required this.role,
    required this.content,
    this.thought = '',
    this.createdAt,
  });

  final String id;
  final String chatId;
  final String role;
  final String content;
  final String thought;
  final DateTime? createdAt;

  factory TavernMessage.fromJson(Map<String, dynamic> json) {
    return TavernMessage(
      id: (json['id'] ?? '').toString(),
      chatId: (json['chatId'] ?? '').toString(),
      role: (json['role'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      thought: (json['thought'] ?? '').toString(),
      createdAt: _parseDate(json['createdAt']),
    );
  }
}

class TavernWorldBook {
  const TavernWorldBook({
    required this.id,
    required this.name,
    this.description = '',
    this.enabled = true,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final bool enabled;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory TavernWorldBook.fromJson(Map<String, dynamic> json) {
    return TavernWorldBook(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      enabled: json['enabled'] != false,
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }
}

DateTime? _parseDate(dynamic value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value * 1000).round(),
      isUtc: true,
    ).toLocal();
  }
  return null;
}
