import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/openclaw/openclaw_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../data/mock_music_catalog.dart';
import '../data/music_repository.dart';
import '../data/music_repository_impl.dart';
import '../data/playback/just_audio_playback_adapter.dart';
import '../data/playback/playback_adapter.dart';
import '../data/playback/stub_playback_adapter.dart';
import '../data/sources/mock_music_source_provider.dart';
import '../data/sources/music_source_registry.dart';
import '../data/sources/music_source_resolver.dart';
import '../data/sources/music_source_resolver_impl.dart';
import '../data/sources/netease_music_source_provider.dart';
import '../domain/music_command.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';

class MusicStore extends ChangeNotifier {
  MusicStore({OpenClawClient? client})
      : _client =
            client ??
            OpenClawHttpClient(
              const OpenClawConfig(
                baseUrl: '',
                modelId: 'alicechat-default',
                providerId: 'alicechat-channel',
                agent: 'main',
                sessionName: 'alicechat',
                bridgeUrl:
                    'ws://127.0.0.1:18791?token=yuanzhe-7611681-668128-zheyuan-012345',
              ),
            ) {
    _resolver = MusicSourceResolverImpl(
      registry: MusicSourceRegistry(
        providers: [NeteaseMusicSourceProvider(), MockMusicSourceProvider()],
      ),
    );
    _playbackAdapter = _createPlaybackAdapter();
    _repository = MusicRepositoryImpl(client: _client, resolver: _resolver);
    _eventClient = _client;
    _currentTrack = MockMusicCatalog.featuredTrack;
    _duration = _currentTrack.duration;
    _queue = MockMusicCatalog.data.queue
        .map((item) => PlaybackQueueItem(track: item))
        .toList(growable: false);
    _configReady = reloadConfig();
  }

  final OpenClawClient _client;
  late OpenClawClient _eventClient;
  late final MusicSourceResolver _resolver;
  late PlaybackAdapter _playbackAdapter;
  late final MusicRepository _repository;
  late Future<void> _configReady;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  StreamSubscription<PlaybackAdapterState>? _playbackStateSub;

  bool _isReady = false;
  bool _isLoading = false;
  String? _error;
  bool _isPlaying = false;
  bool _isBuffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  late MusicTrack _currentTrack;
  List<PlaybackQueueItem> _queue = const [];
  final List<MusicTrack> _playbackHistory = <MusicTrack>[];
  List<MusicPlaylist> _playlists = MockMusicCatalog.playlists;
  List<MusicTrack> _recentTracks = MockMusicCatalog.recentTracks;
  List<MusicPlaylist> _recentPlaylists = MockMusicCatalog.recentPlaylists;
  bool _isSearching = false;
  String? _searchError;
  List<MusicTrack> _searchResults = const [];
  bool _isAdvancingQueue = false;

  bool get isReady => _isReady;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  Duration get position => _position;
  Duration get duration => _duration;
  MusicTrack get currentTrack => _currentTrack;
  List<PlaybackQueueItem> get queue => _queue;
  List<MusicPlaylist> get playlists => _playlists;
  List<MusicTrack> get recentTracks => _recentTracks;
  List<MusicPlaylist> get recentPlaylists => _recentPlaylists;
  bool get isSearching => _isSearching;
  String? get searchError => _searchError;
  List<MusicTrack> get searchResults => _searchResults;

  Future<void> reloadConfig() async {
    final config = await OpenClawSettingsStore.load();
    _eventClient = OpenClawHttpClient(config);
    await _eventsSub?.cancel();
    _eventsSub = null;
    _isReady = false;
    _error = null;
    await _playbackStateSub?.cancel();
    _playbackStateSub = null;
    await _playbackAdapter.dispose();
    _playbackAdapter = _createPlaybackAdapter();
    notifyListeners();
    _eventsSub = _eventClient.subscribeEvents().listen(
      _handleBackendEvent,
      onError: (Object error, StackTrace stackTrace) {
        _error = error.toString();
        notifyListeners();
      },
    );
  }

