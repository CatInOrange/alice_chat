import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';

abstract class MusicSourceProvider {
  String get id;

  Future<List<SourceCandidate>> searchTracks(String query);

  Future<SourceCandidate?> matchTrack(MusicTrack track);

  Future<ResolvedPlaybackSource?> resolvePlayback(SourceCandidate candidate);
}
