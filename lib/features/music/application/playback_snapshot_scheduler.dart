import 'dart:async';

import '../data/music_local_cache_store.dart';

class PlaybackSnapshotScheduler {
  PlaybackSnapshotScheduler({
    required MusicLocalCacheSnapshot Function() buildSnapshot,
    required Future<void> Function(MusicLocalCacheSnapshot snapshot) saveLocal,
    this.localDebounce = const Duration(milliseconds: 180),
  }) : _buildSnapshot = buildSnapshot,
       _saveLocal = saveLocal;

  final MusicLocalCacheSnapshot Function() _buildSnapshot;
  final Future<void> Function(MusicLocalCacheSnapshot snapshot) _saveLocal;
  final Duration localDebounce;

  Timer? _localTimer;
  bool _disposed = false;
  MusicLocalCacheSnapshot? _pendingSnapshot;

  void markDirty() {
    if (_disposed) return;
    _pendingSnapshot = _buildSnapshot();
    _scheduleLocal();
  }

  Future<void> flushNow() async {
    if (_disposed) return;
    _pendingSnapshot = _buildSnapshot();
    _localTimer?.cancel();
    await _flushLocal();
  }

  void dispose() {
    _disposed = true;
    _localTimer?.cancel();
  }

  void _scheduleLocal() {
    _localTimer?.cancel();
    _localTimer = Timer(localDebounce, () {
      unawaited(_flushLocal());
    });
  }

  Future<void> _flushLocal() async {
    if (_disposed) return;
    final snapshot = _pendingSnapshot;
    if (snapshot == null) return;
    try {
      await _saveLocal(snapshot);
    } catch (_) {
      // best effort only; keep latest pending snapshot for future attempts
    }
  }
}
