// Copyright 2024 AliceChat Authors
// SPDX-License-Identifier: MIT
//
// Music System — Domain Layer
// resolved_playback_source.dart
//
// A [ResolvedPlaybackSource] is a fully-resolved, player-ready audio source.
//
// Unlike [SourceCandidate] (which is "here is a URL from provider X"),
// a [ResolvedPlaybackSource] has passed source-selection logic (via
// [MusicSourceResolver]) and is ready to be handed off to the
// [PlaybackAdapter] for actual playback.
//
// This is the canonical "playable thing" in the domain layer.

import 'canonical_track.dart';

/// The resolved quality tier of a playback source.
enum SourceQuality {
  /// Low quality / preview snippet (≤ 30s or ≤ 64 kbps).
  low,

  /// Standard CD-quality (~128–256 kbps).
  standard,

  /// High quality (~320 kbps or lossless).
  high,
}

/// A fully resolved, player-ready audio source.
///
/// This is what the domain layer passes to [PlaybackAdapter.play].
/// It contains everything the adapter needs to start playback without
/// further external lookups.
class ResolvedPlaybackSource {
  const ResolvedPlaybackSource({
    required this.track,
    required this.resolvedUrl,
    required this.providerId,
    required this.quality,
    this.mimeType,
    this.startPosition,
    this.endPosition,
    this.seekable = true,
  });

  /// The canonical track being played.
  final CanonicalTrack track;

  /// The fully resolved, absolute audio URL (or manifest URI).
  /// This has been validated and is expected to be directly playable.
  final String resolvedUrl;

  /// The provider ID this source originated from
  /// (e.g. 'spotify', 'youtube_music', 'local').
  final String providerId;

  /// Quality tier of the resolved source.
  final SourceQuality quality;

  /// MIME type hint for the audio container/codec (e.g. 'audio/mp4').
  /// Null means "let the player auto-detect."
  final String? mimeType;

  /// Optional start position (for non-0 track start, e.g. fade-in).
  final Duration? startPosition;

  /// Optional end position (for preview clips, etc.).
  final Duration? endPosition;

  /// Whether the source supports seeking.
  final bool seekable;

  /// Effective playable duration, accounting for start/end positions.
  Duration? get playableDuration {
    final end = endPosition;
    if (end != null) {
      return end - (startPosition ?? Duration.zero);
    }
    return null; // live stream or unknown
  }

  /// Convenience: true if this is a live / non-seekable stream.
  bool get isLiveStream => endPosition == null && !seekable;

  @override
  String toString() =>
      'ResolvedPlaybackSource(track: ${track.title}, url: $resolvedUrl, '
      'quality: $quality, provider: $providerId)';
}