  Future<void> ensureReady() async {
    if (_isReady || _isLoading) return;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      await _configReady;
      await _playbackAdapter.initialize();
      await _playbackStateSub?.cancel();
      _playbackStateSub = _playbackAdapter.stateStream.listen(
        _handlePlaybackState,
      );
      final state = await _repository.loadMusicState();
      if (state.currentTrack != null) {
        _currentTrack = state.currentTrack!;
      }
      if (state.queue.isNotEmpty) {
        _queue = List<PlaybackQueueItem>.unmodifiable(state.queue);
      }
      if (state.playlists.isNotEmpty) {
        _playlists = List<MusicPlaylist>.unmodifiable(state.playlists);
      }
      if (state.recentTracks.isNotEmpty) {
        _recentTracks = List<MusicTrack>.unmodifiable(state.recentTracks);
      }
      try {
        final remotePlaylists = await _repository.loadUserPlaylists();
        if (remotePlaylists.isNotEmpty) {
          _playlists = List<MusicPlaylist>.unmodifiable(remotePlaylists);
        }
      } catch (_) {
        // ignore and keep fallback playlists
      }
      _isPlaying = state.isPlaying;
      _position = state.position;
      _duration = state.currentTrack?.duration ?? _currentTrack.duration;
      _isReady = true;
    } catch (error) {
      _error = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> selectTrack(MusicTrack track, {bool autoplay = true}) async {
    _currentTrack = track;
    _duration = track.duration;
    _isPlaying = autoplay;
    notifyListeners();
    if (autoplay) {
      await handleCommand(
        MusicCommand.play(
          queue: [PlaybackQueueItem(track: track)],
          source: MusicCommandSource.manual,
        ),
      );
    }
  }

  Future<void> playPlaylist(MusicPlaylist playlist) async {
    List<MusicTrack> tracks;
    try {
      tracks = await _repository.loadPlaylistTracks(playlist);
    } catch (_) {
      tracks = MockMusicCatalog.tracksForPlaylist(playlist.id);
    }
    if (tracks.isEmpty) {
      tracks = MockMusicCatalog.tracksForPlaylist(playlist.id);
    }
    if (tracks.isEmpty) return;
    _recentPlaylists = [
      playlist,
      ..._recentPlaylists.where((item) => item.id != playlist.id),
    ].take(6).toList(growable: false);
    await handleCommand(
      MusicCommand(
        type: MusicCommandType.replaceQueue,
        source: MusicCommandSource.manual,
        queue: tracks
            .map((track) => PlaybackQueueItem(track: track))
            .toList(growable: false),
      ),
    );
  }

  Future<MusicPlaylist> getLikedPlaylist() async {
    try {
      final liked = await _repository.loadLikedPlaylist();
      if (liked != null) {
        return liked;
      }
    } catch (_) {
      // ignore and keep fallback playlist
    }
    return _playlists.isNotEmpty ? _playlists.first : MockMusicCatalog.likedPlaylist;
  }

  Future<void> searchTracks(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      _searchResults = const [];
      _searchError = null;
      notifyListeners();
      return;
    }
    _isSearching = true;
    _searchError = null;
    notifyListeners();
    try {
      final provider = (_resolver as MusicSourceResolverImpl)
          .registry
          .providerById('netease');
      final candidates = await provider?.searchTracks(keyword) ?? const [];
      _searchResults = candidates
          .map((item) => item.track.toMusicTrack())
          .toList(growable: false);
    } catch (error) {
      _searchError = error.toString();
      _searchResults = const [];
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  void clearSearchResults() {
    _searchResults = const [];
    _searchError = null;
    notifyListeners();
  }

  void clearError() {
    if (_error == null || _error!.trim().isEmpty) return;
    _error = null;
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    await ensureReady();
    if (_isPlaying) {
      await _playbackAdapter.pause();
      _isPlaying = false;
    } else {
      await _playbackAdapter.resume();
      _isPlaying = true;
    }
    notifyListeners();
    unawaited(
      _repository.savePlaybackSnapshot(
        currentTrack: _currentTrack,
        queue: _queue,
        isPlaying: _isPlaying,
        position: _position,
      ),
    );
  }

  Future<void> seekTo(Duration position) async {
    await ensureReady();
    final maxMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : _currentTrack.duration.inMilliseconds;
    final clamped = Duration(
      milliseconds: position.inMilliseconds.clamp(0, maxMs),
    );
    await _playbackAdapter.seek(clamped);
    _position = clamped;
    notifyListeners();
    unawaited(
      _repository.savePlaybackSnapshot(
        currentTrack: _currentTrack,
        queue: _queue,
        isPlaying: _isPlaying,
        position: _position,
      ),
    );
  }

  Future<void> playNext() async {
    await handleCommand(
      const MusicCommand(
        type: MusicCommandType.next,
        source: MusicCommandSource.manual,
      ),
    );
  }

  Future<void> playPrevious() async {
    await ensureReady();
    if (_position >= const Duration(seconds: 3)) {
      await seekTo(Duration.zero);
      return;
    }
    if (_playbackHistory.isEmpty) {
      await seekTo(Duration.zero);
      return;
    }

    final previousTrack = _playbackHistory.removeLast();
    _queue = List<PlaybackQueueItem>.unmodifiable([
      PlaybackQueueItem(track: previousTrack),
      ..._queue,
    ]);
    _currentTrack = previousTrack;
    _duration = previousTrack.duration;
    final resolved = await _repository.resolveTrack(previousTrack);
    await _playbackAdapter.play(track: previousTrack, source: resolved);
    _isPlaying = true;
    _position = Duration.zero;
    _error = null;
    notifyListeners();
    unawaited(
      _repository.savePlaybackSnapshot(
        currentTrack: _currentTrack,
        queue: _queue,
        isPlaying: _isPlaying,
        position: _position,
      ),
    );
  }

  Future<void> handleCommand(MusicCommand command) async {
    await ensureReady();
    switch (command.type) {
      case MusicCommandType.play:
      case MusicCommandType.replaceQueue:
        final incomingQueue = command.queue;
        if (incomingQueue.isNotEmpty) {
          _queue = List<PlaybackQueueItem>.unmodifiable(incomingQueue);
          _currentTrack = incomingQueue.first.track;
          _playbackHistory.clear();
        }
        final resolved = await _repository.resolveTrack(_currentTrack);
        await _playbackAdapter.play(
          track: _currentTrack,
          source: resolved,
        );
        _isPlaying = true;
        _duration = _currentTrack.duration;
        _position = Duration.zero;
        _error = null;
        break;
      case MusicCommandType.appendToQueue:
        if (command.queue.isNotEmpty) {
          _queue = List<PlaybackQueueItem>.unmodifiable([
            ..._queue,
            ...command.queue,
          ]);
        }
        break;
      case MusicCommandType.pause:
        await _playbackAdapter.pause();
        _isPlaying = false;
        break;
      case MusicCommandType.resume:
        await _playbackAdapter.resume();
        _isPlaying = true;
        break;
      case MusicCommandType.next:
        await _advanceToNextTrack();
        break;
      case MusicCommandType.previous:
        await playPrevious();
        break;
      case MusicCommandType.seek:
        await seekTo(Duration(milliseconds: command.positionMs ?? 0));
        break;
      case MusicCommandType.likeTrack:
      case MusicCommandType.unlikeTrack:
        break;
    }
    notifyListeners();
    unawaited(
      _repository.savePlaybackSnapshot(
        currentTrack: _currentTrack,
        queue: _queue,
        isPlaying: _isPlaying,
        position: _position,
      ),
    );
  }

  void _handleBackendEvent(Map<String, dynamic> event) {
    final eventName = (event['event'] ?? '').toString();
    if (eventName != 'music.command') {
      return;
    }
    final payload = Map<String, dynamic>.from(event);
    unawaited(handleCommand(MusicCommand.fromMap(payload)));
  }

  void _handlePlaybackState(PlaybackAdapterState state) {
    final track = state.currentTrack;
    if (track != null) {
      _currentTrack = track;
    }
    _isPlaying = state.isPlaying;
    _isBuffering = state.isBuffering;
    _position = state.position;
    _duration = state.duration ?? _currentTrack.duration;
    if (state.error != null && state.error!.trim().isNotEmpty) {
      _error = state.error;
    }
    if (state.completed && !_isAdvancingQueue) {
      if (_queue.length > 1) {
        unawaited(_advanceToNextTrack());
      } else {
        _isPlaying = false;
        _position = _duration;
      }
    }
    notifyListeners();
  }

  PlaybackAdapter _createPlaybackAdapter() {
    try {
      return JustAudioPlaybackAdapter();
    } catch (_) {
      return StubPlaybackAdapter();
    }
  }

  Future<void> _advanceToNextTrack() async {
    if (_queue.length <= 1 || _isAdvancingQueue) {
      return;
    }
    _isAdvancingQueue = true;
    try {
      _playbackHistory.add(_currentTrack);
      final nextQueue = _queue.sublist(1);
      _queue = List<PlaybackQueueItem>.unmodifiable(nextQueue);
      _currentTrack = nextQueue.first.track;
      _duration = _currentTrack.duration;
      final resolved = await _repository.resolveTrack(_currentTrack);
      await _playbackAdapter.play(track: _currentTrack, source: resolved);
      _isPlaying = true;
      _position = Duration.zero;
      _error = null;
    } finally {
      _isAdvancingQueue = false;
    }
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _playbackStateSub?.cancel();
    unawaited(_playbackAdapter.dispose());
    super.dispose();
  }
}

class MusicStateSnapshot {
  const MusicStateSnapshot({
    this.currentTrack,
    this.queue = const [],
    this.playlists = const [],
    this.recentTracks = const [],
    this.isPlaying = false,
    this.position = Duration.zero,
  });

  final MusicTrack? currentTrack;
  final List<PlaybackQueueItem> queue;
  final List<MusicPlaylist> playlists;
  final List<MusicTrack> recentTracks;
  final bool isPlaying;
  final Duration position;
}
