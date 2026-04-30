// Copyright 2024 AliceChat Authors
// SPDX-License-Identifier: MIT
//
// Music System — Domain Layer
// source_candidate.dart
//
// A [SourceCandidate] represents a possible audio source for a track,
// as reported by a single [MusicSourceProvider].
//
// It is "unresolved" — the provider has told us "here is a track with
// a source URL" but we haven't verified that the URL is actually playable,
// accessible, or of acceptable quality.
//
// The [MusicSourceResolver] is responsible for taking one or more
// [SourceCandidate] instances for the same [CanonicalTrack] and turning
// them into a single [ResolvedPlaybackSource] that we can send to the
// [PlaybackAdapter].

import 'canonical_track.dart';

/// Priority hint that a provider can attach to a candidate.
///
/// Used by [MusicSourceResolver] to rank candidates when multiple
/// providers return sources for the same track.
enum SourcePriority {
  /// Fallback only — only use if nothing better is available.
  fallback,

  /// Standard quality — normal provider response.
  normal,

  /// Preferred — this provider is known to have high-quality audio
  /// or reliable streams.
  preferred,
}

/// A single candidate audio source for a track, as returned by one provider.
///
/// This is "raw" data from the provider — it has not been validated
/// (e.g. URL reachable, codec supported, DRM check, etc.).  That validation
/// happens in [MusicSourceResolver].
class SourceCandidate {
  const SourceCandidate({
    required this.track,
    required this.providerId,
    required this.sourceUrl,
    this.formatHint,
    this.bitrate,
    this.sampleRate,
    this.priority = SourcePriority.normal,
    this.metadata = const {},
  });

  /// The canonical track this source belongs to.
  final CanonicalTrack track;

  /// The ID of the [MusicSourceProvider] that returned this candidate.
  /// Corresponds to [MusicSourceProvider.providerId].
  final String providerId;

  /// The audio URL as reported by the provider.
  /// May be a direct file URL, a streaming manifest, or any valid audio URI.
  final String sourceUrl;

  /// Optional hint about the audio format (e.g. 'mp4', 'hls', 'webm').
  /// Null means "unknown / let the player figure it out."
  final String? formatHint;

  /// Audio bitrate in kbps (e.g. 128, 256, 320).  Null means unknown.
  final int? bitrate;

  /// Audio sample rate in Hz (e.g. 44100, 48000).  Null means unknown.
  final int? sampleRate;

  /// Priority hint for ranking when multiple candidates exist.
  final SourcePriority priority;

  /// Arbitrary extra metadata from the provider (e.g. 'isPreview': true).
  final Map<String, Object> metadata;

  /// Whether this candidate came from a free / ad-supported source.
  bool get isAdSupported => metadata['isAdSupported'] == true;

  /// Whether this candidate is a preview snippet (e.g. 30-second clip).
  bool get isPreview => metadata['isPreview'] == true;

  @override
  String toString() =>
      'SourceCandidate(provider: $providerId, url: $sourceUrl, '
      'format: $formatHint, bitrate: $bitrate)';
}
