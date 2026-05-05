import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/openclaw/openclaw_http_client.dart';
import '../../../../core/openclaw/openclaw_settings.dart';
import '../../domain/tavern_models.dart';

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

  Future<TavernChat> getChat(String chatId) async {
    final response = await _getJson('/api/tavern/chats/$chatId');
    return TavernChat.fromJson(
      Map<String, dynamic>.from(response['chat'] as Map),
    );
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
