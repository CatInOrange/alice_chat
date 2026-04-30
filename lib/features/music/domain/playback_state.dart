// Copyright 2024 AliceChat Authors
// SPDX-License-Identifier: MIT
//
// Music System — Domain Layer
// playback_state.dart
//
// [PlaybackState] is a single, immutable snapshot of the entire music
// playback system at a point in time.
//
// It captures:
//   - what is playing (or not)
//   - where we are in the track
//   - what the queue looks like
//   - shuffle / repeat settings
//   - any transient errors
//
// [PlaybackState] is a pure value object — it never mutates itself.
// All transitions happen via [MusicCommand] being processed by the
// [PlaybackAdapter] or a state-management bloc/cubit.
//
// Example usage in a Riverpod Notifier:
//
//   @riverpod\nclass PlaybackNotifier extends _$PlaybackNotifier {\n//     @override\n//     PlaybackState build() => PlaybackState.initial();\n//\n//     void dispatch(MusicCommand cmd) {\n//       // process command, emit new state\n//     }\n//   }

import 'canonical_track.dart';
import 'resolved_playback_source.dart';

/// Repeat mode for the playback queue.
enum RepeatMode {
  /// No repeat — stop at end of queue.
  none,

  /// Repeat the current track indefinitely.
  one,

  /// Repeat the entire queue indefinitely.
  all,
}

/// Overall status of the playback engine.
enum PlaybackStatus {
  /// Nothing is loaded; queue is empty and player is idle.
  idle,

  /// A track is loaded and play is progressing.
  playing,

  /// Playback is paused at [position].
  paused,

  /// The player is buffering / loading the next track.
  loading,

  /// Playback has encountered an error; see [PlaybackState.error].
  error,
}

/// Immutable snapshot of the entire music playback system.
class PlaybackState {
  const PlaybackState({
    required this.status,
    required this.currentTrack,
    required this.currentSource,
    required this.position,
    required this.duration,
    required this.queue,
    required this.queueIndex,
    required this.shuffleEnabled,
    required this.repeatMode,
    required this.volume,
    this.error,
  });

  /// Factory for the initial idle state (empty queue, no track).
  factory PlaybackState.initial() => const PlaybackState(
        status: PlaybackStatus.idle,
        currentTrack: null,
        currentSource: null,
        position: Duration.zero,
        duration: Duration.zero,
        queue: [],
        queueIndex: -1,
        shuffleEnabled: false,
        repeatMode: RepeatMode.none,
        volume: 1.0,
      );

  /// Current overall playback status.
  final PlaybackStatus status;

  /// The track that is currently loaded (or last loaded if idle/error).
  final CanonicalTrack? currentTrack;

  /// The resolved source for [currentTrack].
  final ResolvedPlaybackSource? currentSource;

  /// Current playback position within the track.
  final Duration position;

  /// Total duration of the current track.
  /// Zero if status is idle or duration is unknown.
  final Duration duration;

  /// The ordered list of queued tracks (as resolved sources).
  /// The currently-playing track is at [queueIndex].
  final List<ResolvedPlaybackSource> queue;

  /// Index into [queue] for the currently playing track.
  /// -1 means no track is queued/selected.
  final int queueIndex;

  /// Whether shuffle mode is enabled.
  final bool shuffleEnabled;

  /// Current repeat mode.
  final RepeatMode repeatMode;

  /// Playback volume. 0.0 (silent) to 1.0 (full).
  final double volume;

  /// Error message if [status] is error.
  final String? error;

  // -------------------------------------------------------------------------
  // Convenience accessors
  // -------------------------------------------------------------------------

  bool get isPlaying => status == PlaybackStatus.playing;
  bool get isPaused => status == PlaybackStatus.paused;
  bool get isIdle => status == PlaybackStatus.idle;
  bool get isLoading => status == PlaybackStatus.loading;
  bool get hasError => status == PlaybackStatus.error;

  /// Progress fraction (0.0–1.0).  Returns 0.0 if duration is zero.
  double get progress {
    if (duration.inMilliseconds == 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Returns true if there is a next track in the queue.
  bool get hasNext => queueIndex < queue.length - 1;

  /// Returns true if there is a previous track in the queue.
  bool get hasPrevious => queueIndex > 0;

  /// The currently playing track's resolved source, if any.
  ResolvedPlaybackSource? get playingSource =>
      queueIndex >= 0 && queueIndex < queue.length
          ? queue[queueIndex]
          : null;

  // -------------------------------------------------------------------------
  // CopyWith
  // -------------------------------------------------------------------------

  PlaybackState copyWith({
    PlaybackStatus? status,
    CanonicalTrack? currentTrack,
    ResolvedPlaybackSource? currentSource,
    Duration? position,
    Duration? duration,
    List<ResolvedPlaybackSource>? queue,
    int? queueIndex,
    bool? shuffleEnabled,
    RepeatMode? repeatMode,
    double? volume,
    String? error,
  }) {
    return PlaybackState(
      status: status ?? this.status,
      currentTrack: currentTrack ?? this.currentTrack,
      currentSource: currentSource ?? this.currentSource,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      queue: queue ?? this.queue,
      queueIndex: queueIndex ?? this.queueIndex,
      shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
      repeatMode: repeatMode ?? this.repeatMode,
      volume: volume ?? this.volume,
      error: error ?? this.error,
    );
  }

  /// Creates a copy with cleared error state and [status] set to [PlaybackStatus.idle].
  /// Used after an error has been acknowledged by the user.
  PlaybackState clearError() => copyWith(
        status: PlaybackStatus.idle,
        error: null,
      );

  @override
  String toString() =>
      'PlaybackState(status: $status, track: ${currentTrack?.title}, '
      'position: $position, queueIndex: $queueIndex/${queue.length})';
}
