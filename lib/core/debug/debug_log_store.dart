import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DebugLogEntry {
  const DebugLogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
  });

  final DateTime timestamp;
  final String level;
  final String tag;
  final String message;

  Map<String, dynamic> toJson() => {
    'ts': timestamp.toIso8601String(),
    'level': level,
    'tag': tag,
    'message': message,
  };

  factory DebugLogEntry.fromJson(Map<String, dynamic> json) {
    return DebugLogEntry(
      timestamp: DateTime.tryParse((json['ts'] ?? '').toString()) ?? DateTime.now(),
      level: (json['level'] ?? 'INFO').toString(),
      tag: (json['tag'] ?? 'app').toString(),
      message: (json['message'] ?? '').toString(),
    );
  }

  String formatLine() {
    final ts = timestamp.toLocal().toIso8601String().replaceFirst('T', ' ');
    return '[$ts] [$level] [$tag] $message';
  }
}

class DebugLogStore extends ChangeNotifier {
  DebugLogStore._();

  static final DebugLogStore instance = DebugLogStore._();
  static const _logsKey = 'alicechat.debug.logs';
  static const _maxEntries = 300;
  static const _maxMessageLength = 800;

  final List<DebugLogEntry> _entries = [];
  final StreamController<DebugLogEntry> _streamController =
      StreamController<DebugLogEntry>.broadcast();

  bool _loaded = false;

  List<DebugLogEntry> get entries => List.unmodifiable(_entries.reversed);
  Stream<DebugLogEntry> get stream => _streamController.stream;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_logsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _entries
          ..clear()
          ..addAll(
            decoded
                .whereType<Map>()
                .map((item) => DebugLogEntry.fromJson(Map<String, dynamic>.from(item))),
          );
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> log(
    String tag,
    String message, {
    String level = 'INFO',
  }) async {
    await ensureLoaded();
    final normalizedMessage = message.length > _maxMessageLength
        ? '${message.substring(0, _maxMessageLength)}…'
        : message;
    final entry = DebugLogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: normalizedMessage,
    );
    _entries.add(entry);
    while (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    _streamController.add(entry);
    notifyListeners();
    unawaited(_persist());
    debugPrint(entry.formatLine());
  }

  Future<void> importLines(Iterable<String> lines, {String fallbackTag = 'native'}) async {
    await ensureLoaded();
    var changed = false;
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final entry = DebugLogEntry(
        timestamp: DateTime.now(),
        level: 'INFO',
        tag: fallbackTag,
        message: line,
      );
      _entries.add(entry);
      changed = true;
    }
    while (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    if (!changed) return;
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> clear() async {
    await ensureLoaded();
    _entries.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_logsKey);
  }

  String exportText() {
    return _entries.map((e) => e.formatLine()).join('\n');
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode(_entries.map((e) => e.toJson()).toList());
    await prefs.setString(_logsKey, payload);
  }
}
