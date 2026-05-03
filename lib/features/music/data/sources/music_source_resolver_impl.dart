import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';
import 'music_source_provider.dart';
import 'music_source_registry.dart';
import 'music_source_resolver.dart';

class MusicSourceResolverImpl implements MusicSourceResolver {
  MusicSourceResolverImpl({required MusicSourceRegistry registry})
    : _registry = registry;

  static const Duration _resolveMemoTtl = Duration(seconds: 20);

  final MusicSourceRegistry _registry;
  final Map<String, PlaybackQueueItem> _resolveMemo =
      <String, PlaybackQueueItem>{};

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
    final memoKey = _resolveMemoKey(track);
    final memoized = _resolveMemoized(track, memoKey);
    if (memoized != null) {
      return memoized;
    }

    final providers = _orderedProviders(track, allowFallback: allowFallback);

    for (final provider in providers) {
      final directCandidate = _directCandidateForProvider(provider, track);
      final candidate = directCandidate ?? await provider.matchTrack(track);
      if (candidate == null || !candidate.available) {
        continue;
      }
      final resolved = await provider.resolvePlayback(candidate);
      if (resolved != null) {
        final item = PlaybackQueueItem(
          track: track.copyWith(
            preferredSourceId: provider.id,
            sourceTrackId: candidate.sourceTrackId,
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
        _resolveMemo[memoKey] = item;
        return item;
      }
    }

    if (allowFallback) {
      throw StateError('未能为《${track.title} - ${track.artist}》解析可播放音源');
    }

    throw StateError('未能为《${track.title} - ${track.artist}》解析可播放音源');
  }

  SourceCandidate? _directCandidateForProvider(
    MusicSourceProvider provider,
    MusicTrack track,
  ) {
    final sourceTrackId = track.sourceTrackId?.trim();
    if (track.preferredSourceId != provider.id ||
        sourceTrackId == null ||
        sourceTrackId.isEmpty) {
      return null;
    }
    return SourceCandidate(
      providerId: provider.id,
      sourceTrackId: sourceTrackId,
      track: CanonicalTrack.fromMusicTrack(
        track.copyWith(
          preferredSourceId: provider.id,
          sourceTrackId: sourceTrackId,
        ),
      ),
    );
  }

  PlaybackQueueItem? _resolveMemoized(MusicTrack track, String memoKey) {
    final memoized = _resolveMemo[memoKey];
    final cached = memoized?.track.cachedPlayback;
    if (memoized == null || cached == null) {
      return null;
    }
    final resolvedAt = cached.resolvedAt;
    if (cached.streamUrl.trim().isEmpty || cached.isExpired) {
      _resolveMemo.remove(memoKey);
      return null;
    }
    if (resolvedAt != null &&
        DateTime.now().difference(resolvedAt) > _resolveMemoTtl) {
      _resolveMemo.remove(memoKey);
      return null;
    }
    return memoized.copyWith(
      track: memoized.track.copyWith(
        isFavorite: track.isFavorite,
        artworkUrl: memoized.track.artworkUrl ?? track.artworkUrl,
      ),
    );
  }

  String _resolveMemoKey(MusicTrack track) {
    final providerId = track.preferredSourceId?.trim() ?? '';
    final sourceTrackId = track.sourceTrackId?.trim() ?? '';
    if (providerId.isNotEmpty && sourceTrackId.isNotEmpty) {
      return '$providerId::$sourceTrackId';
    }
    return '${track.id}::${track.title}::${track.artist}';
  }
}
