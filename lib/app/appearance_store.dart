import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AliceThemePreference {
  system,
  light,
  dark,
  autoNight;

  String get label {
    switch (this) {
      case AliceThemePreference.system:
        return '跟随系统';
      case AliceThemePreference.light:
        return '浅色';
      case AliceThemePreference.dark:
        return '深色';
      case AliceThemePreference.autoNight:
        return '自动夜间';
    }
  }
}

class AppearanceStore extends ChangeNotifier {
  static const _themePreferenceKey = 'alicechat.appearance.themePreference';
  static const _autoNightStartKey = 'alicechat.appearance.autoNightStart';
  static const _autoNightEndKey = 'alicechat.appearance.autoNightEnd';

  AliceThemePreference _themePreference = AliceThemePreference.system;
  TimeOfDay _autoNightStart = const TimeOfDay(hour: 22, minute: 0);
  TimeOfDay _autoNightEnd = const TimeOfDay(hour: 7, minute: 0);
  Timer? _autoNightTimer;
  bool _autoNightActive = false;
  bool _isLoaded = false;

  AliceThemePreference get themePreference => _themePreference;
  TimeOfDay get autoNightStart => _autoNightStart;
  TimeOfDay get autoNightEnd => _autoNightEnd;
  bool get autoNightActive => _autoNightActive;
  bool get isLoaded => _isLoaded;

  ThemeMode get themeMode {
    switch (_themePreference) {
      case AliceThemePreference.system:
        return ThemeMode.system;
      case AliceThemePreference.light:
        return ThemeMode.light;
      case AliceThemePreference.dark:
        return ThemeMode.dark;
      case AliceThemePreference.autoNight:
        return _autoNightActive ? ThemeMode.dark : ThemeMode.light;
    }
  }

  String get summary {
    if (_themePreference != AliceThemePreference.autoNight) {
      return _themePreference.label;
    }
    return '${_themePreference.label} · ${_formatTime(_autoNightStart)}-${_formatTime(_autoNightEnd)}';
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_themePreferenceKey);
    _themePreference = AliceThemePreference.values.firstWhere(
      (item) => item.name == raw,
      orElse: () => AliceThemePreference.system,
    );
    _autoNightStart = _parseTime(
      prefs.getString(_autoNightStartKey),
      const TimeOfDay(hour: 22, minute: 0),
    );
    _autoNightEnd = _parseTime(
      prefs.getString(_autoNightEndKey),
      const TimeOfDay(hour: 7, minute: 0),
    );
    _isLoaded = true;
    _refreshAutoNightState(scheduleNext: true);
    notifyListeners();
  }

  Future<void> setThemePreference(AliceThemePreference preference) async {
    if (_themePreference == preference) return;
    _themePreference = preference;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themePreferenceKey, preference.name);
    _refreshAutoNightState(scheduleNext: true);
    notifyListeners();
  }

  Future<void> setAutoNightRange({
    required TimeOfDay start,
    required TimeOfDay end,
  }) async {
    if (_autoNightStart == start && _autoNightEnd == end) return;
    _autoNightStart = start;
    _autoNightEnd = end;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_autoNightStartKey, _formatTime(start));
    await prefs.setString(_autoNightEndKey, _formatTime(end));
    _refreshAutoNightState(scheduleNext: true);
    notifyListeners();
  }

  void _refreshAutoNightState({required bool scheduleNext}) {
    _autoNightTimer?.cancel();
    _autoNightTimer = null;
    final nextActive = _isWithinAutoNight(DateTime.now());
    final changed = nextActive != _autoNightActive;
    _autoNightActive = nextActive;
    if (scheduleNext && _themePreference == AliceThemePreference.autoNight) {
      _autoNightTimer = Timer(_durationUntilNextBoundary(), () {
        _refreshAutoNightState(scheduleNext: true);
        notifyListeners();
      });
    }
    if (changed && !scheduleNext) {
      notifyListeners();
    }
  }

  bool _isWithinAutoNight(DateTime now) {
    final nowMinutes = now.hour * 60 + now.minute;
    final start = _minutes(_autoNightStart);
    final end = _minutes(_autoNightEnd);
    if (start == end) return true;
    if (start < end) {
      return nowMinutes >= start && nowMinutes < end;
    }
    return nowMinutes >= start || nowMinutes < end;
  }

  Duration _durationUntilNextBoundary() {
    final now = DateTime.now();
    DateTime nextFor(TimeOfDay time) {
      var next = DateTime(now.year, now.month, now.day, time.hour, time.minute);
      if (!next.isAfter(now)) {
        next = next.add(const Duration(days: 1));
      }
      return next;
    }

    final startNext = nextFor(_autoNightStart);
    final endNext = nextFor(_autoNightEnd);
    final next = startNext.isBefore(endNext) ? startNext : endNext;
    final duration = next.difference(now);
    if (duration.inSeconds <= 0) return const Duration(minutes: 1);
    return duration;
  }

  static int _minutes(TimeOfDay time) => time.hour * 60 + time.minute;

  static TimeOfDay _parseTime(String? raw, TimeOfDay fallback) {
    if (raw == null) return fallback;
    final parts = raw.split(':');
    if (parts.length != 2) return fallback;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return fallback;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return fallback;
    return TimeOfDay(hour: hour, minute: minute);
  }

  static String _formatTime(TimeOfDay time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
  }

  @override
  void dispose() {
    _autoNightTimer?.cancel();
    super.dispose();
  }
}
