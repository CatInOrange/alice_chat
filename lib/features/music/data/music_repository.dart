import '../application/music_store.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';
import 'music_local_cache_store.dart';

abstract class MusicRepository {
  Future<MusicLocalCacheSnapshot?> loadLocalCache();

  Future<void> saveLocalCache(MusicLocalCacheSnapshot snapshot);

  Future<MusicStateSnapshot> loadMusicState();

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

  Future<String?> syncNeteaseFavoritePlaylistEncryptedId();

  Future<List<MusicPlaylist>> syncNeteaseFavoritePlaylist();

  Future<void> setTrackLiked(MusicTrack track, bool liked);

  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist);

  Future<MusicLyrics?> loadLyrics(MusicTrack track);

  Future<List<MusicTrack>> loadIntelligenceTracks({
    required MusicPlaylist playlist,
    required MusicTrack seedTrack,
    MusicTrack? startTrack,
    String? fallbackEncryptedPlaylistId,
  });

  Future<void> savePlaybackSnapshot({
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
  });
}
