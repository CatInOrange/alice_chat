import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/debug/native_debug_bridge.dart';
import '../../../core/openclaw/openclaw_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import 'background_music_action_bridge.dart';
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
import '../domain/music_action.dart';
import '../domain/music_command.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';

enum MusicRepeatMode { off, all, one, intelligence }

enum MusicPlaybackControlState { idle, starting, playing, paused, ended }

class MusicStore extends ChangeNotifier {
  static const String _downloadsPlaylistId = 'downloads-local';
  static const String _neteaseFmPlaylistId = 'netease-fm';
  static const int _neteaseFmBatchSize = 6;
  static const int _neteaseFmPrefetchThreshold = 5;
  static const int _neteaseFmPrefetchRetryLimit = 3;
  static const Duration _musicPlayHistoryMinimum = Duration(seconds: 30);
  static const Duration _eventReconnectBaseDelay = Duration(seconds: 1);
  static const Duration _eventReconnectMaxDelay = Duration(seconds: 8);

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
      title: '还没开始播放',
      artist: 'AliceChat 音乐',
      album: '等你按下这一首',
      duration: Duration.zero,
      category: '音乐还没响起',
      description: '连上你的音乐，或者先听听 AI 替你挑的歌',
      artworkTone: MusicArtworkTone.twilight,
    );
    _duration = _currentTrack.duration;
    _queue = const [];
    _configReady = reloadConfig();
    unawaited(BackgroundMusicActionBridge.instance.attach(this));
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
  Timer? _eventReconnectTimer;
  int? _lastEventSeq;
  int _eventReconnectAttempts = 0;

  bool _isReady = false;
  bool _isEventConnecting = false;
  bool _isPreparingPlayback = false;
  bool _isRefreshingLibrary = false;
  bool _isHydratingFromCache = false;
  bool _hasHydratedLocalCache = false;
  bool _hasHydratedLikedCache = false;
  String? _error;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _hasLocalPauseOverride = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  late MusicTrack _currentTrack;
  MusicTrack? _musicHistoryTrack;
  String? _musicHistoryPlaylistId;
  DateTime? _musicHistoryStartedAt;
  Duration _musicHistoryAccumulated = Duration.zero;
  Timer? _musicHistoryTimer;
  bool _musicHistoryRecorded = false;
  List<PlaybackQueueItem> _queue = const [];
  final List<MusicTrack> _playbackHistory = <MusicTrack>[];
  List<MusicPlaylist> _playlists = const [];
  List<MusicTrack> _recentTracks = const [];
  List<MusicPlaylist> _recentPlaylists = const [];
  List<MusicTrack> _likedTracks = const <MusicTrack>[];
  List<DownloadedTrackEntry> _downloadedTracks = const <DownloadedTrackEntry>[];
  List<CustomMusicPlaylist> _customPlaylists = const <CustomMusicPlaylist>[];
  List<MusicAiPlaylistDraft> _aiPlaylistHistory = const [];
  MusicAiPlaylistDraft? _latestAiPlaylist;
  final Map<String, List<MusicTrack>> _playlistTracksCache =
      <String, List<MusicTrack>>{};
  final Map<String, MusicTrack> _trackRegistryById = <String, MusicTrack>{};
  final Map<String, MusicTrack> _trackRegistryBySource = <String, MusicTrack>{};
  final Map<String, MusicTrack> _trackRegistryByFingerprint =
      <String, MusicTrack>{};
  final Set<String> _neteaseLikedTrackKeys = <String>{};
  final Set<String> _discardedNeteaseFmTrackKeys = <String>{};
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
  bool _isLoadingFmBatch = false;
  final Set<String> _recentIntelligenceTrackIds = <String>{};
  final Map<String, List<MusicTrack>> _intelligenceCache =
      <String, List<MusicTrack>>{};
  final Map<String, DateTime> _lastDebugLogAt = <String, DateTime>{};
  final Map<String, DateTime> _recentActionFingerprints = <String, DateTime>{};
  bool get isReady => _isReady;
  bool get isPreparingPlayback => _isPreparingPlayback;
  bool get isRefreshingLibrary => _isRefreshingLibrary;
  bool get isLoading => _isPreparingPlayback || _isRefreshingLibrary;
  bool get isHydratingFromCache => _isHydratingFromCache;
  String? get error => _error;
  MusicPlaybackControlState get playbackControlState {
    final adapterState = _playbackAdapter.state;
    final hasTrackContext =
        _currentTrack.id.trim().isNotEmpty || _queue.isNotEmpty;
    if (_hasLocalPauseOverride && hasTrackContext) {
      return MusicPlaybackControlState.paused;
    }
    if ((_isPreparingPlayback || _isBuffering || adapterState.isBuffering) &&
        !adapterState.completed) {
      return MusicPlaybackControlState.starting;
    }
    if (adapterState.completed && hasTrackContext) {
      return MusicPlaybackControlState.ended;
    }
    // Prefer the store's optimistic control state so the UI can react
    // immediately to pause/resume taps before the adapter event arrives.
    if (_isPlaying && !_isBuffering) {
      return MusicPlaybackControlState.playing;
    }
    if (hasTrackContext) {
      return MusicPlaybackControlState.paused;
    }
    if (adapterState.isPlaying && adapterState.currentSource != null) {
      return MusicPlaybackControlState.playing;
    }
    return MusicPlaybackControlState.idle;
  }

  bool get isPlaying =>
      playbackControlState == MusicPlaybackControlState.playing;
  bool get isBuffering =>
      playbackControlState == MusicPlaybackControlState.starting;
  bool get isStartingPlayback =>
      playbackControlState == MusicPlaybackControlState.starting;
  bool get isActivelyPlaying =>
      playbackControlState == MusicPlaybackControlState.playing;
  bool get isPlaybackBusy =>
      playbackControlState == MusicPlaybackControlState.starting;
  bool get hasCompletedCurrentTrack =>
      playbackControlState == MusicPlaybackControlState.ended;
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
  List<DownloadedTrackEntry> get downloadedTracks => _downloadedTracks;
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
  bool get isCurrentNeteaseFm {
    if (_currentPlaylistId == _neteaseFmPlaylistId) return true;
    if (currentPlaylist?.id == _neteaseFmPlaylistId) return true;
    final currentKey = _trackIdentityKey(_currentTrack).trim();
    if (currentKey.isEmpty) return false;
    final fmTracks = _playlistTracksCache[_neteaseFmPlaylistId];
    if (fmTracks == null || fmTracks.isEmpty) return false;
    return fmTracks.any((item) => _trackIdentityKey(item).trim() == currentKey);
  }

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
    if (playlistId == downloadsPlaylist.id) return downloadsPlaylist;
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
      if (playlist.id == likedPlaylist.id) return '所有心动过的歌，都在这里';
      if (playlist.id == downloadsPlaylist.id) return '这些歌已经安静躺在本地了';
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
    if (normalized == downloadsPlaylist.id) {
      return _currentPlaylistId == normalized;
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
    if (normalized == downloadsPlaylist.id) {
      return _currentPlaylistId == normalized && isActivelyPlaying;
    }
    return _currentPlaylistId == normalized && isActivelyPlaying;
  }

  void debugLikedPlaylistButtonState({
    required String source,
    bool? pendingAction,
    bool? widgetBusy,
    bool? widgetPlaying,
    bool? widgetActive,
  }) {
    _debugState(
      'liked_playlist.button_state',
      extra: {
        'source': source,
        'likedPlaylistId': likedPlaylist.id,
        'likedTrackCount': _likedTracks.length,
        'pendingAction': pendingAction,
        'widgetBusy': widgetBusy,
        'widgetPlaying': widgetPlaying,
        'widgetActive': widgetActive,
        'storePlaylistLoading': isPlaylistLoading(likedPlaylist.id),
        'storePlaylistPlaying': isPlaylistPlaying(likedPlaylist.id),
        'storePlaylistActive': isPlaylistActive(likedPlaylist.id),
      },
      force: true,
    );
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
    _eventReconnectTimer?.cancel();
    _eventReconnectTimer = null;
    _lastEventSeq = null;
    _eventReconnectAttempts = 0;
    _isEventConnecting = false;
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
    _ensureEventSubscription(reason: 'reload_config');
  }

  Future<void> handleAppResumed() async {
    await reconnectEvents(force: true, reason: 'app_resumed');
  }

  Future<void> reconnectEvents({
    bool force = false,
    String reason = 'manual',
  }) async {
    if (!force && (_eventsSub != null || _isEventConnecting)) {
      return;
    }
    _eventReconnectTimer?.cancel();
    _eventReconnectTimer = null;
    await _eventsSub?.cancel();
    _eventsSub = null;
    _isEventConnecting = true;
    _debugState(
      'events.reconnect',
      extra: {'reason': reason, 'lastEventSeq': _lastEventSeq},
      force: true,
    );
    notifyListeners();
    _ensureEventSubscription(reason: reason);
  }

  void _ensureEventSubscription({String reason = 'initial'}) {
    if (_eventsSub != null) return;
    _eventReconnectTimer?.cancel();
    _eventReconnectTimer = null;
    _isEventConnecting = true;
    _debugState(
      'events.connecting',
      extra: {'reason': reason, 'since': _lastEventSeq},
      force: true,
    );
    notifyListeners();
    _eventsSub = _eventClient
        .subscribeEvents(since: _lastEventSeq)
        .listen(
          (event) {
            _isEventConnecting = false;
            _handleBackendEvent(event);
          },
          onError: (Object error, StackTrace stackTrace) {
            _eventsSub = null;
            _isEventConnecting = false;
            _error = error.toString();
            _debugState(
              'events.onError',
              extra: {'error': error.toString(), 'lastEventSeq': _lastEventSeq},
              force: true,
              level: 'ERROR',
            );
            notifyListeners();
            _scheduleEventReconnect();
          },
          onDone: () {
            _eventsSub = null;
            _isEventConnecting = false;
            _debugState(
              'events.onDone',
              extra: {'lastEventSeq': _lastEventSeq},
              force: true,
            );
            notifyListeners();
            _scheduleEventReconnect();
          },
        );
  }

  void _scheduleEventReconnect() {
    if (_eventReconnectTimer != null) return;
    _eventReconnectAttempts += 1;
    final multiplier = 1 << (_eventReconnectAttempts - 1).clamp(0, 3);
    final delayMs = (_eventReconnectBaseDelay.inMilliseconds * multiplier)
        .clamp(
          _eventReconnectBaseDelay.inMilliseconds,
          _eventReconnectMaxDelay.inMilliseconds,
        );
    _debugState(
      'events.reconnect_scheduled',
      extra: {
        'attempt': _eventReconnectAttempts,
        'delayMs': delayMs,
        'lastEventSeq': _lastEventSeq,
      },
      force: true,
    );
    _eventReconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _eventReconnectTimer?.cancel();
      _eventReconnectTimer = null;
      _ensureEventSubscription(reason: 'scheduled_reconnect');
    });
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
      _duration = _currentTrack.duration;
      unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
      unawaited(_repairPlaybackArtworkIfNeeded());
      _isReady = true;
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
    _downloadedTracks = List<DownloadedTrackEntry>.unmodifiable(
      snapshot.downloadedTracks,
    );
    final state = snapshot.state;
    if (state.likedTracks.isNotEmpty) {
      _likedTracks = List<MusicTrack>.unmodifiable(
        state.likedTracks.map(_normalizeTrackArtwork),
      );
      _cacheTracksForPlaylist(likedPlaylist.id, _likedTracks);
    }
    _applyStateSnapshot(state, reason: 'hydrate_local_cache');
    _latestAiPlaylist =
        state.latestAiPlaylist ??
        snapshot.latestAiPlaylist ??
        _latestAiPlaylist;
    _aiPlaylistHistory = _normalizeAiPlaylistHistoryEntries(
      state.aiPlaylistHistory.isNotEmpty
          ? state.aiPlaylistHistory
          : snapshot.aiPlaylistHistory,
      latestId: _latestAiPlaylist?.id,
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
    if (_downloadedTracks.isNotEmpty) {
      _cacheTracksForPlaylist(
        downloadsPlaylist.id,
        _downloadedTracks.map((item) => item.track).toList(growable: false),
      );
    }
    _cacheKnownAiPlaylistTracks();
    _currentTrack = _currentTrack.copyWith(
      isFavorite: isTrackLiked(_currentTrack.id),
    );
    _rebuildPlaylists(basePlaylists: _playlists);
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
          playlist: currentPlaylist,
        ),
      );
      return;
    }
    await _playCurrentQueueHead(resetPosition: false);
    notifyListeners();
    _markSnapshotDirty();
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

  MusicPlaylist get downloadsPlaylist => MusicPlaylist(
    id: _downloadsPlaylistId,
    title: '已下载',
    subtitle: '明确保存到本机的歌曲',
    tag: 'OFFLINE',
    trackCount: _downloadedTracks.length,
    artworkTone: MusicArtworkTone.midnight,
  );

  bool isTrackDownloaded(String trackId) =>
      _downloadedTracks.any((item) => item.track.id == trackId);

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
    if (playlist.id == downloadsPlaylist.id) {
      _cacheTracksForPlaylist(playlist.id, immediateTracks);
      return immediateTracks;
    }
    if (playlist.id == 'netease-fm') {
      try {
        final tracks = await _loadNeteaseFmBatch(limit: _neteaseFmBatchSize);
        _cacheTracksForPlaylist(playlist.id, tracks);
        _markSnapshotDirty();
        return _withFavoriteFlags(tracks);
      } catch (firstError) {
        _debugState(
          'playlist.fm.retry',
          extra: {
            'playlistId': playlist.id,
            'attempt': 1,
            'limit': _neteaseFmBatchSize,
            'error': firstError.toString(),
          },
          force: true,
          level: 'ERROR',
        );
        try {
          final tracks = await _loadNeteaseFmBatch(limit: _neteaseFmBatchSize);
          _cacheTracksForPlaylist(playlist.id, tracks);
          _markSnapshotDirty();
          return _withFavoriteFlags(tracks);
        } catch (secondError) {
          _debugState(
            'playlist.fm.retry_failed',
            extra: {
              'playlistId': playlist.id,
              'attempt': 2,
              'limit': _neteaseFmBatchSize,
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
    if (playlist.id == 'netease-daily') {
      try {
        final tracks = await _repository.loadNeteaseDaily();
        _cacheTracksForPlaylist(playlist.id, tracks);
        _markSnapshotDirty();
        return _withFavoriteFlags(tracks);
      } catch (error) {
        _debugState(
          'playlist.daily.error',
          extra: {'playlistId': playlist.id, 'error': error.toString()},
          force: true,
          level: 'ERROR',
        );
        if (immediateTracks.isNotEmpty) {
          return immediateTracks;
        }
        rethrow;
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
    if (playlist.id == downloadsPlaylist.id) {
      return _withFavoriteFlags(
        _downloadedTracks.map((item) => item.track).toList(growable: false),
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
          playlist: normalizedPlaylist,
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
    _pauseMusicHistoryTracking(recordIfReady: true);
    _isPlaying = false;
    _isBuffering = false;
    _isPreparingPlayback = false;
  }

  void _applyQueuedPlaybackState(List<PlaybackQueueItem> queueItems) {
    if (queueItems.isEmpty) {
      throw StateError('当前没有可播放的歌曲');
    }
    final previousTrackId = _currentTrack.id.trim();
    if (queueItems.first.track.id.trim() != previousTrackId) {
      _finishMusicHistoryTracking(reason: 'queue_replaced');
    }
    _isPreparingPlayback = true;
    _isPlaying = false;
    _isBuffering = false;
    final normalizedQueue = queueItems
        .map(
          (item) => PlaybackQueueItem(
            track: _rememberTrack(
              item.track.copyWith(isFavorite: isTrackLiked(item.track.id)),
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
    _queue = _rememberQueueItems(normalizedQueue);
    _currentTrack = _queue.first.track;
    _duration = _currentTrack.duration;
    if (_currentTrack.id.trim() != previousTrackId) {
      _position = Duration.zero;
    }
    _playbackHistory.clear();
    _error = null;
  }

  void _applyCommandPlaylistContext(
    MusicPlaylist? playlist,
    List<PlaybackQueueItem> queueItems,
  ) {
    if (playlist == null) {
      _currentPlaylistId = null;
      return;
    }
    final tracks = queueItems.map((item) => item.track).toList(growable: false);
    final normalizedPlaylist = _normalizeAiPlaylistRef(
      playlist.copyWith(trackCount: tracks.length),
    );
    _cacheTracksForPlaylist(normalizedPlaylist.id, tracks);
    if (normalizedPlaylist.id != _neteaseFmPlaylistId) {
      _recentPlaylists = List<MusicPlaylist>.unmodifiable(
        [
          normalizedPlaylist,
          ..._recentPlaylists.where((item) => item.id != normalizedPlaylist.id),
        ].take(6),
      );
    }
    _currentPlaylistId = normalizedPlaylist.id;
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
    _likedTracks = _rememberTracks(nextLikedTracks, forceFavorite: true);
    _currentTrack =
        _currentTrack.id == track.id
            ? _rememberTrack(
              _currentTrack.copyWith(
                isFavorite: liked,
                cachedPlayback: cachedPlayback,
              ),
              forceFavorite: liked,
            )
            : _currentTrack;
    _queue = _rememberQueueItems(
      _queue.map(
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
      ),
    );
    _recentTracks = _rememberTracks(
      _recentTracks.map(
        (item) =>
            item.id == track.id
                ? item.copyWith(
                  isFavorite: liked,
                  cachedPlayback: cachedPlayback,
                )
                : item,
      ),
    );
    _cacheTracksForPlaylist(likedPlaylist.id, _likedTracks);
    _syncLikedTrackMirrors(nextTrack, liked);
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

  Future<void> queueTrackNext(MusicTrack track) async {
    final normalized = track.copyWith(isFavorite: isTrackLiked(track.id));
    if (_queue.isEmpty) {
      _queue = List<PlaybackQueueItem>.unmodifiable([
        PlaybackQueueItem(track: normalized),
      ]);
    } else {
      _queue = List<PlaybackQueueItem>.unmodifiable([
        _queue.first,
        PlaybackQueueItem(track: normalized),
        ..._queue.skip(1),
      ]);
    }
    notifyListeners();
    _markSnapshotDirty();
  }

  Future<void> appendTrackToQueue(MusicTrack track) async {
    final normalized = track.copyWith(isFavorite: isTrackLiked(track.id));
    _queue = List<PlaybackQueueItem>.unmodifiable([
      ..._queue,
      PlaybackQueueItem(track: normalized),
    ]);
    notifyListeners();
    _markSnapshotDirty();
  }

  Future<void> removeTrackFromQueueAt(int index) async {
    if (index <= 0 || index >= _queue.length) {
      return;
    }
    _queue = List<PlaybackQueueItem>.unmodifiable([
      ..._queue.take(index),
      ..._queue.skip(index + 1),
    ]);
    notifyListeners();
    _markSnapshotDirty();
  }

  Future<int> loadMoreForCurrentPlaylist() async {
    final playlist = currentPlaylist;
    if (playlist == null) return 0;
    return loadMoreForPlaylist(playlist);
  }

  Future<int> loadMoreForPlaylist(MusicPlaylist playlist) async {
    if (playlist.id != _neteaseFmPlaylistId) {
      return 0;
    }
    final incoming = await _loadNeteaseFmBatch(limit: _neteaseFmBatchSize);
    if (incoming.isEmpty) {
      return 0;
    }
    final existingKeys = <String>{};
    for (final track
        in (_playlistTracksCache[_neteaseFmPlaylistId] ??
            const <MusicTrack>[])) {
      final key = _trackIdentityKey(track).trim();
      if (key.isNotEmpty) {
        existingKeys.add(key);
      }
    }
    final merged = <MusicTrack>[
      ...(_playlistTracksCache[_neteaseFmPlaylistId] ?? const <MusicTrack>[]),
    ];
    var appended = 0;
    for (final track in incoming) {
      final key = _trackIdentityKey(track).trim();
      if (key.isEmpty || !existingKeys.add(key)) {
        continue;
      }
      merged.add(track.copyWith(isFavorite: isTrackLiked(track.id)));
      appended += 1;
    }
    if (appended == 0) {
      return 0;
    }
    _cacheTracksForPlaylist(_neteaseFmPlaylistId, merged);
    if (_currentPlaylistId == _neteaseFmPlaylistId) {
      for (final track in merged) {
        final key = _trackIdentityKey(track).trim();
        if (key.isEmpty ||
            _queue.any((item) => _trackIdentityKey(item.track).trim() == key) ||
            (_currentTrack.id.trim().isNotEmpty &&
                _trackIdentityKey(_currentTrack).trim() == key) ||
            _playbackHistory.any(
              (item) => _trackIdentityKey(item).trim() == key,
            )) {
          continue;
        }
        _queue = List<PlaybackQueueItem>.unmodifiable([
          ..._queue,
          PlaybackQueueItem(
            track: track.copyWith(isFavorite: isTrackLiked(track.id)),
          ),
        ]);
      }
    }
    notifyListeners();
    _markSnapshotDirty();
    return appended;
  }

  Future<void> discardCurrentFmTrack() async {
    if (_currentPlaylistId != _neteaseFmPlaylistId) {
      throw StateError('当前不是私人 FM，暂时没法减少推荐');
    }
    final current = _currentTrack;
    final sourceTrackId = (current.sourceTrackId ?? '').trim();
    if (sourceTrackId.isEmpty) {
      throw StateError('当前歌曲还没有网易云源 ID，暂时没法减少推荐');
    }
    await _repository.trashNeteaseFmTrack(current);
    final key = _trackIdentityKey(current).trim();
    if (key.isNotEmpty) {
      _discardedNeteaseFmTrackKeys.add(key);
    }
    _playlistTracksCache[_neteaseFmPlaylistId] = List<MusicTrack>.unmodifiable(
      (_playlistTracksCache[_neteaseFmPlaylistId] ?? const <MusicTrack>[])
          .where((item) => _trackIdentityKey(item).trim() != key)
          .toList(growable: false),
    );
    _queue = List<PlaybackQueueItem>.unmodifiable(
      _queue
          .where((item) => _trackIdentityKey(item.track).trim() != key)
          .toList(growable: false),
    );
    _playbackHistory.removeWhere(
      (item) => _trackIdentityKey(item).trim() == key,
    );
    notifyListeners();
    _markSnapshotDirty();
    await _advanceToNextTrack();
  }

  Future<void> downloadTrack(MusicTrack track) async {
    final existing = _downloadedTrackEntryForTrack(track);
    if (existing != null && await File(existing.localFilePath).exists()) {
      return;
    }
    final prepared = await _preparePlayback(track);
    final source = prepared.resolvedSource;
    if (source == null) {
      throw StateError('当前歌曲暂时还没有可下载的播放源');
    }
    final uri = Uri.parse(source.streamUrl);
    if (uri.scheme == 'file') {
      final entry = DownloadedTrackEntry(
        track: prepared.track.copyWith(
          isFavorite: isTrackLiked(prepared.track.id),
        ),
        localFilePath: uri.toFilePath(),
        mimeType: source.mimeType,
        downloadedAt: DateTime.now(),
      );
      _upsertDownloadedTrack(entry);
      return;
    }
    final file = await _downloadResolvedSource(prepared.track, source);
    final sizeBytes = await file.length();
    final entry = DownloadedTrackEntry(
      track: prepared.track.copyWith(
        isFavorite: isTrackLiked(prepared.track.id),
      ),
      localFilePath: file.path,
      mimeType: source.mimeType,
      fileSizeBytes: sizeBytes,
      downloadedAt: DateTime.now(),
    );
    _upsertDownloadedTrack(entry);
  }

  Future<void> removeDownloadedTrack(String trackId) async {
    final existing = _downloadedTrackEntryForTrackId(trackId);
    if (existing == null) {
      return;
    }
    try {
      final file = File(existing.localFilePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // best effort only
    }
    _downloadedTracks = List<DownloadedTrackEntry>.unmodifiable(
      _downloadedTracks
          .where((item) => item.track.id != trackId)
          .toList(growable: false),
    );
    final remaining = _downloadedTracks
        .map((item) => item.track)
        .toList(growable: false);
    if (remaining.isEmpty) {
      _playlistTracksCache.remove(downloadsPlaylist.id);
    } else {
      _cacheTracksForPlaylist(downloadsPlaylist.id, remaining);
    }
    _rebuildPlaylists(basePlaylists: _playlists);
    notifyListeners();
    _markSnapshotDirty();
  }

  DownloadedTrackEntry? _downloadedTrackEntryForTrack(MusicTrack track) {
    return _downloadedTrackEntryForTrackId(track.id);
  }

  DownloadedTrackEntry? _downloadedTrackEntryForTrackId(String trackId) {
    for (final item in _downloadedTracks) {
      if (item.track.id == trackId) {
        return item;
      }
    }
    return null;
  }

  void _upsertDownloadedTrack(DownloadedTrackEntry entry) {
    final next = <DownloadedTrackEntry>[
      entry,
      ..._downloadedTracks.where((item) => item.track.id != entry.track.id),
    ];
    _downloadedTracks = List<DownloadedTrackEntry>.unmodifiable(next);
    _cacheTracksForPlaylist(
      downloadsPlaylist.id,
      _downloadedTracks.map((item) => item.track).toList(growable: false),
    );
    _rebuildPlaylists(basePlaylists: _playlists);
    notifyListeners();
    _markSnapshotDirty();
  }

  void _syncLikedTrackMirrors(MusicTrack track, bool liked) {
    final key = _trackIdentityKey(track).trim();
    if (key.isNotEmpty) {
      if (liked) {
        _neteaseLikedTrackKeys.add(key);
      } else {
        _neteaseLikedTrackKeys.remove(key);
      }
    }
    final remoteLikedPlaylistId = (_neteaseLikedPlaylistId ?? '').trim();
    if (remoteLikedPlaylistId.isEmpty) {
      return;
    }
    final existing = List<MusicTrack>.from(
      _playlistTracksCache[remoteLikedPlaylistId] ?? const <MusicTrack>[],
    );
    existing.removeWhere(
      (item) => _trackIdentityKey(item).trim() == key || item.id == track.id,
    );
    if (liked) {
      existing.insert(0, track.copyWith(isFavorite: true));
    }
    if (existing.isEmpty) {
      _playlistTracksCache.remove(remoteLikedPlaylistId);
      return;
    }
    _cacheTracksForPlaylist(remoteLikedPlaylistId, existing);
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
    final controlState = playbackControlState;
    if (controlState == MusicPlaybackControlState.playing &&
        hasLocalPlaybackControl) {
      _hasLocalPauseOverride = true;
      _isPlaying = false;
      _isBuffering = false;
      _isPreparingPlayback = false;
      notifyListeners();
      try {
        await _playbackAdapter.pause();
      } catch (_) {
        _hasLocalPauseOverride = false;
        _isPlaying = true;
        notifyListeners();
        rethrow;
      }
      _pauseMusicHistoryTracking(recordIfReady: true);
      _markSnapshotDirty();
      return;
    }

    if (controlState == MusicPlaybackControlState.ended) {
      await _restartCurrentTrackAfterCompletion();
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
          playlist: currentPlaylist,
        ),
      );
      return;
    }

    final adapterState = _playbackAdapter.state;
    if (adapterState.currentSource != null &&
        hasLocalPlaybackControl &&
        controlState == MusicPlaybackControlState.paused) {
      _hasLocalPauseOverride = false;
      _isPlaying = true;
      _isPreparingPlayback = true;
      notifyListeners();
      try {
        await _playbackAdapter.resume();
      } catch (_) {
        _isPlaying = false;
        _isPreparingPlayback = false;
        notifyListeners();
        rethrow;
      }
      _resumeMusicHistoryTracking();
      _markSnapshotDirty();
      return;
    }

    await handleCommand(
      MusicCommand.play(
        queue: _queue,
        source: MusicCommandSource.manual,
        playlist: currentPlaylist,
      ),
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
    await _hydrateCurrentTrackFromPlaybackSourceIfNeeded();
    final providerId = _currentTrackProviderId();
    final sourceTrackId = _currentTrackResolvedSourceTrackId();
    _debugState(
      'intelligence.enable.request',
      extra: {
        'trackId': _currentTrack.id,
        'title': _currentTrack.title,
        'providerId': providerId,
        'sourceTrackId': sourceTrackId,
        'neteaseLikedPlaylistId': _neteaseLikedPlaylistId,
        'neteaseLikedPlaylistOpaqueId': _neteaseLikedPlaylistOpaqueId,
      },
      force: true,
    );
    if (providerId != 'netease' || sourceTrackId.isEmpty) {
      _repeatMode =
          originalMode == MusicRepeatMode.intelligence
              ? MusicRepeatMode.one
              : originalMode;
      _error = '当前歌曲还没有网易云音源，暂时无法开启心动模式';
      _debugState(
        'intelligence.enable.blocked_no_source',
        extra: {
          'providerId': providerId,
          'sourceTrackId': sourceTrackId,
          'cachedProviderId': _currentTrack.cachedPlayback?.providerId,
          'playbackSourceProviderId':
              _playbackAdapter.state.currentSource?.providerId,
          'playbackSourceTrackId':
              _playbackAdapter.state.currentSource?.sourceTrackId,
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
                  track: _rememberTrack(
                    item.track.copyWith(
                      isFavorite: isTrackLiked(item.track.id),
                    ),
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
          _queue = _rememberQueueItems(normalizedQueue);
          _currentTrack = _queue.first.track;
          _playbackHistory.clear();
          _applyCommandPlaylistContext(command.playlist, normalizedQueue);
        }
        if (_queue.isEmpty) {
          throw StateError('当前没有可播放的歌曲');
        }
        await _playCurrentQueueHead();
        break;
      case MusicCommandType.prependToQueue:
        if (command.queue.isNotEmpty) {
          final incoming = command.queue
              .map(
                (item) => PlaybackQueueItem(
                  track: _rememberTrack(
                    item.track.copyWith(
                      isFavorite: isTrackLiked(item.track.id),
                    ),
                  ),
                  candidate: item.candidate,
                  resolvedSource: item.resolvedSource,
                  requestedBy: item.requestedBy,
                ),
              )
              .toList(growable: false);
          _queue = _rememberQueueItems([
            if (_queue.isNotEmpty) _queue.first,
            ...incoming,
            if (_queue.isNotEmpty) ..._queue.skip(1),
          ]);
          if (_queue.isNotEmpty && _currentTrack.id.trim().isEmpty) {
            _currentTrack = _queue.first.track;
          }
        }
        break;
      case MusicCommandType.appendToQueue:
        if (command.queue.isNotEmpty) {
          _queue = _rememberQueueItems([
            ..._queue,
            ...command.queue.map(
              (item) => PlaybackQueueItem(
                track: _rememberTrack(
                  item.track.copyWith(isFavorite: isTrackLiked(item.track.id)),
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
        _hasLocalPauseOverride = true;
        await _playbackAdapter.pause();
        _pauseMusicHistoryTracking(recordIfReady: true);
        _isPlaying = false;
        _isBuffering = false;
        _isPreparingPlayback = false;
        break;
      case MusicCommandType.resume:
        if (hasCompletedCurrentTrack) {
          await _restartCurrentTrackAfterCompletion();
          return;
        }
        _hasLocalPauseOverride = false;
        _isPreparingPlayback = true;
        await _playbackAdapter.resume();
        _isPlaying = true;
        _resumeMusicHistoryTracking();
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

  Future<void> handleAction(MusicAction action) async {
    if (!_acceptAction(action)) {
      _debugState(
        'action.duplicate_ignored',
        extra: {'type': action.type.name, 'requestId': action.requestId},
      );
      return;
    }
    switch (action.type) {
      case MusicActionType.playTrack:
        final track = action.track;
        if (track == null) {
          throw StateError('缺少要播放的歌曲');
        }
        await handleCommand(
          MusicCommand(
            type: MusicCommandType.replaceQueue,
            source: action.source,
            queue: [PlaybackQueueItem(track: track)],
            playlist: action.playlist ?? action.playlistDraft?.asPlaylist,
            requestId: action.requestId,
          ),
        );
        return;
      case MusicActionType.playPlaylist:
        final playlistDraft = action.playlistDraft;
        final playlist = action.playlist ?? playlistDraft?.asPlaylist;
        if (playlist == null) {
          throw StateError('缺少要播放的歌单');
        }
        final tracks =
            playlistDraft?.tracks.isNotEmpty == true
                ? playlistDraft!.tracks
                : await loadPlaylistTracks(playlist);
        await playLoadedPlaylist(
          playlist,
          tracks,
          startIndex: action.startIndex,
        );
        return;
      case MusicActionType.queueNext:
        final tracks = action.tracks;
        if (tracks.isEmpty) {
          throw StateError('缺少要插队的歌曲');
        }
        await handleCommand(
          MusicCommand(
            type: MusicCommandType.prependToQueue,
            source: action.source,
            queue: tracks
                .map((track) => PlaybackQueueItem(track: track))
                .toList(growable: false),
            playlist: action.playlist ?? action.playlistDraft?.asPlaylist,
            requestId: action.requestId,
          ),
        );
        return;
      case MusicActionType.queueAppend:
        final tracks = action.tracks;
        if (tracks.isEmpty) {
          throw StateError('缺少要加入队列的歌曲');
        }
        await handleCommand(
          MusicCommand(
            type: MusicCommandType.appendToQueue,
            source: action.source,
            queue: tracks
                .map((track) => PlaybackQueueItem(track: track))
                .toList(growable: false),
            playlist: action.playlist ?? action.playlistDraft?.asPlaylist,
            requestId: action.requestId,
          ),
        );
        return;
      case MusicActionType.pauseResume:
        final shouldPause = switch (action.mode) {
          'pause' => true,
          'resume' => false,
          _ => _isPlaying,
        };
        await handleCommand(
          MusicCommand(
            type:
                shouldPause ? MusicCommandType.pause : MusicCommandType.resume,
            source: action.source,
            requestId: action.requestId,
          ),
        );
        return;
      case MusicActionType.skip:
        await handleCommand(
          MusicCommand(
            type: MusicCommandType.next,
            source: action.source,
            requestId: action.requestId,
          ),
        );
        return;
      case MusicActionType.saveAiPlaylist:
        return;
    }
  }

  Future<void> handleBackgroundAction(
    MusicAction action, {
    required String source,
  }) async {
    _debugState(
      'background_action.received',
      extra: {
        'bridgeSource': source,
        'type': action.type.name,
        'requestId': action.requestId,
        'payload': jsonEncode(action.payload),
      },
      force: true,
    );
    try {
      await handleAction(action);
      _debugState(
        'background_action.applied',
        extra: {
          'bridgeSource': source,
          'type': action.type.name,
          'requestId': action.requestId,
        },
        force: true,
      );
    } catch (error) {
      _debugState(
        'background_action.error',
        extra: {
          'bridgeSource': source,
          'type': action.type.name,
          'requestId': action.requestId,
          'error': error.toString(),
        },
        force: true,
        level: 'ERROR',
      );
      rethrow;
    }
  }

  void debugBackgroundActionBridgeError(
    String error, {
    String rawPayload = '',
  }) {
    _debugState(
      'background_action.bridge_error',
      extra: {'error': error, 'rawPayload': rawPayload},
      force: true,
      level: 'ERROR',
    );
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
      _aiPlaylistHistory = _normalizeAiPlaylistHistoryEntries(
        _aiPlaylistHistory,
        latestId: _latestAiPlaylist?.id,
      );
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
    final seqValue = event['seq'];
    if (seqValue is num) {
      final seq = seqValue.toInt();
      if (_lastEventSeq != null && seq <= _lastEventSeq!) {
        _debugState(
          'events.duplicate',
          extra: {'eventType': eventName, 'seq': seq},
          force: true,
        );
        return;
      }
      _lastEventSeq = seq;
      _eventReconnectAttempts = 0;
    }
    _debugState(
      'events.$eventName',
      extra: {
        'eventType': eventName,
        'seq': _lastEventSeq,
        'transportEvent': event['transportEvent'],
      },
      force: eventName == 'music.action' || eventName == 'music.command',
    );
    if (eventName == 'music.ai_playlist_updated') {
      unawaited(_refreshLatestAiPlaylist());
      return;
    }
    final payload = Map<String, dynamic>.from(event);
    if (eventName == 'music.state_changed') {
      _debugState(
        'events.state_changed.ignored',
        extra: {'seq': _lastEventSeq, 'eventType': eventName},
      );
      return;
    }
    if (eventName == 'music.command') {
      _dispatchMusicCommandEvent(payload);
      return;
    }
    if (eventName == 'music.action') {
      _dispatchMusicActionEvent(payload);
    }
  }

  void _dispatchMusicCommandEvent(Map<String, dynamic> payload) {
    try {
      final command = MusicCommand.fromMap(payload);
      unawaited(handleCommand(command));
    } catch (error) {
      _debugState(
        'events.command.parse_error',
        extra: {
          'error': error.toString(),
          'seq': _lastEventSeq,
          'eventType': payload['event'],
          'transportEvent': payload['transportEvent'],
        },
        force: true,
        level: 'ERROR',
      );
    }
  }

  void _dispatchMusicActionEvent(Map<String, dynamic> payload) {
    _debugState(
      'events.music_action.received',
      extra: {
        'actionType': payload['type'],
        'actionSource': payload['source'],
        'actionRequestId': payload['requestId'],
        'actionPayload': jsonEncode(payload['payload']),
        'seq': _lastEventSeq,
      },
      force: true,
    );
    try {
      final action = MusicAction.fromMap(payload);
      unawaited(handleAction(action));
    } catch (error) {
      _debugState(
        'events.action.parse_error',
        extra: {
          'error': error.toString(),
          'seq': _lastEventSeq,
          'eventType': payload['event'],
          'transportEvent': payload['transportEvent'],
        },
        force: true,
        level: 'ERROR',
      );
    }
  }

  void _handlePlaybackState(PlaybackAdapterState state) {
    final track = state.currentTrack;
    final expectedQueueHeadId =
        _queue.isNotEmpty
            ? _queue.first.track.id.trim()
            : _currentTrack.id.trim();
    final incomingTrackId = track?.id.trim() ?? '';
    final hasExpectedQueueHead = expectedQueueHeadId.isNotEmpty;
    final hasIncomingTrack = incomingTrackId.isNotEmpty;
    final incomingTrackMatchesQueueHead =
        !hasExpectedQueueHead ||
        !hasIncomingTrack ||
        incomingTrackId == expectedQueueHeadId;
    final shouldIgnoreIncomingTrack =
        hasExpectedQueueHead &&
        hasIncomingTrack &&
        incomingTrackId != expectedQueueHeadId;

    if (shouldIgnoreIncomingTrack) {
      _applyPlaybackAdapterState(state);
      _handlePlaybackCompletionIfNeeded(state);
      notifyListeners();
      return;
    }

    if (incomingTrackMatchesQueueHead) {
      _isPreparingPlayback = false;
    }
    if (track != null) {
      final previousTrackId = _currentTrack.id;
      if (previousTrackId.trim().isNotEmpty &&
          track.id.trim().isNotEmpty &&
          track.id != previousTrackId) {
        _finishMusicHistoryTracking(reason: 'adapter_track_changed');
      }
      _currentTrack = track.copyWith(isFavorite: isTrackLiked(track.id));
      if (_currentTrack.id != previousTrackId) {
        unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
      }
    }
    _applyPlaybackAdapterState(state);
    _handlePlaybackCompletionIfNeeded(state);
    notifyListeners();
  }

  void _applyPlaybackAdapterState(PlaybackAdapterState state) {
    if (state.error != null && state.error!.trim().isNotEmpty) {
      _error = state.error;
    }
    _duration = state.duration ?? _currentTrack.duration;
    if (state.completed) {
      _finishMusicHistoryTracking(reason: 'completed');
      _isPlaying = false;
      _isBuffering = false;
      _isPreparingPlayback = false;
      _position = _duration;
      return;
    }
    final adapterIsPlaying = state.isPlaying && state.currentSource != null;
    if (_hasLocalPauseOverride && adapterIsPlaying) {
      _isPlaying = false;
      _isBuffering = false;
      _isPreparingPlayback = false;
      _position = state.position;
      _pauseMusicHistoryTracking(recordIfReady: true);
      return;
    }
    if (_hasLocalPauseOverride && !adapterIsPlaying) {
      _hasLocalPauseOverride = false;
    }
    _isPlaying = adapterIsPlaying;
    _isBuffering = state.isBuffering;
    _position = state.position;
    if (adapterIsPlaying) {
      _resumeMusicHistoryTracking();
    } else {
      _pauseMusicHistoryTracking(recordIfReady: true);
    }
  }

  void _handlePlaybackCompletionIfNeeded(PlaybackAdapterState state) {
    if (!state.completed || _isAdvancingQueue) {
      return;
    }
    if (_queue.isNotEmpty) {
      unawaited(_advanceToNextTrack());
      return;
    }
    _finishPlaybackSession();
  }

  void _finishPlaybackSession() {
    _finishMusicHistoryTracking(reason: 'session_finished');
    _isPlaying = false;
    _isBuffering = false;
    _isPreparingPlayback = false;
    _position = _duration;
    _markSnapshotDirty();
  }

  void _resumeMusicHistoryTracking({bool resetForCurrentTrack = false}) {
    final trackId = _currentTrack.id.trim();
    if (trackId.isEmpty) {
      return;
    }
    final currentKey = _trackIdentityKey(_currentTrack).trim();
    final trackedKey =
        _musicHistoryTrack == null
            ? ''
            : _trackIdentityKey(_musicHistoryTrack!).trim();
    if (resetForCurrentTrack || trackedKey != currentKey) {
      _finishMusicHistoryTracking(reason: 'track_changed');
      _musicHistoryTrack = _currentTrack;
      _musicHistoryPlaylistId = _currentPlaylistId;
      _musicHistoryAccumulated = Duration.zero;
      _musicHistoryRecorded = false;
    }
    if (_musicHistoryRecorded || _musicHistoryStartedAt != null) {
      return;
    }
    _musicHistoryStartedAt = DateTime.now();
    _scheduleMusicHistoryTimer();
  }

  void _pauseMusicHistoryTracking({required bool recordIfReady}) {
    final startedAt = _musicHistoryStartedAt;
    if (startedAt == null) {
      if (recordIfReady) {
        _recordMusicHistoryIfReady(reason: 'paused');
      }
      return;
    }
    _musicHistoryAccumulated += DateTime.now().difference(startedAt);
    _musicHistoryStartedAt = null;
    _musicHistoryTimer?.cancel();
    _musicHistoryTimer = null;
    if (recordIfReady) {
      _recordMusicHistoryIfReady(reason: 'paused');
    }
  }

  void _finishMusicHistoryTracking({required String reason}) {
    _pauseMusicHistoryTracking(recordIfReady: true);
    _musicHistoryTrack = null;
    _musicHistoryPlaylistId = null;
    _musicHistoryAccumulated = Duration.zero;
    _musicHistoryRecorded = false;
    _musicHistoryTimer?.cancel();
    _musicHistoryTimer = null;
  }

  void _scheduleMusicHistoryTimer() {
    _musicHistoryTimer?.cancel();
    if (_musicHistoryRecorded) {
      return;
    }
    final remaining = _musicPlayHistoryMinimum - _musicHistoryAccumulated;
    _musicHistoryTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () => _recordMusicHistoryIfReady(reason: 'threshold_reached'),
    );
  }

  void _recordMusicHistoryIfReady({required String reason}) {
    if (_musicHistoryRecorded) {
      return;
    }
    final track = _musicHistoryTrack;
    if (track == null || track.id.trim().isEmpty) {
      return;
    }
    var listened = _musicHistoryAccumulated;
    final startedAt = _musicHistoryStartedAt;
    if (startedAt != null) {
      listened += DateTime.now().difference(startedAt);
    }
    if (listened < _musicPlayHistoryMinimum) {
      return;
    }
    _musicHistoryRecorded = true;
    _musicHistoryTimer?.cancel();
    _musicHistoryTimer = null;
    unawaited(
      _repository.recordMusicPlay(
        track: track,
        playlistId: _musicHistoryPlaylistId,
        position: listened,
      ),
    );
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
        if (_currentPlaylistId == 'netease-fm') {
          await _maybePrefetchNeteaseFmQueue();
        }
        if (_queue.length > 1) {
          // FM 预取成功后，直接继续走后续切歌逻辑。
        } else if (_repeatMode == MusicRepeatMode.all &&
            _playbackHistory.isNotEmpty) {
          _queue = List<PlaybackQueueItem>.unmodifiable([
            ..._queue,
            ..._playbackHistory.map((track) => PlaybackQueueItem(track: track)),
          ]);
          _playbackHistory.clear();
        } else {
          _finishPlaybackSession();
          return;
        }
      }
      _playbackHistory.add(_currentTrack);
      if (_repeatMode == MusicRepeatMode.intelligence) {
        unawaited(_maybePrefetchIntelligenceQueue());
      }
      if (_currentPlaylistId == 'netease-fm') {
        unawaited(_maybePrefetchNeteaseFmQueue());
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
    final downloadedEntry = _downloadedTrackEntryForTrack(normalizedTrack);
    if (downloadedEntry != null) {
      final file = File(downloadedEntry.localFilePath);
      if (await file.exists()) {
        final localPath = file.uri.toString();
        _debugState(
          'playback.prepare.downloaded',
          extra: {
            'trackId': normalizedTrack.id,
            'title': normalizedTrack.title,
            'localFilePath': downloadedEntry.localFilePath,
          },
        );
        return PlaybackQueueItem(
          track: normalizedTrack.copyWith(
            isFavorite: isTrackLiked(normalizedTrack.id),
          ),
          resolvedSource: ResolvedPlaybackSource(
            providerId: 'local-download',
            sourceTrackId:
                (normalizedTrack.sourceTrackId ??
                        downloadedEntry.track.sourceTrackId ??
                        normalizedTrack.id)
                    .trim(),
            streamUrl: localPath,
            artworkUrl: normalizedTrack.artworkUrl,
            mimeType: downloadedEntry.mimeType,
          ),
        );
      }
    }
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
        force: true,
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

  Future<void> cycleRepeatMode() async {
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
        await _hydrateCurrentTrackFromPlaybackSourceIfNeeded();
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
    if (seen.add(downloadsPlaylist.id)) {
      merged.add(downloadsPlaylist);
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
    final playbackSourceProviderId =
        (_playbackAdapter.state.currentSource?.providerId ?? '').trim();
    if (playbackSourceProviderId.isNotEmpty) {
      return playbackSourceProviderId;
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

  String _currentTrackResolvedSourceTrackId() {
    final sourceTrackId =
        (_currentTrack.sourceTrackId ??
                _currentTrack.cachedPlayback?.sourceTrackId ??
                '')
            .trim();
    if (sourceTrackId.isNotEmpty) {
      return sourceTrackId;
    }
    return (_playbackAdapter.state.currentSource?.sourceTrackId ?? '').trim();
  }

  Future<void> _hydrateCurrentTrackFromPlaybackSourceIfNeeded() async {
    final providerId = _currentTrackProviderId();
    final sourceTrackId = _currentTrackResolvedSourceTrackId();
    if (providerId == 'netease' && sourceTrackId.isNotEmpty) {
      return;
    }
    final playbackSource = _playbackAdapter.state.currentSource;
    if (playbackSource == null ||
        playbackSource.providerId.trim() != 'netease') {
      return;
    }
    final nextCachedPlayback = CachedPlaybackSource(
      providerId: playbackSource.providerId,
      sourceTrackId: playbackSource.sourceTrackId,
      streamUrl: playbackSource.streamUrl,
      artworkUrl: playbackSource.artworkUrl,
      mimeType: playbackSource.mimeType,
      headers: playbackSource.headers,
      expiresAt: playbackSource.expiresAt,
      resolvedAt: DateTime.now(),
    );
    _currentTrack = _currentTrack.copyWith(
      preferredSourceId:
          (_currentTrack.preferredSourceId ?? '').trim().isNotEmpty
              ? _currentTrack.preferredSourceId
              : playbackSource.providerId,
      sourceTrackId:
          (_currentTrack.sourceTrackId ?? '').trim().isNotEmpty
              ? _currentTrack.sourceTrackId
              : playbackSource.sourceTrackId,
      cachedPlayback: nextCachedPlayback,
    );
    _queue = List<PlaybackQueueItem>.unmodifiable(
      _queue
          .map(
            (item) =>
                item.track.id == _currentTrack.id
                    ? PlaybackQueueItem(
                      track: item.track.copyWith(
                        preferredSourceId:
                            (item.track.preferredSourceId ?? '')
                                    .trim()
                                    .isNotEmpty
                                ? item.track.preferredSourceId
                                : playbackSource.providerId,
                        sourceTrackId:
                            (item.track.sourceTrackId ?? '').trim().isNotEmpty
                                ? item.track.sourceTrackId
                                : playbackSource.sourceTrackId,
                        cachedPlayback: nextCachedPlayback,
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
                item.id == _currentTrack.id
                    ? item.copyWith(
                      preferredSourceId:
                          (item.preferredSourceId ?? '').trim().isNotEmpty
                              ? item.preferredSourceId
                              : playbackSource.providerId,
                      sourceTrackId:
                          (item.sourceTrackId ?? '').trim().isNotEmpty
                              ? item.sourceTrackId
                              : playbackSource.sourceTrackId,
                      cachedPlayback: nextCachedPlayback,
                    )
                    : item,
          )
          .toList(growable: false),
    );
    _debugState(
      'intelligence.enable.hydrated_from_playback_source',
      extra: {
        'trackId': _currentTrack.id,
        'providerId': playbackSource.providerId,
        'sourceTrackId': playbackSource.sourceTrackId,
      },
      force: true,
    );
    notifyListeners();
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
        playlist.id == downloadsPlaylist.id ||
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

  List<MusicAiPlaylistDraft> _normalizeAiPlaylistHistoryEntries(
    List<MusicAiPlaylistDraft> items, {
    String? latestId,
  }) {
    final excludedId = (latestId ?? _latestAiPlaylist?.id ?? '').trim();
    final seen = <String>{};
    final normalized = <MusicAiPlaylistDraft>[];
    for (final item in items) {
      final id = item.id.trim();
      if (id.isEmpty) continue;
      if (excludedId.isNotEmpty && id == excludedId) continue;
      if (!seen.add(id)) continue;
      normalized.add(item);
    }
    return List<MusicAiPlaylistDraft>.unmodifiable(normalized);
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

  String _trackSourceIdentityKey(MusicTrack track) {
    final providerId =
        (track.preferredSourceId ?? track.cachedPlayback?.providerId ?? '')
            .trim()
            .toLowerCase();
    final sourceTrackId =
        (track.sourceTrackId ?? track.cachedPlayback?.sourceTrackId ?? '')
            .trim()
            .toLowerCase();
    if (providerId.isEmpty || sourceTrackId.isEmpty) {
      return '';
    }
    return '$providerId::$sourceTrackId';
  }

  String _trackFingerprintKey(MusicTrack track) {
    String normalize(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

    final title = normalize(track.title);
    final artist = normalize(track.artist);
    final album = normalize(track.album);
    final durationBucket = track.duration.inSeconds;
    if (title.isEmpty && artist.isEmpty) {
      return track.id.trim().toLowerCase();
    }
    return '$title::$artist::$album::$durationBucket';
  }

  bool _tracksRepresentSameEntity(MusicTrack a, MusicTrack b) {
    final aSourceKey = _trackSourceIdentityKey(a);
    final bSourceKey = _trackSourceIdentityKey(b);
    if (aSourceKey.isNotEmpty && bSourceKey.isNotEmpty) {
      return aSourceKey == bSourceKey;
    }
    if (aSourceKey.isNotEmpty || bSourceKey.isNotEmpty) {
      return _trackFingerprintKey(a) == _trackFingerprintKey(b);
    }
    return _trackFingerprintKey(a) == _trackFingerprintKey(b);
  }

  MusicTrack? _findRememberedTrack(MusicTrack track) {
    final sourceKey = _trackSourceIdentityKey(track);
    if (sourceKey.isNotEmpty) {
      final bySource = _trackRegistryBySource[sourceKey];
      if (bySource != null) {
        return bySource;
      }
    }
    final fingerprintKey = _trackFingerprintKey(track);
    final byFingerprint = _trackRegistryByFingerprint[fingerprintKey];
    if (byFingerprint != null &&
        _tracksRepresentSameEntity(byFingerprint, track)) {
      return byFingerprint;
    }
    final idKey = track.id.trim();
    if (idKey.isEmpty) {
      return null;
    }
    final byId = _trackRegistryById[idKey];
    if (byId != null && _tracksRepresentSameEntity(byId, track)) {
      return byId;
    }
    return null;
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

    final currentSourceTrackId = _currentTrackResolvedSourceTrackId();
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

  int _artworkStrength(MusicTrack track) {
    final cachedArtwork = (track.cachedPlayback?.artworkUrl ?? '').trim();
    if (cachedArtwork.isNotEmpty) {
      return 3;
    }
    final directArtwork = (track.artworkUrl ?? '').trim();
    if (directArtwork.isNotEmpty) {
      final hasStableSource = _trackSourceIdentityKey(track).isNotEmpty;
      return hasStableSource ? 2 : 1;
    }
    return 0;
  }

  String? _pickArtworkUrl(MusicTrack base, MusicTrack candidate) {
    final baseArtwork = (base.artworkUrl ?? '').trim();
    final candidateArtwork = (candidate.artworkUrl ?? '').trim();
    if (candidateArtwork.isEmpty) {
      return base.artworkUrl;
    }
    if (baseArtwork.isEmpty) {
      return candidate.artworkUrl;
    }
    final sameEntity = _tracksRepresentSameEntity(base, candidate);
    final baseStrength = _artworkStrength(base);
    final candidateStrength = _artworkStrength(candidate);
    if (candidateStrength > baseStrength && sameEntity) {
      return candidate.artworkUrl;
    }
    if (candidateStrength == baseStrength &&
        sameEntity &&
        (base.cachedPlayback?.artworkUrl ?? '').trim().isEmpty) {
      return candidate.artworkUrl;
    }
    return base.artworkUrl;
  }

  CachedPlaybackSource? _pickCachedPlayback(
    MusicTrack base,
    MusicTrack candidate,
  ) {
    final candidateCached = candidate.cachedPlayback;
    if (candidateCached == null) {
      return base.cachedPlayback;
    }
    final hasUsefulCandidateData =
        (candidateCached.artworkUrl ?? '').trim().isNotEmpty ||
        candidateCached.streamUrl.trim().isNotEmpty;
    if (!hasUsefulCandidateData) {
      return base.cachedPlayback;
    }
    final baseCached = base.cachedPlayback;
    if (baseCached == null) {
      return candidateCached;
    }
    if (!_tracksRepresentSameEntity(base, candidate)) {
      return baseCached;
    }
    final candidateHasArtwork =
        (candidateCached.artworkUrl ?? '').trim().isNotEmpty;
    final baseHasArtwork = (baseCached.artworkUrl ?? '').trim().isNotEmpty;
    final candidateHasStream = candidateCached.streamUrl.trim().isNotEmpty;
    final baseHasStream = baseCached.streamUrl.trim().isNotEmpty;
    if ((candidateHasArtwork && !baseHasArtwork) ||
        (candidateHasStream && !baseHasStream)) {
      return candidateCached;
    }
    return baseCached;
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
      artworkUrl: _pickArtworkUrl(base, candidate),
      preferredSourceId:
          (candidate.preferredSourceId ?? '').trim().isNotEmpty
              ? candidate.preferredSourceId
              : base.preferredSourceId,
      sourceTrackId:
          (candidate.sourceTrackId ?? '').trim().isNotEmpty
              ? candidate.sourceTrackId
              : base.sourceTrackId,
      cachedPlayback: _pickCachedPlayback(base, candidate),
    );
  }

  MusicTrack _rememberTrack(MusicTrack track, {bool? forceFavorite}) {
    final normalized = _normalizeTrackArtwork(track);
    final existing = _findRememberedTrack(normalized);
    final merged =
        existing == null
            ? normalized
            : _preferRicherTrack(existing, normalized);
    final favorite =
        forceFavorite ??
        normalized.isFavorite ||
            (existing?.isFavorite ?? false) ||
            isTrackLiked(normalized.id);
    final canonical = merged.copyWith(isFavorite: favorite);
    final idKey = canonical.id.trim();
    if (idKey.isNotEmpty) {
      _trackRegistryById[idKey] = canonical;
    }
    final sourceKey = _trackSourceIdentityKey(canonical);
    if (sourceKey.isNotEmpty) {
      _trackRegistryBySource[sourceKey] = canonical;
    }
    final fingerprintKey = _trackFingerprintKey(canonical);
    if (fingerprintKey.isNotEmpty) {
      _trackRegistryByFingerprint[fingerprintKey] = canonical;
    }
    return canonical;
  }

  List<MusicTrack> _rememberTracks(
    Iterable<MusicTrack> tracks, {
    bool? forceFavorite,
  }) {
    return List<MusicTrack>.unmodifiable(
      tracks.map((item) => _rememberTrack(item, forceFavorite: forceFavorite)),
    );
  }

  PlaybackQueueItem _rememberQueueItem(PlaybackQueueItem item) {
    return item.copyWith(track: _rememberTrack(item.track));
  }

  List<PlaybackQueueItem> _rememberQueueItems(
    Iterable<PlaybackQueueItem> items,
  ) {
    return List<PlaybackQueueItem>.unmodifiable(items.map(_rememberQueueItem));
  }

  void _mergeTrackAcrossState(MusicTrack updatedTrack) {
    final normalized = _rememberTrack(updatedTrack);
    _currentTrack =
        _tracksRepresentSameEntity(_currentTrack, normalized)
            ? _preferRicherTrack(
              _currentTrack,
              normalized,
            ).copyWith(isFavorite: isTrackLiked(normalized.id))
            : _currentTrack;
    _queue = _rememberQueueItems(
      _queue.map(
        (item) =>
            _tracksRepresentSameEntity(item.track, normalized)
                ? item.copyWith(
                  track: _preferRicherTrack(
                    item.track,
                    normalized,
                  ).copyWith(isFavorite: isTrackLiked(normalized.id)),
                )
                : item,
      ),
    );
    _recentTracks = _rememberTracks(
      _recentTracks.map(
        (item) =>
            _tracksRepresentSameEntity(item, normalized)
                ? _preferRicherTrack(
                  item,
                  normalized,
                ).copyWith(isFavorite: isTrackLiked(normalized.id))
                : item,
      ),
    );
    _likedTracks = _rememberTracks(
      _likedTracks.map(
        (item) =>
            _tracksRepresentSameEntity(item, normalized)
                ? _preferRicherTrack(
                  item,
                  normalized,
                ).copyWith(isFavorite: true)
                : item,
      ),
      forceFavorite: true,
    );
    for (final entry in _playlistTracksCache.entries.toList(growable: false)) {
      final replaced = _rememberTracks(
        entry.value.map(
          (item) =>
              _tracksRepresentSameEntity(item, normalized)
                  ? _preferRicherTrack(
                    item,
                    normalized,
                  ).copyWith(isFavorite: isTrackLiked(normalized.id))
                  : item,
        ),
      );
      _playlistTracksCache[entry.key] = replaced;
    }
    if (_latestAiPlaylist != null) {
      final tracks = _rememberTracks(
        _latestAiPlaylist!.tracks.map(
          (item) =>
              _tracksRepresentSameEntity(item, normalized)
                  ? _preferRicherTrack(
                    item,
                    normalized,
                  ).copyWith(isFavorite: isTrackLiked(normalized.id))
                  : item,
        ),
      );
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
    int skipFailureCount = 0,
  }) async {
    final targetTrack =
        _queue.isNotEmpty
            ? _queue.first.track.copyWith(
              isFavorite: isTrackLiked(_queue.first.track.id),
            )
            : _currentTrack;
    final prepared = await _preparePlayback(targetTrack);
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
      if (!clearCachedPlaybackOnRetry || targetTrack.cachedPlayback == null) {
        final friendlyError = _friendlyPlaybackError(error);
        final skipped = await _skipFailedCurrentTrack(
          friendlyError,
          allowSkipOnFailure: allowSkipOnFailure,
          skipFailureCount: skipFailureCount,
        );
        if (skipped) {
          return;
        }
        _isPlaying = false;
        _error = friendlyError;
        rethrow;
      }
      final refreshed = await _preparePlayback(
        targetTrack.copyWith(cachedPlayback: null),
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
          skipFailureCount: skipFailureCount,
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
    _hasLocalPauseOverride = false;
    _isPlaying = true;
    if (resetPosition) {
      _position = Duration.zero;
    }
    _duration = _currentTrack.duration;
    _error = null;
    _resumeMusicHistoryTracking(resetForCurrentTrack: resetPosition);
    unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
    unawaited(_warmUpcomingQueueTracks());
    if (_currentPlaylistId == 'netease-fm') {
      unawaited(_maybePrefetchNeteaseFmQueue());
    }
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
    required int skipFailureCount,
  }) async {
    if (!allowSkipOnFailure) {
      return false;
    }
    if (_queue.length <= 1 && _currentPlaylistId == 'netease-fm') {
      await _maybePrefetchNeteaseFmQueue();
    }
    if (_queue.length <= 1) {
      return false;
    }
    final failedTrack = _currentTrack;
    final nextSkipFailureCount = skipFailureCount + 1;
    _debugState(
      'playback.skip_failed_track',
      extra: {
        'trackId': failedTrack.id,
        'title': failedTrack.title,
        'error': friendlyError,
        'remainingQueue': _queue.length - 1,
        'skipFailureCount': nextSkipFailureCount,
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
    if (nextSkipFailureCount >= 3) {
      _error = '《${failedTrack.title}》暂时无法播放，已尝试自动跳过；连续失败过多，请手动重试';
      notifyListeners();
      return false;
    }
    _error = '《${failedTrack.title}》暂时无法播放，已自动跳到下一首';
    notifyListeners();
    await _playCurrentQueueHead(
      resetPosition: true,
      clearCachedPlaybackOnRetry: true,
      allowSkipOnFailure: true,
      skipFailureCount: nextSkipFailureCount,
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

  Future<List<MusicTrack>> _loadNeteaseFmBatch({
    int limit = _neteaseFmBatchSize,
  }) async {
    final existingKeys = <String>{};
    void collect(Iterable<MusicTrack> tracks) {
      for (final track in tracks) {
        final key = _trackIdentityKey(track).trim();
        if (key.isNotEmpty) {
          existingKeys.add(key);
        }
      }
    }

    collect(_queue.map((item) => item.track));
    collect(_playbackHistory);
    if (_currentTrack.id.trim().isNotEmpty) {
      collect([_currentTrack]);
    }
    collect(_playlistTracksCache['netease-fm'] ?? const <MusicTrack>[]);
    existingKeys.addAll(_discardedNeteaseFmTrackKeys);

    final merged = <MusicTrack>[];
    final seen = <String>{...existingKeys};
    for (var attempt = 0; attempt < 3 && merged.length < limit; attempt++) {
      final requestLimit = max(1, limit - merged.length);
      final fetched = await _repository.loadNeteaseFmTracks(
        limit: requestLimit,
      );
      var addedThisRound = 0;
      for (final track in fetched) {
        final key = _trackIdentityKey(track).trim();
        if (key.isEmpty || !seen.add(key)) {
          continue;
        }
        merged.add(track);
        addedThisRound += 1;
        if (merged.length >= limit) {
          break;
        }
      }
      if (addedThisRound == 0) {
        break;
      }
    }
    _debugState(
      'playlist.fm.batch.done',
      extra: {
        'requestedLimit': limit,
        'resultCount': merged.length,
        'existingKeyCount': existingKeys.length,
      },
    );
    return List<MusicTrack>.unmodifiable(merged);
  }

  Future<void> _maybePrefetchNeteaseFmQueue() async {
    if (_currentPlaylistId != 'netease-fm' || _isLoadingFmBatch) {
      return;
    }
    if (_queue.length > _neteaseFmPrefetchThreshold) {
      return;
    }
    _isLoadingFmBatch = true;
    try {
      _debugState(
        'playlist.fm.prefetch.start',
        extra: {
          'queueLength': _queue.length,
          'historyLength': _playbackHistory.length,
          'currentTrackId': _currentTrack.id,
        },
      );
      var totalAppended = 0;
      for (
        var attempt = 1;
        attempt <= _neteaseFmPrefetchRetryLimit &&
            _queue.length <= _neteaseFmPrefetchThreshold;
        attempt++
      ) {
        final appendedCount = await _appendNeteaseFmPrefetchBatch(
          attempt: attempt,
          targetLimit: _neteaseFmBatchSize,
        );
        totalAppended += appendedCount;
        if (appendedCount == 0) {
          break;
        }
      }
      if (totalAppended == 0) {
        _debugState(
          'playlist.fm.prefetch.give_up',
          extra: {
            'queueLength': _queue.length,
            'historyLength': _playbackHistory.length,
            'currentTrackId': _currentTrack.id,
          },
          force: true,
          level: 'ERROR',
        );
        return;
      }
      _markSnapshotDirty();
      _debugState(
        'playlist.fm.prefetch.ready',
        extra: {'totalAppended': totalAppended, 'queueLength': _queue.length},
      );
      notifyListeners();
    } catch (error) {
      _debugState(
        'playlist.fm.prefetch.error',
        extra: {
          'queueLength': _queue.length,
          'historyLength': _playbackHistory.length,
          'currentTrackId': _currentTrack.id,
          'error': error.toString(),
        },
        force: true,
        level: 'ERROR',
      );
    } finally {
      _isLoadingFmBatch = false;
    }
  }

  Future<int> _appendNeteaseFmPrefetchBatch({
    required int attempt,
    required int targetLimit,
  }) async {
    final incoming = await _loadNeteaseFmBatch(limit: targetLimit);
    if (incoming.isEmpty) {
      _debugState(
        'playlist.fm.prefetch.empty',
        extra: {
          'attempt': attempt,
          'queueLength': _queue.length,
          'historyLength': _playbackHistory.length,
          'currentTrackId': _currentTrack.id,
        },
        force: true,
        level: 'ERROR',
      );
      return 0;
    }

    final existingKeys = <String>{};
    for (final item in _queue) {
      final key = _trackIdentityKey(item.track).trim();
      if (key.isNotEmpty) {
        existingKeys.add(key);
      }
    }

    final appended = <PlaybackQueueItem>[];
    for (final track in incoming) {
      final key = _trackIdentityKey(track).trim();
      if (key.isEmpty || !existingKeys.add(key)) {
        continue;
      }
      appended.add(
        PlaybackQueueItem(
          track: track.copyWith(isFavorite: isTrackLiked(track.id)),
        ),
      );
    }

    if (appended.isEmpty) {
      _debugState(
        'playlist.fm.prefetch.duplicate_only',
        extra: {
          'attempt': attempt,
          'queueLength': _queue.length,
          'incomingCount': incoming.length,
          'historyLength': _playbackHistory.length,
        },
        force: true,
        level: 'ERROR',
      );
      return 0;
    }

    _queue = List<PlaybackQueueItem>.unmodifiable([..._queue, ...appended]);
    final mergedPlaylistTracks = <MusicTrack>[
      ...(_playlistTracksCache['netease-fm'] ?? const <MusicTrack>[]),
      ...appended.map((item) => item.track),
    ];
    _cacheTracksForPlaylist('netease-fm', mergedPlaylistTracks);
    _debugState(
      'playlist.fm.prefetch.attempt_ready',
      extra: {
        'attempt': attempt,
        'appendedCount': appended.length,
        'queueLength': _queue.length,
      },
    );
    return appended.length;
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
      buildSnapshot: _buildLocalSnapshot,
      saveLocal: _repository.saveLocalCache,
    );
  }

  MusicLocalCacheSnapshot _buildLocalSnapshot() {
    return MusicLocalCacheSnapshot(
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
      downloadedTracks: _downloadedTracks,
      cachedAt: DateTime.now(),
    );
  }

  void _markSnapshotDirty() {
    _snapshotScheduler.markDirty();
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

  Future<File> _downloadResolvedSource(
    MusicTrack track,
    ResolvedPlaybackSource source,
  ) async {
    final directory = await getApplicationSupportDirectory();
    final root = Directory(p.join(directory.path, 'music_downloads'));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    final extension = _inferAudioExtension(source);
    final baseName = _sanitizeFileName(
      '${track.artist.isEmpty ? '未知歌手' : track.artist} - ${track.title.isEmpty ? track.id : track.title}',
    );
    final target = File(
      p.join(
        root.path,
        '$baseName-${track.id.hashCode.abs().toRadixString(16)}$extension',
      ),
    );
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(source.streamUrl));
      source.headers.forEach((key, value) {
        request.headers.set(key, value);
      });
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw StateError('下载失败，状态码 ${response.statusCode}');
      }
      final sink = target.openWrite();
      await response.pipe(sink);
      await sink.close();
      return target;
    } finally {
      client.close(force: true);
    }
  }

  String _inferAudioExtension(ResolvedPlaybackSource source) {
    final mime = (source.mimeType ?? '').toLowerCase().trim();
    if (mime.contains('flac')) return '.flac';
    if (mime.contains('aac')) return '.aac';
    if (mime.contains('ogg')) return '.ogg';
    if (mime.contains('wav')) return '.wav';
    if (mime.contains('mpeg') || mime.contains('mp3')) return '.mp3';
    final uri = Uri.tryParse(source.streamUrl);
    final path = uri?.path.toLowerCase() ?? '';
    final known = ['.mp3', '.flac', '.m4a', '.aac', '.ogg', '.wav'];
    for (final ext in known) {
      if (path.endsWith(ext)) {
        return ext;
      }
    }
    return '.mp3';
  }

  String _sanitizeFileName(String value) {
    return value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
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
      'lastEventSeq': _lastEventSeq,
      'eventConnecting': _isEventConnecting,
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
    BackgroundMusicActionBridge.instance.detach(this);
    _snapshotScheduler.dispose();
    _aiPlaylistEnricher.cancel();
    _warmupCoordinator.cancel();
    _eventReconnectTimer?.cancel();
    _musicHistoryTimer?.cancel();
    _eventsSub?.cancel();
    _playbackStateSub?.cancel();
    unawaited(_playbackAdapter.dispose());
    super.dispose();
  }

  bool _acceptAction(MusicAction action) {
    final now = DateTime.now();
    final staleBefore = now.subtract(const Duration(seconds: 8));
    _recentActionFingerprints.removeWhere(
      (_, timestamp) => timestamp.isBefore(staleBefore),
    );
    final fingerprint = _actionFingerprint(action);
    final previous = _recentActionFingerprints[fingerprint];
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 8)) {
      return false;
    }
    _recentActionFingerprints[fingerprint] = now;
    return true;
  }

  String _actionFingerprint(MusicAction action) {
    final requestId = action.requestId?.trim() ?? '';
    if (requestId.isNotEmpty) {
      return 'request:$requestId';
    }
    return '${action.type.name}:${jsonEncode(action.payload)}:${action.source.name}';
  }

  void _applyStateSnapshot(
    MusicStateSnapshot state, {
    String reason = 'unspecified',
  }) {
    final previousTrackId = _currentTrack.id.trim();
    final previousQueueHeadId =
        _queue.isNotEmpty ? _queue.first.track.id.trim() : '';
    final adapterTrackId = _playbackAdapter.state.currentTrack?.id.trim() ?? '';
    final adapterIsPlaying = _playbackAdapter.state.isPlaying;
    if (state.playlists.isNotEmpty) {
      _playlists = List<MusicPlaylist>.unmodifiable(state.playlists);
    }
    if (state.currentTrack != null) {
      final nextTrack = _rememberTrack(
        state.currentTrack!.copyWith(
          isFavorite: isTrackLiked(state.currentTrack!.id),
        ),
      );
      final previousTrackId = _currentTrack.id;
      _currentTrack = nextTrack;
      if (_currentTrack.id != previousTrackId) {
        unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
      }
      _duration = _currentTrack.duration;
    }
    if (state.queue.isNotEmpty || previousQueueHeadId.isNotEmpty) {
      _queue = _rememberQueueItems(
        state.queue.map(
          (item) => item.copyWith(
            track: _rememberTrack(
              item.track.copyWith(isFavorite: isTrackLiked(item.track.id)),
            ),
          ),
        ),
      );
    }
    _isPlaying = state.isPlaying;
    _position = state.position;
    if (state.currentTrack != null &&
        state.position > state.currentTrack!.duration) {
      _position = state.currentTrack!.duration;
    }
    _isPreparingPlayback = false;
    _recentTracks = _rememberTracks(state.recentTracks);
    _recentPlaylists = _normalizeRecentPlaylists(state.recentPlaylists);
    _likedTracks = _rememberTracks(
      state.likedTracks.map(_normalizeTrackArtwork),
      forceFavorite: true,
    );
    _cacheTracksForPlaylist(likedPlaylist.id, _likedTracks);
    _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(
      state.customPlaylists,
    );
    final nextCurrentPlaylistId = _normalizePlaylistId(state.currentPlaylistId);
    if (nextCurrentPlaylistId != null) {
      _currentPlaylistId = nextCurrentPlaylistId;
    } else {
      _currentPlaylistId = null;
    }
    _neteaseLikedPlaylistId = state.neteaseLikedPlaylistId?.trim();
    _neteaseLikedPlaylistOpaqueId = state.neteaseLikedPlaylistOpaqueId?.trim();
    _latestAiPlaylist = state.latestAiPlaylist ?? _latestAiPlaylist;
    _aiPlaylistHistory = _normalizeAiPlaylistHistoryEntries(
      state.aiPlaylistHistory,
      latestId: _latestAiPlaylist?.id,
    );
    _cacheKnownAiPlaylistTracks();
    _debugState(
      'state.snapshot.applied',
      extra: {
        'reason': reason,
        'trackId': _currentTrack.id,
        'queueLength': _queue.length,
        'isPlaying': _isPlaying,
        'positionMs': _position.inMilliseconds,
      },
      force: reason.startsWith('event_'),
    );
    _maybeRecoverPlaybackFromRemoteState(
      state,
      allowStaleOverride: true,
      previousTrackId: previousTrackId,
      previousQueueHeadId: previousQueueHeadId,
      adapterTrackId: adapterTrackId,
      adapterIsPlaying: adapterIsPlaying,
    );
  }

  void _maybeRecoverPlaybackFromRemoteState(
    MusicStateSnapshot state, {
    required bool allowStaleOverride,
    required String previousTrackId,
    required String previousQueueHeadId,
    required String adapterTrackId,
    required bool adapterIsPlaying,
  }) {
    if (!allowStaleOverride || !state.isPlaying) {
      return;
    }
    final targetTrackId =
        state.currentTrack?.id.trim().isNotEmpty == true
            ? state.currentTrack!.id.trim()
            : (_queue.isNotEmpty ? _queue.first.track.id.trim() : '');
    final queueHeadId = _queue.isNotEmpty ? _queue.first.track.id.trim() : '';
    if (targetTrackId.isEmpty ||
        queueHeadId.isEmpty ||
        queueHeadId != targetTrackId) {
      return;
    }
    final trackChanged =
        previousTrackId != targetTrackId || previousQueueHeadId != queueHeadId;
    final adapterMismatch = adapterTrackId != targetTrackId;
    final shouldRecover = !adapterIsPlaying || trackChanged || adapterMismatch;
    if (!shouldRecover) {
      return;
    }
    _debugState(
      'state.reconcile.recover_playback',
      extra: {
        'targetTrackId': targetTrackId,
        'previousTrackId': previousTrackId,
        'previousQueueHeadId': previousQueueHeadId,
        'adapterTrackId': adapterTrackId,
        'adapterIsPlaying': adapterIsPlaying,
      },
      force: true,
    );
    unawaited(
      _recoverPlaybackFromRemoteState(
        targetTrackId: targetTrackId,
        targetPosition: state.position,
      ),
    );
  }

  Future<void> _recoverPlaybackFromRemoteState({
    required String targetTrackId,
    required Duration targetPosition,
  }) async {
    try {
      await ensurePlaybackReady();
      if (_queue.isEmpty || _queue.first.track.id.trim() != targetTrackId) {
        return;
      }
      await _playCurrentQueueHead(resetPosition: true);
      if (targetPosition > Duration.zero) {
        await seekTo(targetPosition);
      }
      _debugState(
        'state.reconcile.recover_playback.applied',
        extra: {
          'targetTrackId': targetTrackId,
          'targetPositionMs': targetPosition.inMilliseconds,
        },
        force: true,
      );
    } catch (error) {
      _debugState(
        'state.reconcile.recover_playback.error',
        extra: {
          'targetTrackId': targetTrackId,
          'targetPositionMs': targetPosition.inMilliseconds,
          'error': error.toString(),
        },
        force: true,
        level: 'ERROR',
      );
    }
  }

  Future<void> _refreshHomeSections() async {
    try {
      final home = await _repository.loadMusicHome();
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
      _aiPlaylistHistory = _normalizeAiPlaylistHistoryEntries(
        home.aiPlaylistHistory,
        latestId: _latestAiPlaylist?.id,
      );
      final latestAiPlaylist = _latestAiPlaylist;
      if (latestAiPlaylist != null) {
        unawaited(_enrichLatestAiPlaylistInBackground(latestAiPlaylist));
      }
      _cacheKnownAiPlaylistTracks();
      _cacheTracksForPlaylist(likedPlaylist.id, _likedTracks);
      unawaited(_repairLatestAiPlaylistArtworkIfNeeded());
      unawaited(warmLikedPlaylist());
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
      _aiPlaylistHistory = _normalizeAiPlaylistHistoryEntries(
        _aiPlaylistHistory,
        latestId: enriched.id,
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
