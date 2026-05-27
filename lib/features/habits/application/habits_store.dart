import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/debug/native_debug_bridge.dart';
import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../domain/habits_models.dart';

class HabitsStore extends ChangeNotifier {
  OpenClawHttpClient? _client;
  late Future<void> _configReady;

  bool _loaded = false;
  bool _loading = false;
  String? _error;
  List<Habit> _habits = const [];

  bool get isLoaded => _loaded;
  bool get isLoading => _loading;
  String? get error => _error;
  List<Habit> get habits => _habits;
  List<Habit> get dailyHabits =>
      _habits.where((h) => h.isDaily).toList(growable: false);
  List<Habit> get weeklyHabits =>
      _habits.where((h) => h.isWeekly).toList(growable: false);

  HabitsStore() {
    _configReady = _reloadConfig();
  }

  Future<void> _reloadConfig() async {
    try {
      final settings = await OpenClawSettingsStore.load();
      _client = OpenClawHttpClient(settings);
    } catch (_) {}
  }

  Future<void> ensureLoaded() async {
    if (_loaded || _loading) return;
    _loading = true;
    notifyListeners();
    try {
      await _configReady;
      await _fetchHabits();
      _loaded = true;
      _error = null;
    } catch (e) {
      _error = '$e';
      await NativeDebugBridge.instance.log(
        'habits',
        'ensureLoaded failed error=$e',
        level: 'WARN',
      );
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> _fetchHabits() async {
    final client = _client;
    if (client == null) return;
    final payload = await client.getJson('/api/habits');
    final list =
        (payload['habits'] as List<dynamic>?)
            ?.map((j) => Habit.fromJson(j as Map<String, dynamic>))
            .toList() ??
        [];
    _habits = list;
  }

  Future<void> refreshFromRemote({bool force = false}) async {
    await _configReady;
    if (_client == null) return;
    if (!_loaded && !force) return;
    try {
      await _fetchHabits();
      _error = null;
      notifyListeners();
    } catch (e) {
      await NativeDebugBridge.instance.log(
        'habits',
        'refreshFromRemote failed error=$e',
        level: 'WARN',
      );
    }
  }

  Future<Habit?> createHabit(Map<String, dynamic> payload) async {
    await _configReady;
    final client = _client;
    if (client == null) return null;
    final result = await client.postJson('/api/habits', payload);
    final habitJson = result['habit'] as Map<String, dynamic>?;
    if (habitJson == null) return null;
    final habit = Habit.fromJson(habitJson);
    _habits = [..._habits, habit];
    notifyListeners();
    return habit;
  }

  Future<void> updateHabit(String habitId, Map<String, dynamic> payload) async {
    await _configReady;
    final client = _client;
    if (client == null) return;
    final result = await client.putJson('/api/habits/$habitId', payload);
    final habitJson = result['habit'] as Map<String, dynamic>?;
    if (habitJson == null) return;
    final habit = Habit.fromJson(habitJson);
    _habits = _habits.map((h) => h.id == habitId ? habit : h).toList();
    notifyListeners();
  }

  Future<void> deleteHabit(String habitId) async {
    await _configReady;
    final client = _client;
    if (client == null) return;
    await client.deleteJson('/api/habits/$habitId');
    _habits = _habits.where((h) => h.id != habitId).toList();
    notifyListeners();
  }

  Future<void> toggleHabit(String habitId) async {
    await _configReady;
    final client = _client;
    if (client == null) return;
    final result = await client.postJson('/api/habits/$habitId/toggle', {});
    final habitJson = result['habit'] as Map<String, dynamic>?;
    if (habitJson == null) return;
    final habit = Habit.fromJson(habitJson);
    _habits = _habits.map((h) => h.id == habitId ? habit : h).toList();
    notifyListeners();
  }

  Future<Habit?> completeHabitOnDate(String habitId, String date) async {
    return _setHabitInstanceStatus(habitId, date, action: 'complete');
  }

  Future<Habit?> reopenHabitOnDate(String habitId, String date) async {
    return _setHabitInstanceStatus(habitId, date, action: 'reopen');
  }

  Future<Habit?> _setHabitInstanceStatus(
    String habitId,
    String date, {
    required String action,
  }) async {
    await _configReady;
    final client = _client;
    if (client == null) return null;
    final result = await client.postJson(
      '/api/habits/$habitId/instances/$date/$action',
      {},
    );
    final habitJson = result['habit'] as Map<String, dynamic>?;
    if (habitJson == null) return null;
    final habit = Habit.fromJson(habitJson);
    _habits = _habits.map((h) => h.id == habitId ? habit : h).toList();
    notifyListeners();
    return habit;
  }
}
