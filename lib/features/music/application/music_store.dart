import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/debug/native_debug_bridge.dart';
import '../../../core/openclaw/openclaw_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../data/music_local_cache_store.dart';
import '../data/music_repository.dart';
import '../data/music_repository_impl.dart';
import 'ai_playlist_enricher.dart';
import 'playback_snapshot_scheduler.dart';
import 'playback_warmup_coordinator.dart';
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

enum MusicRepeatMode { off, all, one, intelligence }

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
    _aiPlaylistEnricher = AiPlaylistEnricher(repository: _repository);
    _warmupCoordinator = PlaybackWarmupCoordinator(repository: _repository);
    _snapshotScheduler = _createSnapshotScheduler();
    _eventClient = _client;
    _currentTrack = const MusicTrack(
      id: '',
      title: '还没有开始播放',
      artist: 'AliceChat 音乐',
      album: '等待你的下一首歌',
      duration: Duration.zero,
      category: '未开始播放',
      description: '连上你的音乐 或者先从 AI 给你的推荐开始',
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
  late AiPlaylistEnricher _aiPlaylistEnricher;
  late PlaybackWarmupCoordinator _warmupCoordinator;
  late PlaybackSnapshotScheduler _snapshotScheduler;
  late Future<void> _configReady;
  Future<void>? _ensurePlaybackReadyTask;
  Future<void>? _ensureLibraryReadyTask;
  Future<void>? _likedPrewarmTask;

  OpenClawConfig get currentConfig =>
      _client is OpenClawHttpClient
          ? (_client as OpenClawHttpClient).config
          : const OpenClawConfig(
            baseUrl: '',
            modelId: 'alicechat-default',
            providerId: 'alicechat-channel',
            agent: 'main',
            sessionName: 'alicechat',
          );
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  StreamSubscription<PlaybackAdapterState>? _playbackStateSub;

  bool _isReady = false;
  bool _isPreparingPlayback = false;
  bool _isRefreshingLibrary = false;
  bool _isHydratingFromCache = false;
  bool _hasHydratedLocalCache = false;
  bool _hasHydratedLikedCache = false;
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
  List<CustomMusicPlaylist> _customPlaylists = const <CustomMusicPlaylist>[];
  List<MusicAiPlaylistDraft> _aiPlaylistHistory = const [];
  MusicAiPlaylistDraft? _latestAiPlaylist;
  final Map<String, List<MusicTrack>> _playlistTracksCache =
      <String, List<MusicTrack>>{};
  final Set<String> _neteaseLikedTrackKeys = <String>{};
  int _searchRequestSerial = 0;
  String? _activeSearchQuery;
  bool _isSearching = false;
  String? _searchError;
  List<MusicTrack> _searchResults = const [];
  final Map<String, List<MusicTrack>> _searchCache =
      <String, List<MusicTrack>>{};
  List<String> _recentSearches = const [];
  final Map<String, MusicLyrics?> _lyricsCache = <String, MusicLyrics?>{};
  MusicLyrics? _currentLyrics;
  bool _isLyricsLoading = false;
  String? _lyricsError;
  bool _isAdvancingQueue = false;
  bool _isLoadingPlaylist = false;
  String? _loadingPlaylistId;
  String? _currentPlaylistId;
  String? _neteaseLikedPlaylistId;
  String? _neteaseLikedPlaylistOpaqueId;
  bool _shuffleEnabled = false;
  MusicRepeatMode _repeatMode = MusicRepeatMode.off;
  MusicPlaylist? _intelligenceSourcePlaylist;
  String? _intelligenceLastAnchorTrackId;
  bool _isLoadingIntelligenceBatch = false;
  final Set<String> _recentIntelligenceTrackIds = <String>{};
  final Map<String, List<MusicTrack>> _intelligenceCache =
      <String, List<MusicTrack>>{};
  final Map<String, DateTime> _lastDebugLogAt = <String, DateTime>{};
  int _localRevision = 0;
  int _lastAckedRevision = 0;
  bool _hasPendingRemoteSync = false;
  DateTime? _lastRemoteStateUpdatedAt;

  bool get isReady => _isReady;
  bool get isPreparingPlayback => _isPreparingPlayback;
  bool get isRefreshingLibrary => _isRefreshingLibrary;
  bool get isLoading => _isPreparingPlayback || _isRefreshingLibrary;
  bool get isHydratingFromCache => _isHydratingFromCache;
  String? get error => _error;
  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  bool get isStartingPlayback => _isPreparingPlayback && !_isPlaying;
  bool get isActivelyPlaying => _isPlaying && !_isBuffering;
  bool get isPlaybackBusy => isStartingPlayback || _isBuffering;
  bool get hasCompletedCurrentTrack =>
      _playbackAdapter.state.completed && _currentTrack.id.trim().isNotEmpty;
  Duration get position => _position;
  Duration get duration => _duration;
  MusicTrack get currentTrack => _currentTrack;
  List<PlaybackQueueItem> get queue => _queue;
  List<MusicPlaylist> get playlists => _playlists;
  List<MusicPlaylist> get customPlaylistCards =>
      List<MusicPlaylist>.unmodifiable(
        _customPlaylists.map((item) => item.asPlaylist).toList(growable: false),
      );

  List<MusicPlaylist> get remotePlaylists {
    final ordered = <MusicPlaylist>[];
    final seen = <String>{};
    for (final item in _playlists) {
      if (_isSystemPlaylist(item)) continue;
      if (_isRemoteLikedPlaylist(item)) continue;
      if (_isCustomPlaylist(item.id)) continue;
      if (seen.add(item.id)) {
        ordered.add(item);
      }
    }
    return List<MusicPlaylist>.unmodifiable(ordered);
  }

  List<MusicTrack> get recentTracks => _recentTracks;
  List<MusicPlaylist> get recentPlaylists => _recentPlaylists;
  List<MusicTrack> get likedTracks => _likedTracks;
  List<CustomMusicPlaylist> get customPlaylists => _customPlaylists;
  List<MusicAiPlaylistDraft> get aiPlaylistHistory => _aiPlaylistHistory;
  MusicAiPlaylistDraft? get latestAiPlaylist => _latestAiPlaylist;
  bool get isSearching => _isSearching;
  String? get searchError => _searchError;
  List<MusicTrack> get searchResults => _searchResults;
  List<String> get recentSearches => _recentSearches;
  MusicLyrics? get currentLyrics => _currentLyrics;
  bool get isLyricsLoading => _isLyricsLoading;
  String? get lyricsError => _lyricsError;
  bool get isLoadingPlaylist => _isLoadingPlaylist;
  String? get loadingPlaylistId => _loadingPlaylistId;
  String? get currentPlaylistId => _currentPlaylistId;
  bool get shuffleEnabled => _shuffleEnabled;
  MusicRepeatMode get repeatMode => _repeatMode;
  MusicPlaylist? get intelligenceSourcePlaylist => _intelligenceSourcePlaylist;
  bool get isIntelligenceMode => _repeatMode == MusicRepeatMode.intelligence;
  bool get hasPlaybackContext =>
      _queue.isNotEmpty || _isPlaying || _currentTrack.id.trim().isNotEmpty;

  MusicPlaylist? get currentPlaylist {
    final playlistId = _currentPlaylistId;
    if (playlistId == null || playlistId.trim().isEmpty) return null;
    if (playlistId == likedPlaylist.id) return likedPlaylist;
    if (_latestAiPlaylist != null && _latestAiPlaylist!.id == playlistId) {
      return _latestAiPlaylist!.asPlaylist;
    }
    for (final item in _customPlaylists) {
      if (item.id == playlistId) return item.asPlaylist;
    }
    for (final item in _aiPlaylistHistory) {
      if (item.id == playlistId) return item.asPlaylist;
    }
    for (final item in _recentPlaylists) {
      if (item.id == playlistId) return item;
    }
    for (final item in _playlists) {
      if (item.id == playlistId) return item;
    }
    return null;
  }

  String? get currentLyricLine =>
      _currentLyrics?.lineAt(_position)?.text.trim();

  String? get nextLyricLine =>
      _currentLyrics?.nextLineAfter(_position)?.text.trim();

  String get miniPlayerSubtitle {
    final lyric = currentLyricLine;
    if ((lyric ?? '').trim().isNotEmpty) return lyric!.replaceAll('\n', ' · ');
    final fallback = '${_currentTrack.artist} · ${_currentTrack.album}'.trim();
    return fallback.isEmpty ? currentPlaybackSourceLabel : fallback;
  }

  String? get currentPlaybackModeBadge {
    if (isIntelligenceMode) return '心动模式';
    return null;
  }

  String get currentPlaybackSourceLabel {
    final playlist = currentPlaylist;
    if (playlist != null) {
      if (isIntelligenceMode && _intelligenceSourcePlaylist != null) {
        return '心动模式 · 基于 ${_intelligenceSourcePlaylist!.title}';
      }
      if (playlist.id == likedPlaylist.id) return '喜欢过的歌 都收在这里';
      if (playlist.isAiGenerated) return '来自 ${playlist.title}';
      return '来自 ${playlist.title}';
    }
    if (_latestAiPlaylist != null && _currentTrack.id == heroTrack.id) {
      return '来自刚为你整理的歌单';
    }
    if (_queue.isNotEmpty) return '从刚刚的播放里接着来';
    return '这首歌 还没接上正在听的那段感觉';
  }

  bool get hasPreviousTrack =>
      _playbackHistory.isNotEmpty || _position >= const Duration(seconds: 3);
  bool get hasNextTrack =>
      _queue.length > 1 ||
      (_repeatMode == MusicRepeatMode.one && _queue.isNotEmpty) ||
      (_repeatMode == MusicRepeatMode.all &&
          (_queue.isNotEmpty || _playbackHistory.isNotEmpty)) ||
      (_repeatMode == MusicRepeatMode.intelligence && _queue.isNotEmpty);
  bool get hasLocalPlaybackControl =>
      _playbackAdapter.state.initialized || _queue.isNotEmpty || _isReady;

  bool isPlaylistLoading(String playlistId) => _loadingPlaylistId == playlistId;

  bool isPlaylistActive(String playlistId) {
    final normalized = playlistId.trim();
    if (normalized.isEmpty) return false;
    if (normalized == likedPlaylist.id) {
      return _currentPlaylistId == normalized && !isIntelligenceMode;
    }
    return _currentPlaylistId == normalized;
  }

  bool isPlaylistPlaying(String playlistId) {
    final normalized = playlistId.trim();
    if (normalized.isEmpty) return false;
    if (normalized == likedPlaylist.id) {
      return _currentPlaylistId == normalized &&
          isActivelyPlaying &&
          !isIntelligenceMode;
    }
    return _currentPlaylistId == normalized && isActivelyPlaying;
  }

  Future<void> reloadConfig() async {
    final config = await OpenClawSettingsStore.load();
    _client = OpenClawHttpClient(config);
    _repository = MusicRepositoryImpl(client: _client, resolver: _resolver);
    _aiPlaylistEnricher = AiPlaylistEnricher(repository: _repository);
    _warmupCoordinator = PlaybackWarmupCoordinator(repository: _repository);
    _snapshotScheduler.dispose();
    _snapshotScheduler = _createSnapshotScheduler();
    _eventClient = _client;
    await _eventsSub?.cancel();
    _eventsSub = null;
    _isReady = false;
    _ensurePlaybackReadyTask = null;
    _ensureLibraryReadyTask = null;
    _likedPrewarmTask = null;
    _hasHydratedLikedCache = false;
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
    await ensureLibraryReady();
  }

  Future<void> warmPlayback() async {
    unawaited(ensurePlaybackReady());
  }

  Future<void> warmLikedPlaylist() async {
    await _hydrateLikedCacheIfNeeded();
    final existingTask = _likedPrewarmTask;
    if (existingTask != null) {
      await existingTask;
      return;
    }

    final task = _prewarmLikedTracksInBackground();
    _likedPrewarmTask = task;
    try {
      await task;
    } finally {
      if (identical(_likedPrewarmTask, task)) {
        _likedPrewarmTask = null;
      }
    }
  }

  Future<void> ensurePlaybackReady() async {
    await _ensureDataAccessReady();
    final existingTask = _ensurePlaybackReadyTask;
    if (existingTask != null) {
      await existingTask;
      return;
    }

    final task = _performEnsurePlaybackReady();
    _ensurePlaybackReadyTask = task;
    try {
      await task;
    } finally {
      if (identical(_ensurePlaybackReadyTask, task)) {
        _ensurePlaybackReadyTask = null;
      }
    }
  }

  Future<void> ensureLibraryReady() async {
    await ensurePlaybackReady();
    final existingTask = _ensureLibraryReadyTask;
    if (existingTask != null) {
      await existingTask;
      return;
    }

    final task = _performEnsureLibraryReady();
    _ensureLibraryReadyTask = task;
    try {
      await task;
    } finally {
      if (identical(_ensureLibraryReadyTask, task)) {
        _ensureLibraryReadyTask = null;
      }
    }
  }

  Future<void> _ensureDataAccessReady() async {
    await _hydrateLikedCacheIfNeeded();
    await _hydrateFromLocalCacheIfNeeded();
    await _configReady;
  }

  Future<void> refreshLibrary() async {
    await _ensureDataAccessReady();
    _isRefreshingLibrary = true;
    _error = null;
    notifyListeners();
    _debugState(
      'refresh.start',
      extra: {
        'hasLatestAiPlaylist': _latestAiPlaylist != null,
        'playlistCount': _playlists.length,
        'likedCount': _likedTracks.length,
      },
    );
    try {
      final state = await _repository.loadMusicState();
      _applyRemoteStateSnapshot(state);
      await Future.wait<void>([
        _refreshHomeSections(),
        _loadAndApplyRemotePlaylists(),
      ]);
      _currentTrack = _currentTrack.copyWith(
        isFavorite: isTrackLiked(_currentTrack.id),
      );
      unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
      unawaited(_repairPlaybackArtworkIfNeeded());
      _debugState(
        'refresh.done',
        extra: {
          'hasLatestAiPlaylist': _latestAiPlaylist != null,
          'latestAiPlaylistId': _latestAiPlaylist?.id,
          'latestAiTrackCount': _latestAiPlaylist?.tracks.length ?? 0,
          'playlistCount': _playlists.length,
          'likedCount': _likedTracks.length,
          'recentPlaylistCount': _recentPlaylists.length,
        },
        force: true,
      );
      _markSnapshotDirty();
    } catch (error) {
      _error = '刷新歌单失败，请稍后再试';
      _debugState(
        'refresh.error',
        extra: {'error': error.toString()},
        force: true,
        level: 'ERROR',
      );
      rethrow;
    } finally {
      _isRefreshingLibrary = false;
      notifyListeners();
    }
  }

  Future<void> _performEnsurePlaybackReady() async {
    _isPreparingPlayback = true;
    _error = null;
    notifyListeners();
    try {
      await _playbackAdapter.initialize();
      await _playbackStateSub?.cancel();
      _playbackStateSub = _playbackAdapter.stateStream.listen(
        _handlePlaybackState,
      );
      final state = await _repository.loadMusicState();
      _applyRemoteStateSnapshot(state);
      _isPlaying = state.isPlaying && _queue.isNotEmpty;
      _position = state.position;
      _duration = state.currentTrack?.duration ?? _currentTrack.duration;
      unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
      unawaited(_repairPlaybackArtworkIfNeeded());
      _isReady = true;
      _markSnapshotDirty();
    } catch (error) {
      _error = error.toString();
    } finally {
      _isPreparingPlayback = false;
      notifyListeners();
    }
  }

  Future<void> _performEnsureLibraryReady() async {
    try {
      await Future.wait<void>([
        _refreshHomeSections(),
        _loadAndApplyRemotePlaylists(),
      ]);
      _currentTrack = _currentTrack.copyWith(
        isFavorite: isTrackLiked(_currentTrack.id),
      );
      _markSnapshotDirty();
      notifyListeners();
    } catch (_) {
      _rebuildPlaylists(basePlaylists: _playlists);
      notifyListeners();
    }
  }

  Future<void> _hydrateLikedCacheIfNeeded() async {
    if (_hasHydratedLikedCache) {
      return;
    }
    _hasHydratedLikedCache = true;
    try {
      final likedCache = await _repository.loadLikedCache();
      if (likedCache == null) {
        return;
      }
      var changed = false;
      if (likedCache.likedTracks.isNotEmpty) {
        _likedTracks = List<MusicTrack>.unmodifiable(
          likedCache.likedTracks.map(_normalizeTrackArtwork),
        );
        _cacheTracksForPlaylist(likedPlaylist.id, _likedTracks);
        changed = true;
      }
      final likedPlaylistId = likedCache.neteaseLikedPlaylistId?.trim();
      if ((likedPlaylistId ?? '').isNotEmpty) {
        _neteaseLikedPlaylistId = likedPlaylistId;
      }
      final likedPlaylistOpaqueId =
          likedCache.neteaseLikedPlaylistOpaqueId?.trim();
      if ((likedPlaylistOpaqueId ?? '').isNotEmpty) {
        _neteaseLikedPlaylistOpaqueId = likedPlaylistOpaqueId;
      }
      if (changed) {
        _rebuildPlaylists(basePlaylists: _playlists);
        notifyListeners();
      }
    } catch (_) {
      // best effort only
    }
  }

  Future<void> _hydrateFromLocalCacheIfNeeded() async {
    if (_hasHydratedLocalCache) {
      return;
    }
    _hasHydratedLocalCache = true;
    _isHydratingFromCache = true;
    try {
      final snapshot = await _repository.loadLocalCache();
      if (snapshot == null) {
        return;
      }
      _applyLocalSnapshot(snapshot);
      notifyListeners();
    } catch (_) {
      // best effort only
    } finally {
      _isHydratingFromCache = false;
    }
  }

  void _applyLocalSnapshot(MusicLocalCacheSnapshot snapshot) {
    _localRevision = snapshot.localRevision;
    _lastAckedRevision = snapshot.lastAckedRevision;
    _hasPendingRemoteSync = snapshot.hasPendingSync;
    final state = snapshot.state;
    if (state.likedTracks.isNotEmpty) {
      _likedTracks = List<MusicTrack>.unmodifiable(
        state.likedTracks.map(_normalizeTrackArtwork),
      );
      _cacheTracksForPlaylist(likedPlaylist.id, _likedTracks);
    }
    _applyRemoteStateSnapshot(state, allowStaleOverride: true);
    _latestAiPlaylist =
        state.latestAiPlaylist ??
        snapshot.latestAiPlaylist ??
        _latestAiPlaylist;
    _aiPlaylistHistory = List<MusicAiPlaylistDraft>.unmodifiable(
      state.aiPlaylistHistory.isNotEmpty
          ? state.aiPlaylistHistory
          : snapshot.aiPlaylistHistory,
    );
    if (snapshot.playlistTracksCache.isNotEmpty) {
      _playlistTracksCache
        ..clear()
        ..addAll(
          snapshot.playlistTracksCache.map(
            (key, value) => MapEntry(key, List<MusicTrack>.unmodifiable(value)),
          ),
        );
    }
    _cacheKnownAiPlaylistTracks();
    _currentTrack = _currentTrack.copyWith(
      isFavorite: isTrackLiked(_currentTrack.id),
    );
  }

  Future<void> selectTrack(MusicTrack track, {bool autoplay = true}) async {
    _currentTrack = track.copyWith(isFavorite: isTrackLiked(track.id));
    _duration = track.duration;
    _isPlaying = autoplay;
    _currentPlaylistId = null;
    unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
    notifyListeners();
    unawaited(
      _ensureTrackArtwork(
        _currentTrack,
        reason: 'select_track',
        persist: !autoplay,
      ),
    );
    if (autoplay) {
      unawaited(
        handleCommand(
          MusicCommand.play(
            queue: [PlaybackQueueItem(track: track)],
            source: MusicCommandSource.manual,
          ),
        ),
      );
    }
  }

  Future<void> retryCurrentPlaylist() async {
    final playlist = currentPlaylist;
    if (playlist == null) {
      if (_queue.isNotEmpty || _currentTrack.id.trim().isNotEmpty) {
        await retryCurrentTrack();
        return;
      }
      await refreshLibrary();
      return;
    }
    await playPlaylist(playlist);
  }

  Future<void> retryCurrentTrack() async {
    await ensurePlaybackReady();
    _error = null;
    notifyListeners();
    if (_queue.isEmpty) {
      if (_currentTrack.id.trim().isEmpty) {
        _error = '当前没有可重试的歌曲';
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
    await _playCurrentQueueHead(resetPosition: false);
    notifyListeners();
    _markSnapshotDirty(flushRemote: true);
  }

  Future<void> playPlaylist(
    MusicPlaylist playlist, {
    bool awaitPlaybackStart = true,
  }) async {
    _isLoadingPlaylist = true;
    _loadingPlaylistId = playlist.id;
    _error = null;
    notifyListeners();
    _debugState(
      'playlist.open.start',
      extra: {
        'playlistId': playlist.id,
        'playlistTitle': playlist.title,
        'awaitPlaybackStart': awaitPlaybackStart,
      },
    );
    try {
      final tracks = await loadPlaylistTracks(playlist);
      _debugState(
        'playlist.open.loaded',
        extra: {
          'playlistId': playlist.id,
          'playlistTitle': playlist.title,
          'trackCount': tracks.length,
          'firstTrack':
              tracks.isEmpty
                  ? null
                  : '${tracks.first.title} - ${tracks.first.artist}',
          'firstPreferredSourceId':
              tracks.isEmpty ? null : tracks.first.preferredSourceId,
          'firstSourceTrackId':
              tracks.isEmpty ? null : tracks.first.sourceTrackId,
        },
      );
      await playLoadedPlaylist(
        playlist,
        tracks,
        awaitPlaybackStart: awaitPlaybackStart,
      );
      _debugState(
        awaitPlaybackStart ? 'playlist.open.playing' : 'playlist.open.queued',
        extra: {
          'playlistId': playlist.id,
          'currentTrackId': _currentTrack.id,
          'currentTrackTitle': _currentTrack.title,
          'isPlaying': _isPlaying,
          'queueLength': _queue.length,
        },
        force: true,
      );
    } catch (error) {
      _error = _friendlyPlaylistLoadError(error, playlist);
      _debugState(
        'playlist.open.error',
        extra: {
          'playlistId': playlist.id,
          'playlistTitle': playlist.title,
          'error': error.toString(),
          'friendlyError': _error,
          'currentTrackId': _currentTrack.id,
          'queueLength': _queue.length,
        },
        force: true,
        level: 'ERROR',
      );
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
            description:
                (_latestAiPlaylist!.updatedAt ??
                            _latestAiPlaylist!.createdAt) ==
                        null
                    ? _latestAiPlaylist!.description
                    : '${_formatPlaylistStamp(_latestAiPlaylist!.updatedAt ?? _latestAiPlaylist!.createdAt!)} · ${_latestAiPlaylist!.description}',
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

  bool isCustomPlaylist(String playlistId) => _isCustomPlaylist(playlistId);

  CustomMusicPlaylist? customPlaylistById(String playlistId) {
    for (final item in _customPlaylists) {
      if (item.id == playlistId) return item;
    }
    return null;
  }

  Future<void> createCustomPlaylist({
    required String title,
    String subtitle = '',
    String description = '',
  }) async {
    final now = DateTime.now();
    final playlist = CustomMusicPlaylist(
      id: 'custom-playlist:${now.millisecondsSinceEpoch}',
      title: title.trim(),
      subtitle: subtitle.trim(),
      description: description.trim(),
      createdAt: now,
      updatedAt: now,
    );
    _customPlaylists = List<CustomMusicPlaylist>.unmodifiable([
      playlist,
      ..._customPlaylists,
    ]);
    _rebuildPlaylists(basePlaylists: _playlists);
    notifyListeners();
    await _repository.saveCustomPlaylists(_customPlaylists);
    _markSnapshotDirty();
  }

  Future<void> renameCustomPlaylist(
    String playlistId, {
    required String title,
    String? subtitle,
    String? description,
  }) async {
    final now = DateTime.now();
    _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(
      _customPlaylists
          .map((item) {
            if (item.id != playlistId) return item;
            return item.copyWith(
              title: title.trim(),
              subtitle: subtitle ?? item.subtitle,
              description: description ?? item.description,
              updatedAt: now,
            );
          })
          .toList(growable: false),
    );
    _rebuildPlaylists(basePlaylists: _playlists);
    notifyListeners();
    await _repository.saveCustomPlaylists(_customPlaylists);
    _markSnapshotDirty();
  }

  Future<void> deleteCustomPlaylist(String playlistId) async {
    _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(
      _customPlaylists
          .where((item) => item.id != playlistId)
          .toList(growable: false),
    );
    _recentPlaylists = List<MusicPlaylist>.unmodifiable(
      _recentPlaylists
          .where((item) => item.id != playlistId)
          .toList(growable: false),
    );
    if (_currentPlaylistId == playlistId) {
      _currentPlaylistId = null;
    }
    _playlistTracksCache.remove(playlistId);
    _rebuildPlaylists(basePlaylists: _playlists);
    notifyListeners();
    await _repository.saveCustomPlaylists(_customPlaylists);
    _markSnapshotDirty();
  }

  Future<bool> addTrackToCustomPlaylist(
    String playlistId,
    MusicTrack track,
  ) async {
    final now = DateTime.now();
    var added = false;
    _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(
      _customPlaylists
          .map((item) {
            if (item.id != playlistId) return item;
            if (item.tracks.any((existing) => existing.id == track.id)) {
              return item;
            }
            added = true;
            final nextTracks = List<MusicTrack>.unmodifiable([
              track.copyWith(isFavorite: isTrackLiked(track.id)),
              ...item.tracks,
            ]);
            _playlistTracksCache[playlistId] = nextTracks;
            return item.copyWith(tracks: nextTracks, updatedAt: now);
          })
          .toList(growable: false),
    );
    if (added) {
      _rebuildPlaylists(basePlaylists: _playlists);
      notifyListeners();
      await _repository.saveCustomPlaylists(_customPlaylists);
      _markSnapshotDirty();
    }
    return added;
  }

  Future<void> removeTrackFromCustomPlaylist(
    String playlistId,
    String trackId,
  ) async {
    final now = DateTime.now();
    _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(
      _customPlaylists
          .map((item) {
            if (item.id != playlistId) return item;
            final nextTracks = List<MusicTrack>.unmodifiable(
              item.tracks
                  .where((track) => track.id != trackId)
                  .toList(growable: false),
            );
            _playlistTracksCache[playlistId] = nextTracks;
            return item.copyWith(tracks: nextTracks, updatedAt: now);
          })
          .toList(growable: false),
    );
    _rebuildPlaylists(basePlaylists: _playlists);
    notifyListeners();
    await _repository.saveCustomPlaylists(_customPlaylists);
    _markSnapshotDirty();
  }

  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist) async {
    await _ensureDataAccessReady();
    final immediateTracks = peekPlaylistTracks(playlist);
    if (playlist.id == 'netease-fm') {
      try {
        final tracks = await _repository.loadNeteaseFmTracks(limit: 3);
        _cacheTracksForPlaylist(playlist.id, tracks);
        _markSnapshotDirty();
        return _withFavoriteFlags(tracks);
      } catch (firstError) {
        _debugState(
          'playlist.fm.retry',
          extra: {
            'playlistId': playlist.id,
            'attempt': 1,
            'limit': 3,
            'error': firstError.toString(),
          },
          force: true,
          level: 'ERROR',
        );
        try {
          final tracks = await _repository.loadNeteaseFmTracks(limit: 1);
          _cacheTracksForPlaylist(playlist.id, tracks);
          _markSnapshotDirty();
          return _withFavoriteFlags(tracks);
        } catch (secondError) {
          _debugState(
            'playlist.fm.retry_failed',
            extra: {
              'playlistId': playlist.id,
              'attempt': 2,
              'limit': 1,
              'error': secondError.toString(),
            },
            force: true,
            level: 'ERROR',
          );
          if (immediateTracks.isNotEmpty) {
            return immediateTracks;
          }
          rethrow;
        }
      }
    }
    if (immediateTracks.isNotEmpty) {
      unawaited(_refreshPlaylistTracksInBackground(playlist));
      return immediateTracks;
    }
    try {
      final tracks = await _repository.loadPlaylistTracks(playlist);
      _cacheTracksForPlaylist(playlist.id, tracks);
      _markSnapshotDirty();
      return _withFavoriteFlags(tracks);
    } catch (error) {
      final cachedTracks = _playlistTracksCache[playlist.id];
      if (cachedTracks != null && cachedTracks.isNotEmpty) {
        _debugState(
          'playlist.load.cached_fallback',
          extra: {
            'playlistId': playlist.id,
            'playlistTitle': playlist.title,
            'trackCount': cachedTracks.length,
            'error': error.toString(),
          },
        );
        return _withFavoriteFlags(cachedTracks);
      }
      rethrow;
    }
  }

  List<MusicTrack> peekPlaylistTracks(MusicPlaylist playlist) {
    if (playlist.id == likedPlaylist.id) {
      return _withFavoriteFlags(
        _likedTracks
            .map((track) => track.copyWith(isFavorite: true))
            .toList(growable: false),
      );
    }
    final cachedTracks = _playlistTracksCache[playlist.id];
    if (cachedTracks != null && cachedTracks.isNotEmpty) {
      return _withFavoriteFlags(cachedTracks);
    }
    final customPlaylist = customPlaylistById(playlist.id);
    if (customPlaylist != null) {
      _cacheTracksForPlaylist(playlist.id, customPlaylist.tracks);
      return _withFavoriteFlags(customPlaylist.tracks);
    }
    final inMemoryTracks = _knownAiPlaylistTracks(playlist.id);
    if (inMemoryTracks != null) {
      _cacheTracksForPlaylist(playlist.id, inMemoryTracks);
      return _withFavoriteFlags(inMemoryTracks);
    }
    return const <MusicTrack>[];
  }

  Future<void> _refreshPlaylistTracksInBackground(
    MusicPlaylist playlist,
  ) async {
    if (playlist.id == likedPlaylist.id) {
      return;
    }
    final customPlaylist = customPlaylistById(playlist.id);
    if (customPlaylist != null || _knownAiPlaylistTracks(playlist.id) != null) {
      return;
    }
    try {
      final remoteTracks = await _repository.loadPlaylistTracks(playlist);
      if (remoteTracks.isEmpty) {
        return;
      }
      final currentDigest = _playlistTracksCache[playlist.id]
          ?.map((item) => item.id)
          .join('|');
      final nextDigest = remoteTracks.map((item) => item.id).join('|');
      _cacheTracksForPlaylist(playlist.id, remoteTracks);
      if (currentDigest != nextDigest) {
        notifyListeners();
      }
      await _flushSnapshotNow();
    } catch (_) {
      // silent background refresh
    }
  }

  Future<void> playLoadedPlaylist(
    MusicPlaylist playlist,
    List<MusicTrack> tracks, {
    int startIndex = 0,
    bool awaitPlaybackStart = true,
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
    final normalizedPlaylist = _normalizeAiPlaylistRef(
      playlist.copyWith(trackCount: tracks.length),
    );
    _cacheTracksForPlaylist(normalizedPlaylist.id, tracks);
    final shouldAddToRecent = normalizedPlaylist.id != 'netease-fm';
    final nextRecentPlaylists =
        shouldAddToRecent
            ? List<MusicPlaylist>.unmodifiable(
              [
                normalizedPlaylist,
                ..._recentPlaylists.where(
                  (item) => item.id != normalizedPlaylist.id,
                ),
              ].take(6),
            )
            : _recentPlaylists;
    final queueItems = orderedTracks
        .map((track) => PlaybackQueueItem(track: track))
        .toList(growable: false);
    _currentPlaylistId = normalizedPlaylist.id;
    _recentPlaylists = nextRecentPlaylists;
    if (awaitPlaybackStart) {
      await handleCommand(
        MusicCommand(
          type: MusicCommandType.replaceQueue,
          source: MusicCommandSource.manual,
          queue: queueItems,
        ),
      );
      notifyListeners();
      _markSnapshotDirty();
      return;
    }

    await _pausePlaybackForPlaylistSwitch(nextQueue: queueItems);
    _applyQueuedPlaybackState(queueItems);
    notifyListeners();
    _markSnapshotDirty();
    unawaited(_startQueuedPlaybackInBackground());
  }

  Future<void> _pausePlaybackForPlaylistSwitch({
    List<PlaybackQueueItem> nextQueue = const <PlaybackQueueItem>[],
  }) async {
    final adapterState = _playbackAdapter.state;
    final nextTrackId =
        nextQueue.isNotEmpty ? nextQueue.first.track.id.trim() : '';
    final currentTrackId = _currentTrack.id.trim();
    final isSameHeadTrack =
        nextTrackId.isNotEmpty && nextTrackId == currentTrackId;
    final shouldPauseCurrentPlayback =
        !isSameHeadTrack &&
        (adapterState.isPlaying ||
            adapterState.isBuffering ||
            adapterState.currentSource != null);
    if (!shouldPauseCurrentPlayback) {
      return;
    }
    try {
      await _playbackAdapter.pause();
    } catch (_) {
      // best effort: switching to a new playlist should still proceed
    }
    _isPlaying = false;
    _isBuffering = false;
    _isPreparingPlayback = false;
    _position = Duration.zero;
  }

  void _applyQueuedPlaybackState(List<PlaybackQueueItem> queueItems) {
    if (queueItems.isEmpty) {
      throw StateError('当前没有可播放的歌曲');
    }
    _isPreparingPlayback = true;
    _isPlaying = false;
    _isBuffering = false;
    final normalizedQueue = queueItems
        .map(
          (item) => PlaybackQueueItem(
            track: item.track.copyWith(isFavorite: isTrackLiked(item.track.id)),
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
    _duration = _currentTrack.duration;
    _position = Duration.zero;
    _playbackHistory.clear();
    _error = null;
  }

  Future<void> _startQueuedPlaybackInBackground() async {
    try {
      await ensurePlaybackReady();
      await _playCurrentQueueHead();
    } catch (error) {
      _error ??= _friendlyPlaybackError(error);
      _isPlaying = false;
      _isBuffering = false;
    } finally {
      _isPreparingPlayback = false;
      notifyListeners();
      _markSnapshotDirty();
    }
  }

  bool isTrackLiked(String trackId) =>
      _likedTracks.any((item) => item.id == trackId);

  Future<void> toggleTrackLiked(MusicTrack track) async {
    await ensurePlaybackReady();
    final liked = !isTrackLiked(track.id);
    final playbackState = _playbackAdapter.state;
    final cachedPlayback =
        _currentTrack.id == track.id && playbackState.currentSource != null
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
    final nextLikedTracks =
        liked
            ? <MusicTrack>[
              nextTrack,
              ..._likedTracks.where((item) => item.id != track.id),
            ]
            : _likedTracks
                .where((item) => item.id != track.id)
                .toList(growable: false);
    _likedTracks = List<MusicTrack>.unmodifiable(nextLikedTracks);
    _currentTrack =
        _currentTrack.id == track.id
            ? _currentTrack.copyWith(
              isFavorite: liked,
              cachedPlayback: cachedPlayback,
            )
            : _currentTrack;
    _queue = List<PlaybackQueueItem>.unmodifiable(
      _queue
          .map(
            (item) =>
                item.track.id == track.id
                    ? PlaybackQueueItem(
                      track: item.track.copyWith(
                        isFavorite: liked,
                        cachedPlayback:
                            item.track.id == track.id
                                ? cachedPlayback
                                : item.track.cachedPlayback,
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
            (item) =>
                item.id == track.id
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
    try {
      await _repository.setTrackLiked(nextTrack, liked);
      if (liked && _neteaseLikedPlaylistId != null) {
        _intelligenceSourcePlaylist ??= MusicPlaylist(
          id: _neteaseLikedPlaylistId!,
          title: '喜欢',
          subtitle: '网易云喜欢的歌曲',
          tag: 'LIKED',
          trackCount: _likedTracks.length,
          artworkTone: MusicArtworkTone.rose,
        );
      }
    } catch (error) {
      _debugState(
        'liked.sync.error',
        extra: {'trackId': track.id, 'liked': liked, 'error': error.toString()},
        force: true,
        level: 'ERROR',
      );
    }
    _markSnapshotDirty();
  }

  Future<void> searchTracks(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      _searchResults = const [];
      _searchError = null;
      _activeSearchQuery = null;
      notifyListeners();
      return;
    }
    if (_isSearching && _activeSearchQuery == keyword) {
      return;
    }
    final requestSerial = ++_searchRequestSerial;
    _activeSearchQuery = keyword;
    _recentSearches = List<String>.unmodifiable(
      [keyword, ..._recentSearches.where((item) => item != keyword)].take(8),
    );
    final cachedResults = _searchCache[keyword];
    _searchResults =
        cachedResults == null
            ? const []
            : List<MusicTrack>.unmodifiable(cachedResults);
    _isSearching = true;
    _searchError = null;
    notifyListeners();
    try {
      final registry = (_resolver as MusicSourceResolverImpl).registry;
      final netease = registry.providerById('netease');
      final migu = registry.providerById('migu');
      final results = <MusicTrack>[];
      final seen = <String>{};
      int neteaseCount = 0;
      int miguCount = 0;

      void mergeTracks(List<MusicTrack> tracks) {
        for (final track in tracks) {
          final key = _searchDedupKey(track);
          if (seen.add(key)) {
            results.add(track);
          }
        }
        _searchResults = List<MusicTrack>.unmodifiable(results.take(20));
        _searchCache[keyword] = _searchResults;
      }

      Future<void> collectProviderResults(
        String providerId,
        Future<List<SourceCandidate>> future,
      ) async {
        final candidates = await future;
        if (requestSerial != _searchRequestSerial) {
          return;
        }
        final tracks = candidates
            .map((item) => item.track.toMusicTrack())
            .toList(growable: false);
        if (providerId == 'netease') {
          neteaseCount = tracks.length;
        } else if (providerId == 'migu') {
          miguCount = tracks.length;
        }
        mergeTracks(tracks);
        notifyListeners();
      }

      await Future.wait<void>([
        collectProviderResults(
          'netease',
          Future(() async => await netease?.searchTracks(keyword) ?? const []),
        ),
        collectProviderResults(
          'migu',
          Future(() async => await migu?.searchTracks(keyword) ?? const []),
        ),
      ]);
      if (requestSerial != _searchRequestSerial) {
        return;
      }
      _debugState(
        'search.done',
        extra: {
          'query': keyword,
          'neteaseCount': neteaseCount,
          'miguCount': miguCount,
          'resultCount': _searchResults.length,
        },
      );
    } catch (error) {
      if (requestSerial != _searchRequestSerial) {
        return;
      }
      _searchError = error.toString();
      _searchResults = const [];
      _debugState(
        'search.error',
        extra: {'query': keyword, 'error': error.toString()},
        force: true,
        level: 'ERROR',
      );
    } finally {
      if (requestSerial == _searchRequestSerial) {
        _isSearching = false;
        _activeSearchQuery = null;
        notifyListeners();
      }
    }
  }

  void clearSearchResults() {
    _searchRequestSerial += 1;
    _activeSearchQuery = null;
    _isSearching = false;
    _searchResults = const [];
    _searchError = null;
    notifyListeners();
  }

  void clearRecentSearches() {
    _recentSearches = const [];
    notifyListeners();
  }

  void clearError() {
    if (_error == null || _error!.trim().isEmpty) return;
    _error = null;
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    if (_isPlaying && hasLocalPlaybackControl) {
      _isPlaying = false;
      notifyListeners();
      try {
        await _playbackAdapter.pause();
      } catch (_) {
        _isPlaying = true;
        notifyListeners();
        rethrow;
      }
      _markSnapshotDirty();
      return;
    }

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
    if (adapterState.completed) {
      await _restartCurrentTrackAfterCompletion();
      return;
    }
    if (adapterState.currentSource != null && hasLocalPlaybackControl) {
      _isPlaying = true;
      notifyListeners();
      try {
        await _playbackAdapter.resume();
      } catch (_) {
        _isPlaying = false;
        notifyListeners();
        rethrow;
      }
      _markSnapshotDirty();
      return;
    }

    await handleCommand(
      MusicCommand.play(queue: _queue, source: MusicCommandSource.manual),
    );
  }

  Future<void> seekTo(Duration position) async {
    if (!hasLocalPlaybackControl) {
      await ensurePlaybackReady();
    }
    final maxMs =
        _duration.inMilliseconds > 0
            ? _duration.inMilliseconds
            : _currentTrack.duration.inMilliseconds;
    final clamped = Duration(
      milliseconds: position.inMilliseconds.clamp(0, maxMs),
    );
    await _playbackAdapter.seek(clamped);
    _position = clamped;
    notifyListeners();
    _markSnapshotDirty();
  }

  Future<void> playNext() async {
    await handleCommand(
      const MusicCommand(
        type: MusicCommandType.next,
        source: MusicCommandSource.manual,
      ),
    );
  }

  bool get canEnableIntelligenceMode => _resolveIntelligenceContext() != null;

  bool get canAttemptIntelligenceMode => _currentTrackProviderId() == 'netease';

  bool get canManualSyncNeteaseLikedPlaylist =>
      (_neteaseLikedPlaylistId ?? '').trim().isNotEmpty;

  String? get intelligenceModeHint {
    if (isIntelligenceMode) {
      return '后续会根据当前歌曲自动续播相似内容';
    }
    if (!canAttemptIntelligenceMode) {
      return '心动模式仅支持当前有网易云音源的歌曲';
    }
    if (!canEnableIntelligenceMode) {
      return '当前歌曲还不在“我喜欢”的网易云收藏里';
    }
    return '当前歌曲可开启心动模式';
  }

  Future<void> enableIntelligenceMode() async {
    await ensurePlaybackReady();
    final originalMode = _repeatMode;
    final sourceTrackId = (_currentTrack.sourceTrackId ?? '').trim();
    _debugState(
      'intelligence.enable.request',
      extra: {
        'trackId': _currentTrack.id,
        'title': _currentTrack.title,
        'providerId': _currentTrackProviderId(),
        'sourceTrackId': sourceTrackId,
        'neteaseLikedPlaylistId': _neteaseLikedPlaylistId,
        'neteaseLikedPlaylistOpaqueId': _neteaseLikedPlaylistOpaqueId,
      },
      force: true,
    );
    if (!canAttemptIntelligenceMode || sourceTrackId.isEmpty) {
      _repeatMode =
          originalMode == MusicRepeatMode.intelligence
              ? MusicRepeatMode.one
              : originalMode;
      _error = '当前歌曲还没有网易云音源，暂时无法开启心动模式';
      _debugState(
        'intelligence.enable.blocked_no_source',
        extra: {
          'providerId': _currentTrackProviderId(),
          'sourceTrackId': sourceTrackId,
        },
        force: true,
        level: 'ERROR',
      );
      notifyListeners();
      return;
    }
    final playlist = _resolveIntelligenceContext();
    if (playlist == null) {
      _repeatMode =
          originalMode == MusicRepeatMode.intelligence
              ? MusicRepeatMode.one
              : originalMode;
      _error = '当前歌曲还不在“我喜欢”的网易云收藏里，暂时无法开启心动模式';
      _debugState(
        'intelligence.enable.blocked_no_context',
        extra: {
          'sourceTrackId': sourceTrackId,
          'neteaseLikedPlaylistId': _neteaseLikedPlaylistId,
          'neteaseLikedPlaylistOpaqueId': _neteaseLikedPlaylistOpaqueId,
        },
        force: true,
        level: 'ERROR',
      );
      notifyListeners();
      return;
    }
    _intelligenceSourcePlaylist = playlist;
    _intelligenceLastAnchorTrackId = sourceTrackId;
    _recentIntelligenceTrackIds
      ..clear()
      ..add(sourceTrackId);
    _repeatMode = MusicRepeatMode.intelligence;
    _debugState(
      'intelligence.enable.ready',
      extra: {
        'sourceTrackId': sourceTrackId,
        'playlistId': playlist.id,
        'playlistTitle': playlist.title,
        'playlistTag': playlist.tag,
        'neteaseLikedPlaylistOpaqueId': _neteaseLikedPlaylistOpaqueId,
      },
      force: true,
    );
    notifyListeners();
    await _refreshIntelligenceQueue(
      startTrack: _currentTrack,
      keepCurrentTrack: true,
    );
  }

  void disableIntelligenceMode({bool keepQueue = true}) {
    _repeatMode = MusicRepeatMode.off;
    _intelligenceSourcePlaylist = null;
    _intelligenceLastAnchorTrackId = null;
    _isLoadingIntelligenceBatch = false;
    _recentIntelligenceTrackIds.clear();
    if (!keepQueue) {
      _queue = List<PlaybackQueueItem>.unmodifiable(_queue.take(1));
    }
    notifyListeners();
  }

  Future<void> _refreshIntelligenceQueue({
    required MusicTrack startTrack,
    required bool keepCurrentTrack,
  }) async {
    final playlist = _intelligenceSourcePlaylist;
    if (playlist == null || _isLoadingIntelligenceBatch) return;
    _isLoadingIntelligenceBatch = true;
    try {
      final cacheKey =
          '${playlist.id}::${startTrack.sourceTrackId ?? startTrack.id}';
      List<MusicTrack> tracks =
          _intelligenceCache[cacheKey] ?? const <MusicTrack>[];
      _debugState(
        'intelligence.queue.refresh.start',
        extra: {
          'playlistId': playlist.id,
          'playlistTitle': playlist.title,
          'seedTrackId': startTrack.id,
          'seedSourceTrackId': startTrack.sourceTrackId,
          'keepCurrentTrack': keepCurrentTrack,
          'cacheKey': cacheKey,
          'cacheHit': tracks.isNotEmpty,
        },
        force: true,
      );
      if (tracks.isEmpty) {
        tracks = await _repository.loadIntelligenceTracks(
          playlist: playlist,
          seedTrack: startTrack,
          startTrack: startTrack,
          fallbackPlaylistOpaqueId: _neteaseLikedPlaylistOpaqueId,
        );
        _intelligenceCache[cacheKey] = tracks;
        _debugState(
          'intelligence.queue.fetch.done',
          extra: {
            'playlistId': playlist.id,
            'seedSourceTrackId': startTrack.sourceTrackId,
            'fetchedCount': tracks.length,
          },
          force: true,
        );
      }
      final filtered = <MusicTrack>[];
      var filteredByRecent = 0;
      var filteredByQueue = 0;
      for (final track in tracks) {
        final sourceId = (track.sourceTrackId ?? '').trim();
        if (sourceId.isNotEmpty &&
            _recentIntelligenceTrackIds.contains(sourceId)) {
          filteredByRecent += 1;
          continue;
        }
        if (_queue.any((item) => item.track.id == track.id)) {
          filteredByQueue += 1;
          continue;
        }
        filtered.add(track.copyWith(isFavorite: isTrackLiked(track.id)));
      }
      if (filtered.isEmpty) {
        _error = '心动模式暂时没有拿到新的推荐歌曲，我会继续再试几次';
        _debugState(
          'intelligence.queue.empty',
          extra: {
            'playlistId': playlist.id,
            'rawCount': tracks.length,
            'filteredByRecent': filteredByRecent,
            'filteredByQueue': filteredByQueue,
            'queueLength': _queue.length,
            'recentIntelligenceCount': _recentIntelligenceTrackIds.length,
            'currentTrackId': _currentTrack.id,
            'currentTrackTitle': _currentTrack.title,
          },
          force: true,
          level: 'ERROR',
        );
        notifyListeners();
        return;
      }
      if (keepCurrentTrack) {
        final currentHead =
            _queue.isNotEmpty
                ? _queue.first
                : PlaybackQueueItem(track: _currentTrack);
        _queue = List<PlaybackQueueItem>.unmodifiable([
          currentHead,
          ...filtered.map((track) => PlaybackQueueItem(track: track)),
        ]);
      } else {
        _queue = List<PlaybackQueueItem>.unmodifiable([
          ..._queue,
          ...filtered.map((track) => PlaybackQueueItem(track: track)),
        ]);
      }
      for (final track in filtered) {
        final sourceId = (track.sourceTrackId ?? '').trim();
        if (sourceId.isNotEmpty) {
          _recentIntelligenceTrackIds.add(sourceId);
        }
      }
      if (_recentIntelligenceTrackIds.length > 120) {
        final keep = _recentIntelligenceTrackIds.toList(growable: false);
        _recentIntelligenceTrackIds
          ..clear()
          ..addAll(keep.skip(keep.length - 120));
      }
      _currentPlaylistId = playlist.id;
      _error = null;
      _debugState(
        'intelligence.queue.ready',
        extra: {
          'playlistId': playlist.id,
          'addedCount': filtered.length,
          'queueLength': _queue.length,
          'recentIntelligenceCount': _recentIntelligenceTrackIds.length,
        },
        force: true,
      );
      notifyListeners();
      _markSnapshotDirty();
    } catch (error) {
      final message = error.toString();
      final friendlyMessage =
          message.contains('网易云心动模式请求失败')
              ? '网易云官方心动模式这次没接上，我会在这首歌结束前继续尝试'
              : '心动模式加载失败，这首歌结束前我还会继续尝试';
      _debugState(
        'intelligence.queue.error',
        extra: {
          'playlistId': playlist.id,
          'seedTrackId': startTrack.id,
          'seedSourceTrackId': startTrack.sourceTrackId,
          'error': message,
          'friendlyMessage': friendlyMessage,
          'currentTrackId': _currentTrack.id,
          'currentTrackTitle': _currentTrack.title,
          'queueLength': _queue.length,
        },
        force: true,
        level: 'ERROR',
      );
      _error = friendlyMessage;
      notifyListeners();
    } finally {
      _isLoadingIntelligenceBatch = false;
    }
  }

  Future<void> _maybePrefetchIntelligenceQueue() async {
    if (!isIntelligenceMode || _queue.length > 2) return;
    final lastTrack = _queue.isNotEmpty ? _queue.last.track : _currentTrack;
    final sourceId = (lastTrack.sourceTrackId ?? '').trim();
    if (sourceId.isEmpty) return;
    if (_intelligenceLastAnchorTrackId == sourceId && _queue.length > 1) return;
    _intelligenceLastAnchorTrackId = sourceId;
    await _refreshIntelligenceQueue(
      startTrack: lastTrack,
      keepCurrentTrack: false,
    );
  }

  Future<void> playPrevious() async {
    if (_position >= const Duration(seconds: 3)) {
      await seekTo(Duration.zero);
      return;
    }
    if (_playbackHistory.isEmpty) {
      await seekTo(Duration.zero);
      return;
    }
    await ensurePlaybackReady();

    final previousTrack = _playbackHistory.removeLast();
    _queue = List<PlaybackQueueItem>.unmodifiable([
      PlaybackQueueItem(track: previousTrack),
      ..._queue,
    ]);
    _currentTrack = previousTrack;
    _duration = previousTrack.duration;
    final queueItem = await _preparePlayback(previousTrack);
    final resolved = queueItem.resolvedSource!;
    _currentTrack = queueItem.track.copyWith(
      isFavorite: isTrackLiked(queueItem.track.id),
    );
    _queue = List<PlaybackQueueItem>.unmodifiable([
      queueItem,
      ..._queue.skip(1),
    ]);
    await _playbackAdapter.play(track: _currentTrack, source: resolved);
    _isPlaying = true;
    _position = Duration.zero;
    _error = null;
    notifyListeners();
    _markSnapshotDirty();
  }

  Future<void> handleCommand(MusicCommand command) async {
    await ensurePlaybackReady();
    switch (command.type) {
      case MusicCommandType.play:
      case MusicCommandType.replaceQueue:
        final incomingQueue = command.queue;
        if (command.type == MusicCommandType.replaceQueue) {
          await _pausePlaybackForPlaylistSwitch(nextQueue: incomingQueue);
        }
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
        _isPreparingPlayback = false;
        break;
      case MusicCommandType.resume:
        if (_playbackAdapter.state.completed) {
          await _restartCurrentTrackAfterCompletion();
          return;
        }
        _isPreparingPlayback = true;
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
    _markSnapshotDirty();
  }

  Future<void> _refreshLatestAiPlaylist() async {
    try {
      final previousLatestId = _latestAiPlaylist?.id;
      _latestAiPlaylist = await _repository.loadLatestAiPlaylist();
      try {
        _aiPlaylistHistory = await _repository.loadAiPlaylistHistory();
      } catch (_) {
        // keep current history when refresh fails
      }
      if (_latestAiPlaylist != null) {
        _aiPlaylistHistory = List<MusicAiPlaylistDraft>.unmodifiable(
          _aiPlaylistHistory.where((item) => item.id != _latestAiPlaylist!.id),
        );
      }
      _cacheKnownAiPlaylistTracks();
      unawaited(_repairLatestAiPlaylistArtworkIfNeeded());
      _currentPlaylistId = _normalizePlaylistId(_currentPlaylistId);
      _rebuildPlaylists(basePlaylists: _playlists);
      final heroTrack = _latestAiPlaylist?.tracks.firstOrNull;
      _debugState(
        'ai_playlist.refresh',
        extra: {
          'latestAiPlaylistId': _latestAiPlaylist?.id,
          'previousLatestId': previousLatestId,
          'latestAiTrackCount': _latestAiPlaylist?.tracks.length ?? 0,
          'aiHistoryCount': _aiPlaylistHistory.length,
          'heroTrackId': heroTrack?.id,
          'heroTrackTitle': heroTrack?.title,
          'heroTrackArtworkUrl': heroTrack?.artworkUrl,
          'heroTrackCachedArtworkUrl': heroTrack?.cachedPlayback?.artworkUrl,
        },
        force: true,
      );
      _markSnapshotDirty();
      notifyListeners();
    } catch (error) {
      _debugState(
        'ai_playlist.refresh.error',
        extra: {'error': error.toString()},
        force: true,
        level: 'ERROR',
      );
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
    _isPreparingPlayback = false;
    final track = state.currentTrack;
    if (track != null) {
      final previousTrackId = _currentTrack.id;
      _currentTrack = track.copyWith(isFavorite: isTrackLiked(track.id));
      if (_currentTrack.id != previousTrackId) {
        unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
      }
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
        _isBuffering = false;
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
        await _playCurrentQueueHead(
          resetPosition: true,
          clearCachedPlaybackOnRetry: false,
        );
        return;
      }
      if (_queue.length <= 1) {
        if (_repeatMode == MusicRepeatMode.intelligence) {
          await _maybePrefetchIntelligenceQueue();
        }
        if (_repeatMode == MusicRepeatMode.all && _playbackHistory.isNotEmpty) {
          _queue = List<PlaybackQueueItem>.unmodifiable([
            ..._queue,
            ..._playbackHistory.map((track) => PlaybackQueueItem(track: track)),
          ]);
          _playbackHistory.clear();
        } else {
          _isPlaying = false;
          _isBuffering = false;
          _isPreparingPlayback = false;
          _position = _duration;
          return;
        }
      }
      _playbackHistory.add(_currentTrack);
      if (_repeatMode == MusicRepeatMode.intelligence) {
        unawaited(_maybePrefetchIntelligenceQueue());
      }
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
    final normalizedTrack = _normalizeTrackArtwork(track);
    final cached = normalizedTrack.cachedPlayback;
    if (cached != null &&
        cached.streamUrl.trim().isNotEmpty &&
        !cached.isExpired) {
      _debugState(
        'playback.prepare.cached',
        extra: {
          'trackId': normalizedTrack.id,
          'title': normalizedTrack.title,
          'artist': normalizedTrack.artist,
          'providerId': cached.providerId,
          'sourceTrackId': cached.sourceTrackId,
        },
      );
      return PlaybackQueueItem(
        track: normalizedTrack.copyWith(
          preferredSourceId:
              normalizedTrack.preferredSourceId ?? cached.providerId,
          sourceTrackId: normalizedTrack.sourceTrackId ?? cached.sourceTrackId,
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
      final resolved = await _repository.resolveTrack(
        normalizedTrack,
        allowFallback: false,
      );
      unawaited(
        _ensureTrackArtwork(
          resolved.track,
          reason: 'prepare_playback',
          persist: resolved.track.id == _currentTrack.id,
        ),
      );
      _debugState(
        'playback.prepare.resolved',
        extra: {
          'trackId': normalizedTrack.id,
          'title': normalizedTrack.title,
          'artist': normalizedTrack.artist,
          'preferredSourceId': resolved.track.preferredSourceId,
          'sourceTrackId': resolved.track.sourceTrackId,
          'resolvedProviderId': resolved.resolvedSource?.providerId,
        },
      );
      return resolved.copyWith(
        track: resolved.track.copyWith(
          isFavorite: isTrackLiked(resolved.track.id),
        ),
      );
    } catch (error) {
      _debugState(
        'playback.prepare.error',
        extra: {
          'trackId': normalizedTrack.id,
          'title': normalizedTrack.title,
          'artist': normalizedTrack.artist,
          'preferredSourceId': normalizedTrack.preferredSourceId,
          'sourceTrackId': normalizedTrack.sourceTrackId,
          'error': error.toString(),
        },
        force: true,
        level: 'ERROR',
      );
      rethrow;
    }
  }

  Future<void> playQueueIndex(int index) async {
    if (index < 0 || index >= _queue.length) return;
    if (index == 0) {
      await _playCurrentQueueHead(
        resetPosition: true,
        clearCachedPlaybackOnRetry: false,
      );
      return;
    }
    await ensurePlaybackReady();
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
        notifyListeners();
        return;
      case MusicRepeatMode.all:
        _repeatMode = MusicRepeatMode.one;
        notifyListeners();
        return;
      case MusicRepeatMode.one:
        if (canEnableIntelligenceMode) {
          _repeatMode = MusicRepeatMode.intelligence;
          notifyListeners();
          unawaited(enableIntelligenceMode());
          return;
        }
        _repeatMode = MusicRepeatMode.off;
        notifyListeners();
        return;
      case MusicRepeatMode.intelligence:
        disableIntelligenceMode();
        return;
    }
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
      final normalized = _normalizeAiPlaylistRef(item);
      if (_isSystemPlaylist(normalized)) continue;
      if (_isRemoteLikedPlaylist(normalized)) continue;
      if (_isCustomPlaylist(normalized.id)) continue;
      if (seen.add(normalized.id)) {
        merged.add(normalized);
      }
    }
    for (final item in _customPlaylists) {
      final playlist = item.asPlaylist;
      if (seen.add(playlist.id)) {
        merged.add(playlist);
      }
    }
    _playlists = List<MusicPlaylist>.unmodifiable(merged);
  }

  bool _isRemoteLikedPlaylist(MusicPlaylist playlist) =>
      playlist.id != likedPlaylist.id && playlist.tag == 'LIKED';

  bool _isCustomPlaylist(String playlistId) =>
      playlistId.startsWith('custom-playlist:');

  String? _providerIdForPlaylist(String playlistId) {
    if (playlistId.startsWith('netease-playlist:')) return 'netease';
    if (playlistId.startsWith('migu-playlist:')) return 'migu';
    return null;
  }

  String? _currentTrackProviderId() {
    final preferred = (_currentTrack.preferredSourceId ?? '').trim();
    if (preferred.isNotEmpty) {
      return preferred;
    }
    final cached = (_currentTrack.cachedPlayback?.providerId ?? '').trim();
    if (cached.isNotEmpty) {
      return cached;
    }
    final trackId = _currentTrack.id.trim();
    if (trackId.contains(':')) {
      final prefix = trackId.split(':').first.trim();
      if (prefix.isNotEmpty) {
        return prefix;
      }
    }
    return null;
  }

  MusicPlaylist? _resolveIntelligenceContext() {
    if (_currentTrackProviderId() != 'netease') {
      return null;
    }
    if (_isCurrentTrackInNeteaseLiked()) {
      return MusicPlaylist(
        id: _neteaseLikedPlaylistId!,
        title: '喜欢',
        subtitle: '网易云喜欢的歌曲',
        tag: 'LIKED',
        trackCount: _likedTracks.length,
        artworkTone: MusicArtworkTone.rose,
      );
    }
    if (_intelligenceSourcePlaylist != null &&
        _providerIdForPlaylist(_intelligenceSourcePlaylist!.id) == 'netease') {
      return _intelligenceSourcePlaylist;
    }
    return null;
  }

  bool _isSystemPlaylist(MusicPlaylist playlist) {
    return playlist.id == likedPlaylist.id ||
        playlist.isAiGenerated ||
        playlist.id.startsWith('ai-playlist:');
  }

  List<MusicPlaylist> _normalizeRecentPlaylists(List<MusicPlaylist> items) {
    final normalized = items
        .map(_normalizeAiPlaylistRef)
        .toList(growable: false);
    final seen = <String>{};
    return List<MusicPlaylist>.unmodifiable(
      normalized.where((item) => seen.add(item.id)).take(6),
    );
  }

  MusicPlaylist _normalizeAiPlaylistRef(MusicPlaylist playlist) {
    if (!playlist.id.startsWith('ai-playlist:')) {
      return playlist;
    }
    if (playlist.id == 'ai-playlist:latest') {
      return _latestAiPlaylist?.asPlaylist ?? playlist;
    }
    for (final item in _aiPlaylistHistory) {
      if (item.id == playlist.id) {
        return item.asPlaylist;
      }
    }
    return playlist;
  }

  Future<void> _mergeRemoteLikedTracks(MusicPlaylist playlist) async {
    try {
      final remoteTracks = await _repository.loadPlaylistTracks(playlist);
      if (remoteTracks.isEmpty) {
        return;
      }
      final merged = <MusicTrack>[];
      final seen = <String>{};
      for (final track in [...remoteTracks, ..._likedTracks]) {
        final normalized = track.copyWith(
          isFavorite: true,
          preferredSourceId: track.preferredSourceId ?? 'netease',
        );
        final key = _trackIdentityKey(normalized);
        if (seen.add(key)) {
          merged.add(normalized);
        }
      }
      _likedTracks = List<MusicTrack>.unmodifiable(merged);
      _neteaseLikedTrackKeys
        ..clear()
        ..addAll(
          remoteTracks
              .map(_trackIdentityKey)
              .where((item) => item.trim().isNotEmpty),
        );
      _cacheTracksForPlaylist(likedPlaylist.id, _likedTracks);
      unawaited(warmLikedPlaylist());
    } catch (error) {
      _debugState(
        'liked.remote_merge.error',
        extra: {'playlistId': playlist.id, 'error': error.toString()},
        force: true,
        level: 'ERROR',
      );
    }
  }

  Future<void> syncLikedPlaylistFromNetease() async {
    await ensurePlaybackReady();
    await _repository.syncNeteaseFavoritePlaylistOpaqueId();
    final remotePlaylists = await _repository.loadUserPlaylists();
    final remoteLikedPlaylist = _findNeteaseLikedPlaylist(remotePlaylists);
    if (remoteLikedPlaylist == null) {
      throw Exception('未获取到网易云喜欢歌单');
    }
    _neteaseLikedPlaylistId = remoteLikedPlaylist.id;
    _neteaseLikedPlaylistOpaqueId =
        await _repository.syncNeteaseFavoritePlaylistOpaqueId();
    await _mergeRemoteLikedTracks(remoteLikedPlaylist);
    final basePlaylists =
        remotePlaylists.isNotEmpty
            ? remotePlaylists
            : _playlists
                .where(
                  (item) =>
                      item.id != likedPlaylist.id &&
                      item.id != _latestAiPlaylist?.id,
                )
                .toList(growable: false);
    _rebuildPlaylists(basePlaylists: basePlaylists);
    _currentTrack = _currentTrack.copyWith(
      isFavorite: isTrackLiked(_currentTrack.id),
    );
    notifyListeners();
    _markSnapshotDirty();
  }

  MusicPlaylist? _findNeteaseLikedPlaylist(List<MusicPlaylist> playlists) {
    for (final item in playlists) {
      if (item.tag == 'LIKED' && _providerIdForPlaylist(item.id) == 'netease') {
        return item;
      }
    }
    return null;
  }

  String _trackIdentityKey(MusicTrack track) {
    final providerId =
        (track.preferredSourceId ?? track.cachedPlayback?.providerId ?? '')
            .trim();
    final sourceTrackId =
        (track.sourceTrackId ?? track.cachedPlayback?.sourceTrackId ?? '')
            .trim();
    if (providerId.isNotEmpty && sourceTrackId.isNotEmpty) {
      return '$providerId::$sourceTrackId';
    }
    return track.id.trim();
  }

  bool _isCurrentTrackInNeteaseLiked() {
    final likedPlaylistId = (_neteaseLikedPlaylistId ?? '').trim();
    if (likedPlaylistId.isEmpty) {
      return false;
    }
    final providerId = (_currentTrackProviderId() ?? '').trim();
    if (providerId != 'netease') {
      return false;
    }

    final currentSourceTrackId =
        (_currentTrack.sourceTrackId ??
                _currentTrack.cachedPlayback?.sourceTrackId ??
                '')
            .trim();
    final currentTrackId = _currentTrack.id.trim();
    final currentKey = _trackIdentityKey(_currentTrack).trim();

    if (currentKey.isNotEmpty && _neteaseLikedTrackKeys.contains(currentKey)) {
      return true;
    }

    for (final track in _likedTracks) {
      final likedProvider =
          (track.preferredSourceId ?? track.cachedPlayback?.providerId ?? '')
              .trim();
      if (likedProvider.isNotEmpty && likedProvider != 'netease') {
        continue;
      }
      final likedSourceTrackId =
          (track.sourceTrackId ?? track.cachedPlayback?.sourceTrackId ?? '')
              .trim();
      if (currentSourceTrackId.isNotEmpty &&
          likedSourceTrackId.isNotEmpty &&
          currentSourceTrackId == likedSourceTrackId) {
        return true;
      }
      if (currentTrackId.isNotEmpty && currentTrackId == track.id.trim()) {
        return true;
      }
    }
    return false;
  }

  String? _normalizePlaylistId(String? playlistId) {
    final trimmed = playlistId?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed == 'ai-playlist:latest') {
      return _latestAiPlaylist?.id ?? trimmed;
    }
    return trimmed;
  }

  bool _hasArtwork(MusicTrack track) {
    return (track.cachedPlayback?.artworkUrl ?? '').trim().isNotEmpty ||
        (track.artworkUrl ?? '').trim().isNotEmpty;
  }

  String _normalizeArtworkUrl(String? value) {
    final trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) return '';
    return trimmed.replaceFirst(
      RegExp(r'^http://p(?=\d+\.music\.126\.net/)'),
      'https://p',
    );
  }

  MusicTrack _normalizeTrackArtwork(MusicTrack track) {
    final artworkUrl = _normalizeArtworkUrl(track.artworkUrl);
    final cached = track.cachedPlayback;
    final cachedArtworkUrl = _normalizeArtworkUrl(cached?.artworkUrl);
    return track.copyWith(
      artworkUrl: artworkUrl.isEmpty ? null : artworkUrl,
      cachedPlayback:
          cached == null
              ? null
              : CachedPlaybackSource(
                providerId: cached.providerId,
                sourceTrackId: cached.sourceTrackId,
                streamUrl: cached.streamUrl.trim(),
                artworkUrl: cachedArtworkUrl.isEmpty ? null : cachedArtworkUrl,
                mimeType:
                    (cached.mimeType ?? '').trim().isEmpty
                        ? null
                        : cached.mimeType!.trim(),
                headers: Map<String, String>.from(cached.headers),
                expiresAt: cached.expiresAt,
                resolvedAt: cached.resolvedAt,
              ),
    );
  }

  MusicTrack _preferRicherTrack(MusicTrack base, MusicTrack candidate) {
    return base.copyWith(
      title: candidate.title.trim().isNotEmpty ? candidate.title : base.title,
      artist:
          candidate.artist.trim().isNotEmpty ? candidate.artist : base.artist,
      album: candidate.album.trim().isNotEmpty ? candidate.album : base.album,
      duration:
          candidate.duration.inMilliseconds > 0
              ? candidate.duration
              : base.duration,
      category:
          candidate.category.trim().isNotEmpty
              ? candidate.category
              : base.category,
      description:
          candidate.description.trim().isNotEmpty
              ? candidate.description
              : base.description,
      artworkUrl:
          (candidate.artworkUrl ?? '').trim().isNotEmpty
              ? candidate.artworkUrl
              : base.artworkUrl,
      preferredSourceId:
          (candidate.preferredSourceId ?? '').trim().isNotEmpty
              ? candidate.preferredSourceId
              : base.preferredSourceId,
      sourceTrackId:
          (candidate.sourceTrackId ?? '').trim().isNotEmpty
              ? candidate.sourceTrackId
              : base.sourceTrackId,
      cachedPlayback:
          (candidate.cachedPlayback?.artworkUrl ?? '').trim().isNotEmpty ||
                  (candidate.cachedPlayback?.streamUrl ?? '').trim().isNotEmpty
              ? candidate.cachedPlayback
              : base.cachedPlayback,
    );
  }

  void _mergeTrackAcrossState(MusicTrack updatedTrack) {
    final normalized = _normalizeTrackArtwork(updatedTrack);
    _currentTrack =
        _currentTrack.id == normalized.id
            ? _preferRicherTrack(
              _currentTrack,
              normalized,
            ).copyWith(isFavorite: isTrackLiked(normalized.id))
            : _currentTrack;
    _queue = List<PlaybackQueueItem>.unmodifiable(
      _queue
          .map(
            (item) =>
                item.track.id == normalized.id
                    ? item.copyWith(
                      track: _preferRicherTrack(
                        item.track,
                        normalized,
                      ).copyWith(isFavorite: isTrackLiked(normalized.id)),
                    )
                    : item,
          )
          .toList(growable: false),
    );
    _recentTracks = List<MusicTrack>.unmodifiable(
      _recentTracks
          .map(
            (item) =>
                item.id == normalized.id
                    ? _preferRicherTrack(
                      item,
                      normalized,
                    ).copyWith(isFavorite: isTrackLiked(normalized.id))
                    : item,
          )
          .toList(growable: false),
    );
    _likedTracks = List<MusicTrack>.unmodifiable(
      _likedTracks
          .map(
            (item) =>
                item.id == normalized.id
                    ? _preferRicherTrack(
                      item,
                      normalized,
                    ).copyWith(isFavorite: true)
                    : item,
          )
          .toList(growable: false),
    );
    for (final entry in _playlistTracksCache.entries.toList(growable: false)) {
      final replaced = entry.value
          .map(
            (item) =>
                item.id == normalized.id
                    ? _preferRicherTrack(
                      item,
                      normalized,
                    ).copyWith(isFavorite: isTrackLiked(normalized.id))
                    : item,
          )
          .toList(growable: false);
      _playlistTracksCache[entry.key] = List<MusicTrack>.unmodifiable(replaced);
    }
    if (_latestAiPlaylist != null) {
      final tracks = _latestAiPlaylist!.tracks
          .map(
            (item) =>
                item.id == normalized.id
                    ? _preferRicherTrack(
                      item,
                      normalized,
                    ).copyWith(isFavorite: isTrackLiked(normalized.id))
                    : item,
          )
          .toList(growable: false);
      _latestAiPlaylist = MusicAiPlaylistDraft(
        id: _latestAiPlaylist!.id,
        title: _latestAiPlaylist!.title,
        subtitle: _latestAiPlaylist!.subtitle,
        description: _latestAiPlaylist!.description,
        tag: _latestAiPlaylist!.tag,
        artworkTone: _latestAiPlaylist!.artworkTone,
        isAiGenerated: _latestAiPlaylist!.isAiGenerated,
        tracks: List<MusicTrack>.unmodifiable(tracks),
        createdAt: _latestAiPlaylist!.createdAt,
        updatedAt: _latestAiPlaylist!.updatedAt,
      );
    }
  }

  Future<MusicTrack> _ensureTrackArtwork(
    MusicTrack track, {
    required String reason,
    bool persist = false,
  }) async {
    if (_hasArtwork(track)) {
      return track;
    }
    final enriched = _normalizeTrackArtwork(
      await _repository.enrichTrackMetadata(
        _normalizeTrackArtwork(track),
        allowFallback: false,
      ),
    );
    if (!_hasArtwork(enriched)) {
      _debugState(
        'artwork.ensure.miss',
        extra: {
          'reason': reason,
          'trackId': track.id,
          'title': track.title,
          'artist': track.artist,
          'preferredSourceId': track.preferredSourceId,
          'sourceTrackId': track.sourceTrackId,
        },
        force: true,
        level: 'ERROR',
      );
      return enriched;
    }
    _mergeTrackAcrossState(enriched);
    _debugState(
      'artwork.ensure.hit',
      extra: {
        'reason': reason,
        'trackId': track.id,
        'title': track.title,
        'artist': track.artist,
        'artworkUrl': enriched.artworkUrl,
        'artworkSource':
            (enriched.cachedPlayback?.artworkUrl ?? '').trim().isNotEmpty
                ? 'cachedPlayback'
                : 'track.artworkUrl',
        'preferredSourceId': enriched.preferredSourceId,
        'sourceTrackId': enriched.sourceTrackId,
      },
    );
    if (persist) {
      notifyListeners();
      _markSnapshotDirty();
    }
    return _currentTrack.id == enriched.id ? _currentTrack : enriched;
  }

  Future<void> _repairPlaybackArtworkIfNeeded() async {
    final tasks = <MusicTrack>[];
    if (_currentTrack.id.trim().isNotEmpty && !_hasArtwork(_currentTrack)) {
      tasks.add(_currentTrack);
    }
    for (final item in _queue.take(3)) {
      if (!_hasArtwork(item.track) &&
          tasks.every((track) => track.id != item.track.id)) {
        tasks.add(item.track);
      }
    }
    for (final track in tasks) {
      try {
        await _ensureTrackArtwork(
          track,
          reason: 'state_repair',
          persist: track.id == _currentTrack.id,
        );
      } catch (_) {}
    }
  }

  Future<void> _restartCurrentTrackAfterCompletion() async {
    if (_currentTrack.id.trim().isEmpty) {
      _isPlaying = false;
      _isPreparingPlayback = false;
      _position = Duration.zero;
      notifyListeners();
      _markSnapshotDirty();
      return;
    }
    _error = null;
    _isPreparingPlayback = true;
    notifyListeners();
    await _playCurrentQueueHead(resetPosition: true);
    notifyListeners();
    _markSnapshotDirty();
  }

  Future<void> _playCurrentQueueHead({
    bool resetPosition = true,
    bool clearCachedPlaybackOnRetry = true,
    bool allowSkipOnFailure = true,
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
        final friendlyError = _friendlyPlaybackError(error);
        final skipped = await _skipFailedCurrentTrack(
          friendlyError,
          allowSkipOnFailure: allowSkipOnFailure,
        );
        if (skipped) {
          return;
        }
        _isPlaying = false;
        _error = friendlyError;
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
        final friendlyError = _friendlyPlaybackError(retryError);
        final skipped = await _skipFailedCurrentTrack(
          friendlyError,
          allowSkipOnFailure: allowSkipOnFailure,
        );
        if (skipped) {
          return;
        }
        _isPlaying = false;
        _error = friendlyError;
        rethrow;
      }
    }
    _isPreparingPlayback = false;
    _isPlaying = true;
    if (resetPosition) {
      _position = Duration.zero;
    }
    _duration = _currentTrack.duration;
    _error = null;
    unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
    unawaited(_warmUpcomingQueueTracks());
    unawaited(
      _ensureTrackArtwork(
        _currentTrack,
        reason: 'playback_started',
        persist: true,
      ),
    );
  }

  Future<void> refreshCurrentLyrics() async {
    await _loadLyricsForTrack(_currentTrack, forceRefresh: true);
  }

  Future<void> _loadLyricsForTrack(
    MusicTrack track, {
    required bool forceRefresh,
  }) async {
    final cacheKey = _lyricsCacheKey(track);
    if (cacheKey.isEmpty) {
      _currentLyrics = null;
      _lyricsError = null;
      _isLyricsLoading = false;
      notifyListeners();
      return;
    }
    if (!forceRefresh && _lyricsCache.containsKey(cacheKey)) {
      _currentLyrics = _lyricsCache[cacheKey];
      _lyricsError = null;
      _isLyricsLoading = false;
      notifyListeners();
      return;
    }
    _isLyricsLoading = true;
    _lyricsError = null;
    notifyListeners();
    try {
      final lyrics = await _repository.loadLyrics(track);
      _lyricsCache[cacheKey] = lyrics;
      if (_currentTrack.id == track.id) {
        _currentLyrics = lyrics;
      }
    } catch (error) {
      if (_currentTrack.id == track.id) {
        _currentLyrics = null;
        _lyricsError = error.toString();
      }
    } finally {
      if (_currentTrack.id == track.id) {
        _isLyricsLoading = false;
        notifyListeners();
      }
    }
  }

  String _lyricsCacheKey(MusicTrack track) {
    final preferred =
        (track.preferredSourceId ?? track.cachedPlayback?.providerId ?? '')
            .trim();
    final sourceTrackId =
        (track.sourceTrackId ?? track.cachedPlayback?.sourceTrackId ?? '')
            .trim();
    if (preferred.isEmpty && sourceTrackId.isEmpty) {
      return track.id.trim();
    }
    return '$preferred::$sourceTrackId';
  }

  String _friendlyPlaylistLoadError(Object error, MusicPlaylist playlist) {
    final raw = error
        .toString()
        .trim()
        .replaceFirst('Exception: ', '')
        .replaceFirst('Bad state: ', '');
    if (raw.contains('这个歌单暂时没有可播放的歌曲')) {
      if (playlist.id.startsWith('ai-playlist:')) {
        return '这份 AI 歌单里暂时没有可播放的歌曲';
      }
      return raw;
    }
    if (playlist.id == 'netease-fm') {
      if (raw.contains('认证失败')) {
        return raw;
      }
      if (raw.contains('404') ||
          raw.contains('Not Found') ||
          raw.contains('未找到') ||
          raw.contains('unsupported')) {
        return '私人 FM 暂时不可用，请确认后端已经更新到最新版本';
      }
      if (raw.contains('凭据未配置') ||
          raw.contains('登录态缺失') ||
          raw.contains('授权登录')) {
        return '私人 FM 暂时不可用，请先检查网易云登录状态';
      }
      if (raw.contains('加载网易云私人 FM 失败')) {
        return '私人 FM 暂时不可用，请稍后再试';
      }
    }
    if (playlist.id.startsWith('ai-playlist:')) {
      if (raw.contains('加载 AI 歌单失败') || raw.contains('加载 AI 历史歌单失败')) {
        return 'AI 歌单加载失败，请稍后再试';
      }
      if (raw.contains('source') || raw.contains('未能为')) {
        return 'AI 歌单里的歌曲暂时没能成功匹配音源，请稍后重试';
      }
    }
    return _friendlyPlaybackError(error, fallback: '加载歌单失败，请稍后再试');
  }

  Future<bool> _skipFailedCurrentTrack(
    String friendlyError, {
    required bool allowSkipOnFailure,
  }) async {
    if (!allowSkipOnFailure || _queue.length <= 1) {
      return false;
    }
    final failedTrack = _currentTrack;
    _debugState(
      'playback.skip_failed_track',
      extra: {
        'trackId': failedTrack.id,
        'title': failedTrack.title,
        'error': friendlyError,
        'remainingQueue': _queue.length - 1,
      },
      force: true,
      level: 'ERROR',
    );
    _playbackHistory.add(failedTrack);
    _queue = List<PlaybackQueueItem>.unmodifiable(_queue.skip(1));
    _currentTrack = _queue.first.track.copyWith(
      isFavorite: isTrackLiked(_queue.first.track.id),
    );
    _duration = _currentTrack.duration;
    _position = Duration.zero;
    _error = '《${failedTrack.title}》暂时无法播放，已自动跳到下一首';
    notifyListeners();
    await _playCurrentQueueHead(
      resetPosition: true,
      clearCachedPlaybackOnRetry: true,
      allowSkipOnFailure: false,
    );
    return true;
  }

  Future<void> _warmUpcomingQueueTracks() async {
    if (_queue.length <= 1) return;
    final warmed = await _warmupCoordinator.warmup(_queue);
    if (identical(warmed, _queue)) {
      return;
    }
    _queue = warmed;
    _markSnapshotDirty();
    notifyListeners();
  }

  Future<void> _prewarmLikedTracksInBackground() async {
    if (_likedTracks.isEmpty) {
      return;
    }
    try {
      final queue = _likedTracks
          .take(3)
          .map(
            (track) =>
                PlaybackQueueItem(track: track.copyWith(isFavorite: true)),
          )
          .toList(growable: false);
      if (queue.isEmpty) {
        return;
      }
      final warmed = await _warmupCoordinator.warmup(queue);
      var changed = false;
      for (final item in warmed) {
        final before = _likedTracks.firstWhere(
          (track) => track.id == item.track.id,
          orElse: () => item.track,
        );
        final merged = _preferRicherTrack(
          before,
          item.track,
        ).copyWith(isFavorite: true);
        if ((merged.preferredSourceId ?? '') !=
                (before.preferredSourceId ?? '') ||
            (merged.sourceTrackId ?? '') != (before.sourceTrackId ?? '') ||
            (merged.cachedPlayback?.streamUrl ?? '') !=
                (before.cachedPlayback?.streamUrl ?? '') ||
            (merged.cachedPlayback?.artworkUrl ?? '') !=
                (before.cachedPlayback?.artworkUrl ?? '') ||
            (merged.artworkUrl ?? '') != (before.artworkUrl ?? '')) {
          changed = true;
          _mergeTrackAcrossState(merged);
        }
      }
      if (!changed) {
        return;
      }
      _cacheTracksForPlaylist(likedPlaylist.id, _likedTracks);
      _markSnapshotDirty();
      notifyListeners();
    } catch (_) {
      // best effort only
    }
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
    return fallback ??
        raw.replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '');
  }

  PlaybackSnapshotScheduler _createSnapshotScheduler() {
    return PlaybackSnapshotScheduler(
      buildSnapshot: _buildSnapshotBundle,
      saveLocal: _repository.saveLocalCache,
      saveRemote: (payload) async {
        final ackedAt = await _repository.savePlaybackSnapshot(
          currentTrack: payload.currentTrack,
          queue: payload.queue,
          isPlaying: payload.isPlaying,
          position: payload.position,
          likedTracks: payload.likedTracks,
          recentPlaylists: payload.recentPlaylists,
          customPlaylists: payload.customPlaylists,
          currentPlaylistId: payload.currentPlaylistId,
          neteaseLikedPlaylistId: payload.neteaseLikedPlaylistId,
          neteaseLikedPlaylistOpaqueId: payload.neteaseLikedPlaylistOpaqueId,
          localRevision: payload.localRevision,
        );
        if (payload.localRevision >= _lastAckedRevision) {
          _lastAckedRevision = payload.localRevision;
          _hasPendingRemoteSync = _lastAckedRevision < _localRevision;
          if (ackedAt != null) {
            _lastRemoteStateUpdatedAt = ackedAt;
          }
          await _repository.saveLocalCache(
            _buildSnapshotBundle().localSnapshot,
          );
        }
      },
    );
  }

  MusicSnapshotBundle _buildSnapshotBundle() {
    final localSnapshot = MusicLocalCacheSnapshot(
      state: MusicStateSnapshot(
        currentTrack: _currentTrack,
        queue: _queue,
        playlists: _playlists,
        recentTracks: _recentTracks,
        likedTracks: _likedTracks,
        recentPlaylists: _recentPlaylists,
        customPlaylists: _customPlaylists,
        currentPlaylistId: _currentPlaylistId,
        neteaseLikedPlaylistId: _neteaseLikedPlaylistId,
        neteaseLikedPlaylistOpaqueId: _neteaseLikedPlaylistOpaqueId,
        isPlaying: _isPlaying,
        position: _position,
      ),
      latestAiPlaylist: _latestAiPlaylist,
      aiPlaylistHistory: _aiPlaylistHistory,
      playlistTracksCache: Map<String, List<MusicTrack>>.from(
        _playlistTracksCache,
      ),
      cachedAt: DateTime.now(),
      localRevision: _localRevision,
      lastAckedRevision: _lastAckedRevision,
      hasPendingSync: _hasPendingRemoteSync,
    );
    return MusicSnapshotBundle(
      localSnapshot: localSnapshot,
      remoteSnapshot: MusicRemoteSnapshotPayload(
        currentTrack: _currentTrack,
        queue: _queue,
        isPlaying: _isPlaying,
        position: _position,
        likedTracks: _likedTracks,
        recentPlaylists: _recentPlaylists,
        customPlaylists: _customPlaylists,
        currentPlaylistId: _currentPlaylistId,
        neteaseLikedPlaylistId: _neteaseLikedPlaylistId,
        neteaseLikedPlaylistOpaqueId: _neteaseLikedPlaylistOpaqueId,
        localRevision: _localRevision,
      ),
    );
  }

  void _markSnapshotDirty({bool flushRemote = false}) {
    _localRevision += 1;
    _hasPendingRemoteSync = true;
    _snapshotScheduler.markDirty(flushRemote: flushRemote);
  }

  Future<void> _flushSnapshotNow() {
    return _snapshotScheduler.flushNow();
  }

  String _searchDedupKey(MusicTrack track) {
    String normalize(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'\s+'), '').trim();
    return '${normalize(track.title)}::${normalize(track.artist)}';
  }

  String _formatPlaylistStamp(DateTime value) {
    final local = value.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$min';
  }

  List<MusicTrack> _withFavoriteFlags(List<MusicTrack> tracks) {
    return List<MusicTrack>.unmodifiable(
      tracks
          .map((track) => track.copyWith(isFavorite: isTrackLiked(track.id)))
          .toList(growable: false),
    );
  }

  List<MusicTrack>? _knownAiPlaylistTracks(String playlistId) {
    if (_latestAiPlaylist != null && _latestAiPlaylist!.id == playlistId) {
      return _latestAiPlaylist!.tracks;
    }
    final customPlaylist = customPlaylistById(playlistId);
    if (customPlaylist != null) {
      return customPlaylist.tracks;
    }
    for (final item in _aiPlaylistHistory) {
      if (item.id == playlistId) {
        return item.tracks;
      }
    }
    return null;
  }

  void _cacheTracksForPlaylist(String playlistId, List<MusicTrack> tracks) {
    if (playlistId.trim().isEmpty || tracks.isEmpty) {
      return;
    }
    _playlistTracksCache[playlistId] = List<MusicTrack>.unmodifiable(
      tracks.map((track) => track.copyWith()).toList(growable: false),
    );
  }

  void _cacheKnownAiPlaylistTracks() {
    if (_latestAiPlaylist != null && _latestAiPlaylist!.tracks.isNotEmpty) {
      _cacheTracksForPlaylist(_latestAiPlaylist!.id, _latestAiPlaylist!.tracks);
    }
    for (final item in _aiPlaylistHistory) {
      if (item.tracks.isNotEmpty) {
        _cacheTracksForPlaylist(item.id, item.tracks);
      }
    }
  }

  Future<void> _repairLatestAiPlaylistArtworkIfNeeded() async {
    final latest = _latestAiPlaylist;
    if (latest == null || latest.tracks.isEmpty) {
      return;
    }
    var changed = false;
    final repairedTracks = <MusicTrack>[];
    for (final track in latest.tracks) {
      var nextTrack = _normalizeTrackArtwork(track);
      if (!_hasArtwork(nextTrack)) {
        try {
          nextTrack = _normalizeTrackArtwork(
            await _repository.enrichTrackMetadata(
              nextTrack,
              allowFallback: false,
            ),
          );
        } catch (_) {}
      }
      if ((nextTrack.artworkUrl ?? '') != (track.artworkUrl ?? '') ||
          (nextTrack.cachedPlayback?.artworkUrl ?? '') !=
              (track.cachedPlayback?.artworkUrl ?? '') ||
          (nextTrack.preferredSourceId ?? '') !=
              (track.preferredSourceId ?? '') ||
          (nextTrack.sourceTrackId ?? '') != (track.sourceTrackId ?? '')) {
        changed = true;
      }
      repairedTracks.add(nextTrack);
    }
    if (!changed) {
      return;
    }
    _latestAiPlaylist = MusicAiPlaylistDraft(
      id: latest.id,
      title: latest.title,
      subtitle: latest.subtitle,
      description: latest.description,
      tag: latest.tag,
      artworkTone: latest.artworkTone,
      isAiGenerated: latest.isAiGenerated,
      tracks: List<MusicTrack>.unmodifiable(repairedTracks),
      createdAt: latest.createdAt,
      updatedAt: latest.updatedAt,
    );
    _cacheKnownAiPlaylistTracks();
    notifyListeners();
  }

  void _debugState(
    String tag, {
    Map<String, dynamic>? extra,
    bool force = false,
    String level = 'INFO',
  }) {
    final now = DateTime.now();
    final lastAt = _lastDebugLogAt[tag];
    if (!force &&
        lastAt != null &&
        now.difference(lastAt).inMilliseconds < 250) {
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
      'isPreparingPlayback': _isPreparingPlayback,
      'isRefreshingLibrary': _isRefreshingLibrary,
      'isLoading': isLoading,
      'isLoadingPlaylist': _isLoadingPlaylist,
      'latestAiPlaylistId': _latestAiPlaylist?.id,
      if (extra != null) ...extra,
    };
    final message = payload.entries
        .map((e) => '${e.key}=${e.value}')
        .join(' | ');
    unawaited(NativeDebugBridge.instance.log('music', message, level: level));
    unawaited(_client.sendClientDebugLog(payload));
  }

  @override
  void dispose() {
    _snapshotScheduler.dispose();
    _aiPlaylistEnricher.cancel();
    _warmupCoordinator.cancel();
    _eventsSub?.cancel();
    _playbackStateSub?.cancel();
    unawaited(_playbackAdapter.dispose());
    super.dispose();
  }

  void _applyRemoteStateSnapshot(
    MusicStateSnapshot state, {
    bool allowStaleOverride = false,
  }) {
    final remoteUpdatedAt = state.serverUpdatedAt;
    final remoteRevision = state.remoteRevision;
    final hasNewerLocal =
        _hasPendingRemoteSync || _localRevision > _lastAckedRevision;
    if (!allowStaleOverride && hasNewerLocal) {
      final remoteLooksFresh =
          remoteRevision > 0 && remoteRevision >= _localRevision;
      final remoteTimeFresh =
          remoteUpdatedAt != null &&
          (_lastRemoteStateUpdatedAt == null ||
              !remoteUpdatedAt.isBefore(_lastRemoteStateUpdatedAt!));
      if (!remoteLooksFresh && !remoteTimeFresh) {
        _debugState(
          'state.apply_remote.skipped_stale',
          extra: {
            'remoteRevision': remoteRevision,
            'localRevision': _localRevision,
            'lastAckedRevision': _lastAckedRevision,
            'remoteUpdatedAt': remoteUpdatedAt?.toIso8601String(),
            'lastRemoteUpdatedAt': _lastRemoteStateUpdatedAt?.toIso8601String(),
          },
          force: true,
        );
        return;
      }
    }
    if (state.currentTrack != null) {
      _currentTrack = state.currentTrack!;
    }
    if (state.queue.isNotEmpty) {
      _queue = List<PlaybackQueueItem>.unmodifiable(state.queue);
    }
    if (state.playlists.isNotEmpty) {
      _playlists = List<MusicPlaylist>.unmodifiable(state.playlists);
    }
    _recentTracks = List<MusicTrack>.unmodifiable(state.recentTracks);
    _recentPlaylists = _normalizeRecentPlaylists(state.recentPlaylists);
    _likedTracks = List<MusicTrack>.unmodifiable(
      state.likedTracks.map(_normalizeTrackArtwork),
    );
    _cacheTracksForPlaylist(likedPlaylist.id, _likedTracks);
    _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(
      state.customPlaylists,
    );
    _currentPlaylistId = _normalizePlaylistId(state.currentPlaylistId);
    _neteaseLikedPlaylistId = state.neteaseLikedPlaylistId?.trim();
    _neteaseLikedPlaylistOpaqueId = state.neteaseLikedPlaylistOpaqueId?.trim();
    _latestAiPlaylist = state.latestAiPlaylist ?? _latestAiPlaylist;
    _aiPlaylistHistory = List<MusicAiPlaylistDraft>.unmodifiable(
      state.aiPlaylistHistory,
    );
    _cacheKnownAiPlaylistTracks();
    if (remoteRevision > 0) {
      _lastAckedRevision =
          remoteRevision > _lastAckedRevision
              ? remoteRevision
              : _lastAckedRevision;
      if (remoteRevision > _localRevision) {
        _localRevision = remoteRevision;
      }
      _hasPendingRemoteSync = _localRevision > _lastAckedRevision;
    }
    if (remoteUpdatedAt != null) {
      _lastRemoteStateUpdatedAt = remoteUpdatedAt;
    }
  }

  Future<void> _refreshHomeSections() async {
    try {
      final home = await _repository.loadMusicHome();
      if (_hasPendingRemoteSync &&
          home.remoteRevision > 0 &&
          home.remoteRevision < _localRevision) {
        _debugState(
          'refresh.home.skipped_stale',
          extra: {
            'homeRevision': home.remoteRevision,
            'localRevision': _localRevision,
            'lastAckedRevision': _lastAckedRevision,
          },
          force: true,
        );
        return;
      }
      _recentTracks = List<MusicTrack>.unmodifiable(home.recentTracks);
      _recentPlaylists = _normalizeRecentPlaylists(home.recentPlaylists);
      _likedTracks = List<MusicTrack>.unmodifiable(
        home.likedTracks.map(_normalizeTrackArtwork),
      );
      _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(
        home.customPlaylists,
      );
      _neteaseLikedPlaylistId = home.neteaseLikedPlaylistId?.trim();
      _neteaseLikedPlaylistOpaqueId = home.neteaseLikedPlaylistOpaqueId?.trim();
      _latestAiPlaylist = home.latestAiPlaylist ?? _latestAiPlaylist;
      _aiPlaylistHistory = List<MusicAiPlaylistDraft>.unmodifiable(
        home.aiPlaylistHistory,
      );
      final latestAiPlaylist = _latestAiPlaylist;
      if (latestAiPlaylist != null) {
        unawaited(_enrichLatestAiPlaylistInBackground(latestAiPlaylist));
      }
      _cacheKnownAiPlaylistTracks();
      _cacheTracksForPlaylist(likedPlaylist.id, _likedTracks);
      unawaited(_repairLatestAiPlaylistArtworkIfNeeded());
      unawaited(warmLikedPlaylist());
      _markSnapshotDirty();
      notifyListeners();
    } catch (error) {
      _debugState(
        'refresh.home.error',
        extra: {'error': error.toString()},
        force: true,
        level: 'ERROR',
      );
    }
  }

  Future<void> _applyRemotePlaylists(
    List<MusicPlaylist> remotePlaylists,
  ) async {
    final remoteLikedPlaylist = _findNeteaseLikedPlaylist(remotePlaylists);
    if (remoteLikedPlaylist != null) {
      _neteaseLikedPlaylistId = remoteLikedPlaylist.id;
      unawaited(
        _refreshRemoteLikedPlaylistInBackground(
          remoteLikedPlaylist,
          shouldSyncOpaqueId:
              (_neteaseLikedPlaylistOpaqueId ?? '').trim().isEmpty,
        ),
      );
    }
    final basePlaylists =
        remotePlaylists.isNotEmpty
            ? remotePlaylists
            : _playlists
                .where(
                  (item) =>
                      item.id != likedPlaylist.id &&
                      item.id != _latestAiPlaylist?.id,
                )
                .toList(growable: false);
    _rebuildPlaylists(basePlaylists: basePlaylists);
  }

  Future<void> _loadAndApplyRemotePlaylists() async {
    final remotePlaylists = await _repository.loadUserPlaylists();
    await _applyRemotePlaylists(remotePlaylists);
  }

  Future<void> _enrichLatestAiPlaylistInBackground(
    MusicAiPlaylistDraft playlist,
  ) async {
    try {
      final enriched = await _aiPlaylistEnricher.enrichTopTracks(
        playlist,
        limit: 3,
      );
      if (_latestAiPlaylist?.id != playlist.id) {
        return;
      }
      _latestAiPlaylist = enriched;
      _aiPlaylistHistory = List<MusicAiPlaylistDraft>.unmodifiable(
        _aiPlaylistHistory.where((item) => item.id != enriched.id),
      );
      _cacheKnownAiPlaylistTracks();
      _markSnapshotDirty();
      notifyListeners();
    } catch (_) {
      // best effort only
    }
  }

  Future<void> _refreshRemoteLikedPlaylistInBackground(
    MusicPlaylist playlist, {
    bool shouldSyncOpaqueId = false,
  }) async {
    try {
      if (shouldSyncOpaqueId) {
        _neteaseLikedPlaylistOpaqueId ??=
            await _repository.syncNeteaseFavoritePlaylistOpaqueId();
      }
      await _mergeRemoteLikedTracks(playlist);
      _markSnapshotDirty();
      notifyListeners();
    } catch (_) {
      // silent background refresh
    }
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
    this.customPlaylists = const [],
    this.currentPlaylistId,
    this.neteaseLikedPlaylistId,
    this.neteaseLikedPlaylistOpaqueId,
    this.latestAiPlaylist,
    this.aiPlaylistHistory = const [],
    this.serverUpdatedAt,
    this.remoteRevision = 0,
    this.isPlaying = false,
    this.position = Duration.zero,
  });

  final MusicTrack? currentTrack;
  final List<PlaybackQueueItem> queue;
  final List<MusicPlaylist> playlists;
  final List<MusicTrack> recentTracks;
  final List<MusicTrack> likedTracks;
  final List<MusicPlaylist> recentPlaylists;
  final List<CustomMusicPlaylist> customPlaylists;
  final String? currentPlaylistId;
  final String? neteaseLikedPlaylistId;
  final String? neteaseLikedPlaylistOpaqueId;
  final MusicAiPlaylistDraft? latestAiPlaylist;
  final List<MusicAiPlaylistDraft> aiPlaylistHistory;
  final DateTime? serverUpdatedAt;
  final int remoteRevision;
  final bool isPlaying;
  final Duration position;
}
