import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';
import 'music_source_provider.dart';
import 'music_source_registry.dart';
import 'music_source_resolver.dart';

class MusicSourceResolverImpl implements MusicSourceResolver {
  MusicSourceResolverImpl({required MusicSourceRegistry registry})
      : _registry = registry;

  final MusicSourceRegistry _registry;

  MusicSourceRegistry get registry => _registry;

  @override
  Future<PlaybackQueueItem> resolveTrack(
    MusicTrack track, {
    bool allowFallback = true,
  }) async {
    final preferredProviderId = track.preferredSourceId;
    final allProviders = <MusicSourceProvider>[
      if (preferredProviderId != null)
        ..._registry.providers.where((item) => item.id == preferredProviderId),
      ..._registry.providers.where((item) => item.id != preferredProviderId),
    ];
    final providers = allowFallback
        ? allProviders
        : allProviders.where((item) => item.id != 'mock').toList(growable: false);

    for (final provider in providers) {
      final candidate = await provider.matchTrack(track);
      if (candidate == null || !candidate.available) {
        continue;
      }
      final resolved = await provider.resolvePlayback(candidate);
      if (resolved != null) {
        return PlaybackQueueItem(
          track: track.copyWith(
            preferredSourceId: provider.id,
            sourceTrackId: candidate.sourceTrackId,
            cachedPlayback: CachedPlaybackSource(
              providerId: resolved.providerId,
              sourceTrackId: resolved.sourceTrackId,
              streamUrl: resolved.streamUrl,
              artworkUrl: resolved.artworkUrl,
              mimeType: resolved.mimeType,
              headers: resolved.headers,
              expiresAt: resolved.expiresAt,
              resolvedAt: DateTime.now(),
            ),
          ),
          candidate: candidate,
          resolvedSource: resolved,
        );
      }
    }

    if (allowFallback) {
      return PlaybackQueueItem(
        track: track,
        resolvedSource: ResolvedPlaybackSource(
          providerId: preferredProviderId ?? 'unresolved',
          sourceTrackId: track.sourceTrackId ?? track.id,
          streamUrl: 'mock://${track.id}',
          artworkUrl: track.artworkUrl,
        ),
      );
    }

    throw StateError('未能为《${track.title} - ${track.artist}》解析可播放音源');
  }
}
