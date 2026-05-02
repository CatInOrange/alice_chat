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

  List<MusicSourceProvider> _orderedProviders(
    MusicTrack track, {
    required bool allowFallback,
  }) {
    final preferredProviderId = track.preferredSourceId?.trim();
    final allProviders = <MusicSourceProvider>[
      if (preferredProviderId != null && preferredProviderId.isNotEmpty)
        ..._registry.providers.where((item) => item.id == preferredProviderId),
      ..._registry.providers.where((item) => item.id != preferredProviderId),
    ];
    return allowFallback
        ? allProviders
        : allProviders
            .where((item) => item.id != 'mock')
            .toList(growable: false);
  }

  @override
  Future<SourceCandidate?> matchTrack(
    MusicTrack track, {
    bool allowFallback = true,
  }) async {
    final providers = _orderedProviders(track, allowFallback: allowFallback);
    for (final provider in providers) {
      final candidate = await provider.matchTrack(track);
      if (candidate == null || !candidate.available) {
        continue;
      }
      return candidate;
    }
    return null;
  }

  @override
  Future<PlaybackQueueItem> resolveTrack(
    MusicTrack track, {
    bool allowFallback = true,
  }) async {
    final providers = _orderedProviders(track, allowFallback: allowFallback);

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
            encryptedSourceTrackId:
                candidate.track.encryptedSourceTrackId ??
                track.encryptedSourceTrackId,
            artworkUrl: candidate.track.artworkUrl ?? track.artworkUrl,
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
      throw StateError('未能为《${track.title} - ${track.artist}》解析可播放音源');
    }

    throw StateError('未能为《${track.title} - ${track.artist}》解析可播放音源');
  }
}
