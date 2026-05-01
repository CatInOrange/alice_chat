import '../application/music_store.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';

abstract class MusicRepository {
  Future<MusicStateSnapshot> loadMusicState();

  Future<PlaybackQueueItem> resolveTrack(MusicTrack track, {bool allowFallback = true});

  Future<List<MusicPlaylist>> loadUserPlaylists();

  Future<MusicAiPlaylistDraft?> loadLatestAiPlaylist();

  Future<List<MusicAiPlaylistDraft>> loadAiPlaylistHistory();

  Future<List<MusicTrack>> loadLikedTracks();

  Future<List<CustomMusicPlaylist>> loadCustomPlaylists();

  Future<void> saveCustomPlaylists(List<CustomMusicPlaylist> playlists);

  Future<void> setTrackLiked(MusicTrack track, bool liked);

  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist);

  Future<MusicLyrics?> loadLyrics(MusicTrack track);

  Future<List<MusicTrack>> loadIntelligenceTracks({
    required MusicPlaylist playlist,
    required MusicTrack seedTrack,
    MusicTrack? startTrack,
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
  });
}
