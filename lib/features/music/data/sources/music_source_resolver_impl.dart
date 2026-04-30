import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';
import 'music_source_provider.dart';
import 'music_source_registry.dart';
import 'music_source_resolver.dart';

class MusicSourceResolverImpl implements MusicSourceResolver {
  MusicSourceResolverImpl({required MusicSourceRegistry registry})
      : _registry = registry;

  final MusicSourceRegistry _registry;

  @override
  Future<PlaybackQueueItem> resolveTrack(MusicTrack track) async {
    final preferredProviderId = track.preferredSourceId;
    final providers = <MusicSourceProvider>[
      if (preferredProviderId != null)
        ..._registry.providers.where((item) => item.id == preferredProviderId),
      ..._registry.providers.where((item) => item.id != preferredProviderId),
    ];

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
          ),
          candidate: candidate,
          resolvedSource: resolved,
        );
      }
    }

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
}
