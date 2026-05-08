import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/repositories/tavern_repository.dart';
import '../data/tavern_chat_cache_store.dart';
import '../domain/tavern_models.dart';

class TavernStore extends ChangeNotifier {
  TavernStore({TavernRepository? repository, TavernChatCacheStore? cacheStore})
    : _repository = repository ?? TavernRepository(),
      _cacheStore = cacheStore ?? TavernChatCacheStore.instance;

  final TavernRepository _repository;
  final TavernChatCacheStore _cacheStore;

  bool _isLoading = false;
  String? _error;
  List<TavernCharacter> _characters = const <TavernCharacter>[];
  List<TavernChat> _recentChats = const <TavernChat>[];
  List<TavernWorldBook> _worldBooks = const <TavernWorldBook>[];
  List<TavernPreset> _presets = const <TavernPreset>[];
  List<TavernProviderOption> _providers = const <TavernProviderOption>[];
  List<TavernPromptOrder> _promptOrders = const <TavernPromptOrder>[];
  List<TavernPromptBlock> _promptBlocks = const <TavernPromptBlock>[];
  List<TavernPersona> _personas = const <TavernPersona>[];
  Map<String, dynamic> _globalVariables = const <String, dynamic>{};
  final Map<String, Map<String, dynamic>> _chatVariables =
      <String, Map<String, dynamic>>{};
  final Map<String, List<TavernWorldBookEntry>> _worldBookEntries =
      <String, List<TavernWorldBookEntry>>{};
  String? _lastImportMessage;
  TavernCharacterImportResult? _lastImportResult;
  final Map<String, TavernChatCacheSnapshot> _chatSnapshots =
      <String, TavernChatCacheSnapshot>{};

  bool get isLoading => _isLoading;
  String? get error => _error;
  List<TavernCharacter> get characters => _characters;
  List<TavernChat> get recentChats => _recentChats;
  List<TavernWorldBook> get worldBooks => _worldBooks;
  List<TavernPreset> get presets => _presets;
  List<TavernProviderOption> get providers => _providers;
  List<TavernPromptOrder> get promptOrders => _promptOrders;
  List<TavernPromptBlock> get promptBlocks => _promptBlocks;
  List<TavernPersona> get personas => _personas;
  Map<String, dynamic> get globalVariables => _globalVariables;
  String? get lastImportMessage => _lastImportMessage;
  TavernCharacterImportResult? get lastImportResult => _lastImportResult;

