import 'dart:async';

import '../../../core/debug/native_debug_bridge.dart';
import '../../../core/openclaw/openclaw_client.dart';
import '../application/music_store.dart';
import '../domain/music_home_models.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';
import 'music_local_cache_store.dart';
import 'music_repository.dart';
import 'sources/music_source_provider.dart';
import 'sources/music_source_resolver.dart';
import 'sources/music_source_resolver_impl.dart';

class MusicRepositoryImpl implements MusicRepository {
  MusicRepositoryImpl({
    required OpenClawClient client,
    required MusicSourceResolver resolver,
    MusicLocalCacheStore? localCacheStore,
  }) : _client = client,
       _resolver = resolver,
       _localCacheStore = localCacheStore ?? MusicLocalCacheStore();

  final OpenClawClient _client;
  final MusicSourceResolver _resolver;
  final MusicLocalCacheStore _localCacheStore;

  @override
  Future<MusicLocalCacheSnapshot?> loadLocalCache() {
    return _localCacheStore.load();
  }

  @override
  Future<void> saveLocalCache(MusicLocalCacheSnapshot snapshot) {
    return _localCacheStore.save(snapshot);
  }

  @override
  Future<MusicStateSnapshot> loadMusicState() async {
    try {
      final response = await _client.getMusicState();
      return _parseMusicStateSnapshot(response);
    } catch (error) {
      await _debugLog('repository.loadMusicState.error', {
        'error': error.toString(),
      });
      rethrow;
    }
  }

