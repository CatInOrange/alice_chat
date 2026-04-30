import '../../../core/openclaw/openclaw_client.dart';
import '../application/music_store.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';
import 'mock_music_catalog.dart';
import 'music_repository.dart';
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
      final positionMsRaw = response['positionMs'] ?? 0;
      return MusicStateSnapshot(
        currentTrack:
            currentTrackMap == null ? null : MusicTrack.fromMap(currentTrackMap),
        queue: queue,
        playlists: playlists,
        recentTracks: recentTracks,
        likedTracks: likedTracks,
        isPlaying: response['isPlaying'] == true,
        position: Duration(
          milliseconds: positionMsRaw is num
              ? positionMsRaw.toInt()
              : int.tryParse('$positionMsRaw') ?? 0,
        ),
      );
    } catch (_) {
      return MusicStateSnapshot(
        currentTrack: MockMusicCatalog.featuredTrack,
        queue: MockMusicCatalog.data.queue
            .map((item) => PlaybackQueueItem(track: item))
            .toList(growable: false),
        playlists: MockMusicCatalog.playlists,
        recentTracks: MockMusicCatalog.recentTracks,
      );
    }
  }

  @override
  Future<ResolvedPlaybackSource> resolveTrack(MusicTrack track) async {
    final candidate = await _resolver.resolveTrack(track);
    return candidate.resolvedSource ??
        ResolvedPlaybackSource(
          providerId: track.preferredSourceId ?? 'mock',
          sourceTrackId: track.sourceTrackId ?? track.id,
          streamUrl:
              candidate.candidate?.sourceUrl ??
              candidate.resolvedSource?.streamUrl ??
              'mock://${track.id}',
          artworkUrl: track.artworkUrl,
        );
  }

  @override
  Future<List<MusicPlaylist>> loadUserPlaylists() async {
    final netease = (_resolver as MusicSourceResolverImpl).registry.providerById(
      'netease',
    );
    return netease?.loadUserPlaylists() ?? const <MusicPlaylist>[];
  }

  @override
  Future<MusicAiPlaylistDraft?> loadLatestAiPlaylist() async {
    final response = await _client.getLatestAiPlaylist();
    final playlistMap = (response['playlist'] as Map?)?.cast<String, dynamic>();
    if (playlistMap == null) {
      return null;
    }
    final draft = MusicAiPlaylistDraft.fromMap(playlistMap);
    if (draft.tracks.isEmpty) {
      return draft;
    }
    final resolvedTracks = <MusicTrack>[];
    for (final track in draft.tracks) {
      try {
        final resolved = await _resolver.resolveTrack(track);
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
  }

  @override
  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist) async {
    final providerId = playlist.id.startsWith('netease-playlist:')
        ? 'netease'
        : null;
    if (playlist.id == 'liked-local') {
      return loadLikedTracks();
    }
    if (playlist.id.startsWith('ai-playlist:')) {
      final latest = await loadLatestAiPlaylist();
      if (latest != null && latest.id == playlist.id) {
        return latest.tracks;
      }
      return const <MusicTrack>[];
    }
    if (providerId == null) {
      return MockMusicCatalog.tracksForPlaylist(playlist.id);
    }
    final provider = (_resolver as MusicSourceResolverImpl)
        .registry
        .providerById(providerId);
    final tracks = await provider?.loadPlaylistTracks(playlist.id) ??
        const <MusicTrack>[];
    return tracks;
  }

  @override
  Future<void> savePlaybackSnapshot({
    required MusicTrack currentTrack,
    required List<PlaybackQueueItem> queue,
    required bool isPlaying,
    required Duration position,
    List<MusicTrack>? likedTracks,
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
        },
      );
    } catch (_) {
      // best effort for first pass
    }
  }
}
