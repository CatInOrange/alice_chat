import 'dart:async';

import '../domain/music_models.dart';
import '../data/music_repository.dart';

class AiPlaylistEnricher {
  AiPlaylistEnricher({required MusicRepository repository})
    : _repository = repository;

  final MusicRepository _repository;
  int _token = 0;

  Future<MusicAiPlaylistDraft> enrichTopTracks(
    MusicAiPlaylistDraft draft, {
    int limit = 3,
  }) async {
    final currentToken = ++_token;
    if (draft.tracks.isEmpty || limit <= 0) {
      return draft;
    }
    final safeLimit = limit.clamp(1, draft.tracks.length);
    final nextTracks = draft.tracks.toList(growable: true);
    for (var index = 0; index < safeLimit; index++) {
      if (currentToken != _token) {
        return draft;
      }
      var track = nextTracks[index];
      try {
        track = await _repository.enrichTrackMetadata(
          track,
          allowFallback: false,
        );
        if (track.preferredSourceId != null && track.sourceTrackId != null) {
          final resolved = await _repository.resolveTrack(
            track,
            allowFallback: false,
          );
          track = resolved.track.copyWith(
            artworkUrl:
                resolved.resolvedSource?.artworkUrl ??
                resolved.candidate?.track.artworkUrl ??
                resolved.track.artworkUrl ??
                track.artworkUrl,
          );
        }
        nextTracks[index] = track;
      } catch (_) {
        // keep original track on enrich failure
      }
    }
    if (currentToken != _token) {
      return draft;
    }
    return MusicAiPlaylistDraft(
      id: draft.id,
      title: draft.title,
      subtitle: draft.subtitle,
      description: draft.description,
      tag: draft.tag,
      artworkTone: draft.artworkTone,
      isAiGenerated: draft.isAiGenerated,
      tracks: List<MusicTrack>.unmodifiable(nextTracks),
      createdAt: draft.createdAt,
      updatedAt: draft.updatedAt,
    );
  }

  void cancel() {
    _token += 1;
  }
}
