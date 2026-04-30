import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';
import '../mock_music_catalog.dart';
import 'music_source_provider.dart';

class MockMusicSourceProvider implements MusicSourceProvider {
  @override
  String get id => 'mock';

  @override
  Future<SourceCandidate?> matchTrack(MusicTrack track) async {
    final matched = MockMusicCatalog.recentTracks.firstWhere(
      (item) => item.id == track.id,
      orElse: () => track,
    );
    final canonical = CanonicalTrack.fromMusicTrack(
      matched.copyWith(
        preferredSourceId: id,
        sourceTrackId: track.sourceTrackId ?? track.id,
      ),
    );
    return SourceCandidate(
      providerId: id,
      sourceTrackId: track.sourceTrackId ?? track.id,
      track: canonical,
      sourceUrl: 'mock://${track.id}',
    );
  }

  @override
  Future<ResolvedPlaybackSource?> resolvePlayback(SourceCandidate candidate) async {
    return ResolvedPlaybackSource(
      providerId: id,
      sourceTrackId: candidate.sourceTrackId,
      streamUrl: candidate.sourceUrl ?? 'mock://${candidate.track.id}',
      artworkUrl: candidate.track.artworkUrl,
    );
  }

  @override
  Future<List<SourceCandidate>> searchTracks(String query) async {
    final keyword = query.trim().toLowerCase();
    return MockMusicCatalog.recentTracks
        .where(
          (item) =>
              item.title.toLowerCase().contains(keyword) ||
              item.artist.toLowerCase().contains(keyword),
        )
        .map(
          (item) => SourceCandidate(
            providerId: id,
            sourceTrackId: item.id,
            track: CanonicalTrack.fromMusicTrack(
              item.copyWith(
                preferredSourceId: id,
                sourceTrackId: item.id,
              ),
            ),
            sourceUrl: 'mock://${item.id}',
          ),
        )
        .toList(growable: false);
  }
}
