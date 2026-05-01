import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/debug/native_debug_bridge.dart';
import '../../../core/openclaw/openclaw_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../data/music_repository.dart';
import '../data/music_repository_impl.dart';
import '../data/playback/just_audio_playback_adapter.dart';
import '../data/playback/playback_adapter.dart';
import '../data/playback/stub_playback_adapter.dart';
import '../data/sources/migu_music_source_provider.dart';
import '../data/sources/mock_music_source_provider.dart';
import '../data/sources/music_source_registry.dart';
import '../data/sources/music_source_resolver.dart';
import '../data/sources/music_source_resolver_impl.dart';
import '../data/sources/netease_music_source_provider.dart';
import '../domain/music_command.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';

enum MusicRepeatMode { off, all, one }

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
        providers: [
          NeteaseMusicSourceProvider(),
          MiguMusicSourceProvider(),
          MockMusicSourceProvider(),
        ],
      ),
    );
    _playbackAdapter = _createPlaybackAdapter();
    _repository = MusicRepositoryImpl(client: _client, resolver: _resolver);
    _eventClient = _client;
    _currentTrack = const MusicTrack(
      id: '',
      title: '还没有开始播放',
      artist: 'AliceChat 音乐',
      album: '等待你的下一首歌',
      duration: Duration.zero,
      category: '未开始播放',
      description: '登录音乐平台、点开歌单，或者让 AI 先为你生成一份歌单。',
      artworkTone: MusicArtworkTone.twilight,
    );
    _duration = _currentTrack.duration;
    _queue = const [];
    _configReady = reloadConfig();
  }

  OpenClawClient _client;
  late OpenClawClient _eventClient;
  late final MusicSourceResolver _resolver;
  late PlaybackAdapter _playbackAdapter;
  late MusicRepository _repository;
  late Future<void> _configReady;
  Future<void>? _ensureReadyTask;
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
  List<MusicPlaylist> _playlists = const [];
  List<MusicTrack> _recentTracks = const [];
  List<MusicPlaylist> _recentPlaylists = const [];
  List<MusicTrack> _likedTracks = const <MusicTrack>[];
  MusicAiPlaylistDraft? _latestAiPlaylist;
  bool _isSearching = false;
  String? _searchError;
  List<MusicTrack> _searchResults = const [];
  bool _isAdvancingQueue = false;
  bool _isLoadingPlaylist = false;
  String? _loadingPlaylistId;
  String? _currentPlaylistId;
  bool _shuffleEnabled = false;
  MusicRepeatMode _repeatMode = MusicRepeatMode.off;
  final Map<String, DateTime> _lastDebugLogAt = <String, DateTime>{};

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
  List<MusicPlaylist> get libraryPlaylists {
    final ordered = <MusicPlaylist>[likedPlaylist];
    final seen = <String>{likedPlaylist.id};
    for (final item in _playlists) {
      if (_isSystemPlaylist(item)) continue;
      if (_isRemoteLikedPlaylist(item)) continue;
      if (seen.add(item.id)) {
        ordered.add(item);
      }
    }
    return List<MusicPlaylist>.unmodifiable(ordered);
  }

  List<MusicTrack> get recentTracks => _recentTracks;
  List<MusicPlaylist> get recentPlaylists => _recentPlaylists;
  List<MusicTrack> get likedTracks => _likedTracks;
  MusicAiPlaylistDraft? get latestAiPlaylist => _latestAiPlaylist;
  bool get isSearching => _isSearching;
  String? get searchError => _searchError;
  List<MusicTrack> get searchResults => _searchResults;
  bool get isLoadingPlaylist => _isLoadingPlaylist;
  String? get loadingPlaylistId => _loadingPlaylistId;
  String? get currentPlaylistId => _currentPlaylistId;
  bool get shuffleEnabled => _shuffleEnabled;
  MusicRepeatMode get repeatMode => _repeatMode;
  bool get hasPlaybackContext => _queue.isNotEmpty || _isPlaying;
  bool get hasPreviousTrack =>
      _playbackHistory.isNotEmpty || _position >= const Duration(seconds: 3);
  bool get hasNextTrack =>
      _queue.length > 1 ||
      (_repeatMode == MusicRepeatMode.one && _queue.isNotEmpty) ||
      (_repeatMode == MusicRepeatMode.all &&
          (_queue.isNotEmpty || _playbackHistory.isNotEmpty));

  bool isPlaylistLoading(String playlistId) => _loadingPlaylistId == playlistId;

  bool isPlaylistActive(String playlistId) => _currentPlaylistId == playlistId;

  bool isPlaylistPlaying(String playlistId) =>
      _currentPlaylistId == playlistId && (_isPlaying || _isLoadingPlaylist);

  Future<void> reloadConfig() async {
    final config = await OpenClawSettingsStore.load();
    _client = OpenClawHttpClient(config);
    _repository = MusicRepositoryImpl(client: _client, resolver: _resolver);
    _eventClient = _client;
    await _eventsSub?.cancel();
    _eventsSub = null;
    _isReady = false;
    _ensureReadyTask = null;
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
    if (_isReady) return;
    final existingTask = _ensureReadyTask;
    if (existingTask != null) {
      await existingTask;
      return;
    }

    final task = _performEnsureReady();
    _ensureReadyTask = task;
    try {
      await task;
    } finally {
      if (identical(_ensureReadyTask, task)) {
        _ensureReadyTask = null;
      }
    }
  }

  Future<void> refreshLibrary() async {
    await _configReady;
    _isLoading = true;
    _error = null;
    notifyListeners();
    _debugState('refresh.start', extra: {
      'hasLatestAiPlaylist': _latestAiPlaylist != null,
      'playlistCount': _playlists.length,
      'likedCount': _likedTracks.length,
    });
    try {
      final state = await _repository.loadMusicState();
      _likedTracks = List<MusicTrack>.unmodifiable(state.likedTracks);
      _recentTracks = List<MusicTrack>.unmodifiable(state.recentTracks);
      _recentPlaylists = List<MusicPlaylist>.unmodifiable(state.recentPlaylists);
      _currentPlaylistId = state.currentPlaylistId;
      _latestAiPlaylist = await _repository.loadLatestAiPlaylist();
      final remotePlaylists = await _repository.loadUserPlaylists();
      final basePlaylists = remotePlaylists.isNotEmpty
          ? remotePlaylists
          : _playlists.where(
              (item) => item.id != likedPlaylist.id && item.id != _latestAiPlaylist?.id,
            ).toList(growable: false);
      _rebuildPlaylists(basePlaylists: basePlaylists);
      _currentTrack = _currentTrack.copyWith(
        isFavorite: isTrackLiked(_currentTrack.id),
      );
      _debugState('refresh.done', extra: {
        'hasLatestAiPlaylist': _latestAiPlaylist != null,
        'latestAiPlaylistId': _latestAiPlaylist?.id,
        'latestAiTrackCount': _latestAiPlaylist?.tracks.length ?? 0,
        'playlistCount': _playlists.length,
        'likedCount': _likedTracks.length,
        'recentPlaylistCount': _recentPlaylists.length,
      }, force: true);
    } catch (error) {
      _error = '刷新歌单失败，请稍后再试';
      _debugState('refresh.error', extra: {
        'error': error.toString(),
      }, force: true, level: 'ERROR');
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _performEnsureReady() async {
    if (_isReady) return;
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
      _queue = List<PlaybackQueueItem>.unmodifiable(state.queue);
      _playlists = List<MusicPlaylist>.unmodifiable(state.playlists);
      _recentTracks = List<MusicTrack>.unmodifiable(state.recentTracks);
      _recentPlaylists = List<MusicPlaylist>.unmodifiable(state.recentPlaylists);
      _likedTracks = List<MusicTrack>.unmodifiable(state.likedTracks);
      _currentPlaylistId = state.currentPlaylistId;
      _currentTrack = _currentTrack.copyWith(
        isFavorite: isTrackLiked(_currentTrack.id),
      );
      try {
        _latestAiPlaylist = await _repository.loadLatestAiPlaylist();
      } catch (_) {
        _latestAiPlaylist = null;
      }
      try {
        final remotePlaylists = await _repository.loadUserPlaylists();
        final basePlaylists = remotePlaylists.isNotEmpty
            ? remotePlaylists
            : _playlists;
        _rebuildPlaylists(basePlaylists: basePlaylists);
      } catch (_) {
        _rebuildPlaylists(basePlaylists: _playlists);
      }
      _isPlaying = state.isPlaying && _queue.isNotEmpty;
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
    _currentTrack = track.copyWith(isFavorite: isTrackLiked(track.id));
    _duration = track.duration;
    _isPlaying = autoplay;
    _currentPlaylistId = null;
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
    _isLoadingPlaylist = true;
    _loadingPlaylistId = playlist.id;
    _error = null;
    notifyListeners();
    _debugState('playlist.open.start', extra: {
      'playlistId': playlist.id,
      'playlistTitle': playlist.title,
    });
    try {
      final tracks = await _repository.loadPlaylistTracks(playlist);
      _debugState('playlist.open.loaded', extra: {
        'playlistId': playlist.id,
        'playlistTitle': playlist.title,
        'trackCount': tracks.length,
        'firstTrack': tracks.isEmpty ? null : '${tracks.first.title} - ${tracks.first.artist}',
        'firstPreferredSourceId': tracks.isEmpty ? null : tracks.first.preferredSourceId,
        'firstSourceTrackId': tracks.isEmpty ? null : tracks.first.sourceTrackId,
      });
      await playLoadedPlaylist(playlist, tracks);
      _debugState('playlist.open.playing', extra: {
        'playlistId': playlist.id,
        'currentTrackId': _currentTrack.id,
        'currentTrackTitle': _currentTrack.title,
        'isPlaying': _isPlaying,
        'queueLength': _queue.length,
      }, force: true);
    } catch (error) {
      _error = _friendlyPlaybackError(error, fallback: '加载歌单失败，请稍后再试');
      _debugState('playlist.open.error', extra: {
        'playlistId': playlist.id,
        'playlistTitle': playlist.title,
        'error': error.toString(),
        'friendlyError': _error,
        'currentTrackId': _currentTrack.id,
        'queueLength': _queue.length,
      }, force: true, level: 'ERROR');
      notifyListeners();
      rethrow;
    } finally {
      _isLoadingPlaylist = false;
      _loadingPlaylistId = null;
      notifyListeners();
    }
  }

  MusicTrack get heroTrack =>
      _latestAiPlaylist?.tracks.isNotEmpty == true
          ? _latestAiPlaylist!.tracks.first.copyWith(
              isFavorite: isTrackLiked(_latestAiPlaylist!.tracks.first.id),
            )
          : _currentTrack;

  MusicPlaylist get likedPlaylist => MusicPlaylist(
    id: 'liked-local',
    title: '喜欢',
    subtitle: '你的跨平台收藏',
    tag: 'LIKED',
    trackCount: _likedTracks.length,
    artworkTone: MusicArtworkTone.rose,
  );

  Future<MusicPlaylist> getLikedPlaylist() async => likedPlaylist;

  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist) async {
    await ensureReady();
    if (playlist.id == likedPlaylist.id) {
      return _likedTracks
          .map((track) => track.copyWith(isFavorite: true))
          .toList(growable: false);
    }
    final tracks = await _repository.loadPlaylistTracks(playlist);
    return tracks
        .map((track) => track.copyWith(isFavorite: isTrackLiked(track.id)))
        .toList(growable: false);
  }

  Future<void> playLoadedPlaylist(
    MusicPlaylist playlist,
    List<MusicTrack> tracks, {
    int startIndex = 0,
  }) async {
    if (tracks.isEmpty) {
      throw StateError('这个歌单暂时没有可播放的歌曲');
    }
    final safeIndex = startIndex.clamp(0, tracks.length - 1);
    final orderedTracks = <MusicTrack>[
      ...tracks.skip(safeIndex),
      ...tracks.take(safeIndex),
    ]
        .map((track) => track.copyWith(isFavorite: isTrackLiked(track.id)))
        .toList(growable: false);
    _currentPlaylistId = playlist.id;
    _recentPlaylists = List<MusicPlaylist>.unmodifiable([
      playlist.copyWith(trackCount: tracks.length),
      ..._recentPlaylists.where((item) => item.id != playlist.id),
    ].take(6));
    await handleCommand(
      MusicCommand(
        type: MusicCommandType.replaceQueue,
        source: MusicCommandSource.manual,
        queue: orderedTracks
            .map((track) => PlaybackQueueItem(track: track))
            .toList(growable: false),
      ),
    );
  }

  bool isTrackLiked(String trackId) =>
      _likedTracks.any((item) => item.id == trackId);

  Future<void> toggleTrackLiked(MusicTrack track) async {
    final liked = !isTrackLiked(track.id);
    final playbackState = _playbackAdapter.state;
    final cachedPlayback = _currentTrack.id == track.id &&
            playbackState.currentSource != null
        ? CachedPlaybackSource(
            providerId: playbackState.currentSource!.providerId,
            sourceTrackId: playbackState.currentSource!.sourceTrackId,
            streamUrl: playbackState.currentSource!.streamUrl,
            artworkUrl: playbackState.currentSource!.artworkUrl,
            mimeType: playbackState.currentSource!.mimeType,
            headers: playbackState.currentSource!.headers,
            expiresAt: playbackState.currentSource!.expiresAt,
            resolvedAt: DateTime.now(),
          )
        : track.cachedPlayback;
    final nextTrack = track.copyWith(
      isFavorite: liked,
      cachedPlayback: cachedPlayback,
    );
    final nextLikedTracks = liked
        ? <MusicTrack>[nextTrack, ..._likedTracks.where((item) => item.id != track.id)]
        : _likedTracks.where((item) => item.id != track.id).toList(growable: false);
    _likedTracks = List<MusicTrack>.unmodifiable(nextLikedTracks);
    _currentTrack = _currentTrack.id == track.id
        ? _currentTrack.copyWith(
            isFavorite: liked,
            cachedPlayback: cachedPlayback,
          )
        : _currentTrack;
    _queue = List<PlaybackQueueItem>.unmodifiable(
      _queue
          .map(
            (item) => item.track.id == track.id
                ? PlaybackQueueItem(
                    track: item.track.copyWith(
                      isFavorite: liked,
                      cachedPlayback:
                          item.track.id == track.id ? cachedPlayback : item.track.cachedPlayback,
                    ),
                    candidate: item.candidate,
                    resolvedSource: item.resolvedSource,
                    requestedBy: item.requestedBy,
                  )
                : item,
          )
          .toList(growable: false),
    );
    _recentTracks = List<MusicTrack>.unmodifiable(
      _recentTracks
          .map(
            (item) => item.id == track.id
                ? item.copyWith(
                    isFavorite: liked,
                    cachedPlayback: cachedPlayback,
                  )
                : item,
          )
          .toList(growable: false),
    );
    _rebuildPlaylists(basePlaylists: _playlists);
    notifyListeners();
    await _repository.setTrackLiked(nextTrack, liked);
    unawaited(_savePlaybackSnapshot());
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
      final registry = (_resolver as MusicSourceResolverImpl).registry;
      final netease = registry.providerById('netease');
      final migu = registry.providerById('migu');
      final neteaseCandidates = await netease?.searchTracks(keyword) ?? const [];
      final miguCandidates = await migu?.searchTracks(keyword) ?? const [];
      final results = <MusicTrack>[];
      final seen = <String>{};
      for (final item in neteaseCandidates) {
        final track = item.track.toMusicTrack();
        final key = _searchDedupKey(track);
        if (seen.add(key)) {
          results.add(track);
        }
      }
      for (final item in miguCandidates) {
        final track = item.track.toMusicTrack();
        final key = _searchDedupKey(track);
        if (seen.add(key)) {
          results.add(track);
        }
      }
      _searchResults = List<MusicTrack>.unmodifiable(results.take(20));
      _debugState('search.done', extra: {
        'query': keyword,
        'neteaseCount': neteaseCandidates.length,
        'miguCount': miguCandidates.length,
        'resultCount': _searchResults.length,
      });
    } catch (error) {
      _searchError = error.toString();
      _searchResults = const [];
      _debugState('search.error', extra: {
        'query': keyword,
        'error': error.toString(),
      }, force: true, level: 'ERROR');
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
      if (_queue.isEmpty) {
        if (_currentTrack.id.trim().isEmpty) {
          _error = '当前没有可播放的歌曲';
          notifyListeners();
          return;
        }
        await handleCommand(
          MusicCommand.play(
            queue: [PlaybackQueueItem(track: _currentTrack)],
            source: MusicCommandSource.manual,
          ),
        );
        return;
      }
      final adapterState = _playbackAdapter.state;
      if (adapterState.currentSource == null) {
        await handleCommand(
          MusicCommand.play(
            queue: _queue,
            source: MusicCommandSource.manual,
          ),
        );
        return;
      }
      await _playbackAdapter.resume();
      _isPlaying = true;
    }
    notifyListeners();
    unawaited(_savePlaybackSnapshot());
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
    unawaited(_savePlaybackSnapshot());
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
    final queueItem = await _preparePlayback(previousTrack);
    final resolved = queueItem.resolvedSource!;
    _currentTrack = queueItem.track.copyWith(isFavorite: isTrackLiked(queueItem.track.id));
    _queue = List<PlaybackQueueItem>.unmodifiable([
      queueItem,
      ..._queue.skip(1),
    ]);
    await _playbackAdapter.play(track: _currentTrack, source: resolved);
    _isPlaying = true;
    _position = Duration.zero;
    _error = null;
    notifyListeners();
    unawaited(_savePlaybackSnapshot());
  }

  Future<void> handleCommand(MusicCommand command) async {
    await ensureReady();
    switch (command.type) {
      case MusicCommandType.play:
      case MusicCommandType.replaceQueue:
        final incomingQueue = command.queue;
        if (incomingQueue.isNotEmpty) {
          final normalizedQueue = incomingQueue
              .map(
                (item) => PlaybackQueueItem(
                  track: item.track.copyWith(
                    isFavorite: isTrackLiked(item.track.id),
                  ),
                  candidate: item.candidate,
                  resolvedSource: item.resolvedSource,
                  requestedBy: item.requestedBy,
                ),
              )
              .toList(growable: true);
          if (_shuffleEnabled && normalizedQueue.length > 1) {
            final first = normalizedQueue.first;
            final tail = normalizedQueue.sublist(1)..shuffle(Random());
            normalizedQueue
              ..clear()
              ..add(first)
              ..addAll(tail);
          }
          _queue = List<PlaybackQueueItem>.unmodifiable(normalizedQueue);
          _currentTrack = _queue.first.track;
          _playbackHistory.clear();
        }
        if (_queue.isEmpty) {
          throw StateError('当前没有可播放的歌曲');
        }
        await _playCurrentQueueHead();
        break;
      case MusicCommandType.appendToQueue:
        if (command.queue.isNotEmpty) {
          _queue = List<PlaybackQueueItem>.unmodifiable([
            ..._queue,
            ...command.queue.map(
              (item) => PlaybackQueueItem(
                track: item.track.copyWith(
                  isFavorite: isTrackLiked(item.track.id),
                ),
                candidate: item.candidate,
                resolvedSource: item.resolvedSource,
                requestedBy: item.requestedBy,
              ),
            ),
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
        await toggleTrackLiked(_currentTrack.copyWith(isFavorite: false));
        return;
      case MusicCommandType.unlikeTrack:
        if (isTrackLiked(_currentTrack.id)) {
          await toggleTrackLiked(_currentTrack.copyWith(isFavorite: true));
          return;
        }
        break;
    }
    notifyListeners();
    unawaited(_savePlaybackSnapshot());
  }

  Future<void> _refreshLatestAiPlaylist() async {
    try {
      _latestAiPlaylist = await _repository.loadLatestAiPlaylist();
      _rebuildPlaylists(basePlaylists: _playlists);
      _debugState('ai_playlist.refresh', extra: {
        'latestAiPlaylistId': _latestAiPlaylist?.id,
        'latestAiTrackCount': _latestAiPlaylist?.tracks.length ?? 0,
      }, force: true);
      notifyListeners();
    } catch (error) {
      _debugState('ai_playlist.refresh.error', extra: {
        'error': error.toString(),
      }, force: true, level: 'ERROR');
    }
  }

  void _handleBackendEvent(Map<String, dynamic> event) {
    final eventName = (event['event'] ?? '').toString();
    if (eventName == 'music.ai_playlist_updated') {
      unawaited(_refreshLatestAiPlaylist());
      return;
    }
    if (eventName != 'music.command') {
      return;
    }
    final payload = Map<String, dynamic>.from(event);
    unawaited(handleCommand(MusicCommand.fromMap(payload)));
  }

  void _handlePlaybackState(PlaybackAdapterState state) {
    final track = state.currentTrack;
    if (track != null) {
      _currentTrack = track.copyWith(isFavorite: isTrackLiked(track.id));
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
    if (_isAdvancingQueue || _queue.isEmpty) {
      return;
    }
    _isAdvancingQueue = true;
    try {
      if (_repeatMode == MusicRepeatMode.one) {
        await _playCurrentQueueHead(resetPosition: true, clearCachedPlaybackOnRetry: false);
        return;
      }
      if (_queue.length <= 1) {
        if (_repeatMode == MusicRepeatMode.all && _playbackHistory.isNotEmpty) {
          _queue = List<PlaybackQueueItem>.unmodifiable([
            ..._queue,
            ..._playbackHistory.map((track) => PlaybackQueueItem(track: track)),
          ]);
          _playbackHistory.clear();
        } else {
          _isPlaying = false;
          _position = _duration;
          return;
        }
      }
      _playbackHistory.add(_currentTrack);
      final nextQueue = _queue.sublist(1);
      _queue = List<PlaybackQueueItem>.unmodifiable(nextQueue);
      _currentTrack = _queue.first.track.copyWith(
        isFavorite: isTrackLiked(_queue.first.track.id),
      );
      _duration = _currentTrack.duration;
      await _playCurrentQueueHead();
    } finally {
      _isAdvancingQueue = false;
    }
  }

  Future<PlaybackQueueItem> _preparePlayback(MusicTrack track) async {
    final cached = track.cachedPlayback;
    if (cached != null &&
        cached.streamUrl.trim().isNotEmpty &&
        !cached.isExpired) {
      _debugState('playback.prepare.cached', extra: {
        'trackId': track.id,
        'title': track.title,
        'artist': track.artist,
        'providerId': cached.providerId,
        'sourceTrackId': cached.sourceTrackId,
      });
      return PlaybackQueueItem(
        track: track.copyWith(
          preferredSourceId: track.preferredSourceId ?? cached.providerId,
          sourceTrackId: track.sourceTrackId ?? cached.sourceTrackId,
          cachedPlayback: cached,
        ),
        resolvedSource: ResolvedPlaybackSource(
          providerId: cached.providerId,
          sourceTrackId: cached.sourceTrackId,
          streamUrl: cached.streamUrl,
          artworkUrl: cached.artworkUrl,
          mimeType: cached.mimeType,
          headers: cached.headers,
          expiresAt: cached.expiresAt,
        ),
      );
    }

    try {
      final resolved = await _repository.resolveTrack(track, allowFallback: false);
      _debugState('playback.prepare.resolved', extra: {
        'trackId': track.id,
        'title': track.title,
        'artist': track.artist,
        'preferredSourceId': resolved.track.preferredSourceId,
        'sourceTrackId': resolved.track.sourceTrackId,
        'resolvedProviderId': resolved.resolvedSource?.providerId,
      });
      return resolved.copyWith(
        track: resolved.track.copyWith(
          isFavorite: isTrackLiked(resolved.track.id),
        ),
      );
    } catch (error) {
      _debugState('playback.prepare.error', extra: {
        'trackId': track.id,
        'title': track.title,
        'artist': track.artist,
        'preferredSourceId': track.preferredSourceId,
        'sourceTrackId': track.sourceTrackId,
        'error': error.toString(),
      }, force: true, level: 'ERROR');
      rethrow;
    }
  }

  Future<void> playQueueIndex(int index) async {
    await ensureReady();
    if (index < 0 || index >= _queue.length) return;
    if (index == 0) {
      await _playCurrentQueueHead(resetPosition: true, clearCachedPlaybackOnRetry: false);
      return;
    }
    final selected = _queue[index];
    _playbackHistory.addAll(_queue.take(index).map((item) => item.track));
    _queue = List<PlaybackQueueItem>.unmodifiable([
      selected,
      ..._queue.skip(index + 1),
    ]);
    _currentTrack = selected.track.copyWith(
      isFavorite: isTrackLiked(selected.track.id),
    );
    _duration = _currentTrack.duration;
    await _playCurrentQueueHead();
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    _shuffleEnabled = !_shuffleEnabled;
    if (_queue.length > 2) {
      final head = _queue.first;
      final tail = _queue.sublist(1).toList(growable: true);
      if (_shuffleEnabled) {
        tail.shuffle(Random());
      }
      _queue = List<PlaybackQueueItem>.unmodifiable([head, ...tail]);
    }
    notifyListeners();
  }

  void cycleRepeatMode() {
    switch (_repeatMode) {
      case MusicRepeatMode.off:
        _repeatMode = MusicRepeatMode.all;
        break;
      case MusicRepeatMode.all:
        _repeatMode = MusicRepeatMode.one;
        break;
      case MusicRepeatMode.one:
        _repeatMode = MusicRepeatMode.off;
        break;
    }
    notifyListeners();
  }

  void _rebuildPlaylists({List<MusicPlaylist>? basePlaylists}) {
    final source = basePlaylists ?? _playlists;
    final merged = <MusicPlaylist>[];
    final seen = <String>{};
    if (_latestAiPlaylist != null && seen.add(_latestAiPlaylist!.id)) {
      merged.add(_latestAiPlaylist!.asPlaylist);
    }
    if (seen.add(likedPlaylist.id)) {
      merged.add(likedPlaylist);
    }
    for (final item in source) {
      if (_isSystemPlaylist(item)) continue;
      if (_isRemoteLikedPlaylist(item)) continue;
      if (seen.add(item.id)) {
        merged.add(item);
      }
    }
    _playlists = List<MusicPlaylist>.unmodifiable(merged);
  }

  bool _isRemoteLikedPlaylist(MusicPlaylist playlist) =>
      playlist.id != likedPlaylist.id && playlist.tag == 'LIKED';

  bool _isSystemPlaylist(MusicPlaylist playlist) {
    return playlist.id == likedPlaylist.id ||
        playlist.isAiGenerated ||
        playlist.id.startsWith('ai-playlist:');
  }

  Future<void> _playCurrentQueueHead({
    bool resetPosition = true,
    bool clearCachedPlaybackOnRetry = true,
  }) async {
    final prepared = await _preparePlayback(_currentTrack);
    final preparedTrack = prepared.track.copyWith(
      isFavorite: isTrackLiked(prepared.track.id),
    );
    _currentTrack = preparedTrack;
    if (_queue.isNotEmpty) {
      _queue = List<PlaybackQueueItem>.unmodifiable([
        prepared.copyWith(track: preparedTrack),
        ..._queue.skip(1),
      ]);
    }
    try {
      await _playbackAdapter.play(
        track: _currentTrack,
        source: prepared.resolvedSource!,
      );
    } catch (error) {
      if (!clearCachedPlaybackOnRetry || _currentTrack.cachedPlayback == null) {
        _isPlaying = false;
        _error = _friendlyPlaybackError(error);
        rethrow;
      }
      final refreshed = await _preparePlayback(
        _currentTrack.copyWith(cachedPlayback: null),
      );
      _currentTrack = refreshed.track.copyWith(
        isFavorite: isTrackLiked(refreshed.track.id),
      );
      if (_queue.isNotEmpty) {
        _queue = List<PlaybackQueueItem>.unmodifiable([
          refreshed.copyWith(track: _currentTrack),
          ..._queue.skip(1),
        ]);
      }
      try {
        await _playbackAdapter.play(
          track: _currentTrack,
          source: refreshed.resolvedSource!,
        );
      } catch (retryError) {
        _isPlaying = false;
        _error = _friendlyPlaybackError(retryError);
        rethrow;
      }
    }
    _isPlaying = true;
    if (resetPosition) {
      _position = Duration.zero;
    }
    _duration = _currentTrack.duration;
    _error = null;
  }

  String _friendlyPlaybackError(Object error, {String? fallback}) {
    final raw = error.toString().trim();
    if (raw.isEmpty) return fallback ?? '当前歌曲暂时无法播放';
    if (raw.contains('未能为')) {
      return raw.replaceFirst('Bad state: ', '');
    }
    if (raw.contains('Source error') || raw.contains('PlayerException')) {
      return fallback ?? '播放失败，已尝试重新解析音源但仍未成功';
    }
    return fallback ?? raw.replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '');
  }

  Future<void> _savePlaybackSnapshot() {
    return _repository.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      queue: _queue,
      isPlaying: _isPlaying,
      position: _position,
      likedTracks: _likedTracks,
      recentPlaylists: _recentPlaylists,
      currentPlaylistId: _currentPlaylistId,
    );
  }

  String _searchDedupKey(MusicTrack track) {
    String normalize(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'\s+'), '').trim();
    return '${normalize(track.title)}::${normalize(track.artist)}';
  }

  void _debugState(
    String tag, {
    Map<String, dynamic>? extra,
    bool force = false,
    String level = 'INFO',
  }) {
    final now = DateTime.now();
    final lastAt = _lastDebugLogAt[tag];
    if (!force && lastAt != null && now.difference(lastAt).inMilliseconds < 250) {
      return;
    }
    _lastDebugLogAt[tag] = now;
    final payload = <String, dynamic>{
      'tag': 'music.$tag',
      'ts': now.toIso8601String(),
      'currentTrackId': _currentTrack.id,
      'currentTrackTitle': _currentTrack.title,
      'currentTrackArtist': _currentTrack.artist,
      'currentPlaylistId': _currentPlaylistId,
      'loadingPlaylistId': _loadingPlaylistId,
      'queueLength': _queue.length,
      'isPlaying': _isPlaying,
      'isBuffering': _isBuffering,
      'isLoading': _isLoading,
      'isLoadingPlaylist': _isLoadingPlaylist,
      'latestAiPlaylistId': _latestAiPlaylist?.id,
      if (extra != null) ...extra,
    };
    final message = payload.entries.map((e) => '${e.key}=${e.value}').join(' | ');
    unawaited(NativeDebugBridge.instance.log('music', message, level: level));
    unawaited(_client.sendClientDebugLog(payload));
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
    this.likedTracks = const [],
    this.recentPlaylists = const [],
    this.currentPlaylistId,
    this.isPlaying = false,
    this.position = Duration.zero,
  });

  final MusicTrack? currentTrack;
  final List<PlaybackQueueItem> queue;
  final List<MusicPlaylist> playlists;
  final List<MusicTrack> recentTracks;
  final List<MusicTrack> likedTracks;
  final List<MusicPlaylist> recentPlaylists;
  final String? currentPlaylistId;
  final bool isPlaying;
  final Duration position;
}
