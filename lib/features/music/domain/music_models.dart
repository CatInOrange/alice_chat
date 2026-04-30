enum MusicArtworkTone {
  twilight,
  sunset,
  aurora,
  ocean,
  rose,
  midnight,
}

MusicArtworkTone musicArtworkToneFromName(String value) {
  return MusicArtworkTone.values.firstWhere(
    (tone) => tone.name == value,
    orElse: () => MusicArtworkTone.twilight,
  );
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
    this.artworkUrl,
    this.preferredSourceId,
    this.sourceTrackId,
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
  final String? artworkUrl;
  final String? preferredSourceId;
  final String? sourceTrackId;

  String get durationLabel {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'durationMs': duration.inMilliseconds,
      'category': category,
      'description': description,
      'artworkTone': artworkTone.name,
      'isFavorite': isFavorite,
      if (artworkUrl != null && artworkUrl!.isNotEmpty) 'artworkUrl': artworkUrl,
      if (preferredSourceId != null && preferredSourceId!.isNotEmpty)
        'preferredSourceId': preferredSourceId,
      if (sourceTrackId != null && sourceTrackId!.isNotEmpty)
        'sourceTrackId': sourceTrackId,
    };
  }

  factory MusicTrack.fromMap(Map<String, dynamic> map) {
    final durationMsRaw = map['durationMs'] ?? map['duration'] ?? 0;
    final durationMs =
        durationMsRaw is num
            ? durationMsRaw.toInt()
            : int.tryParse('$durationMsRaw') ?? 0;
    return MusicTrack(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      artist: (map['artist'] ?? '').toString(),
      album: (map['album'] ?? '').toString(),
      duration: Duration(milliseconds: durationMs),
      category: (map['category'] ?? '').toString(),
      description: (map['description'] ?? '').toString(),
      artworkTone: musicArtworkToneFromName(
        (map['artworkTone'] ?? MusicArtworkTone.twilight.name).toString(),
      ),
      isFavorite: map['isFavorite'] == true,
      artworkUrl: (map['artworkUrl'] ?? '').toString().trim().isEmpty
          ? null
          : (map['artworkUrl'] ?? '').toString(),
      preferredSourceId: (map['preferredSourceId'] ?? '').toString().trim().isEmpty
          ? null
          : (map['preferredSourceId'] ?? '').toString(),
      sourceTrackId: (map['sourceTrackId'] ?? '').toString().trim().isEmpty
          ? null
          : (map['sourceTrackId'] ?? '').toString(),
    );
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
    String? artworkUrl,
    String? preferredSourceId,
    String? sourceTrackId,
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
      artworkUrl: artworkUrl ?? this.artworkUrl,
      preferredSourceId: preferredSourceId ?? this.preferredSourceId,
      sourceTrackId: sourceTrackId ?? this.sourceTrackId,
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
    this.isAiGenerated = false,
  });

  final String id;
  final String title;
  final String subtitle;
  final String tag;
  final int trackCount;
  final MusicArtworkTone artworkTone;
  final bool isAiGenerated;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'tag': tag,
      'trackCount': trackCount,
      'artworkTone': artworkTone.name,
      'isAiGenerated': isAiGenerated,
    };
  }

  factory MusicPlaylist.fromMap(Map<String, dynamic> map) {
    final trackCountRaw = map['trackCount'] ?? 0;
    return MusicPlaylist(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      subtitle: (map['subtitle'] ?? '').toString(),
      tag: (map['tag'] ?? '').toString(),
      trackCount: trackCountRaw is num
          ? trackCountRaw.toInt()
          : int.tryParse('$trackCountRaw') ?? 0,
      artworkTone: musicArtworkToneFromName(
        (map['artworkTone'] ?? MusicArtworkTone.twilight.name).toString(),
      ),
      isAiGenerated: map['isAiGenerated'] == true,
    );
  }
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
