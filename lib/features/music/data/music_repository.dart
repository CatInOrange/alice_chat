import '../application/music_store.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';

abstract class MusicRepository {
  Future<MusicStateSnapshot> loadMusicState();

  Future<PlaybackQueueItem> resolveTrack(MusicTrack track, {bool allowFallback = true});

  Future<List<MusicPlaylist>> loadUserPlaylists();

  Future<MusicAiPlaylistDraft?> loadLatestAiPlaylist();

  Future<List<MusicTrack>> loadLikedTracks();

  Future<void> setTrackLiked(MusicTrack track, bool liked);

  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist);

  Future<void> savePlaybackSnapshot({
    required MusicTrack currentTrack,
    required List<PlaybackQueueItem> queue,
    required bool isPlaying,
    required Duration position,
    List<MusicTrack>? likedTracks,
  });
}
