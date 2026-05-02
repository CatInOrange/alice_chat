import 'music_models.dart';

class MusicHomeBundle {
  const MusicHomeBundle({
    this.latestAiPlaylist,
    this.aiPlaylistHistory = const [],
    this.recentTracks = const [],
    this.recentPlaylists = const [],
    this.likedTracks = const [],
    this.customPlaylists = const [],
    this.neteaseLikedPlaylistId,
    this.neteaseLikedPlaylistEncryptedId,
    this.serverUpdatedAt,
    this.remoteRevision = 0,
  });

  final MusicAiPlaylistDraft? latestAiPlaylist;
  final List<MusicAiPlaylistDraft> aiPlaylistHistory;
  final List<MusicTrack> recentTracks;
  final List<MusicPlaylist> recentPlaylists;
  final List<MusicTrack> likedTracks;
  final List<CustomMusicPlaylist> customPlaylists;
  final String? neteaseLikedPlaylistId;
  final String? neteaseLikedPlaylistEncryptedId;
  final DateTime? serverUpdatedAt;
  final int remoteRevision;
}
