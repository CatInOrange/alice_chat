import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/debug/native_debug_bridge.dart';

class WebviewHostController extends ChangeNotifier {
  WebviewHostController({
    Duration disposeDelay = const Duration(minutes: 5),
  }) : _disposeDelay = disposeDelay;

  final Duration _disposeDelay;

  bool _mounted = true;
  int _seed = 0;
  Timer? _disposeTimer;
  DateTime? _inactiveAt;
  DateTime? _appBackgroundAt;
  bool _keepAliveRequested = false;

  bool get mountedView => _mounted;
  int get seed => _seed;
  bool get isActive => _keepAliveRequested;

  void disposeController() {
    _disposeTimer?.cancel();
    _disposeTimer = null;
  }

  void setKeepAliveRequested(bool value, {required String reason}) {
    if (_keepAliveRequested == value) {
      refreshRetention(reason: reason);
      return;
    }
    _keepAliveRequested = value;
    refreshRetention(reason: reason);
  }

  void onAppLifecycleChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appBackgroundAt = null;
      refreshRetention(reason: 'appResumed');
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _appBackgroundAt ??= DateTime.now();
      refreshRetention(reason: 'appBackground:$state');
    }
  }

  void refreshRetention({required String reason}) {
    if (_keepAliveRequested) {
      _disposeTimer?.cancel();
      _disposeTimer = null;
      _inactiveAt = null;
      if (!_mounted) {
        _mounted = true;
        _seed++;
        notifyListeners();
      }
      unawaited(
        NativeDebugBridge.instance.log(
          'webviewHost',
          'keepAlive reason=$reason seed=$_seed mounted=$_mounted active=$_keepAliveRequested',
        ),
      );
      return;
    }

    _inactiveAt ??= DateTime.now();
    final inactiveAt = _inactiveAt!;
    final now = DateTime.now();
    final backgroundAt = _appBackgroundAt;
    final elapsed =
        backgroundAt != null && backgroundAt.isBefore(inactiveAt)
            ? now.difference(backgroundAt)
            : now.difference(inactiveAt);

    if (elapsed >= _disposeDelay) {
      _dispose(reason: '$reason elapsed=${elapsed.inSeconds}s');
      return;
    }

    _disposeTimer?.cancel();
    final remaining = _disposeDelay - elapsed;
    _disposeTimer = Timer(remaining, () {
      _dispose(reason: 'timer elapsed=${remaining.inSeconds}s');
    });
    unawaited(
      NativeDebugBridge.instance.log(
        'webviewHost',
        'scheduleDispose reason=$reason remaining=${remaining.inSeconds}s mounted=$_mounted active=$_keepAliveRequested',
      ),
    );
  }

  void _dispose({required String reason}) {
    _disposeTimer?.cancel();
    _disposeTimer = null;
    if (!_mounted) return;
    _mounted = false;
    notifyListeners();
    unawaited(
      NativeDebugBridge.instance.log(
        'webviewHost',
        'disposed reason=$reason seed=$_seed',
      ),
    );
  }
}
