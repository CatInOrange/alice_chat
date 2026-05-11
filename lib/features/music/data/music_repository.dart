import '../application/music_store.dart';
import '../domain/music_home_models.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';
import 'music_local_cache_store.dart';

abstract class MusicRepository {
  Future<MusicLocalCacheSnapshot?> loadLocalCache();

  Future<MusicLikedCacheBucket?> loadLikedCache();

  Future<void> saveLocalCache(MusicLocalCacheSnapshot snapshot);

  Future<MusicStateSnapshot> loadMusicState();

  Future<MusicHomeBundle> loadMusicHome();

  Future<PlaybackQueueItem> resolveTrack(
    MusicTrack track, {
    bool allowFallback = true,
  });

  Future<MusicTrack> enrichTrackMetadata(
    MusicTrack track, {
    bool allowFallback = true,
  });

  Future<List<MusicPlaylist>> loadUserPlaylists();

  Future<MusicAiPlaylistDraft?> loadLatestAiPlaylist();

  Future<List<MusicAiPlaylistDraft>> loadAiPlaylistHistory();

  Future<List<MusicTrack>> loadLikedTracks();

  Future<List<CustomMusicPlaylist>> loadCustomPlaylists();

  Future<void> saveCustomPlaylists(List<CustomMusicPlaylist> playlists);

  Future<String?> syncNeteaseFavoritePlaylistOpaqueId();

  Future<List<MusicTrack>> loadNeteaseFmTracks({int limit = 20});

  Future<List<MusicTrack>> loadNeteaseDaily();

  Future<void> setTrackLiked(MusicTrack track, bool liked);

  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist);

  Future<MusicLyrics?> loadLyrics(MusicTrack track);

  Future<List<MusicTrack>> loadIntelligenceTracks({
    required MusicPlaylist playlist,
    required MusicTrack seedTrack,
    MusicTrack? startTrack,
    String? fallbackPlaylistOpaqueId,
  });

  Future<DateTime?> savePlaybackSnapshot({
    List<MusicTrack>? likedTracks,
    List<MusicPlaylist>? recentPlaylists,
    List<CustomMusicPlaylist>? customPlaylists,
    String? neteaseLikedPlaylistId,
    String? neteaseLikedPlaylistOpaqueId,
    int? localRevision,
  });
}
