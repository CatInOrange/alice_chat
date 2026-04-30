import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';

class PlaybackAdapterState {
  const PlaybackAdapterState({
    this.initialized = false,
    this.isPlaying = false,
    this.isBuffering = false,
    this.completed = false,
    this.position = Duration.zero,
    this.duration,
    this.currentTrack,
    this.currentSource,
    this.error,
  });

  final bool initialized;
  final bool isPlaying;
  final bool isBuffering;
  final bool completed;
  final Duration position;
  final Duration? duration;
  final MusicTrack? currentTrack;
  final ResolvedPlaybackSource? currentSource;
  final String? error;

  PlaybackAdapterState copyWith({
    bool? initialized,
    bool? isPlaying,
    bool? isBuffering,
    bool? completed,
    Duration? position,
    Duration? duration,
    MusicTrack? currentTrack,
    ResolvedPlaybackSource? currentSource,
    String? error,
    bool clearError = false,
  }) {
    return PlaybackAdapterState(
      initialized: initialized ?? this.initialized,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      completed: completed ?? this.completed,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      currentTrack: currentTrack ?? this.currentTrack,
      currentSource: currentSource ?? this.currentSource,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

abstract class PlaybackAdapter {
  PlaybackAdapterState get state;
  Stream<PlaybackAdapterState> get stateStream;

  Future<void> initialize();

  Future<void> play({
    required MusicTrack track,
    required ResolvedPlaybackSource source,
  });

  Future<void> pause();

  Future<void> resume();

  Future<void> seek(Duration position);

  Future<void> dispose();
}
