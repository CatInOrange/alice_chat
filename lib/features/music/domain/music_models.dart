enum MusicArtworkTone {
  twilight,
  sunset,
  aurora,
  ocean,
  rose,
  midnight,
}

class MusicTrack {
  const MusicTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.category,
    required this.description,
    required this.artworkTone,
    this.isFavorite = false,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final String category;
  final String description;
  final MusicArtworkTone artworkTone;
  final bool isFavorite;

  String get durationLabel {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  MusicTrack copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? category,
    String? description,
    MusicArtworkTone? artworkTone,
    bool? isFavorite,
  }) {
    return MusicTrack(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      category: category ?? this.category,
      description: description ?? this.description,
      artworkTone: artworkTone ?? this.artworkTone,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }
}

class MusicPlaylist {
  const MusicPlaylist({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tag,
    required this.trackCount,
    required this.artworkTone,
  });

  final String id;
  final String title;
  final String subtitle;
  final String tag;
  final int trackCount;
  final MusicArtworkTone artworkTone;
}

class MusicCatalogData {
  const MusicCatalogData({
    required this.featuredTrack,
    required this.playlists,
    required this.recentTracks,
    required this.queue,
  });

  final MusicTrack featuredTrack;
  final List<MusicPlaylist> playlists;
  final List<MusicTrack> recentTracks;
  final List<MusicTrack> queue;
}
