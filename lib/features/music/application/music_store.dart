import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/openclaw/openclaw_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../data/mock_music_catalog.dart';
import '../data/music_repository.dart';
import '../data/music_repository_impl.dart';
import '../data/playback/playback_adapter.dart';
import '../data/playback/stub_playback_adapter.dart';
import '../data/sources/mock_music_source_provider.dart';
import '../data/sources/music_source_registry.dart';
import '../data/sources/music_source_resolver.dart';
import '../data/sources/music_source_resolver_impl.dart';
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
        providers: [MockMusicSourceProvider()],
      ),
    );
    _playbackAdapter = StubPlaybackAdapter();
    _repository = MusicRepositoryImpl(client: _client, resolver: _resolver);
    _eventClient = _client;
    _currentTrack = MockMusicCatalog.featuredTrack;
    _queue = MockMusicCatalog.data.queue
        .map((item) => PlaybackQueueItem(track: item))
        .toList(growable: false);
    _configReady = reloadConfig();
  }

  final OpenClawClient _client;
  late OpenClawClient _eventClient;
  late final MusicSourceResolver _resolver;
  late final PlaybackAdapter _playbackAdapter;
  late final MusicRepository _repository;
  late Future<void> _configReady;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;

  bool _isReady = false;
  bool _isLoading = false;
  String? _error;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  late MusicTrack _currentTrack;
  List<PlaybackQueueItem> _queue = const [];
  List<MusicPlaylist> _playlists = MockMusicCatalog.playlists;
  List<MusicTrack> _recentTracks = MockMusicCatalog.recentTracks;
  List<MusicPlaylist> _recentPlaylists = MockMusicCatalog.recentPlaylists;

  bool get isReady => _isReady;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isPlaying => _isPlaying;
  Duration get position => _position;
  MusicTrack get currentTrack => _currentTrack;
  List<PlaybackQueueItem> get queue => _queue;
  List<MusicPlaylist> get playlists => _playlists;
  List<MusicTrack> get recentTracks => _recentTracks;
  List<MusicPlaylist> get recentPlaylists => _recentPlaylists;

  Future<void> reloadConfig() async {
    final config = await OpenClawSettingsStore.load();
    _eventClient = OpenClawHttpClient(config);
    await _eventsSub?.cancel();
    _eventsSub = null;
    _isReady = false;
    _error = null;
    await _playbackAdapter.dispose();
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
      _isPlaying = state.isPlaying;
      _position = state.position;
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
    final tracks = MockMusicCatalog.tracksForPlaylist(playlist.id);
    if (tracks.isEmpty) return;
    _recentPlaylists = [
      playlist,
      ..._recentPlaylists.where((item) => item.id != playlist.id),
    ].take(6).toList(growable: false);
    await handleCommand(
      MusicCommand(
        type: MusicCommandType.replaceQueue,
        source: MusicCommandSource.manual,
        queue: tracks.map((track) => PlaybackQueueItem(track: track)).toList(growable: false),
      ),
    );
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
    unawaited(_repository.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      queue: _queue,
      isPlaying: _isPlaying,
      position: _position,
    ));
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
        }
        final resolved = await _repository.resolveTrack(_currentTrack);
        await _playbackAdapter.play(
          track: _currentTrack,
          source: resolved,
        );
        _isPlaying = true;
        _position = Duration.zero;
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
        if (_queue.length > 1) {
          final nextQueue = _queue.sublist(1);
          _queue = List<PlaybackQueueItem>.unmodifiable(nextQueue);
          _currentTrack = nextQueue.first.track;
          final resolved = await _repository.resolveTrack(_currentTrack);
          await _playbackAdapter.play(track: _currentTrack, source: resolved);
          _isPlaying = true;
          _position = Duration.zero;
        }
        break;
      case MusicCommandType.previous:
      case MusicCommandType.seek:
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
    unawaited(
      handleCommand(MusicCommand.fromMap(payload)),
    );
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
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
