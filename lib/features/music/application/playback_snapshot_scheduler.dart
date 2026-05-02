import 'dart:async';

import '../data/music_local_cache_store.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';

class MusicRemoteSnapshotPayload {
  const MusicRemoteSnapshotPayload({
    required this.currentTrack,
    required this.queue,
    required this.isPlaying,
    required this.position,
    required this.likedTracks,
    required this.recentPlaylists,
    required this.customPlaylists,
    required this.currentPlaylistId,
    required this.neteaseLikedPlaylistId,
    required this.neteaseLikedPlaylistEncryptedId,
    required this.localRevision,
  });

  final MusicTrack currentTrack;
  final List<PlaybackQueueItem> queue;
  final bool isPlaying;
  final Duration position;
  final List<MusicTrack> likedTracks;
  final List<MusicPlaylist> recentPlaylists;
  final List<CustomMusicPlaylist> customPlaylists;
  final String? currentPlaylistId;
  final String? neteaseLikedPlaylistId;
  final String? neteaseLikedPlaylistEncryptedId;
  final int localRevision;
}

class MusicSnapshotBundle {
  const MusicSnapshotBundle({
    required this.localSnapshot,
    required this.remoteSnapshot,
  });

  final MusicLocalCacheSnapshot localSnapshot;
  final MusicRemoteSnapshotPayload remoteSnapshot;
}

class PlaybackSnapshotScheduler {
  PlaybackSnapshotScheduler({
    required MusicSnapshotBundle Function() buildSnapshot,
    required Future<void> Function(MusicLocalCacheSnapshot snapshot) saveLocal,
    required Future<void> Function(MusicRemoteSnapshotPayload payload)
    saveRemote,
    this.localDebounce = const Duration(milliseconds: 180),
    this.remoteDebounce = const Duration(milliseconds: 1400),
  }) : _buildSnapshot = buildSnapshot,
       _saveLocal = saveLocal,
       _saveRemote = saveRemote;

  final MusicSnapshotBundle Function() _buildSnapshot;
  final Future<void> Function(MusicLocalCacheSnapshot snapshot) _saveLocal;
  final Future<void> Function(MusicRemoteSnapshotPayload payload) _saveRemote;
  final Duration localDebounce;
  final Duration remoteDebounce;

  Timer? _localTimer;
  Timer? _remoteTimer;
  bool _disposed = false;
  bool _remoteFlushRunning = false;
  bool _remoteFlushQueued = false;
  MusicSnapshotBundle? _pendingBundle;

  void markDirty({bool flushRemote = false}) {
    if (_disposed) return;
    _pendingBundle = _buildSnapshot();
    _scheduleLocal();
    if (flushRemote) {
      unawaited(flushNow());
      return;
    }
    _scheduleRemote();
  }

  Future<void> flushNow() async {
    if (_disposed) return;
    _pendingBundle = _buildSnapshot();
    _localTimer?.cancel();
    _remoteTimer?.cancel();
    await _flushLocal();
    await _flushRemote();
  }

  void dispose() {
    _disposed = true;
    _localTimer?.cancel();
    _remoteTimer?.cancel();
  }

  void _scheduleLocal() {
    _localTimer?.cancel();
    _localTimer = Timer(localDebounce, () {
      unawaited(_flushLocal());
    });
  }

  void _scheduleRemote() {
    _remoteTimer?.cancel();
    _remoteTimer = Timer(remoteDebounce, () {
      unawaited(_flushRemote());
    });
  }

  Future<void> _flushLocal() async {
    if (_disposed) return;
    final bundle = _pendingBundle;
    if (bundle == null) return;
    try {
      await _saveLocal(bundle.localSnapshot);
    } catch (_) {
      // best effort only; keep latest pending bundle for future attempts
    }
  }

  Future<void> _flushRemote() async {
    if (_disposed) return;
    final bundle = _pendingBundle;
    if (bundle == null) return;
    if (_remoteFlushRunning) {
      _remoteFlushQueued = true;
      return;
    }
    _remoteFlushRunning = true;
    try {
      do {
        _remoteFlushQueued = false;
        final latest = _pendingBundle;
        if (latest == null) {
          break;
        }
        await _saveRemote(latest.remoteSnapshot);
      } while (_remoteFlushQueued && !_disposed);
    } catch (_) {
      _remoteFlushQueued = true;
    } finally {
      _remoteFlushRunning = false;
      if (_remoteFlushQueued && !_disposed) {
        _scheduleRemote();
      }
    }
  }
}
