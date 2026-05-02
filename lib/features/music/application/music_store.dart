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
  List<CustomMusicPlaylist> _customPlaylists = const <CustomMusicPlaylist>[];
  List<MusicAiPlaylistDraft> _aiPlaylistHistory = const [];
  MusicAiPlaylistDraft? _latestAiPlaylist;
  final Map<String, List<MusicTrack>> _playlistTracksCache =
      <String, List<MusicTrack>>{};
  int _searchRequestSerial = 0;
  String? _activeSearchQuery;
  bool _isSearching = false;
  String? _searchError;
  List<MusicTrack> _searchResults = const [];
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
  String? _neteaseLikedPlaylistEncryptedId;
  bool _shuffleEnabled = false;
  MusicRepeatMode _repeatMode = MusicRepeatMode.off;
  MusicPlaylist? _intelligenceSourcePlaylist;
  String? _intelligenceLastAnchorTrackId;
  bool _isLoadingIntelligenceBatch = false;
  final Set<String> _recentIntelligenceTrackIds = <String>{};
  final Map<String, List<MusicTrack>> _intelligenceCache =
      <String, List<MusicTrack>>{};
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
  List<MusicPlaylist> get customPlaylistCards => List<MusicPlaylist>.unmodifiable(
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
  bool get hasPlaybackContext => _queue.isNotEmpty || _isPlaying;

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

  String? get currentLyricLine => _currentLyrics?.lineAt(_position)?.text.trim();

  String? get nextLyricLine => _currentLyrics?.nextLineAfter(_position)?.text.trim();

  String get miniPlayerSubtitle {
    final lyric = currentLyricLine;
    if ((lyric ?? '').trim().isNotEmpty) return lyric!.replaceAll('\n', ' · ');
    final fallback = '${_currentTrack.artist} · ${_currentTrack.album}'.trim();
    return fallback.isEmpty ? currentPlaybackSourceLabel : fallback;
  }

  String get currentPlaybackSourceLabel {
    final playlist = currentPlaylist;
    if (playlist != null) {
      if (isIntelligenceMode && _intelligenceSourcePlaylist != null) {
        return '心动模式 · 基于 ${_intelligenceSourcePlaylist!.title}';
      }
      if (playlist.id == likedPlaylist.id) return '来自 我喜欢的';
      if (playlist.isAiGenerated) return '来自 ${playlist.title}';
      return '来自 ${playlist.title}';
    }
    if (_latestAiPlaylist != null && _currentTrack.id == heroTrack.id) {
      return '来自 AI 最新歌单';
    }
    if (_queue.isNotEmpty) return '来自当前播放队列';
    return '还没有播放来源';
  }
  bool get hasPreviousTrack =>
      _playbackHistory.isNotEmpty || _position >= const Duration(seconds: 3);
  bool get hasNextTrack =>
      _queue.length > 1 ||
      (_repeatMode == MusicRepeatMode.one && _queue.isNotEmpty) ||
      (_repeatMode == MusicRepeatMode.all &&
          (_queue.isNotEmpty || _playbackHistory.isNotEmpty)) ||
      (_repeatMode == MusicRepeatMode.intelligence && _queue.isNotEmpty);

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
      _recentPlaylists = _normalizeRecentPlaylists(state.recentPlaylists);
      _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(state.customPlaylists);
      _currentPlaylistId = _normalizePlaylistId(state.currentPlaylistId);
      _neteaseLikedPlaylistId = state.neteaseLikedPlaylistId?.trim();
      _neteaseLikedPlaylistEncryptedId =
          state.neteaseLikedPlaylistEncryptedId?.trim();
      try {
        _latestAiPlaylist = await _repository.loadLatestAiPlaylist();
      } catch (error) {
        _debugState('refresh.latest_ai.error', extra: {
          'error': error.toString(),
        }, force: true, level: 'ERROR');
      }
      try {
        _aiPlaylistHistory = await _repository.loadAiPlaylistHistory();
      } catch (error) {
        _debugState('refresh.ai_history.error', extra: {
          'error': error.toString(),
        }, force: true, level: 'ERROR');
        _aiPlaylistHistory = const [];
      }
      _cacheKnownAiPlaylistTracks();
      final remotePlaylists = await _repository.loadUserPlaylists();
      final remoteLikedPlaylist = _findNeteaseLikedPlaylist(remotePlaylists);
      if (remoteLikedPlaylist != null) {
        _neteaseLikedPlaylistId = remoteLikedPlaylist.id;
        _neteaseLikedPlaylistEncryptedId ??=
            await _repository.syncNeteaseFavoritePlaylistEncryptedId();
        await _mergeRemoteLikedTracks(remoteLikedPlaylist);
      }
      final basePlaylists = remotePlaylists.isNotEmpty
          ? remotePlaylists
          : _playlists.where(
              (item) => item.id != likedPlaylist.id && item.id != _latestAiPlaylist?.id,
            ).toList(growable: false);
      _rebuildPlaylists(basePlaylists: basePlaylists);
      _currentTrack = _currentTrack.copyWith(
        isFavorite: isTrackLiked(_currentTrack.id),
      );
      unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
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
      _recentPlaylists = _normalizeRecentPlaylists(state.recentPlaylists);
      _likedTracks = List<MusicTrack>.unmodifiable(state.likedTracks);
      _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(state.customPlaylists);
      _currentPlaylistId = _normalizePlaylistId(state.currentPlaylistId);
      _neteaseLikedPlaylistId = state.neteaseLikedPlaylistId?.trim();
      _neteaseLikedPlaylistEncryptedId =
          state.neteaseLikedPlaylistEncryptedId?.trim();
      _currentTrack = _currentTrack.copyWith(
        isFavorite: isTrackLiked(_currentTrack.id),
      );
      try {
        _latestAiPlaylist = await _repository.loadLatestAiPlaylist();
      } catch (_) {
        _latestAiPlaylist = null;
      }
      try {
        _aiPlaylistHistory = await _repository.loadAiPlaylistHistory();
      } catch (_) {
        _aiPlaylistHistory = const [];
      }
      _cacheKnownAiPlaylistTracks();
      try {
        final remotePlaylists = await _repository.loadUserPlaylists();
        final remoteLikedPlaylist = _findNeteaseLikedPlaylist(remotePlaylists);
        if (remoteLikedPlaylist != null) {
          _neteaseLikedPlaylistId = remoteLikedPlaylist.id;
          _neteaseLikedPlaylistEncryptedId ??=
              await _repository.syncNeteaseFavoritePlaylistEncryptedId();
          await _mergeRemoteLikedTracks(remoteLikedPlaylist);
        }
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
      unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
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
    unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
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
    await ensureReady();
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
    unawaited(_savePlaybackSnapshot());
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
      final tracks = await loadPlaylistTracks(playlist);
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
      _error = _friendlyPlaylistLoadError(error, playlist);
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
              description: (_latestAiPlaylist!.updatedAt ?? _latestAiPlaylist!.createdAt) == null
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
    unawaited(_savePlaybackSnapshot());
  }

  Future<void> renameCustomPlaylist(
    String playlistId, {
    required String title,
    String? subtitle,
    String? description,
  }) async {
    final now = DateTime.now();
    _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(
      _customPlaylists.map((item) {
        if (item.id != playlistId) return item;
        return item.copyWith(
          title: title.trim(),
          subtitle: subtitle ?? item.subtitle,
          description: description ?? item.description,
          updatedAt: now,
        );
      }).toList(growable: false),
    );
    _rebuildPlaylists(basePlaylists: _playlists);
    notifyListeners();
    await _repository.saveCustomPlaylists(_customPlaylists);
    unawaited(_savePlaybackSnapshot());
  }

  Future<void> deleteCustomPlaylist(String playlistId) async {
    _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(
      _customPlaylists.where((item) => item.id != playlistId).toList(growable: false),
    );
    _recentPlaylists = List<MusicPlaylist>.unmodifiable(
      _recentPlaylists.where((item) => item.id != playlistId).toList(growable: false),
    );
    if (_currentPlaylistId == playlistId) {
      _currentPlaylistId = null;
    }
    _playlistTracksCache.remove(playlistId);
    _rebuildPlaylists(basePlaylists: _playlists);
    notifyListeners();
    await _repository.saveCustomPlaylists(_customPlaylists);
    unawaited(_savePlaybackSnapshot());
  }

  Future<bool> addTrackToCustomPlaylist(String playlistId, MusicTrack track) async {
    final now = DateTime.now();
    var added = false;
    _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(
      _customPlaylists.map((item) {
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
      }).toList(growable: false),
    );
    if (added) {
      _rebuildPlaylists(basePlaylists: _playlists);
      notifyListeners();
      await _repository.saveCustomPlaylists(_customPlaylists);
      unawaited(_savePlaybackSnapshot());
    }
    return added;
  }

  Future<void> removeTrackFromCustomPlaylist(String playlistId, String trackId) async {
    final now = DateTime.now();
    _customPlaylists = List<CustomMusicPlaylist>.unmodifiable(
      _customPlaylists.map((item) {
        if (item.id != playlistId) return item;
        final nextTracks = List<MusicTrack>.unmodifiable(
          item.tracks.where((track) => track.id != trackId).toList(growable: false),
        );
        _playlistTracksCache[playlistId] = nextTracks;
        return item.copyWith(tracks: nextTracks, updatedAt: now);
      }).toList(growable: false),
    );
    _rebuildPlaylists(basePlaylists: _playlists);
    notifyListeners();
    await _repository.saveCustomPlaylists(_customPlaylists);
    unawaited(_savePlaybackSnapshot());
  }

  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist) async {
    await ensureReady();
    if (playlist.id == likedPlaylist.id) {
      return _withFavoriteFlags(
        _likedTracks
            .map((track) => track.copyWith(isFavorite: true))
            .toList(growable: false),
      );
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
    try {
      final tracks = await _repository.loadPlaylistTracks(playlist);
      _cacheTracksForPlaylist(playlist.id, tracks);
      return _withFavoriteFlags(tracks);
    } catch (error) {
      final cachedTracks = _playlistTracksCache[playlist.id];
      if (cachedTracks != null && cachedTracks.isNotEmpty) {
        _debugState('playlist.load.cached_fallback', extra: {
          'playlistId': playlist.id,
          'playlistTitle': playlist.title,
          'trackCount': cachedTracks.length,
          'error': error.toString(),
        });
        return _withFavoriteFlags(cachedTracks);
      }
      rethrow;
    }
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
    final normalizedPlaylist = _normalizeAiPlaylistRef(
      playlist.copyWith(trackCount: tracks.length),
    );
    _cacheTracksForPlaylist(normalizedPlaylist.id, tracks);
    final nextRecentPlaylists = List<MusicPlaylist>.unmodifiable([
      normalizedPlaylist,
      ..._recentPlaylists.where((item) => item.id != normalizedPlaylist.id),
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
    _currentPlaylistId = normalizedPlaylist.id;
    _recentPlaylists = nextRecentPlaylists;
    notifyListeners();
    unawaited(_savePlaybackSnapshot());
  }

  bool isTrackLiked(String trackId) =>
      _likedTracks.any((item) => item.id == trackId);

  Future<void> toggleTrackLiked(MusicTrack track) async {
    await ensureReady();
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
      _debugState('liked.sync.error', extra: {
        'trackId': track.id,
        'liked': liked,
        'error': error.toString(),
      }, force: true, level: 'ERROR');
    }
    unawaited(_savePlaybackSnapshot());
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
    _recentSearches = List<String>.unmodifiable([
      keyword,
      ..._recentSearches.where((item) => item != keyword),
    ].take(8));
    _isSearching = true;
    _searchError = null;
    notifyListeners();
    try {
      final registry = (_resolver as MusicSourceResolverImpl).registry;
      final netease = registry.providerById('netease');
      final migu = registry.providerById('migu');
      final neteaseCandidates = await netease?.searchTracks(keyword) ?? const [];
      final miguCandidates = await migu?.searchTracks(keyword) ?? const [];
      if (requestSerial != _searchRequestSerial) {
        return;
      }
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
      if (requestSerial != _searchRequestSerial) {
        return;
      }
      _searchError = error.toString();
      _searchResults = const [];
      _debugState('search.error', extra: {
        'query': keyword,
        'error': error.toString(),
      }, force: true, level: 'ERROR');
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

  bool get canEnableIntelligenceMode => _resolveIntelligenceContext() != null;

  bool get canAttemptIntelligenceMode => _currentTrackProviderId() == 'netease';

  String? get intelligenceModeHint {
    if (isIntelligenceMode) {
      return '后续会根据当前歌曲自动续播相似内容';
    }
    if (!canAttemptIntelligenceMode) {
      return '心动模式仅支持当前有网易云音源的歌曲';
    }
    if (!canEnableIntelligenceMode) {
      return '当前歌曲有网易云音源，但需要从网易云歌单内开启心动模式';
    }
    return '当前歌曲可开启心动模式';
  }

  Future<void> enableIntelligenceMode() async {
    await ensureReady();
    final sourceTrackId = (_currentTrack.sourceTrackId ?? '').trim();
    _debugState('intelligence.enable.request', extra: {
      'trackId': _currentTrack.id,
      'title': _currentTrack.title,
      'providerId': _currentTrackProviderId(),
      'sourceTrackId': sourceTrackId,
      'encryptedSourceTrackId': _currentTrack.encryptedSourceTrackId,
      'neteaseLikedPlaylistId': _neteaseLikedPlaylistId,
      'neteaseLikedPlaylistEncryptedId': _neteaseLikedPlaylistEncryptedId,
    }, force: true);
    if (!canAttemptIntelligenceMode || sourceTrackId.isEmpty) {
      _error = '当前歌曲还没有网易云音源，暂时无法开启心动模式';
      _debugState('intelligence.enable.blocked_no_source', extra: {
        'providerId': _currentTrackProviderId(),
        'sourceTrackId': sourceTrackId,
      }, force: true, level: 'ERROR');
      notifyListeners();
      return;
    }
    final playlist = _resolveIntelligenceContext();
    if (playlist == null) {
      _error = '当前歌曲有网易云音源，但还缺少网易云歌单上下文，暂时无法开启心动模式';
      _debugState('intelligence.enable.blocked_no_context', extra: {
        'sourceTrackId': sourceTrackId,
        'encryptedSourceTrackId': _currentTrack.encryptedSourceTrackId,
        'neteaseLikedPlaylistId': _neteaseLikedPlaylistId,
        'neteaseLikedPlaylistEncryptedId': _neteaseLikedPlaylistEncryptedId,
      }, force: true, level: 'ERROR');
      notifyListeners();
      return;
    }
    _intelligenceSourcePlaylist = playlist;
    _intelligenceLastAnchorTrackId = sourceTrackId;
    _recentIntelligenceTrackIds
      ..clear()
      ..add(sourceTrackId);
    _repeatMode = MusicRepeatMode.intelligence;
    _debugState('intelligence.enable.ready', extra: {
      'sourceTrackId': sourceTrackId,
      'encryptedSourceTrackId': _currentTrack.encryptedSourceTrackId,
      'playlistId': playlist.id,
      'playlistTitle': playlist.title,
      'playlistTag': playlist.tag,
      'neteaseLikedPlaylistEncryptedId': _neteaseLikedPlaylistEncryptedId,
    }, force: true);
    notifyListeners();
    await _refreshIntelligenceQueue(startTrack: _currentTrack, keepCurrentTrack: true);
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
      final cacheKey = '${playlist.id}::${startTrack.sourceTrackId ?? startTrack.id}';
      List<MusicTrack> tracks = _intelligenceCache[cacheKey] ?? const <MusicTrack>[];
      _debugState('intelligence.queue.refresh.start', extra: {
        'playlistId': playlist.id,
        'playlistTitle': playlist.title,
        'seedTrackId': startTrack.id,
        'seedSourceTrackId': startTrack.sourceTrackId,
        'keepCurrentTrack': keepCurrentTrack,
        'cacheKey': cacheKey,
        'cacheHit': tracks.isNotEmpty,
      }, force: true);
      if (tracks.isEmpty) {
        tracks = await _repository.loadIntelligenceTracks(
          playlist: playlist,
          seedTrack: startTrack,
          startTrack: startTrack,
          fallbackEncryptedPlaylistId: _neteaseLikedPlaylistEncryptedId,
        );
        _intelligenceCache[cacheKey] = tracks;
        _debugState('intelligence.queue.fetch.done', extra: {
          'playlistId': playlist.id,
          'seedSourceTrackId': startTrack.sourceTrackId,
          'fetchedCount': tracks.length,
        }, force: true);
      }
      final filtered = <MusicTrack>[];
      for (final track in tracks) {
        final sourceId = (track.sourceTrackId ?? '').trim();
        if (sourceId.isNotEmpty && _recentIntelligenceTrackIds.contains(sourceId)) {
          continue;
        }
        if (_queue.any((item) => item.track.id == track.id)) {
          continue;
        }
        filtered.add(track.copyWith(isFavorite: isTrackLiked(track.id)));
      }
      if (filtered.isEmpty) {
        _error = '心动模式暂时没有拿到新的推荐歌曲';
        _debugState('intelligence.queue.empty', extra: {
          'playlistId': playlist.id,
          'rawCount': tracks.length,
          'queueLength': _queue.length,
          'recentIntelligenceCount': _recentIntelligenceTrackIds.length,
        }, force: true, level: 'ERROR');
        disableIntelligenceMode();
        return;
      }
      if (keepCurrentTrack) {
        final currentHead = _queue.isNotEmpty
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
      _debugState('intelligence.queue.ready', extra: {
        'playlistId': playlist.id,
        'addedCount': filtered.length,
        'queueLength': _queue.length,
        'recentIntelligenceCount': _recentIntelligenceTrackIds.length,
      }, force: true);
      notifyListeners();
      unawaited(_savePlaybackSnapshot());
    } catch (error) {
      _debugState('intelligence.queue.error', extra: {
        'playlistId': playlist.id,
        'seedTrackId': startTrack.id,
        'seedSourceTrackId': startTrack.sourceTrackId,
        'error': error.toString(),
      }, force: true, level: 'ERROR');
      _error = '心动模式加载失败，已退回普通播放';
      disableIntelligenceMode();
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
    await _refreshIntelligenceQueue(startTrack: lastTrack, keepCurrentTrack: false);
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
      _aiPlaylistHistory = await _repository.loadAiPlaylistHistory();
      _cacheKnownAiPlaylistTracks();
      _currentPlaylistId = _normalizePlaylistId(_currentPlaylistId);
      _rebuildPlaylists(basePlaylists: _playlists);
      _debugState('ai_playlist.refresh', extra: {
        'latestAiPlaylistId': _latestAiPlaylist?.id,
        'latestAiTrackCount': _latestAiPlaylist?.tracks.length ?? 0,
        'aiHistoryCount': _aiPlaylistHistory.length,
      }, force: true);
      unawaited(_savePlaybackSnapshot());
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
        if (canEnableIntelligenceMode) {
          unawaited(enableIntelligenceMode());
        } else {
          _repeatMode = MusicRepeatMode.off;
        }
        break;
      case MusicRepeatMode.intelligence:
        disableIntelligenceMode();
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
    final playlist = currentPlaylist;
    if (playlist != null && _providerIdForPlaylist(playlist.id) == 'netease') {
      return playlist;
    }
    if (_intelligenceSourcePlaylist != null &&
        _providerIdForPlaylist(_intelligenceSourcePlaylist!.id) == 'netease') {
      return _intelligenceSourcePlaylist;
    }
    if ((_neteaseLikedPlaylistId ?? '').trim().isNotEmpty) {
      return MusicPlaylist(
        id: _neteaseLikedPlaylistId!,
        title: '喜欢',
        subtitle: '网易云喜欢的歌曲',
        tag: 'LIKED',
        trackCount: _likedTracks.length,
        artworkTone: MusicArtworkTone.rose,
      );
    }
    for (final item in _recentPlaylists) {
      if (_providerIdForPlaylist(item.id) == 'netease') {
        final tracks = _playlistTracksCache[item.id] ?? const <MusicTrack>[];
        if (tracks.any((track) => track.id == _currentTrack.id)) {
          return item;
        }
      }
    }
    for (final item in _playlists) {
      if (_providerIdForPlaylist(item.id) == 'netease') {
        final tracks = _playlistTracksCache[item.id] ?? const <MusicTrack>[];
        if (tracks.any((track) => track.id == _currentTrack.id)) {
          return item;
        }
      }
    }
    return null;
  }

  bool _isSystemPlaylist(MusicPlaylist playlist) {
    return playlist.id == likedPlaylist.id ||
        playlist.isAiGenerated ||
        playlist.id.startsWith('ai-playlist:');
  }

  List<MusicPlaylist> _normalizeRecentPlaylists(List<MusicPlaylist> items) {
    final normalized = items.map(_normalizeAiPlaylistRef).toList(growable: false);
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
      _cacheTracksForPlaylist(likedPlaylist.id, _likedTracks);
    } catch (error) {
      _debugState('liked.remote_merge.error', extra: {
        'playlistId': playlist.id,
        'error': error.toString(),
      }, force: true, level: 'ERROR');
    }
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
    final providerId = (track.preferredSourceId ?? track.cachedPlayback?.providerId ?? '').trim();
    final sourceTrackId = (track.sourceTrackId ?? track.cachedPlayback?.sourceTrackId ?? '').trim();
    if (providerId.isNotEmpty && sourceTrackId.isNotEmpty) {
      return '$providerId::$sourceTrackId';
    }
    return track.id.trim();
  }

  String? _normalizePlaylistId(String? playlistId) {
    final trimmed = playlistId?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed == 'ai-playlist:latest') {
      return _latestAiPlaylist?.id ?? trimmed;
    }
    return trimmed;
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
        final skipped = await _skipFailedCurrentTrack(friendlyError, allowSkipOnFailure: allowSkipOnFailure);
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
        final skipped = await _skipFailedCurrentTrack(friendlyError, allowSkipOnFailure: allowSkipOnFailure);
        if (skipped) {
          return;
        }
        _isPlaying = false;
        _error = friendlyError;
        rethrow;
      }
    }
    _isPlaying = true;
    if (resetPosition) {
      _position = Duration.zero;
    }
    _duration = _currentTrack.duration;
    _error = null;
    unawaited(_loadLyricsForTrack(_currentTrack, forceRefresh: false));
  }

  Future<void> refreshCurrentLyrics() async {
    await _loadLyricsForTrack(_currentTrack, forceRefresh: true);
  }

  Future<void> _loadLyricsForTrack(MusicTrack track, {required bool forceRefresh}) async {
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
    final preferred = (track.preferredSourceId ?? track.cachedPlayback?.providerId ?? '').trim();
    final sourceTrackId = (track.sourceTrackId ?? track.cachedPlayback?.sourceTrackId ?? '').trim();
    if (preferred.isEmpty && sourceTrackId.isEmpty) {
      return track.id.trim();
    }
    return '$preferred::$sourceTrackId';
  }

  String _friendlyPlaylistLoadError(Object error, MusicPlaylist playlist) {
    final raw = error.toString().trim().replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '');
    if (raw.contains('这个歌单暂时没有可播放的歌曲')) {
      if (playlist.id.startsWith('ai-playlist:')) {
        return '这份 AI 歌单里暂时没有可播放的歌曲';
      }
      return raw;
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
    _debugState('playback.skip_failed_track', extra: {
      'trackId': failedTrack.id,
      'title': failedTrack.title,
      'error': friendlyError,
      'remainingQueue': _queue.length - 1,
    }, force: true, level: 'ERROR');
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
      customPlaylists: _customPlaylists,
      currentPlaylistId: _currentPlaylistId,
      neteaseLikedPlaylistId: _neteaseLikedPlaylistId,
      neteaseLikedPlaylistEncryptedId: _neteaseLikedPlaylistEncryptedId,
    );
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
    this.customPlaylists = const [],
    this.currentPlaylistId,
    this.neteaseLikedPlaylistId,
    this.neteaseLikedPlaylistEncryptedId,
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
  final String? neteaseLikedPlaylistEncryptedId;
  final bool isPlaying;
  final Duration position;
}
