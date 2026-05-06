import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/tavern_models.dart';

class TavernChatCacheSnapshot {
  const TavernChatCacheSnapshot({
    required this.messages,
    this.chat,
    this.character,
    this.cachedAt,
  });

  final List<TavernMessage> messages;
  final TavernChat? chat;
  final TavernCharacter? character;
  final DateTime? cachedAt;
}

class TavernChatCacheStore {
  TavernChatCacheStore._();

  static const String _dbName = 'alice_tavern_cache.db';
  static const int _dbVersion = 1;
  static const int maxMessagesPerChat = 200;

  static final TavernChatCacheStore instance = TavernChatCacheStore._();

  Database? _db;

  Future<Database> _database() async {
    final existing = _db;
    if (existing != null) return existing;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);
    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE tavern_chat_cache (
            chat_id TEXT PRIMARY KEY,
            chat_json TEXT,
            character_json TEXT,
            cached_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE tavern_message_cache (
            id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT,
            thought TEXT,
            metadata_json TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_tavern_message_cache_chat_created ON tavern_message_cache(chat_id, created_at, id)',
        );
      },
    );
    return _db!;
  }

  Future<TavernChatCacheSnapshot?> loadChatSnapshot(String chatId) async {
    try {
      final db = await _database();
      final chatRows = await db.query(
        'tavern_chat_cache',
        where: 'chat_id = ?',
        whereArgs: [chatId],
        limit: 1,
      );
      if (chatRows.isEmpty) return null;
      final chatRow = chatRows.first;
      final messageRows = await db.query(
        'tavern_message_cache',
        where: 'chat_id = ?',
        whereArgs: [chatId],
        orderBy: 'created_at ASC, id ASC',
      );
      final messages = messageRows.map(_messageFromRow).toList(growable: false);
      return TavernChatCacheSnapshot(
        messages: messages,
        chat: _decodeChat(chatRow['chat_json']),
        character: _decodeCharacter(chatRow['character_json']),
        cachedAt: _dateTimeOrNull(chatRow['cached_at']),
      );
    } catch (error, stackTrace) {
      debugPrint('[tavern.cache] loadChatSnapshot failed: $error\n$stackTrace');
      return null;
    }
  }

  Future<void> saveChatSnapshot({
    required TavernChat chat,
    required TavernCharacter character,
    required List<TavernMessage> messages,
  }) async {
    try {
      final db = await _database();
      final trimmed = _trimMessages(messages, maxMessagesPerChat);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      await db.transaction((txn) async {
        await txn.insert(
          'tavern_chat_cache',
          {
            'chat_id': chat.id,
            'chat_json': jsonEncode(chat.toJson()),
            'character_json': jsonEncode(character.toJson()),
            'cached_at': nowMs,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        await txn.delete(
          'tavern_message_cache',
          where: 'chat_id = ?',
          whereArgs: [chat.id],
        );

        final batch = txn.batch();
        for (final message in trimmed) {
          batch.insert(
            'tavern_message_cache',
            _messageRow(chat.id, message, nowMs),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      });
    } catch (error, stackTrace) {
      debugPrint('[tavern.cache] saveChatSnapshot failed: $error\n$stackTrace');
    }
  }

  Future<void> deleteChatSnapshot(String chatId) async {
    try {
      final db = await _database();
      await db.transaction((txn) async {
        await txn.delete(
          'tavern_chat_cache',
          where: 'chat_id = ?',
          whereArgs: [chatId],
        );
        await txn.delete(
          'tavern_message_cache',
          where: 'chat_id = ?',
          whereArgs: [chatId],
        );
      });
    } catch (error, stackTrace) {
      debugPrint('[tavern.cache] deleteChatSnapshot failed: $error\n$stackTrace');
    }
  }

  List<TavernMessage> _trimMessages(List<TavernMessage> messages, int maxCount) {
    if (messages.length <= maxCount) {
      return List<TavernMessage>.unmodifiable(messages);
    }
    return List<TavernMessage>.unmodifiable(
      messages.sublist(messages.length - maxCount),
    );
  }

  Map<String, Object?> _messageRow(String chatId, TavernMessage message, int nowMs) {
    final createdAt = message.createdAt?.millisecondsSinceEpoch ?? nowMs;
    return {
      'id': message.id,
      'chat_id': chatId,
      'role': message.role,
      'content': message.content,
      'thought': message.thought,
      'metadata_json': message.metadata.isEmpty ? null : jsonEncode(message.metadata),
      'created_at': createdAt,
      'updated_at': nowMs,
    };
  }

  TavernMessage _messageFromRow(Map<String, Object?> row) {
    return TavernMessage(
      id: (row['id'] ?? '').toString(),
      chatId: (row['chat_id'] ?? '').toString(),
      role: (row['role'] ?? '').toString(),
      content: (row['content'] ?? '').toString(),
      thought: (row['thought'] ?? '').toString(),
      metadata: _decodeMap(row['metadata_json']) ?? const <String, dynamic>{},
      createdAt: _dateTimeOrNull(row['created_at']),
    );
  }

  TavernChat? _decodeChat(Object? raw) {
    final map = _decodeMap(raw);
    return map == null ? null : TavernChat.fromJson(map);
  }

  TavernCharacter? _decodeCharacter(Object? raw) {
    final map = _decodeMap(raw);
    return map == null ? null : TavernCharacter.fromJson(map);
  }

  Map<String, dynamic>? _decodeMap(Object? raw) {
    if (raw == null) return null;
    try {
      if (raw is String && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {}
    return null;
  }

  DateTime? _dateTimeOrNull(Object? raw) {
    if (raw == null) return null;
    final ms = raw is int ? raw : int.tryParse(raw.toString());
    if (ms == null || ms <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
}
