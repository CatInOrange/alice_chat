import 'dart:async';

import '../domain/music_runtime_models.dart';
import '../data/music_repository.dart';

class PlaybackWarmupCoordinator {
  PlaybackWarmupCoordinator({required MusicRepository repository})
    : _repository = repository;

  final MusicRepository _repository;
  int _token = 0;

  Future<List<PlaybackQueueItem>> warmup(List<PlaybackQueueItem> queue) async {
    final currentToken = ++_token;
    if (queue.length <= 1) {
      return queue;
    }
    final nextQueue = queue.toList(growable: true);
    final upperBound = queue.length < 3 ? queue.length : 3;
    for (var index = 1; index < upperBound; index++) {
      if (currentToken != _token) {
        return queue;
      }
      final item = nextQueue[index];
      final cached = item.track.cachedPlayback;
      if (cached != null &&
          cached.streamUrl.trim().isNotEmpty &&
          !cached.isExpired) {
        continue;
      }
      try {
        final resolved = await _repository.resolveTrack(
          item.track,
          allowFallback: false,
        );
        nextQueue[index] = resolved.copyWith(
          track: resolved.track.copyWith(isFavorite: item.track.isFavorite),
        );
      } catch (_) {
        // ignore warmup failures
      }
    }
    if (currentToken != _token) {
      return queue;
    }
    return List<PlaybackQueueItem>.unmodifiable(nextQueue);
  }

  void cancel() {
    _token += 1;
  }
}
