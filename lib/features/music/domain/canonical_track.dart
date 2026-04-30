// Copyright 2024 AliceChat Authors
// SPDX-License-Identifier: MIT
//
// Music System — Domain Layer
// canonical_track.dart
//
// A [CanonicalTrack] is a normalized, source-agnostic track identity.
// It captures the minimal set of fields that uniquely identify a musical work
// regardless of which provider the track came from.
//
// Contrast with [MusicTrack] (music_models.dart) which is the presentation-layer
// model with UI-friendly fields (artworkTone, isFavorite, etc.).
// A [CanonicalTrack] is what the domain/data layers use to match and resolve
// tracks across multiple music source providers.

import 'package:flutter/foundation.dart';

/// Represents the canonical identity of a musical track.
///
/// This is the "what" of a track — title, primary artist, album (if any),
/// and an optional external ID from a known provider (e.g. Spotify URI,
/// YouTube Music video ID, local file path).  It does NOT carry artwork
/// tones or UI preferences — those belong in [MusicTrack].
///
/// [CanonicalTrack] instances are equal when they represent the same logical
/// work, so they can be used as `Set`/`Map` keys for deduplication.
@immutable
class CanonicalTrack {
  const CanonicalTrack({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.externalIds = const {},
  });

  /// A unique identifier for this canonical track within the app.
  /// Use a stable, app-scoped ID (e.g. `sha256(title+artist)`) so that the
  /// same logical track always produces the same [id] regardless of which
  /// provider we queried.
  final String id;

  final String title;
  final String artist;

  /// Album name. May be null for singles / tracks without a parent album.
  final String? album;

  /// Track duration as known from the best available source.
  /// May be null if the source didn't provide it.
  final Duration? duration;

  /// Provider → ID mapping for external integrations.
  /// e.g. {'spotify': '4uLU6hMCjMI75M1A2tKUQC',
  ///       'youtube_music': 'dQw4w9WgXcQ',
  ///       'local': '/path/to/file.mp3'}
  ///
  /// Not every source will be present; only sources that have been resolved
  /// for this track are stored here.
  final Map<String, String> externalIds;

  /// Returns the external ID for [provider] if present.
  String? externalId(String provider) => externalIds[provider];

  /// Creates a copy with an additional or updated external ID.
  CanonicalTrack withExternalId(String provider, String externalId) {
    return CanonicalTrack(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      externalIds: {...externalIds, provider: externalId},
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanonicalTrack &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'CanonicalTrack(id: $id, title: $title, artist: $artist)';
}
