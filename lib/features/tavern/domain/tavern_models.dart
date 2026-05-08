class TavernCharacterImportResult {
  const TavernCharacterImportResult({
    required this.character,
    this.warnings = const <String>[],
  });

  final TavernCharacter character;
  final List<String> warnings;
}

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
      alternateGreetings: ((json['alternateGreetings'] as List?) ??
              const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
      creatorNotes: (json['creatorNotes'] ?? '').toString(),
      systemPrompt: (json['systemPrompt'] ?? '').toString(),
      postHistoryInstructions:
          (json['postHistoryInstructions'] ?? '').toString(),
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

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'personality': personality,
      'scenario': scenario,
      'firstMessage': firstMessage,
      'exampleDialogues': exampleDialogues,
      'avatarPath': avatarPath,
      'tags': tags,
      'alternateGreetings': alternateGreetings,
      'creatorNotes': creatorNotes,
      'systemPrompt': systemPrompt,
      'postHistoryInstructions': postHistoryInstructions,
      'creator': creator,
      'characterVersion': characterVersion,
      'extensions': extensions,
      'sourceType': sourceType,
      'sourceName': sourceName,
      'metadata': metadata,
      if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    };
  }
}

class TavernChat {
  const TavernChat({
    required this.id,
    required this.characterId,
    required this.title,
    this.presetId = '',
    this.personaId = '',
    this.authorNoteEnabled = false,
    this.authorNote = '',
    this.authorNoteDepth = 4,
    this.metadata = const <String, dynamic>{},
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String characterId;
  final String title;
  final String presetId;
  final String personaId;
  final bool authorNoteEnabled;
  final String authorNote;
  final int authorNoteDepth;
  final Map<String, dynamic> metadata;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory TavernChat.fromJson(Map<String, dynamic> json) {
    return TavernChat(
      id: (json['id'] ?? '').toString(),
      characterId: (json['characterId'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      presetId: (json['presetId'] ?? '').toString(),
      personaId: (json['personaId'] ?? '').toString(),
      authorNoteEnabled: json['authorNoteEnabled'] == true,
      authorNote: (json['authorNote'] ?? '').toString(),
      authorNoteDepth: (json['authorNoteDepth'] as num?)?.toInt() ?? 4,
      metadata: Map<String, dynamic>.from(
        (json['metadata'] as Map?) ?? const <String, dynamic>{},
      ),
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'characterId': characterId,
      'title': title,
      if (presetId.isNotEmpty) 'presetId': presetId,
      if (personaId.isNotEmpty) 'personaId': personaId,
      'authorNoteEnabled': authorNoteEnabled,
      'authorNote': authorNote,
      'authorNoteDepth': authorNoteDepth,
      if (metadata.isNotEmpty) 'metadata': metadata,
      if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    };
  }
}

class TavernMessage {
  const TavernMessage({
    required this.id,
    required this.chatId,
    required this.role,
    required this.content,
    this.thought = '',
    this.metadata = const <String, dynamic>{},
    this.createdAt,
  });

  final String id;
  final String chatId;
  final String role;
  final String content;
  final String thought;
  final Map<String, dynamic> metadata;
  final DateTime? createdAt;

  factory TavernMessage.fromJson(Map<String, dynamic> json) {
    return TavernMessage(
      id: (json['id'] ?? '').toString(),
      chatId: (json['chatId'] ?? '').toString(),
      role: (json['role'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      thought: (json['thought'] ?? '').toString(),
      metadata: Map<String, dynamic>.from(
        (json['metadata'] as Map?) ?? const <String, dynamic>{},
      ),
      createdAt: _parseDate(json['createdAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chatId': chatId,
      'role': role,
      'content': content,
      if (thought.isNotEmpty) 'thought': thought,
      if (metadata.isNotEmpty) 'metadata': metadata,
      if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    };
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
    this.frequencyPenalty = 0,
    this.presencePenalty = 0,
    this.maxTokens = 0,
    this.contextLength = 0,
    this.stopSequences = const <String>[],
    this.topK = 0,
    this.topA = 0,
    this.minP = 0,
    this.typicalP = 1,
    this.repetitionPenalty = 1,
    this.createdAt,
    this.updatedAt,
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
  final double frequencyPenalty;
  final double presencePenalty;
  final int maxTokens;
  final int contextLength;
  final List<String> stopSequences;
  final int topK;
  final double topA;
  final double minP;
  final double typicalP;
  final double repetitionPenalty;
  final DateTime? createdAt;
  final DateTime? updatedAt;

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
      storyStringPosition:
          (json['storyStringPosition'] ?? 'in_prompt').toString(),
      storyStringDepth: (json['storyStringDepth'] as num?)?.toInt() ?? 1,
      storyStringRole: (json['storyStringRole'] ?? 'system').toString(),
      temperature: (json['temperature'] as num?)?.toDouble() ?? 1,
      topP: (json['topP'] as num?)?.toDouble() ?? 1,
      frequencyPenalty: (json['frequencyPenalty'] as num?)?.toDouble() ?? 0,
      presencePenalty: (json['presencePenalty'] as num?)?.toDouble() ?? 0,
      maxTokens: (json['maxTokens'] as num?)?.toInt() ?? 0,
      contextLength: (json['contextLength'] as num?)?.toInt() ?? 0,
      stopSequences: ((json['stopSequences'] as List?) ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
      topK: (json['topK'] as num?)?.toInt() ?? 0,
      topA: (json['topA'] as num?)?.toDouble() ?? 0,
      minP: (json['minP'] as num?)?.toDouble() ?? 0,
      typicalP: (json['typicalP'] as num?)?.toDouble() ?? 1,
      repetitionPenalty: (json['repetitionPenalty'] as num?)?.toDouble() ?? 1,
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }

  TavernPreset copyWith({
    String? name,
    String? provider,
    String? model,
    String? promptOrderId,
    String? storyString,
    String? chatStart,
    String? exampleSeparator,
    String? storyStringPosition,
    int? storyStringDepth,
    String? storyStringRole,
    double? temperature,
    double? topP,
    double? frequencyPenalty,
    double? presencePenalty,
    int? contextLength,
    int? topK,
    double? topA,
    double? minP,
    double? typicalP,
    double? repetitionPenalty,
    int? maxTokens,
    List<String>? stopSequences,
  }) {
    return TavernPreset(
      id: id,
      name: name ?? this.name,
      provider: provider ?? this.provider,
      model: model ?? this.model,
      promptOrderId: promptOrderId ?? this.promptOrderId,
      storyString: storyString ?? this.storyString,
      chatStart: chatStart ?? this.chatStart,
      exampleSeparator: exampleSeparator ?? this.exampleSeparator,
      storyStringPosition: storyStringPosition ?? this.storyStringPosition,
      storyStringDepth: storyStringDepth ?? this.storyStringDepth,
      storyStringRole: storyStringRole ?? this.storyStringRole,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      maxTokens: maxTokens ?? this.maxTokens,
      contextLength: contextLength ?? this.contextLength,
      stopSequences: stopSequences ?? this.stopSequences,
      topK: topK ?? this.topK,
      topA: topA ?? this.topA,
      minP: minP ?? this.minP,
      typicalP: typicalP ?? this.typicalP,
      repetitionPenalty: repetitionPenalty ?? this.repetitionPenalty,
      createdAt: createdAt,
      updatedAt: updatedAt,
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
    this.items = const <TavernPromptOrderItem>[],
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final List<TavernPromptOrderItem> items;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory TavernPromptOrder.fromJson(Map<String, dynamic> json) {
    return TavernPromptOrder(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      items: (((json['items'] as List?) ?? const <dynamic>[]).whereType<Map>())
          .map(
            (item) =>
                TavernPromptOrderItem.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false),
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }
}

class TavernPromptOrderItem {
  const TavernPromptOrderItem({
    this.identifier = '',
    this.blockId = '',
    this.name = '',
    this.role = 'system',
    this.content = '',
    this.enabled = true,
    this.orderIndex = 0,
    this.position = 'after_system',
    this.depth,
    this.builtIn = false,
  });

  final String identifier;
  final String blockId;
  final String name;
  final String role;
  final String content;
  final bool enabled;
  final int orderIndex;
  final String position;
  final int? depth;
  final bool builtIn;

  bool get isCustom => !builtIn && identifier.isEmpty;

  factory TavernPromptOrderItem.fromJson(Map<String, dynamic> json) {
    final identifier = (json['identifier'] ?? '').toString();
    final builtIn = json['builtIn'] == true || identifier.isNotEmpty;
    return TavernPromptOrderItem(
      identifier: identifier,
      blockId: (json['block_id'] ?? json['blockId'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      role: (json['role'] ?? 'system').toString(),
      content: (json['content'] ?? '').toString(),
      enabled: json['enabled'] != false,
      orderIndex:
          (json['order_index'] as num?)?.toInt() ??
          (json['orderIndex'] as num?)?.toInt() ??
          0,
      position: (json['position'] ?? 'after_system').toString(),
      depth: (json['depth'] as num?)?.toInt(),
      builtIn: builtIn,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (identifier.isNotEmpty) 'identifier': identifier,
      if (blockId.isNotEmpty) 'block_id': blockId,
      if (name.isNotEmpty) 'name': name,
      if (role.isNotEmpty) 'role': role,
      if (content.isNotEmpty) 'content': content,
      if (!builtIn) 'builtIn': false,
      'enabled': enabled,
      'order_index': orderIndex,
      'position': position,
      if (depth != null) 'depth': depth,
    };
  }

  TavernPromptOrderItem copyWith({
    String? identifier,
    String? blockId,
    String? name,
    String? role,
    String? content,
    bool? enabled,
    int? orderIndex,
    String? position,
    int? depth,
    bool? builtIn,
    bool clearDepth = false,
  }) {
    return TavernPromptOrderItem(
      identifier: identifier ?? this.identifier,
      blockId: blockId ?? this.blockId,
      name: name ?? this.name,
      role: role ?? this.role,
      content: content ?? this.content,
      enabled: enabled ?? this.enabled,
      orderIndex: orderIndex ?? this.orderIndex,
      position: position ?? this.position,
      depth: clearDepth ? null : (depth ?? this.depth),
      builtIn: builtIn ?? this.builtIn,
    );
  }
}

class TavernPromptBlock {
  const TavernPromptBlock({
    required this.id,
    required this.name,
    this.enabled = true,
    this.content = '',
    this.kind = 'custom',
    this.injectionMode = 'position',
    this.depth,
    this.roleScope = 'global',
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final bool enabled;
  final String content;
  final String kind;
  final String injectionMode;
  final int? depth;
  final String roleScope;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory TavernPromptBlock.fromJson(Map<String, dynamic> json) {
    return TavernPromptBlock(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      enabled: json['enabled'] != false,
      content: (json['content'] ?? '').toString(),
      kind: (json['kind'] ?? 'custom').toString(),
      injectionMode: (json['injectionMode'] ?? 'position').toString(),
      depth: (json['depth'] as num?)?.toInt(),
      roleScope: (json['roleScope'] ?? 'global').toString(),
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
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
    this.contextUsage = const <String, dynamic>{},
    this.matchedWorldbookEntries = const <Map<String, dynamic>>[],
    this.rejectedWorldbookEntries = const <Map<String, dynamic>>[],
    this.characterLoreBindings = const <Map<String, dynamic>>[],
    this.depthInserts = const <Map<String, dynamic>>[],
    this.macroEffects = const <Map<String, dynamic>>[],
    this.unknownMacros = const <String>[],
    this.resolvedPersona = const <String, dynamic>{},
    this.summary = const <String, dynamic>{},
  });

  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> blocks;
  final String presetId;
  final String promptOrderId;
  final String renderedStoryString;
  final String renderedExamples;
  final Map<String, dynamic> runtimeContext;
  final Map<String, dynamic> contextUsage;
  final List<Map<String, dynamic>> matchedWorldbookEntries;
  final List<Map<String, dynamic>> rejectedWorldbookEntries;
  final List<Map<String, dynamic>> characterLoreBindings;
  final List<Map<String, dynamic>> depthInserts;
  final List<Map<String, dynamic>> macroEffects;
  final List<String> unknownMacros;
  final Map<String, dynamic> resolvedPersona;
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
      contextUsage: Map<String, dynamic>.from(
        (json['contextUsage'] as Map?) ?? const <String, dynamic>{},
      ),
      matchedWorldbookEntries: parseMapList('matchedWorldbookEntries'),
      rejectedWorldbookEntries: parseMapList('rejectedWorldbookEntries'),
      characterLoreBindings: parseMapList('characterLoreBindings'),
      depthInserts: parseMapList('depthInserts'),
      macroEffects: parseMapList('macroEffects'),
      unknownMacros: ((json['unknownMacros'] as List?) ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
      resolvedPersona: Map<String, dynamic>.from(
        (json['resolvedPersona'] as Map?) ?? const <String, dynamic>{},
      ),
      summary: Map<String, dynamic>.from(
        (json['summary'] as Map?) ?? const <String, dynamic>{},
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'messages': messages,
      'blocks': blocks,
      'presetId': presetId,
      'promptOrderId': promptOrderId,
      'renderedStoryString': renderedStoryString,
      'renderedExamples': renderedExamples,
      'runtimeContext': runtimeContext,
      'contextUsage': contextUsage,
      'matchedWorldbookEntries': matchedWorldbookEntries,
      'rejectedWorldbookEntries': rejectedWorldbookEntries,
      'characterLoreBindings': characterLoreBindings,
      'depthInserts': depthInserts,
      'macroEffects': macroEffects,
      'unknownMacros': unknownMacros,
      'resolvedPersona': resolvedPersona,
      'summary': summary,
    };
  }
}

class TavernPersona {
  const TavernPersona({
    required this.id,
    required this.name,
    this.description = '',
    this.metadata = const <String, dynamic>{},
    this.isDefault = false,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final Map<String, dynamic> metadata;
  final bool isDefault;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory TavernPersona.fromJson(Map<String, dynamic> json) {
    return TavernPersona(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      metadata: Map<String, dynamic>.from(
        (json['metadata'] as Map?) ?? const <String, dynamic>{},
      ),
      isDefault: json['isDefault'] == true,
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'metadata': metadata,
      'isDefault': isDefault,
      if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    };
  }
}

class TavernWorldBook {
  const TavernWorldBook({
    required this.id,
    required this.name,
    this.description = '',
    this.scope = 'local',
    this.enabled = true,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final String scope;
  final bool enabled;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isGlobal => scope == 'global';

  factory TavernWorldBook.fromJson(Map<String, dynamic> json) {
    return TavernWorldBook(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      scope: (json['scope'] ?? 'local').toString(),
      enabled: json['enabled'] != false,
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }
}

class TavernWorldBookEntry {
  const TavernWorldBookEntry({
    required this.id,
    required this.worldbookId,
    this.keys = const <String>[],
    this.secondaryKeys = const <String>[],
    this.content = '',
    this.enabled = true,
    this.priority = 0,
    this.recursive = false,
    this.constant = false,
    this.preventRecursion = false,
    this.secondaryLogic = 'and_any',
    this.scanDepth = 0,
    this.caseSensitive = false,
    this.matchWholeWords = false,
    this.matchCharacterDescription = false,
    this.matchCharacterPersonality = false,
    this.matchScenario = false,
    this.useGroupScoring = false,
    this.groupWeight = 100,
    this.groupOverride = false,
    this.delayUntilRecursion = 0,
    this.probability = 100,
    this.ignoreBudget = false,
    this.characterFilterNames = const <String>[],
    this.characterFilterTags = const <String>[],
    this.characterFilterExclude = false,
    this.sticky = 0,
    this.cooldown = 0,
    this.delay = 0,
    this.insertionPosition = 'before_chat_history',
    this.groupName = '',
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String worldbookId;
  final List<String> keys;
  final List<String> secondaryKeys;
  final String content;
  final bool enabled;
  final int priority;
  final bool recursive;
  final bool constant;
  final bool preventRecursion;
  final String secondaryLogic;
  final int scanDepth;
  final bool caseSensitive;
  final bool matchWholeWords;
  final bool matchCharacterDescription;
  final bool matchCharacterPersonality;
  final bool matchScenario;
  final bool useGroupScoring;
  final int groupWeight;
  final bool groupOverride;
  final int delayUntilRecursion;
  final int probability;
  final bool ignoreBudget;
  final List<String> characterFilterNames;
  final List<String> characterFilterTags;
  final bool characterFilterExclude;
  final int sticky;
  final int cooldown;
  final int delay;
  final String insertionPosition;
  final String groupName;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory TavernWorldBookEntry.fromJson(Map<String, dynamic> json) {
    return TavernWorldBookEntry(
      id: (json['id'] ?? '').toString(),
      worldbookId: (json['worldbookId'] ?? '').toString(),
      keys: ((json['keys'] as List?) ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
      secondaryKeys: ((json['secondaryKeys'] as List?) ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
      content: (json['content'] ?? '').toString(),
      enabled: json['enabled'] != false,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      recursive: json['recursive'] == true,
      constant: json['constant'] == true,
      preventRecursion: json['preventRecursion'] == true,
      secondaryLogic: (json['secondaryLogic'] ?? 'and_any').toString(),
      scanDepth: (json['scanDepth'] as num?)?.toInt() ?? 0,
      caseSensitive: json['caseSensitive'] == true,
      matchWholeWords: json['matchWholeWords'] == true,
      matchCharacterDescription: json['matchCharacterDescription'] == true,
      matchCharacterPersonality: json['matchCharacterPersonality'] == true,
      matchScenario: json['matchScenario'] == true,
      useGroupScoring: json['useGroupScoring'] == true,
      groupWeight: (json['groupWeight'] as num?)?.toInt() ?? 100,
      groupOverride: json['groupOverride'] == true,
      delayUntilRecursion: (json['delayUntilRecursion'] as num?)?.toInt() ?? 0,
      probability: (json['probability'] as num?)?.toInt() ?? 100,
      ignoreBudget: json['ignoreBudget'] == true,
      characterFilterNames: ((json['characterFilterNames'] as List?) ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
      characterFilterTags: ((json['characterFilterTags'] as List?) ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
      characterFilterExclude: json['characterFilterExclude'] == true,
      sticky: (json['sticky'] as num?)?.toInt() ?? 0,
      cooldown: (json['cooldown'] as num?)?.toInt() ?? 0,
      delay: (json['delay'] as num?)?.toInt() ?? 0,
      insertionPosition:
          (json['insertionPosition'] ?? 'before_chat_history').toString(),
      groupName: (json['groupName'] ?? '').toString(),
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
