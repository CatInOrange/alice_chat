import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/chat_session.dart';

class ChatCacheSnapshot {
  const ChatCacheSnapshot({
    required this.messages,
    this.backendSessionId,
    this.oldestMessageId,
    this.newestMessageId,
    this.lastEventSeq,
    this.hasMoreHistory,
    this.cachedAt,
  });

  final List<core.Message> messages;
  final String? backendSessionId;
  final String? oldestMessageId;
  final String? newestMessageId;
  final int? lastEventSeq;
  final bool? hasMoreHistory;
  final DateTime? cachedAt;
}

class ChatCacheStore {
  ChatCacheStore._();

  static const String _dbName = 'alice_chat_cache.db';
  static const int _dbVersion = 2;
  static const int maxMessagesPerSession = 100;

  static final ChatCacheStore instance = ChatCacheStore._();

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
        await _createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('DROP TABLE IF EXISTS chat_message_cache');
          await db.execute('DROP TABLE IF EXISTS chat_session_cache');
          await _createSchema(db);
        }
      },
    );
    return _db!;
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE chat_session_cache (
        session_key TEXT PRIMARY KEY,
        backend_session_id TEXT,
        title TEXT,
        subtitle TEXT,
        avatar_asset_path TEXT,
        oldest_message_id TEXT,
        newest_message_id TEXT,
        last_event_seq INTEGER,
        has_more_history INTEGER,
        cached_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE chat_message_cache (
        id TEXT PRIMARY KEY,
        session_key TEXT NOT NULL,
        backend_session_id TEXT,
        author_id TEXT NOT NULL,
        message_type TEXT NOT NULL,
        text TEXT,
        source TEXT,
        attachments_json TEXT,
        metadata_json TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_chat_message_cache_session_created ON chat_message_cache(session_key, created_at)',
    );
    await db.execute(
      'CREATE INDEX idx_chat_message_cache_backend_created ON chat_message_cache(backend_session_id, created_at)',
    );
  }

  Future<ChatCacheSnapshot?> loadSessionSnapshot(ChatSession session) async {
    try {
      final db = await _database();
      final sessionRows = await db.query(
        'chat_session_cache',
        where: 'session_key = ?',
        whereArgs: [session.id],
        limit: 1,
      );
      if (sessionRows.isEmpty) return null;
      final sessionRow = sessionRows.first;
      final messageRows = await db.query(
        'chat_message_cache',
        where: 'session_key = ?',
        whereArgs: [session.id],
        orderBy: 'created_at ASC, id ASC',
      );
      final messages = messageRows
          .map(_messageFromRow)
          .whereType<core.Message>()
          .toList(growable: false);
      return ChatCacheSnapshot(
        messages: messages,
        backendSessionId: _stringOrNull(sessionRow['backend_session_id']),
        oldestMessageId: _stringOrNull(sessionRow['oldest_message_id']),
        newestMessageId: _stringOrNull(sessionRow['newest_message_id']),
        lastEventSeq: _intOrNull(sessionRow['last_event_seq']),
        hasMoreHistory: _boolOrNull(sessionRow['has_more_history']),
        cachedAt: _dateTimeOrNull(sessionRow['cached_at']),
      );
    } catch (error, stackTrace) {
      debugPrint('[alicechat.cache] loadSessionSnapshot failed: $error\n$stackTrace');
      return null;
    }
  }

  Future<void> saveSessionSnapshot({
    required ChatSession session,
    required List<core.Message> messages,
    String? backendSessionId,
    String? oldestMessageId,
    String? newestMessageId,
    int? lastEventSeq,
    bool? hasMoreHistory,
  }) async {
    try {
      final db = await _database();
      final trimmed = _trimMessages(messages, maxMessagesPerSession);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      await db.transaction((txn) async {
        await txn.insert('chat_session_cache', {
          'session_key': session.id,
          'backend_session_id': backendSessionId,
          'title': session.title,
          'subtitle': session.subtitle,
          'avatar_asset_path': session.avatarAssetPath,
          'oldest_message_id': oldestMessageId ?? (trimmed.isNotEmpty ? trimmed.first.id : null),
          'newest_message_id': newestMessageId ?? (trimmed.isNotEmpty ? trimmed.last.id : null),
          'last_event_seq': lastEventSeq,
          'has_more_history': hasMoreHistory == null ? null : (hasMoreHistory ? 1 : 0),
          'cached_at': nowMs,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        await txn.delete(
          'chat_message_cache',
          where: 'session_key = ?',
          whereArgs: [session.id],
        );

        final batch = txn.batch();
        for (final message in trimmed) {
          batch.insert(
            'chat_message_cache',
            _messageRow(
              sessionKey: session.id,
              backendSessionId: backendSessionId,
              message: message,
              nowMs: nowMs,
            ),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      });
    } catch (error, stackTrace) {
      debugPrint('[alicechat.cache] saveSessionSnapshot failed: $error\n$stackTrace');
    }
  }

  List<core.Message> _trimMessages(List<core.Message> messages, int maxCount) {
    if (messages.length <= maxCount) {
      return List<core.Message>.unmodifiable(messages);
    }
    return List<core.Message>.unmodifiable(
      messages.sublist(messages.length - maxCount),
    );
  }

  Map<String, Object?> _messageRow({
    required String sessionKey,
    required String? backendSessionId,
    required core.Message message,
    required int nowMs,
  }) {
    final createdAt =
        message.createdAt?.millisecondsSinceEpoch ?? nowMs;
    final metadata = _cloneMap(message.metadata);
    final attachments = _attachmentsFromMessage(message);
    return {
      'id': message.id,
      'session_key': sessionKey,
      'backend_session_id': backendSessionId,
      'author_id': message.authorId,
      'message_type': message is core.ImageMessage ? 'image' : 'text',
      'text': _textFromMessage(message),
      'source': _preferredImageSource(message, attachments),
      'attachments_json': jsonEncode(attachments),
      'metadata_json': metadata == null ? null : jsonEncode(metadata),
      'created_at': createdAt,
      'updated_at': nowMs,
    };
  }

  core.Message? _messageFromRow(Map<String, Object?> row) {
    final id = (row['id'] ?? '').toString();
    final authorId = (row['author_id'] ?? '').toString();
    final type = (row['message_type'] ?? 'text').toString();
    final text = _stringOrNull(row['text']);
    final rawSource = _stringOrNull(row['source']);
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      _intOrNull(row['created_at']) ?? DateTime.now().millisecondsSinceEpoch,
    );
    final metadata = _decodeMap(row['metadata_json']);
    final attachments = _decodeList(row['attachments_json']);
    final source = _preferredCachedSource(rawSource, attachments);
    if (type == 'image' && source != null && source.trim().isNotEmpty) {
      final imageMetadata = <String, dynamic>{
        if (metadata != null) ...metadata,
        if (attachments.isNotEmpty) 'attachments': attachments,
      };
      return core.ImageMessage(
        id: id,
        authorId: authorId,
        createdAt: createdAt,
        source: source,
        text: text?.trim().isEmpty == true ? null : text,
        width: _doubleOrNull(_firstAttachmentValue(attachments, 'width')),
        height: _doubleOrNull(_firstAttachmentValue(attachments, 'height')),
        size: _intOrNull(_firstAttachmentValue(attachments, 'size')),
        metadata: imageMetadata.isEmpty ? null : imageMetadata,
      );
    }
    final textMetadata = <String, dynamic>{
      if (metadata != null) ...metadata,
      if (attachments.isNotEmpty) 'attachments': attachments,
    };
    return core.TextMessage(
      id: id,
      authorId: authorId,
      createdAt: createdAt,
      text: text ?? '',
      metadata: textMetadata.isEmpty ? null : textMetadata,
    );
  }

  String? _preferredImageSource(
    core.Message message,
    List<Map<String, dynamic>> attachments,
  ) {
    final attachmentUrl = _stringOrNull(_firstAttachmentValue(attachments, 'url'));
    if (attachmentUrl != null && attachmentUrl.trim().isNotEmpty) {
      return attachmentUrl;
    }
    if (message is core.ImageMessage) {
      return message.source;
    }
    return null;
  }

  String? _preferredCachedSource(
    String? rawSource,
    List<Map<String, dynamic>> attachments,
  ) {
    final attachmentUrl = _stringOrNull(_firstAttachmentValue(attachments, 'url'));
    if (attachmentUrl != null && attachmentUrl.trim().isNotEmpty) {
      return attachmentUrl;
    }
    return rawSource;
  }

  dynamic _firstAttachmentValue(List<Map<String, dynamic>> items, String key) {
    if (items.isEmpty) return null;
    return items.first[key];
  }

  List<Map<String, dynamic>> _attachmentsFromMessage(core.Message message) {
    final metadataAttachments = _attachmentsFromMetadata(message.metadata);
    if (metadataAttachments.isNotEmpty) return metadataAttachments;
    if (message is core.ImageMessage) {
      return [
        {
          'kind': 'image',
          'url': message.source,
          'width': message.width,
          'height': message.height,
          'size': message.size,
        },
      ];
    }
    return const [];
  }

  List<Map<String, dynamic>> _attachmentsFromMetadata(Map<String, dynamic>? metadata) {
    final raw = metadata?['attachments'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Map<String, dynamic>? _cloneMap(Map<String, dynamic>? value) {
    if (value == null) return null;
    return Map<String, dynamic>.from(value);
  }

  String? _textFromMessage(core.Message message) {
    if (message is core.TextMessage) return message.text;
    if (message is core.ImageMessage) return message.text;
    return null;
  }

  Map<String, dynamic>? _decodeMap(Object? raw) {
    final text = _stringOrNull(raw);
    if (text == null || text.isEmpty) return null;
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  }

  List<Map<String, dynamic>> _decodeList(Object? raw) {
    final text = _stringOrNull(raw);
    if (text == null || text.isEmpty) return const [];
    final decoded = jsonDecode(text);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  String? _stringOrNull(Object? value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) return null;
    return text;
  }

  int? _intOrNull(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}');
  }

  double? _doubleOrNull(Object? value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse('${value ?? ''}');
  }

  bool? _boolOrNull(Object? value) {
    if (value == null) return null;
    final number = _intOrNull(value);
    if (number != null) return number != 0;
    if (value is bool) return value;
    return null;
  }

  DateTime? _dateTimeOrNull(Object? value) {
    final millis = _intOrNull(value);
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }
}
