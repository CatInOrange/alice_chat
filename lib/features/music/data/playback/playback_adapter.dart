import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';

abstract class PlaybackAdapter {
  Future<void> initialize();

  Future<void> play({
    required MusicTrack track,
    required ResolvedPlaybackSource source,
  });

  Future<void> pause();

  Future<void> resume();

  Future<void> dispose();
}
