import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';
import 'playback_adapter.dart';

class StubPlaybackAdapter implements PlaybackAdapter {
  bool _initialized = false;
  MusicTrack? currentTrack;
  ResolvedPlaybackSource? currentSource;
  bool isPlaying = false;

  @override
  Future<void> initialize() async {
    _initialized = true;
  }

  @override
  Future<void> play({
    required MusicTrack track,
    required ResolvedPlaybackSource source,
  }) async {
    if (!_initialized) {
      await initialize();
    }
    currentTrack = track;
    currentSource = source;
    isPlaying = true;
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
  }

  @override
  Future<void> resume() async {
    if (currentTrack != null && currentSource != null) {
      isPlaying = true;
    }
  }

  @override
  Future<void> dispose() async {
    currentTrack = null;
    currentSource = null;
    isPlaying = false;
    _initialized = false;
  }
}
