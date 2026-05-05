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

class TavernPreset {
  const TavernPreset({
    required this.id,
    required this.name,
    this.provider = '',
    this.model = '',
    this.promptOrderId = '',
    this.storyString = '',
    this.chatStart = '',
    this.exampleSeparator = '',
    this.storyStringPosition = 'in_prompt',
    this.storyStringDepth = 1,
    this.storyStringRole = 'system',
    this.temperature = 1,
    this.topP = 1,
    this.maxTokens = 0,
    this.stopSequences = const <String>[],
  });

  final String id;
  final String name;
  final String provider;
  final String model;
  final String promptOrderId;
  final String storyString;
  final String chatStart;
  final String exampleSeparator;
  final String storyStringPosition;
  final int storyStringDepth;
  final String storyStringRole;
  final double temperature;
  final double topP;
  final int maxTokens;
  final List<String> stopSequences;

  factory TavernPreset.fromJson(Map<String, dynamic> json) {
    return TavernPreset(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      provider: (json['provider'] ?? '').toString(),
      model: (json['model'] ?? '').toString(),
      promptOrderId: (json['promptOrderId'] ?? '').toString(),
      storyString: (json['storyString'] ?? '').toString(),
      chatStart: (json['chatStart'] ?? '').toString(),
      exampleSeparator: (json['exampleSeparator'] ?? '').toString(),
      storyStringPosition: (json['storyStringPosition'] ?? 'in_prompt').toString(),
      storyStringDepth: (json['storyStringDepth'] as num?)?.toInt() ?? 1,
      storyStringRole: (json['storyStringRole'] ?? 'system').toString(),
      temperature: (json['temperature'] as num?)?.toDouble() ?? 1,
      topP: (json['topP'] as num?)?.toDouble() ?? 1,
      maxTokens: (json['maxTokens'] as num?)?.toInt() ?? 0,
      stopSequences: ((json['stopSequences'] as List?) ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }

  TavernPreset copyWith({
    String? provider,
    String? model,
    String? promptOrderId,
    String? storyString,
    String? chatStart,
    String? exampleSeparator,
  }) {
    return TavernPreset(
      id: id,
      name: name,
      provider: provider ?? this.provider,
      model: model ?? this.model,
      promptOrderId: promptOrderId ?? this.promptOrderId,
      storyString: storyString ?? this.storyString,
      chatStart: chatStart ?? this.chatStart,
      exampleSeparator: exampleSeparator ?? this.exampleSeparator,
      storyStringPosition: storyStringPosition,
      storyStringDepth: storyStringDepth,
      storyStringRole: storyStringRole,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      stopSequences: stopSequences,
    );
  }
}

class TavernProviderOption {
  const TavernProviderOption({
    required this.id,
    this.label = '',
    this.baseUrl = '',
    this.model = '',
  });

  final String id;
  final String label;
  final String baseUrl;
  final String model;

  factory TavernProviderOption.fromJson(Map<String, dynamic> json) {
    return TavernProviderOption(
      id: (json['id'] ?? '').toString(),
      label: (json['label'] ?? json['name'] ?? json['id'] ?? '').toString(),
      baseUrl: (json['baseUrl'] ?? '').toString(),
      model: (json['model'] ?? '').toString(),
    );
  }
}

class TavernPromptOrder {
  const TavernPromptOrder({
    required this.id,
    required this.name,
  });

  final String id;
  final String name;

  factory TavernPromptOrder.fromJson(Map<String, dynamic> json) {
    return TavernPromptOrder(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
    );
  }
}

class TavernPromptDebug {
  const TavernPromptDebug({
    required this.messages,
    required this.blocks,
    this.presetId = '',
    this.promptOrderId = '',
    this.renderedStoryString = '',
    this.renderedExamples = '',
    this.runtimeContext = const <String, dynamic>{},
    this.matchedWorldbookEntries = const <Map<String, dynamic>>[],
    this.rejectedWorldbookEntries = const <Map<String, dynamic>>[],
    this.characterLoreBindings = const <Map<String, dynamic>>[],
    this.depthInserts = const <Map<String, dynamic>>[],
    this.summary = const <String, dynamic>{},
  });

  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> blocks;
  final String presetId;
  final String promptOrderId;
  final String renderedStoryString;
  final String renderedExamples;
  final Map<String, dynamic> runtimeContext;
  final List<Map<String, dynamic>> matchedWorldbookEntries;
  final List<Map<String, dynamic>> rejectedWorldbookEntries;
  final List<Map<String, dynamic>> characterLoreBindings;
  final List<Map<String, dynamic>> depthInserts;
  final Map<String, dynamic> summary;

  factory TavernPromptDebug.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> parseMapList(String key) {
      return (((json[key] as List?) ?? const <dynamic>[]).whereType<Map>())
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
    }

    return TavernPromptDebug(
      messages: parseMapList('messages'),
      blocks: parseMapList('blocks'),
      presetId: (json['presetId'] ?? '').toString(),
      promptOrderId: (json['promptOrderId'] ?? '').toString(),
      renderedStoryString: (json['renderedStoryString'] ?? '').toString(),
      renderedExamples: (json['renderedExamples'] ?? '').toString(),
      runtimeContext: Map<String, dynamic>.from(
        (json['runtimeContext'] as Map?) ?? const <String, dynamic>{},
      ),
      matchedWorldbookEntries: parseMapList('matchedWorldbookEntries'),
      rejectedWorldbookEntries: parseMapList('rejectedWorldbookEntries'),
      characterLoreBindings: parseMapList('characterLoreBindings'),
      depthInserts: parseMapList('depthInserts'),
      summary: Map<String, dynamic>.from(
        (json['summary'] as Map?) ?? const <String, dynamic>{},
      ),
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