  @override
  Future<MusicHomeBundle> loadMusicHome() async {
    final response = await _client.getMusicHome();
    final latestAiPlaylistMap =
        (response['latestAiPlaylist'] as Map?)?.cast<String, dynamic>();
    final aiPlaylistHistory =
        ((response['aiPlaylistHistory'] as List<dynamic>?) ?? const [])
            .whereType<Map>()
            .map(
              (item) => MusicAiPlaylistDraft.fromMap(
                Map<String, dynamic>.from(item.cast<String, dynamic>()),
              ),
            )
            .toList(growable: false);
    final recentTracks = ((response['recentTracks'] as List<dynamic>?) ??
            const [])
        .whereType<Map>()
        .map(
          (item) => MusicTrack.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final recentPlaylists = ((response['recentPlaylists'] as List<dynamic>?) ??
            const [])
        .whereType<Map>()
        .map(
          (item) => MusicPlaylist.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final likedTracks = ((response['likedTracks'] as List<dynamic>?) ??
            const [])
        .whereType<Map>()
        .map(
          (item) => MusicTrack.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final customPlaylists = ((response['customPlaylists'] as List<dynamic>?) ??
            const [])
        .whereType<Map>()
        .map(
          (item) => CustomMusicPlaylist.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final updatedAtRaw = response['updatedAt'];
    final updatedAtSeconds =
        updatedAtRaw is num
            ? updatedAtRaw.toDouble()
            : double.tryParse('$updatedAtRaw');
    return MusicHomeBundle(
      latestAiPlaylist:
          latestAiPlaylistMap == null
              ? null
              : MusicAiPlaylistDraft.fromMap(latestAiPlaylistMap),
      aiPlaylistHistory: aiPlaylistHistory,
      recentTracks: recentTracks,
      recentPlaylists: recentPlaylists,
      likedTracks: likedTracks,
      customPlaylists: customPlaylists,
      neteaseLikedPlaylistId:
          (response['neteaseLikedPlaylistId'] ?? '').toString().trim().isEmpty
              ? null
              : (response['neteaseLikedPlaylistId'] ?? '').toString().trim(),
      neteaseLikedPlaylistEncryptedId:
          (response['neteaseLikedPlaylistEncryptedId'] ?? '')
                  .toString()
                  .trim()
                  .isEmpty
              ? null
              : (response['neteaseLikedPlaylistEncryptedId'] ?? '')
                  .toString()
                  .trim(),
      serverUpdatedAt:
          updatedAtSeconds == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                (updatedAtSeconds * 1000).round(),
              ),
    );
  }

  @override
  Future<PlaybackQueueItem> resolveTrack(
    MusicTrack track, {
    bool allowFallback = true,
  }) async {
    return _resolver.resolveTrack(track, allowFallback: allowFallback);
  }

  @override
  Future<MusicTrack> enrichTrackMetadata(
    MusicTrack track, {
    bool allowFallback = true,
  }) async {
    MusicTrack nextTrack = _normalizeTrackArtwork(track);
    final hadArtwork = _hasArtwork(nextTrack);
    try {
      final candidate = await _resolver.matchTrack(
        nextTrack,
        allowFallback: allowFallback,
      );
      if (candidate != null) {
        nextTrack = _normalizeTrackArtwork(
          nextTrack.copyWith(
            preferredSourceId: candidate.providerId,
            sourceTrackId: candidate.sourceTrackId,
            encryptedSourceTrackId:
                candidate.track.encryptedSourceTrackId ??
                nextTrack.encryptedSourceTrackId,
            artworkUrl: candidate.track.artworkUrl ?? nextTrack.artworkUrl,
            album:
                candidate.track.album.isNotEmpty
                    ? candidate.track.album
                    : nextTrack.album,
            duration:
                candidate.track.duration.inMilliseconds > 0
                    ? candidate.track.duration
                    : nextTrack.duration,
          ),
        );
      }
      final hasArtwork = _hasArtwork(nextTrack);
      await _debugLog('repository.enrichTrackMetadata.done', {
        'trackId': track.id,
        'title': track.title,
        'artist': track.artist,
        'preferredSourceIdBefore': track.preferredSourceId,
        'preferredSourceIdAfter': nextTrack.preferredSourceId,
        'sourceTrackIdBefore': track.sourceTrackId,
        'sourceTrackIdAfter': nextTrack.sourceTrackId,
        'hadArtwork': hadArtwork,
        'hasArtwork': hasArtwork,
        'matched': candidate != null,
        'artworkUrl': nextTrack.artworkUrl ?? '',
        'artworkSource': _artworkSourceLabel(nextTrack),
      });
      if (!hasArtwork) {
        await _debugLog('repository.enrichTrackMetadata.no_artwork', {
          'trackId': track.id,
          'title': track.title,
          'artist': track.artist,
          'preferredSourceId': nextTrack.preferredSourceId,
          'sourceTrackId': nextTrack.sourceTrackId,
          'matched': candidate != null,
        });
      }
      return nextTrack;
    } catch (error) {
      await _debugLog('repository.enrichTrackMetadata.error', {
        'trackId': track.id,
        'title': track.title,
        'artist': track.artist,
        'preferredSourceId': track.preferredSourceId,
        'sourceTrackId': track.sourceTrackId,
        'error': error.toString(),
      });
      return nextTrack;
    }
  }

  @override
  Future<List<MusicPlaylist>> loadUserPlaylists() async {
    final registry = (_resolver as MusicSourceResolverImpl).registry;
    final providers = registry.providers.toList(growable: false);
    final loaded = await Future.wait(
      providers.map((provider) async {
        try {
          return await provider.loadUserPlaylists();
        } catch (error) {
          await _debugLog('repository.loadUserPlaylists.error', {
            'providerId': provider.id,
            'error': error.toString(),
          });
          return const <MusicPlaylist>[];
        }
      }),
    );
    final results = <MusicPlaylist>[];
    final seen = <String>{};
    for (final playlists in loaded) {
      for (final playlist in playlists) {
        if (seen.add(playlist.id)) {
          results.add(playlist);
        }
      }
    }
    return results;
  }

  @override
  Future<MusicAiPlaylistDraft?> loadLatestAiPlaylist() async {
    final response = await _client.getLatestAiPlaylist();
    final playlistMap = (response['playlist'] as Map?)?.cast<String, dynamic>();
    if (playlistMap == null) {
      return null;
    }
    return _parseLatestAiPlaylistDraft(playlistMap);
  }

  @override
  Future<List<MusicAiPlaylistDraft>> loadAiPlaylistHistory() async {
    final response = await _client.getAiPlaylistHistory();
    final raw = (response['playlists'] as List<dynamic>?) ?? const [];
    return raw
        .whereType<Map>()
        .map(
          (item) => MusicAiPlaylistDraft.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<MusicTrack>> loadLikedTracks() async {
    final response = await _client.getMusicState();
    final likedTracks = ((response['likedTracks'] as List<dynamic>?) ??
            const [])
        .whereType<Map>()
        .map(
          (item) => MusicTrack.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    return likedTracks;
  }

  @override
  Future<List<CustomMusicPlaylist>> loadCustomPlaylists() async {
    final response = await _client.getMusicState();
    return ((response['customPlaylists'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map(
          (item) => CustomMusicPlaylist.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> saveCustomPlaylists(List<CustomMusicPlaylist> playlists) async {
    await _client.saveMusicState(
      payload: {
        'customPlaylists': playlists
            .map((item) => item.toMap())
            .toList(growable: false),
      },
    );
  }

  @override
  Future<String?> syncNeteaseFavoritePlaylistEncryptedId() async {
    try {
      final response = await _client.syncNeteaseFavoritePlaylist();
      final playlist =
          (response['playlist'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final encryptedId = (playlist['id'] ?? '').toString().trim();
      return encryptedId.isEmpty ? null : encryptedId;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<MusicTrack>> loadNeteaseFmTracks({int limit = 20}) async {
    final safeLimit = limit.clamp(1, 20);
    final response = await _client.getNeteaseFm(limit: safeLimit);
    final rawTracks = (response['tracks'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (item) => MusicTrack.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    await _debugLog('repository.loadNeteaseFmTracks.done', {
      'limit': safeLimit,
      'trackCount': rawTracks.length,
      'firstTrackTitle': rawTracks.isEmpty ? '' : rawTracks.first.title,
    });
    return rawTracks;
  }

  @override
  Future<void> setTrackLiked(MusicTrack track, bool liked) async {
    final current = await loadLikedTracks();
    final filtered = current
        .where((item) => item.id != track.id)
        .toList(growable: true);
    if (liked) {
      filtered.insert(0, track.copyWith(isFavorite: true));
    }
    await _client.saveMusicState(
      payload: {'likedTracks': filtered.map((item) => item.toMap()).toList()},
    );

    final provider = _providerForTrack(track);
    if (provider == null) {
      return;
    }
    try {
      final synced = await provider.setTrackLiked(track, liked);
      await _debugLog('repository.setTrackLiked.sync', {
        'providerId': provider.id,
        'trackId': track.id,
        'liked': liked,
        'synced': synced,
      });
    } catch (error) {
      await _debugLog('repository.setTrackLiked.sync.error', {
        'providerId': provider.id,
        'trackId': track.id,
        'liked': liked,
        'error': error.toString(),
      });
    }
  }

  @override
  Future<MusicLyrics?> loadLyrics(MusicTrack track) async {
    final provider = _providerForTrack(track);
    if (provider == null) return null;
    try {
      return await provider.loadLyrics(track);
    } catch (error) {
      await _debugLog('repository.loadLyrics.error', {
        'providerId': provider.id,
        'trackId': track.id,
        'error': error.toString(),
      });
      return null;
    }
  }

  @override
  Future<List<MusicTrack>> loadIntelligenceTracks({
    required MusicPlaylist playlist,
    required MusicTrack seedTrack,
    MusicTrack? startTrack,
    String? fallbackEncryptedPlaylistId,
  }) async {
    final providerId = _providerIdForPlaylist(playlist.id);
    if (providerId != 'netease') {
      return const <MusicTrack>[];
    }
    final sourceTrackId = (seedTrack.sourceTrackId ?? '').trim();
    final encryptedSongId = (seedTrack.encryptedSourceTrackId ?? '').trim();
    final encryptedPlaylistId = _encryptedPlaylistIdFor(playlist.id);
    final effectiveEncryptedPlaylistId =
        fallbackEncryptedPlaylistId?.trim().isNotEmpty == true
            ? fallbackEncryptedPlaylistId!.trim()
            : encryptedPlaylistId;
    if (sourceTrackId.isEmpty && encryptedSongId.isEmpty) {
      return const <MusicTrack>[];
    }

    Future<List<MusicTrack>> attempt(int attempt) async {
      await _debugLog('repository.loadIntelligenceTracks.request', {
        'providerId': providerId,
        'playlistId': playlist.id,
        'seedTrackId': seedTrack.id,
        'songId': sourceTrackId,
        'encryptedSongId': encryptedSongId,
        'encryptedPlaylistId': encryptedPlaylistId,
        'effectiveEncryptedPlaylistId': effectiveEncryptedPlaylistId,
        'fallbackEncryptedPlaylistId': fallbackEncryptedPlaylistId,
        'attempt': attempt,
      });
      final response = await _client.requestNeteaseIntelligence(
        payload: {
          'song': {
            'providerId': 'netease',
            'trackId': seedTrack.id,
            'title': seedTrack.title,
            'artist': seedTrack.artist,
            if (sourceTrackId.isNotEmpty) 'sourceTrackId': sourceTrackId,
            if (encryptedSongId.isNotEmpty)
              'encryptedSourceTrackId': encryptedSongId,
          },
          'playlist': {
            'providerId': 'netease',
            'playlistId': playlist.id,
            'title': playlist.title,
            if (_playlistOriginalIdFor(playlist.id).isNotEmpty)
              'sourcePlaylistId': _playlistOriginalIdFor(playlist.id),
            if (effectiveEncryptedPlaylistId.isNotEmpty)
              'encryptedPlaylistId': effectiveEncryptedPlaylistId,
          },
          'count': 20,
          'mode': 'fromPlayAll',
        },
      );
      final rawTracks = (response['tracks'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (item) => MusicTrack.fromMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            ),
          )
          .toList(growable: false);
      final context =
          (response['context'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      await _debugLog('repository.loadIntelligenceTracks.done', {
        'providerId': providerId,
        'playlistId': playlist.id,
        'seedTrackId': seedTrack.id,
        'trackCount': rawTracks.length,
        'fallbackUsed': context['fallbackUsed'],
        'contextPlaylistEncryptedId': context['playlistEncryptedId'],
        'attempt': attempt,
      });
      return rawTracks;
    }

    Object? lastError;
    for (var attemptIndex = 1; attemptIndex <= 1; attemptIndex++) {
      try {
        return await attempt(attemptIndex);
      } catch (error) {
        lastError = error;
        await _debugLog('repository.loadIntelligenceTracks.error', {
          'providerId': providerId,
          'playlistId': playlist.id,
          'seedTrackId': seedTrack.id,
          'songId': sourceTrackId,
          'encryptedSongId': encryptedSongId,
          'attempt': attemptIndex,
          'willRetry': false,
          'error': error.toString(),
        });
      }
    }

    throw Exception('网易云心动模式请求失败，请稍后重试：${lastError ?? 'unknown error'}');
  }

  @override
  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist) async {
    final providerId = _providerIdForPlaylist(playlist.id);
    if (playlist.id == 'liked-local') {
      return loadLikedTracks();
    }
    if (playlist.id == 'netease-fm') {
      return loadNeteaseFmTracks();
    }
    if (playlist.id.startsWith('ai-playlist:')) {
      if (playlist.id == 'ai-playlist:latest') {
        final latest = await loadLatestAiPlaylist();
        if (latest != null) {
          return latest.tracks;
        }
        return const <MusicTrack>[];
      }
      final history = await loadAiPlaylistHistory();
      final matched = history
          .where((item) => item.id == playlist.id)
          .cast<MusicAiPlaylistDraft?>()
          .firstWhere((item) => item != null, orElse: () => null);
      return matched?.tracks ?? const <MusicTrack>[];
    }
    if (providerId == null) {
      return const <MusicTrack>[];
    }
    final provider = (_resolver as MusicSourceResolverImpl).registry
        .providerById(providerId);
    final tracks =
        await provider?.loadPlaylistTracks(playlist.id) ?? const <MusicTrack>[];
    await _debugLog('repository.loadPlaylistTracks', {
      'playlistId': playlist.id,
      'providerId': providerId,
      'trackCount': tracks.length,
    });
    return tracks;
  }

  @override
  Future<DateTime?> savePlaybackSnapshot({
    required MusicTrack currentTrack,
    required List<PlaybackQueueItem> queue,
    required bool isPlaying,
    required Duration position,
    List<MusicTrack>? likedTracks,
    List<MusicPlaylist>? recentPlaylists,
    List<CustomMusicPlaylist>? customPlaylists,
    String? currentPlaylistId,
    String? neteaseLikedPlaylistId,
    String? neteaseLikedPlaylistEncryptedId,
    int? localRevision,
  }) async {
    try {
      final response = await _client.saveMusicState(
        payload: {
          'currentTrack': currentTrack.toMap(),
          'queue': queue.map((item) => item.toMap()).toList(),
          'isPlaying': isPlaying,
          'positionMs': position.inMilliseconds,
          if (likedTracks != null)
            'likedTracks': likedTracks.map((item) => item.toMap()).toList(),
          if (recentPlaylists != null)
            'recentPlaylists':
                recentPlaylists.map((item) => item.toMap()).toList(),
          if (customPlaylists != null)
            'customPlaylists':
                customPlaylists.map((item) => item.toMap()).toList(),
          if (currentPlaylistId != null) 'currentPlaylistId': currentPlaylistId,
          if (neteaseLikedPlaylistId != null)
            'neteaseLikedPlaylistId': neteaseLikedPlaylistId,
          if (neteaseLikedPlaylistEncryptedId != null)
            'neteaseLikedPlaylistEncryptedId': neteaseLikedPlaylistEncryptedId,
          if (localRevision != null) 'localRevision': localRevision,
        },
      );
      final updatedAtRaw = response['updatedAt'];
      if (updatedAtRaw is num) {
        return DateTime.fromMillisecondsSinceEpoch(
          (updatedAtRaw.toDouble() * 1000).round(),
        );
      }
      final updatedAtSeconds = double.tryParse('${response['updatedAt']}');
      if (updatedAtSeconds == null) {
        return null;
      }
      return DateTime.fromMillisecondsSinceEpoch(
        (updatedAtSeconds * 1000).round(),
      );
    } catch (_) {
      return null;
    }
  }

  MusicSourceProvider? _providerForTrack(MusicTrack track) {
    final registry = (_resolver as MusicSourceResolverImpl).registry;
    final preferred = track.preferredSourceId?.trim();
    if (preferred != null && preferred.isNotEmpty) {
      return registry.providerById(preferred);
    }
    if ((track.sourceTrackId ?? '').trim().isNotEmpty &&
        track.id.contains(':')) {
      return registry.providerById(track.id.split(':').first);
    }
    return registry.providerById('netease');
  }

  String? _providerIdForPlaylist(String playlistId) {
    if (playlistId.startsWith('netease-playlist:')) return 'netease';
    if (playlistId.startsWith('migu-playlist:')) return 'migu';
    return null;
  }

  String _playlistOriginalIdFor(String playlistId) {
    if (playlistId.startsWith('netease-playlist:enc:')) {
      return '';
    }
    if (playlistId.startsWith('netease-playlist:')) {
      return playlistId.substring('netease-playlist:'.length).trim();
    }
    return '';
  }

  String _encryptedPlaylistIdFor(String playlistId) {
    if (!playlistId.startsWith('netease-playlist:enc:')) {
      return '';
    }
    final raw = playlistId.substring('netease-playlist:enc:'.length).trim();
    final looksEncrypted =
        raw.length >= 16 &&
        RegExp(r'^[0-9A-Fa-f]+$').hasMatch(raw) &&
        !RegExp(r'^\d+$').hasMatch(raw);
    return looksEncrypted ? raw.toUpperCase() : '';
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

  String _artworkSourceLabel(MusicTrack track) {
    final cached = _normalizeArtworkUrl(track.cachedPlayback?.artworkUrl);
    if (cached.isNotEmpty) return 'cachedPlayback';
    final direct = _normalizeArtworkUrl(track.artworkUrl);
    if (direct.isNotEmpty) return 'track.artworkUrl';
    return 'none';
  }

  MusicStateSnapshot _parseMusicStateSnapshot(Map<String, dynamic> response) {
    final currentTrackMap =
        (response['currentTrack'] as Map?)?.cast<String, dynamic>();
    final queue = ((response['queue'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map(
          (item) => PlaybackQueueItem.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final playlists = ((response['playlists'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map(
          (item) => MusicPlaylist.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final recentTracks = ((response['recentTracks'] as List<dynamic>?) ??
            const [])
        .whereType<Map>()
        .map(
          (item) => MusicTrack.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final likedTracks = ((response['likedTracks'] as List<dynamic>?) ??
            const [])
        .whereType<Map>()
        .map(
          (item) => MusicTrack.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final recentPlaylists = ((response['recentPlaylists'] as List<dynamic>?) ??
            const [])
        .whereType<Map>()
        .map(
          (item) => MusicPlaylist.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final customPlaylists = ((response['customPlaylists'] as List<dynamic>?) ??
            const [])
        .whereType<Map>()
        .map(
          (item) => CustomMusicPlaylist.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
    final currentPlaylistId =
        (response['currentPlaylistId'] ?? '').toString().trim();
    final neteaseLikedPlaylistId =
        (response['neteaseLikedPlaylistId'] ?? '').toString().trim();
    final neteaseLikedPlaylistEncryptedId =
        (response['neteaseLikedPlaylistEncryptedId'] ?? '').toString().trim();
    final latestAiPlaylistMap =
        (response['latestAiPlaylist'] as Map?)?.cast<String, dynamic>();
    final aiPlaylistHistory =
        ((response['aiPlaylistHistory'] as List<dynamic>?) ?? const [])
            .whereType<Map>()
            .map(
              (item) => MusicAiPlaylistDraft.fromMap(
                Map<String, dynamic>.from(item.cast<String, dynamic>()),
              ),
            )
            .toList(growable: false);
    final positionMsRaw = response['positionMs'] ?? 0;
    return MusicStateSnapshot(
      currentTrack:
          currentTrackMap == null ? null : MusicTrack.fromMap(currentTrackMap),
      queue: queue,
      playlists: playlists,
      recentTracks: recentTracks,
      likedTracks: likedTracks,
      recentPlaylists: recentPlaylists,
      customPlaylists: customPlaylists,
      currentPlaylistId: currentPlaylistId.isEmpty ? null : currentPlaylistId,
      neteaseLikedPlaylistId:
          neteaseLikedPlaylistId.isEmpty ? null : neteaseLikedPlaylistId,
      neteaseLikedPlaylistEncryptedId:
          neteaseLikedPlaylistEncryptedId.isEmpty
              ? null
              : neteaseLikedPlaylistEncryptedId,
      latestAiPlaylist:
          latestAiPlaylistMap == null
              ? null
              : MusicAiPlaylistDraft.fromMap(latestAiPlaylistMap),
      aiPlaylistHistory: aiPlaylistHistory,
      serverUpdatedAt: _parseUpdatedAt(response['updatedAt']),
      remoteRevision:
          (response['localRevision'] is num)
              ? (response['localRevision'] as num).toInt()
              : int.tryParse('${response['localRevision']}') ?? 0,
      isPlaying: response['isPlaying'] == true,
      position: Duration(
        milliseconds:
            positionMsRaw is num
                ? positionMsRaw.toInt()
                : int.tryParse('$positionMsRaw') ?? 0,
      ),
    );
  }

  DateTime? _parseUpdatedAt(dynamic raw) {
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        (raw.toDouble() * 1000).round(),
      );
    }
    final seconds = double.tryParse('$raw');
    if (seconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  }

  MusicAiPlaylistDraft _parseLatestAiPlaylistDraft(
    Map<String, dynamic> playlistMap,
  ) {
    final parsed = MusicAiPlaylistDraft.fromMap(playlistMap);
    if (parsed.id == 'ai-playlist:latest') {
      return parsed;
    }
    return MusicAiPlaylistDraft(
      id: 'ai-playlist:latest',
      title: parsed.title,
      subtitle: parsed.subtitle,
      description: parsed.description,
      tag: parsed.tag,
      artworkTone: parsed.artworkTone,
      isAiGenerated: parsed.isAiGenerated,
      tracks: parsed.tracks,
      createdAt: parsed.createdAt,
      updatedAt: parsed.updatedAt,
    );
  }

  Future<void> _debugLog(String tag, Map<String, dynamic> payload) async {
    final enriched = <String, dynamic>{
      'tag': 'music.$tag',
      'ts': DateTime.now().toIso8601String(),
      ...payload,
    };
    final message = enriched.entries
        .map((e) => '${e.key}=${e.value}')
        .join(' | ');
    await NativeDebugBridge.instance.log('music', message, level: 'INFO');
    await _client.sendClientDebugLog(enriched);
  }
}
