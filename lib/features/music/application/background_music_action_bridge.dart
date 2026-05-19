import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'music_store.dart';
import '../domain/music_action.dart';

class BackgroundMusicActionBridge {
  BackgroundMusicActionBridge._();

  static final BackgroundMusicActionBridge instance =
      BackgroundMusicActionBridge._();

  static const MethodChannel _channel = MethodChannel(
    'alicechat/background_music_events',
  );

  MusicStore? _store;
  bool _initialized = false;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> attach(MusicStore store) async {
    _store = store;
    if (!_supported) {
      return;
    }
    if (!_initialized) {
      _initialized = true;
      _channel.setMethodCallHandler(_handleMethodCall);
    }
    await _consumePendingActions();
  }

  void detach(MusicStore store) {
    if (identical(_store, store)) {
      _store = null;
    }
  }

  Future<void> _consumePendingActions() async {
    try {
      final rawItems = await _channel.invokeMethod<List<dynamic>>(
        'consumePendingMusicActions',
      );
      if (rawItems == null || rawItems.isEmpty) {
        return;
      }
      for (final raw in rawItems) {
        await _dispatchRawPayload(raw, source: 'pending');
      }
    } catch (_) {
      // Best effort only. The foreground service may simply not be running.
    }
  }

  Future<void> _dispatchRawPayload(
    Object? raw, {
    required String source,
  }) async {
    final store = _store;
    if (store == null || raw == null) {
      return;
    }
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is! Map) {
        return;
      }
      final payload = Map<String, dynamic>.from(
        decoded.cast<String, dynamic>(),
      );
      await store.handleBackgroundAction(
        MusicAction.fromMap(payload),
        source: source,
      );
    } catch (error) {
      store.debugBackgroundActionBridgeError(
        error.toString(),
        rawPayload: raw.toString(),
      );
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onMusicAction':
        await _dispatchRawPayload(call.arguments, source: 'live');
        return null;
      default:
        return null;
    }
  }
}
