import '../application/music_store.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';

abstract class MusicRepository {
  Future<MusicStateSnapshot> loadMusicState();

  Future<ResolvedPlaybackSource> resolveTrack(MusicTrack track);

  Future<List<MusicPlaylist>> loadUserPlaylists();

  Future<MusicPlaylist?> loadLikedPlaylist();

  Future<List<MusicTrack>> loadPlaylistTracks(MusicPlaylist playlist);

  Future<void> savePlaybackSnapshot({
    required MusicTrack currentTrack,
    required List<PlaybackQueueItem> queue,
    required bool isPlaying,
    required Duration position,
  });
}