  List<TavernWorldBookEntry> worldBookEntriesOf(String worldbookId) =>
      _worldBookEntries[worldbookId] ?? const <TavernWorldBookEntry>[];

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
        _repository.listPromptBlocks(),
        _repository.listPromptOrders(),
        _repository.getConfigOptions(),
      ]);
      _characters = results[0] as List<TavernCharacter>;
      _recentChats = results[1] as List<TavernChat>;
      _worldBooks = results[2] as List<TavernWorldBook>;
      _presets = results[3] as List<TavernPreset>;
      _promptBlocks = results[4] as List<TavernPromptBlock>;
      _promptOrders = results[5] as List<TavernPromptOrder>;
      final config = Map<String, dynamic>.from(results[6] as Map);
      _providers = (((config['providers'] as List?) ?? const <dynamic>[])
              .whereType<Map>())
          .map(
            (item) =>
                TavernProviderOption.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);
      _promptOrders = (((config['promptOrders'] as List?) ?? const <dynamic>[])
              .whereType<Map>())
          .map(
            (item) =>
                TavernPromptOrder.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);
      _promptBlocks = (((config['promptBlocks'] as List?) ?? const <dynamic>[])
              .whereType<Map>())
          .map(
            (item) =>
                TavernPromptBlock.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);
      _personas = (((config['personas'] as List?) ?? const <dynamic>[])
              .whereType<Map>())
          .map(
            (item) => TavernPersona.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);
      _globalVariables = Map<String, dynamic>.from(
        (config['globalVariables'] as Map?) ?? const <String, dynamic>{},
      );
    } catch (exc) {
      _error = exc.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadCharacters() => loadHome();

  Future<TavernCharacterImportResult> importCharacterFile({
    required String filename,
    required Uint8List bytes,
  }) async {
    final lower = filename.toLowerCase();
    _error = null;
    _lastImportMessage = null;
    _lastImportResult = null;
    notifyListeners();
    try {
      late final TavernCharacterImportResult result;
      if (lower.endsWith('.json')) {
        final payload = _repository.parseCharacterJsonText(
          utf8.decode(bytes),
        );
        result = await _repository.importCharacterJson(
          filename: filename,
          payload: payload,
        );
      } else if (lower.endsWith('.png')) {
        result = await _repository.importCharacterPng(
          filename: filename,
          bytes: bytes,
        );
      } else if (lower.endsWith('.charx')) {
        result = await _repository.importCharacterCharX(
          filename: filename,
          bytes: bytes,
        );
      } else {
        throw UnsupportedError('仅支持导入 .json / .png / .charx');
      }
      final character = result.character;
      _characters = [
        character,
        ..._characters.where((item) => item.id != character.id),
      ];
      _lastImportResult = result;
      _lastImportMessage = '已导入 ${character.name}';
      notifyListeners();
      return result;
    } catch (exc) {
      _error = exc.toString();
      notifyListeners();
      rethrow;
    }
  }

  void clearImportMessage() {
    if (_lastImportMessage == null && _lastImportResult == null) return;
    _lastImportMessage = null;
    _lastImportResult = null;
    notifyListeners();
  }

  Future<TavernCharacter> getCharacter(String characterId) {
    return _repository.getCharacter(characterId);
  }

  TavernChatCacheSnapshot? peekChatSnapshot(String chatId) {
    return _chatSnapshots[chatId];
  }

  Future<TavernChatCacheSnapshot?> loadCachedChatSnapshot(String chatId) async {
    final memory = _chatSnapshots[chatId];
    if (memory != null) return memory;
    final snapshot = await _cacheStore.loadChatSnapshot(chatId);
    if (snapshot != null) {
      _chatSnapshots[chatId] = snapshot;
    }
    return snapshot;
  }

  Future<void> saveChatSnapshot({
    required TavernChat chat,
    required TavernCharacter character,
    required List<TavernMessage> messages,
    TavernPromptDebug? promptDebug,
  }) async {
    final snapshot = TavernChatCacheSnapshot(
      messages: List<TavernMessage>.unmodifiable(messages),
      chat: chat,
      character: character,
      promptDebug: promptDebug,
      cachedAt: DateTime.now(),
    );
    _chatSnapshots[chat.id] = snapshot;
    await _cacheStore.saveChatSnapshot(
      chat: chat,
      character: character,
      messages: messages,
      promptDebug: promptDebug,
    );
  }

  Future<void> deleteCharacter(String characterId) async {
    await _repository.deleteCharacter(characterId);
    _characters = _characters.where((item) => item.id != characterId).toList(growable: false);
    _recentChats = _recentChats
        .where((item) => item.characterId != characterId)
        .toList(growable: false);
    notifyListeners();
  }

  Future<TavernChat> getChat(String chatId) {
    return _repository.getChat(chatId);
  }

  Future<TavernChat> updateChat({
    required String chatId,
    required Map<String, dynamic> payload,
  }) async {
    final updated = await _repository.updateChat(
      chatId: chatId,
      payload: payload,
    );
    _recentChats = [
      updated,
      ..._recentChats.where((item) => item.id != updated.id),
    ];
    final snapshot = _chatSnapshots[chatId];
    if (snapshot != null && snapshot.character != null) {
      unawaited(
        saveChatSnapshot(
          chat: updated,
          character: snapshot.character!,
          messages: snapshot.messages,
        ),
      );
    }
    notifyListeners();
    return updated;
  }

  Future<List<TavernMessage>> listChatMessages(String chatId) {
    return _repository.listChatMessages(chatId);
  }

  Future<void> deleteChat(String chatId) async {
    await _repository.deleteChat(chatId);
    _recentChats = _recentChats.where((item) => item.id != chatId).toList(growable: false);
    _chatSnapshots.remove(chatId);
    unawaited(_cacheStore.deleteChatSnapshot(chatId));
    notifyListeners();
  }

  Future<Map<String, dynamic>> sendMessage({
    required String chatId,
    required String text,
    String presetId = '',
    String instructionMode = '',
    String hiddenInstruction = '',
    bool suppressUserMessage = false,
  }) {
    return _repository.sendMessage(
      chatId: chatId,
      text: text,
      presetId: presetId,
      instructionMode: instructionMode,
      hiddenInstruction: hiddenInstruction,
      suppressUserMessage: suppressUserMessage,
    );
  }

  Future<void> streamMessage({
    required String chatId,
    required String text,
    String presetId = '',
    String instructionMode = '',
    String hiddenInstruction = '',
    bool suppressUserMessage = false,
    required TavernStreamEventHandler onEvent,
  }) {
    return _repository.streamMessage(
      chatId: chatId,
      text: text,
      presetId: presetId,
      instructionMode: instructionMode,
      hiddenInstruction: hiddenInstruction,
      suppressUserMessage: suppressUserMessage,
      onEvent: onEvent,
    );
  }

  Future<TavernPromptDebug> getPromptDebug(String chatId) {
    return _repository.getPromptDebug(chatId);
  }

  Future<TavernPreset> createPreset(Map<String, dynamic> payload) async {
    final created = await _repository.createPreset(payload);
    _presets = [created, ..._presets.where((item) => item.id != created.id)];
    notifyListeners();
    return created;
  }

  Future<TavernPreset> updatePreset({
    required String presetId,
    required Map<String, dynamic> payload,
  }) async {
    final updated = await _repository.updatePreset(
      presetId: presetId,
      payload: payload,
    );
    _presets = [updated, ..._presets.where((item) => item.id != updated.id)];
    notifyListeners();
    return updated;
  }

  Future<TavernPromptBlock> createPromptBlock(
    Map<String, dynamic> payload,
  ) async {
    final created = await _repository.createPromptBlock(payload);
    _promptBlocks = [
      created,
      ..._promptBlocks.where((item) => item.id != created.id),
    ];
    notifyListeners();
    return created;
  }

  Future<TavernPromptBlock> updatePromptBlock({
    required String blockId,
    required Map<String, dynamic> payload,
  }) async {
    final updated = await _repository.updatePromptBlock(
      blockId: blockId,
      payload: payload,
    );
    _promptBlocks = [
      updated,
      ..._promptBlocks.where((item) => item.id != updated.id),
    ];
    notifyListeners();
    return updated;
  }

  Future<void> deletePromptBlock(String blockId) async {
    await _repository.deletePromptBlock(blockId);
    _promptBlocks = _promptBlocks.where((item) => item.id != blockId).toList(growable: false);
    _promptOrders = _promptOrders
        .map(
          (order) => TavernPromptOrder(
            id: order.id,
            name: order.name,
            items: order.items
                .where((item) => item.blockId != blockId)
                .toList(growable: false),
            createdAt: order.createdAt,
            updatedAt: order.updatedAt,
          ),
        )
        .toList(growable: false);
    notifyListeners();
  }

  Future<TavernPromptOrder> createPromptOrder(
    Map<String, dynamic> payload,
  ) async {
    final created = await _repository.createPromptOrder(payload);
    _promptOrders = [
      created,
      ..._promptOrders.where((item) => item.id != created.id),
    ];
    notifyListeners();
    return created;
  }

  Future<TavernPromptOrder> updatePromptOrder({
    required String promptOrderId,
    required Map<String, dynamic> payload,
  }) async {
    final updated = await _repository.updatePromptOrder(
      promptOrderId: promptOrderId,
      payload: payload,
    );
    _promptOrders = [
      updated,
      ..._promptOrders.where((item) => item.id != updated.id),
    ];
    notifyListeners();
    return updated;
  }

  Future<TavernWorldBook> createWorldBook(Map<String, dynamic> payload) async {
    final created = await _repository.createWorldBook(payload);
    _worldBooks = [
      created,
      ..._worldBooks.where((item) => item.id != created.id),
    ];
    notifyListeners();
    return created;
  }

  Future<TavernWorldBook> updateWorldBook({
    required String worldbookId,
    required Map<String, dynamic> payload,
  }) async {
    final updated = await _repository.updateWorldBook(
      worldbookId: worldbookId,
      payload: payload,
    );
    _worldBooks = [
      updated,
      ..._worldBooks.where((item) => item.id != updated.id),
    ];
    notifyListeners();
    return updated;
  }

  Future<void> deleteWorldBook(String worldbookId) async {
    await _repository.deleteWorldBook(worldbookId);
    _worldBooks = _worldBooks.where((item) => item.id != worldbookId).toList(growable: false);
    _worldBookEntries.remove(worldbookId);
    notifyListeners();
  }

  Future<List<TavernWorldBookEntry>> loadWorldBookEntries(
    String worldbookId,
  ) async {
    final entries = await _repository.listWorldBookEntries(worldbookId);
    _worldBookEntries[worldbookId] = entries;
    notifyListeners();
    return entries;
  }

  Future<TavernWorldBookEntry> createWorldBookEntry({
    required String worldbookId,
    required Map<String, dynamic> payload,
  }) async {
    final created = await _repository.createWorldBookEntry(
      worldbookId: worldbookId,
      payload: payload,
    );
    final current =
        _worldBookEntries[worldbookId] ?? const <TavernWorldBookEntry>[];
    _worldBookEntries[worldbookId] = [
      created,
      ...current.where((item) => item.id != created.id),
    ];
    notifyListeners();
    return created;
  }

  Future<TavernWorldBookEntry> updateWorldBookEntry({
    required String worldbookId,
    required String entryId,
    required Map<String, dynamic> payload,
  }) async {
    final updated = await _repository.updateWorldBookEntry(
      worldbookId: worldbookId,
      entryId: entryId,
      payload: payload,
    );
    final current =
        _worldBookEntries[worldbookId] ?? const <TavernWorldBookEntry>[];
    _worldBookEntries[worldbookId] = [
      updated,
      ...current.where((item) => item.id != updated.id),
    ];
    notifyListeners();
    return updated;
  }

  Map<String, dynamic> chatVariablesOf(String chatId) =>
      _chatVariables[chatId] ?? const <String, dynamic>{};

  Future<List<TavernPersona>> loadPersonas() async {
    final personas = await _repository.listPersonas();
    _personas = personas;
    notifyListeners();
    return personas;
  }

  Future<TavernPersona> createPersona(Map<String, dynamic> payload) async {
    final created = await _repository.createPersona(payload);
    _personas = [created, ..._personas.where((item) => item.id != created.id)];
    notifyListeners();
    return created;
  }

  Future<TavernPersona> updatePersona({
    required String personaId,
    required Map<String, dynamic> payload,
  }) async {
    final updated = await _repository.updatePersona(
      personaId: personaId,
      payload: payload,
    );
    _personas = [updated, ..._personas.where((item) => item.id != updated.id)];
    notifyListeners();
    return updated;
  }

  Future<void> deletePersona(String personaId) async {
    await _repository.deletePersona(personaId);
    _personas = _personas.where((item) => item.id != personaId).toList(growable: false);
    _recentChats = _recentChats
        .map((chat) => chat.personaId == personaId
            ? TavernChat(
                id: chat.id,
                characterId: chat.characterId,
                title: chat.title,
                presetId: chat.presetId,
                authorNoteEnabled: chat.authorNoteEnabled,
                authorNote: chat.authorNote,
                authorNoteDepth: chat.authorNoteDepth,
                metadata: chat.metadata,
                createdAt: chat.createdAt,
                updatedAt: chat.updatedAt,
              )
            : chat)
        .toList(growable: false);
    notifyListeners();
  }

  Future<Map<String, dynamic>> loadGlobalVariables() async {
    final values = await _repository.getGlobalVariables();
    _globalVariables = values;
    notifyListeners();
    return values;
  }

  Future<Map<String, dynamic>> updateGlobalVariables(
    Map<String, dynamic> values,
  ) async {
    final updated = await _repository.updateGlobalVariables(values);
    _globalVariables = updated;
    notifyListeners();
    return updated;
  }

  Future<Map<String, dynamic>> loadChatVariables(String chatId) async {
    final values = await _repository.getChatVariables(chatId);
    _chatVariables[chatId] = values;
    notifyListeners();
    return values;
  }

  Future<Map<String, dynamic>> updateChatVariables({
    required String chatId,
    required Map<String, dynamic> values,
  }) async {
    final updated = await _repository.updateChatVariables(
      chatId: chatId,
      variables: values,
    );
    _chatVariables[chatId] = updated;
    final snapshot = _chatSnapshots[chatId];
    final cachedChat = snapshot?.chat;
    if (snapshot != null && cachedChat != null) {
      final updatedChat = TavernChat(
        id: cachedChat.id,
        characterId: cachedChat.characterId,
        title: cachedChat.title,
        presetId: cachedChat.presetId,
        personaId: cachedChat.personaId,
        authorNoteEnabled: cachedChat.authorNoteEnabled,
        authorNote: cachedChat.authorNote,
        authorNoteDepth: cachedChat.authorNoteDepth,
        metadata: {
          ...cachedChat.metadata,
          'variables': updated,
        },
        createdAt: cachedChat.createdAt,
        updatedAt: cachedChat.updatedAt,
      );
      _chatSnapshots[chatId] = TavernChatCacheSnapshot(
        messages: snapshot.messages,
        chat: updatedChat,
        character: snapshot.character,
        promptDebug: snapshot.promptDebug,
        cachedAt: snapshot.cachedAt,
      );
    }
    notifyListeners();
    return updated;
  }

  Future<TavernChat> createChatForCharacter(
    TavernCharacter character, {
    String personaId = '',
  }) async {
    final chat = await _repository.createChat(
      characterId: character.id,
      personaId: personaId,
    );
    _recentChats = [chat, ..._recentChats.where((item) => item.id != chat.id)];
    notifyListeners();
    return chat;
  }
}
