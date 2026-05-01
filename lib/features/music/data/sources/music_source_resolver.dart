import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';

abstract class MusicSourceResolver {
  Future<PlaybackQueueItem> resolveTrack(MusicTrack track, {bool allowFallback = true});
}
