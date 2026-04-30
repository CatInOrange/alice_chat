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
      final positionMsRaw = response['positionMs'] ?? 0;
      return MusicStateSnapshot(
        currentTrack:
            currentTrackMap == null ? null : MusicTrack.fromMap(currentTrackMap),
        queue: queue,
        playlists: playlists,
        recentTracks: recentTracks,
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
  Future<MusicPlaylist?> loadLikedPlaylist() async {
    final netease = (_resolver as MusicSourceResolverImpl).registry.providerById(
      'netease',
    );
    return netease?.loadLikedPlaylist();
  }

  @override
  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist) async {
    final providerId = playlist.id.startsWith('netease-playlist:')
        ? 'netease'
        : null;
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
  }) async {
    try {
      await _client.saveMusicState(
        payload: {
          'currentTrack': currentTrack.toMap(),
          'queue': queue.map((item) => item.toMap()).toList(),
          'isPlaying': isPlaying,
          'positionMs': position.inMilliseconds,
        },
      );
    } catch (_) {
      // best effort for first pass
    }
  }
}
