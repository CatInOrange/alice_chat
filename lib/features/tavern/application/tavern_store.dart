import 'package:flutter/foundation.dart';

import '../data/repositories/tavern_repository.dart';
import '../domain/tavern_models.dart';

class TavernStore extends ChangeNotifier {
  TavernStore({TavernRepository? repository})
    : _repository = repository ?? TavernRepository();

  final TavernRepository _repository;

  bool _isLoading = false;
  String? _error;
  List<TavernCharacter> _characters = const <TavernCharacter>[];
  List<TavernChat> _recentChats = const <TavernChat>[];
  List<TavernWorldBook> _worldBooks = const <TavernWorldBook>[];
  List<TavernPreset> _presets = const <TavernPreset>[];
  List<TavernProviderOption> _providers = const <TavernProviderOption>[];
  List<TavernPromptOrder> _promptOrders = const <TavernPromptOrder>[];
  String? _lastImportMessage;

  bool get isLoading => _isLoading;
  String? get error => _error;
  List<TavernCharacter> get characters => _characters;
  List<TavernChat> get recentChats => _recentChats;
  List<TavernWorldBook> get worldBooks => _worldBooks;
  List<TavernPreset> get presets => _presets;
  List<TavernProviderOption> get providers => _providers;
  List<TavernPromptOrder> get promptOrders => _promptOrders;
  String? get lastImportMessage => _lastImportMessage;

  Future<void> loadHome() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        _repository.listCharacters(),
        _repository.listChats(),
        _repository.listWorldBooks(),
        _repository.listPresets(),
        _repository.getConfigOptions(),
      ]);
      _characters = results[0] as List<TavernCharacter>;
      _recentChats = results[1] as List<TavernChat>;
      _worldBooks = results[2] as List<TavernWorldBook>;
      _presets = results[3] as List<TavernPreset>;
      final config = Map<String, dynamic>.from(results[4] as Map);
      _providers = (((config['providers'] as List?) ?? const <dynamic>[]).whereType<Map>())
          .map((item) => TavernProviderOption.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false);
      _promptOrders = (((config['promptOrders'] as List?) ?? const <dynamic>[]).whereType<Map>())
          .map((item) => TavernPromptOrder.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false);
    } catch (exc) {
      _error = exc.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadCharacters() => loadHome();

  Future<TavernCharacter> importCharacterFile({
    required String filename,
    required Uint8List bytes,
  }) async {
    final lower = filename.toLowerCase();
    _error = null;
    _lastImportMessage = null;
    notifyListeners();
    try {
      late final TavernCharacter character;
      if (lower.endsWith('.json')) {
        final payload = _repository.parseCharacterJsonText(String.fromCharCodes(bytes));
        character = await _repository.importCharacterJson(filename: filename, payload: payload);
      } else if (lower.endsWith('.png')) {
        character = await _repository.importCharacterPng(filename: filename, bytes: bytes);
      } else if (lower.endsWith('.charx')) {
        character = await _repository.importCharacterCharX(filename: filename, bytes: bytes);
      } else {
        throw UnsupportedError('仅支持导入 .json / .png / .charx');
      }
      _characters = [character, ..._characters.where((item) => item.id != character.id)];
      _lastImportMessage = '已导入 ${character.name}';
      notifyListeners();
      return character;
    } catch (exc) {
      _error = exc.toString();
      notifyListeners();
      rethrow;
    }
  }

  void clearImportMessage() {
    if (_lastImportMessage == null) return;
    _lastImportMessage = null;
    notifyListeners();
  }

  Future<TavernCharacter> getCharacter(String characterId) {
    return _repository.getCharacter(characterId);
  }

  Future<TavernChat> getChat(String chatId) {
    return _repository.getChat(chatId);
  }

  Future<List<TavernMessage>> listChatMessages(String chatId) {
    return _repository.listChatMessages(chatId);
  }

  Future<Map<String, dynamic>> sendMessage({
    required String chatId,
    required String text,
    String presetId = '',
  }) {
    return _repository.sendMessage(chatId: chatId, text: text, presetId: presetId);
  }

  Future<TavernPromptDebug> getPromptDebug(String chatId) {
    return _repository.getPromptDebug(chatId);
  }

  Future<TavernPreset> updatePreset({
    required String presetId,
    required Map<String, dynamic> payload,
  }) async {
    final updated = await _repository.updatePreset(presetId: presetId, payload: payload);
    _presets = [updated, ..._presets.where((item) => item.id != updated.id)];
    notifyListeners();
    return updated;
  }

  Future<TavernChat> createChatForCharacter(TavernCharacter character) async {
    final chat = await _repository.createChat(characterId: character.id);
    _recentChats = [chat, ..._recentChats.where((item) => item.id != chat.id)];
    notifyListeners();
    return chat;
  }
}
