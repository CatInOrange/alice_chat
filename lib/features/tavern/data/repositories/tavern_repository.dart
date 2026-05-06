import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/openclaw/openclaw_http_client.dart';
import '../../../../core/openclaw/openclaw_settings.dart';
import '../../domain/tavern_models.dart';

typedef TavernStreamEventHandler =
    void Function(String event, Map<String, dynamic> data);

class TavernRepository {
  Future<List<TavernCharacter>> listCharacters() async {
    final response = await _getJson('/api/tavern/characters');
    final list = (response['characters'] as List?) ?? const <dynamic>[];
    return list
        .whereType<Map>()
        .map(
          (item) => TavernCharacter.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
  }

  Future<TavernCharacter> importCharacterJson({
    required String filename,
    required Map<String, dynamic> payload,
  }) async {
    final response = await _postJson('/api/tavern/characters/import-json', {
      'filename': filename,
      'content': payload,
    });
    return TavernCharacter.fromJson(
      Map<String, dynamic>.from(response['character'] as Map),
    );
  }

  Future<TavernCharacter> importCharacterPng({
    required String filename,
    required Uint8List bytes,
  }) async {
    final response = await _postJson('/api/tavern/characters/import-png', {
      'filename': filename,
      'content': base64Encode(bytes),
    });
    return TavernCharacter.fromJson(
      Map<String, dynamic>.from(response['character'] as Map),
    );
  }

  Future<TavernCharacter> importCharacterCharX({
    required String filename,
    required Uint8List bytes,
  }) async {
    final response = await _postJson('/api/tavern/characters/import-charx', {
      'filename': filename,
      'content': base64Encode(bytes),
    });
    return TavernCharacter.fromJson(
      Map<String, dynamic>.from(response['character'] as Map),
    );
  }

  Future<List<TavernChat>> listChats() async {
    final response = await _getJson('/api/tavern/chats');
    final list = (response['chats'] as List?) ?? const <dynamic>[];
    return list
        .whereType<Map>()
        .map((item) => TavernChat.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<TavernChat> createChat({
    required String characterId,
    String presetId = '',
  }) async {
    final response = await _postJson('/api/tavern/chats', {
      'characterId': characterId,
      if (presetId.isNotEmpty) 'presetId': presetId,
    });
    return TavernChat.fromJson(
      Map<String, dynamic>.from(response['chat'] as Map),
    );
  }

  Future<TavernCharacter> getCharacter(String characterId) async {
    final response = await _getJson('/api/tavern/characters/$characterId');
    return TavernCharacter.fromJson(
      Map<String, dynamic>.from(response['character'] as Map),
    );
  }

  Future<void> deleteCharacter(String characterId) async {
    await _postJson('/api/tavern/characters/$characterId/delete', const {});
  }

  Future<TavernChat> getChat(String chatId) async {
    final response = await _getJson('/api/tavern/chats/$chatId');
    return TavernChat.fromJson(
      Map<String, dynamic>.from(response['chat'] as Map),
    );
  }

  Future<TavernChat> updateChat({
    required String chatId,
    required Map<String, dynamic> payload,
  }) async {
    final config = await OpenClawSettingsStore.load();
    final client = OpenClawHttpClient(config);
    final response = await client.putJson('/api/tavern/chats/$chatId', payload);
    return TavernChat.fromJson(
      Map<String, dynamic>.from(response['chat'] as Map),
    );
  }

  Future<void> deleteChat(String chatId) async {
    await _postJson('/api/tavern/chats/$chatId/delete', const {});
  }

  Future<List<TavernMessage>> listChatMessages(String chatId) async {
    final response = await _getJson('/api/tavern/chats/$chatId/messages');
    final list = (response['messages'] as List?) ?? const <dynamic>[];
    return list
        .whereType<Map>()
        .map((item) => TavernMessage.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> sendMessage({
    required String chatId,
    required String text,
    String presetId = '',
  }) {
    return _postJson('/api/tavern/chats/$chatId/send', {
      'text': text,
      if (presetId.isNotEmpty) 'presetId': presetId,
    });
  }

  Future<void> streamMessage({
    required String chatId,
    required String text,
    String presetId = '',
    required TavernStreamEventHandler onEvent,
  }) async {
    final config = await OpenClawSettingsStore.load();
    final client = OpenClawHttpClient(config);
    await client.streamJsonEvents(
      path: '/api/tavern/chats/$chatId/stream',
      body: {
        'text': text,
        if (presetId.isNotEmpty) 'presetId': presetId,
      },
      onEvent: onEvent,
    );
  }

  Future<List<TavernPreset>> listPresets() async {
    final response = await _getJson('/api/tavern/presets');
    final list = (response['presets'] as List?) ?? const <dynamic>[];
    return list
        .whereType<Map>()
        .map((item) => TavernPreset.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<List<TavernPromptBlock>> listPromptBlocks() async {
    final response = await _getJson('/api/tavern/prompt-blocks');
    final list = (response['promptBlocks'] as List?) ?? const <dynamic>[];
    return list
        .whereType<Map>()
        .map(
          (item) => TavernPromptBlock.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
  }

  Future<TavernPromptBlock> createPromptBlock(
    Map<String, dynamic> payload,
  ) async {
    final response = await _postJson('/api/tavern/prompt-blocks', payload);
    return TavernPromptBlock.fromJson(
      Map<String, dynamic>.from(response['promptBlock'] as Map),
    );
  }

  Future<TavernPromptBlock> updatePromptBlock({
    required String blockId,
    required Map<String, dynamic> payload,
  }) async {
    final config = await OpenClawSettingsStore.load();
    final client = OpenClawHttpClient(config);
    final response = await client.putJson(
      '/api/tavern/prompt-blocks/$blockId',
      payload,
    );
    return TavernPromptBlock.fromJson(
      Map<String, dynamic>.from(response['promptBlock'] as Map),
    );
  }

  Future<void> deletePromptBlock(String blockId) async {
    await _postJson('/api/tavern/prompt-blocks/$blockId/delete', const {});
  }

  Future<List<TavernPromptOrder>> listPromptOrders() async {
    final response = await _getJson('/api/tavern/prompt-orders');
    final list = (response['promptOrders'] as List?) ?? const <dynamic>[];
    return list
        .whereType<Map>()
        .map(
          (item) => TavernPromptOrder.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
  }

  Future<TavernPromptOrder> createPromptOrder(
    Map<String, dynamic> payload,
  ) async {
    final response = await _postJson('/api/tavern/prompt-orders', payload);
    return TavernPromptOrder.fromJson(
      Map<String, dynamic>.from(response['promptOrder'] as Map),
    );
  }

  Future<TavernPromptOrder> updatePromptOrder({
    required String promptOrderId,
    required Map<String, dynamic> payload,
  }) async {
    final config = await OpenClawSettingsStore.load();
    final client = OpenClawHttpClient(config);
    final response = await client.putJson(
      '/api/tavern/prompt-orders/$promptOrderId',
      payload,
    );
    return TavernPromptOrder.fromJson(
      Map<String, dynamic>.from(response['promptOrder'] as Map),
    );
  }

  Future<TavernPromptDebug> getPromptDebug(String chatId) async {
    final response = await _getJson('/api/tavern/chats/$chatId/prompt-debug');
    return TavernPromptDebug.fromJson(
      Map<String, dynamic>.from(response['debug'] as Map),
    );
  }

  Future<Map<String, dynamic>> getConfigOptions() {
    return _getJson('/api/tavern/config/options');
  }

  Future<TavernPreset> createPreset(Map<String, dynamic> payload) async {
    final response = await _postJson('/api/tavern/presets', payload);
    return TavernPreset.fromJson(
      Map<String, dynamic>.from(response['preset'] as Map),
    );
  }

  Future<TavernPreset> updatePreset({
    required String presetId,
    required Map<String, dynamic> payload,
  }) async {
    final config = await OpenClawSettingsStore.load();
    final client = OpenClawHttpClient(config);
    final response = await client.putJson(
      '/api/tavern/presets/$presetId',
      payload,
    );
    return TavernPreset.fromJson(
      Map<String, dynamic>.from(response['preset'] as Map),
    );
  }

  Future<List<TavernWorldBook>> listWorldBooks() async {
    final response = await _getJson('/api/tavern/worldbooks');
    final list = (response['worldbooks'] as List?) ?? const <dynamic>[];
    return list
        .whereType<Map>()
        .map(
          (item) => TavernWorldBook.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
  }

  Future<TavernWorldBook> createWorldBook(Map<String, dynamic> payload) async {
    final response = await _postJson('/api/tavern/worldbooks', payload);
    return TavernWorldBook.fromJson(
      Map<String, dynamic>.from(response['worldbook'] as Map),
    );
  }

  Future<TavernWorldBook> updateWorldBook({
    required String worldbookId,
    required Map<String, dynamic> payload,
  }) async {
    final config = await OpenClawSettingsStore.load();
    final client = OpenClawHttpClient(config);
    final response = await client.putJson(
      '/api/tavern/worldbooks/$worldbookId',
      payload,
    );
    return TavernWorldBook.fromJson(
      Map<String, dynamic>.from(response['worldbook'] as Map),
    );
  }

  Future<void> deleteWorldBook(String worldbookId) async {
    final config = await OpenClawSettingsStore.load();
    final client = OpenClawHttpClient(config);
    try {
      await client.deleteJson('/api/tavern/worldbooks/$worldbookId');
    } catch (_) {
      await _postJson('/api/tavern/worldbooks/$worldbookId/delete', const {});
    }
  }

  Future<List<TavernWorldBookEntry>> listWorldBookEntries(
    String worldbookId,
  ) async {
    final response = await _getJson(
      '/api/tavern/worldbooks/$worldbookId/entries',
    );
    final list = (response['entries'] as List?) ?? const <dynamic>[];
    return list
        .whereType<Map>()
        .map(
          (item) =>
              TavernWorldBookEntry.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
  }

  Future<TavernWorldBookEntry> createWorldBookEntry({
    required String worldbookId,
    required Map<String, dynamic> payload,
  }) async {
    final response = await _postJson(
      '/api/tavern/worldbooks/$worldbookId/entries',
      payload,
    );
    return TavernWorldBookEntry.fromJson(
      Map<String, dynamic>.from(response['entry'] as Map),
    );
  }

  Future<TavernWorldBookEntry> updateWorldBookEntry({
    required String worldbookId,
    required String entryId,
    required Map<String, dynamic> payload,
  }) async {
    final config = await OpenClawSettingsStore.load();
    final client = OpenClawHttpClient(config);
    final response = await client.putJson(
      '/api/tavern/worldbooks/$worldbookId/entries/$entryId',
      payload,
    );
    return TavernWorldBookEntry.fromJson(
      Map<String, dynamic>.from(response['entry'] as Map),
    );
  }

  Map<String, dynamic> parseCharacterJsonText(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('角色 JSON 必须是对象');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final config = await OpenClawSettingsStore.load();
    final client = OpenClawHttpClient(config);
    return client.getJson(path);
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final config = await OpenClawSettingsStore.load();
    final client = OpenClawHttpClient(config);
    return client.postJson(path, payload);
  }
}
