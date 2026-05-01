import '../../../core/debug/native_debug_bridge.dart';
import '../../../core/openclaw/openclaw_client.dart';
import '../application/music_store.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';
import 'music_repository.dart';
import 'sources/music_source_provider.dart';
import 'sources/music_source_resolver.dart';
import 'sources/music_source_resolver_impl.dart';

class MusicRepositoryImpl implements MusicRepository {
  MusicRepositoryImpl({
    required OpenClawClient client,
    required MusicSourceResolver resolver,
  })  : _client = client,
        _resolver = resolver;

  final OpenClawClient _client;
  final MusicSourceResolver _resolver;

  @override
  Future<MusicStateSnapshot> loadMusicState() async {
    try {
      final response = await _client.getMusicState();
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
      final recentTracks = ((response['recentTracks'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map(
            (item) => MusicTrack.fromMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            ),
          )
          .toList(growable: false);
      final likedTracks = ((response['likedTracks'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map(
            (item) => MusicTrack.fromMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            ),
          )
          .toList(growable: false);
      final recentPlaylists = ((response['recentPlaylists'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map(
            (item) => MusicPlaylist.fromMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            ),
          )
          .toList(growable: false);
      final customPlaylists = ((response['customPlaylists'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map(
            (item) => CustomMusicPlaylist.fromMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            ),
          )
          .toList(growable: false);
      final currentPlaylistId = (response['currentPlaylistId'] ?? '').toString().trim();
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
        isPlaying: response['isPlaying'] == true,
        position: Duration(
          milliseconds: positionMsRaw is num
              ? positionMsRaw.toInt()
              : int.tryParse('$positionMsRaw') ?? 0,
        ),
      );
    } catch (_) {
      return const MusicStateSnapshot();
    }
  }

  @override
  Future<PlaybackQueueItem> resolveTrack(
    MusicTrack track, {
    bool allowFallback = true,
  }) async {
    return _resolver.resolveTrack(track, allowFallback: allowFallback);
  }

  @override
  Future<List<MusicPlaylist>> loadUserPlaylists() async {
    final registry = (_resolver as MusicSourceResolverImpl).registry;
    final results = <MusicPlaylist>[];
    final seen = <String>{};
    for (final provider in registry.providers) {
      try {
        final playlists = await provider.loadUserPlaylists();
        for (final playlist in playlists) {
          if (seen.add(playlist.id)) {
            results.add(playlist);
          }
        }
      } catch (error) {
        await _debugLog('repository.loadUserPlaylists.error', {
          'providerId': provider.id,
          'error': error.toString(),
        });
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
    final parsed = MusicAiPlaylistDraft.fromMap(playlistMap);
    final draft = parsed.id == 'ai-playlist:latest'
        ? parsed
        : MusicAiPlaylistDraft(
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
    if (draft.tracks.isEmpty) {
      return draft;
    }
    final resolvedTracks = <MusicTrack>[];
    for (final track in draft.tracks) {
      try {
        final resolved = await _resolver.resolveTrack(track, allowFallback: false);
        resolvedTracks.add(
          resolved.track.copyWith(
            artworkUrl:
                resolved.resolvedSource?.artworkUrl ??
                resolved.candidate?.track.artworkUrl ??
                track.artworkUrl,
          ),
        );
      } catch (_) {
        resolvedTracks.add(track);
      }
    }
    return MusicAiPlaylistDraft(
      id: draft.id,
      title: draft.title,
      subtitle: draft.subtitle,
      description: draft.description,
      tag: draft.tag,
      artworkTone: draft.artworkTone,
      isAiGenerated: draft.isAiGenerated,
      tracks: List<MusicTrack>.unmodifiable(resolvedTracks),
      createdAt: draft.createdAt,
      updatedAt: draft.updatedAt,
    );
  }

  @override
  Future<List<MusicAiPlaylistDraft>> loadAiPlaylistHistory() async {
    try {
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
    } catch (error) {
      await _debugLog('repository.loadAiPlaylistHistory.error', {
        'error': error.toString(),
      });
      return const <MusicAiPlaylistDraft>[];
    }
  }

  @override
  Future<List<MusicTrack>> loadLikedTracks() async {
    final response = await _client.getMusicState();
    final likedTracks = ((response['likedTracks'] as List<dynamic>?) ?? const [])
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
        'customPlaylists': playlists.map((item) => item.toMap()).toList(growable: false),
      },
    );
  }

  @override
  Future<void> setTrackLiked(MusicTrack track, bool liked) async {
    final current = await loadLikedTracks();
    final filtered = current.where((item) => item.id != track.id).toList(growable: true);
    if (liked) {
      filtered.insert(0, track.copyWith(isFavorite: true));
    }
    await _client.saveMusicState(
      payload: {
        'likedTracks': filtered.map((item) => item.toMap()).toList(),
      },
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
  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist) async {
    final providerId = _providerIdForPlaylist(playlist.id);
    if (playlist.id == 'liked-local') {
      return loadLikedTracks();
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
      final matched = history.where((item) => item.id == playlist.id).cast<MusicAiPlaylistDraft?>().firstWhere(
            (item) => item != null,
            orElse: () => null,
          );
      return matched?.tracks ?? const <MusicTrack>[];
    }
    if (providerId == null) {
      return const <MusicTrack>[];
    }
    final provider = (_resolver as MusicSourceResolverImpl)
        .registry
        .providerById(providerId);
    final tracks = await provider?.loadPlaylistTracks(playlist.id) ??
        const <MusicTrack>[];
    await _debugLog('repository.loadPlaylistTracks', {
      'playlistId': playlist.id,
      'providerId': providerId,
      'trackCount': tracks.length,
    });
    return tracks;
  }

  @override
  Future<void> savePlaybackSnapshot({
    required MusicTrack currentTrack,
    required List<PlaybackQueueItem> queue,
    required bool isPlaying,
    required Duration position,
    List<MusicTrack>? likedTracks,
    List<MusicPlaylist>? recentPlaylists,
    List<CustomMusicPlaylist>? customPlaylists,
    String? currentPlaylistId,
  }) async {
    try {
      await _client.saveMusicState(
        payload: {
          'currentTrack': currentTrack.toMap(),
          'queue': queue.map((item) => item.toMap()).toList(),
          'isPlaying': isPlaying,
          'positionMs': position.inMilliseconds,
          if (likedTracks != null)
            'likedTracks': likedTracks.map((item) => item.toMap()).toList(),
          if (recentPlaylists != null)
            'recentPlaylists': recentPlaylists.map((item) => item.toMap()).toList(),
          if (customPlaylists != null)
            'customPlaylists': customPlaylists.map((item) => item.toMap()).toList(),
          if (currentPlaylistId != null) 'currentPlaylistId': currentPlaylistId,
        },
      );
    } catch (_) {
      // best effort for first pass
    }
  }

  MusicSourceProvider? _providerForTrack(MusicTrack track) {
    final registry = (_resolver as MusicSourceResolverImpl).registry;
    final preferred = track.preferredSourceId?.trim();
    if (preferred != null && preferred.isNotEmpty) {
      return registry.providerById(preferred);
    }
    if ((track.sourceTrackId ?? '').trim().isNotEmpty && track.id.contains(':')) {
      return registry.providerById(track.id.split(':').first);
    }
    return registry.providerById('netease');
  }

  String? _providerIdForPlaylist(String playlistId) {
    if (playlistId.startsWith('netease-playlist:')) return 'netease';
    if (playlistId.startsWith('migu-playlist:')) return 'migu';
    return null;
  }

  Future<void> _debugLog(String tag, Map<String, dynamic> payload) async {
    final enriched = <String, dynamic>{
      'tag': 'music.$tag',
      'ts': DateTime.now().toIso8601String(),
      ...payload,
    };
    final message = enriched.entries.map((e) => '${e.key}=${e.value}').join(' | ');
    await NativeDebugBridge.instance.log('music', message, level: 'INFO');
    await _client.sendClientDebugLog(enriched);
  }
}
