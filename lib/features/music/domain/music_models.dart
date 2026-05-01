enum MusicArtworkTone {
  twilight,
  sunset,
  aurora,
  ocean,
  rose,
  midnight,
}

class CachedPlaybackSource {
  const CachedPlaybackSource({
    required this.providerId,
    required this.sourceTrackId,
    required this.streamUrl,
    this.artworkUrl,
    this.mimeType,
    this.headers = const {},
    this.expiresAt,
    this.resolvedAt,
  });

  final String providerId;
  final String sourceTrackId;
  final String streamUrl;
  final String? artworkUrl;
  final String? mimeType;
  final Map<String, String> headers;
  final DateTime? expiresAt;
  final DateTime? resolvedAt;

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  Map<String, dynamic> toMap() {
    return {
      'providerId': providerId,
      'sourceTrackId': sourceTrackId,
      'streamUrl': streamUrl,
      if (artworkUrl != null && artworkUrl!.isNotEmpty) 'artworkUrl': artworkUrl,
      if (mimeType != null && mimeType!.isNotEmpty) 'mimeType': mimeType,
      if (headers.isNotEmpty) 'headers': headers,
      if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
      if (resolvedAt != null) 'resolvedAt': resolvedAt!.toIso8601String(),
    };
  }

  factory CachedPlaybackSource.fromMap(Map<String, dynamic> map) {
    final rawHeaders = (map['headers'] as Map?)?.cast<String, dynamic>() ?? const {};
    return CachedPlaybackSource(
      providerId: (map['providerId'] ?? '').toString(),
      sourceTrackId: (map['sourceTrackId'] ?? '').toString(),
      streamUrl: (map['streamUrl'] ?? '').toString(),
      artworkUrl: (map['artworkUrl'] ?? '').toString().trim().isEmpty
          ? null
          : (map['artworkUrl'] ?? '').toString(),
      mimeType: (map['mimeType'] ?? '').toString().trim().isEmpty
          ? null
          : (map['mimeType'] ?? '').toString(),
      headers: rawHeaders.map((key, value) => MapEntry(key, '$value')),
      expiresAt: (map['expiresAt'] ?? '').toString().trim().isEmpty
          ? null
          : DateTime.tryParse((map['expiresAt'] ?? '').toString()),
      resolvedAt: (map['resolvedAt'] ?? '').toString().trim().isEmpty
          ? null
          : DateTime.tryParse((map['resolvedAt'] ?? '').toString()),
    );
  }
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
    this.cachedPlayback,
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
  final CachedPlaybackSource? cachedPlayback;

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
      if (cachedPlayback != null) 'cachedPlayback': cachedPlayback!.toMap(),
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
      cachedPlayback: map['cachedPlayback'] is Map
          ? CachedPlaybackSource.fromMap(
              Map<String, dynamic>.from(
                (map['cachedPlayback'] as Map).cast<String, dynamic>(),
              ),
            )
          : null,
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
    CachedPlaybackSource? cachedPlayback,
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
      cachedPlayback: cachedPlayback ?? this.cachedPlayback,
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

class MusicAiPlaylistDraft {
  const MusicAiPlaylistDraft({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.tag,
    required this.artworkTone,
    this.isAiGenerated = true,
    this.tracks = const [],
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String subtitle;
  final String description;
  final String tag;
  final MusicArtworkTone artworkTone;
  final bool isAiGenerated;
  final List<MusicTrack> tracks;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  MusicPlaylist get asPlaylist => MusicPlaylist(
    id: id,
    title: title,
    subtitle: subtitle,
    tag: tag,
    trackCount: tracks.length,
    artworkTone: artworkTone,
    isAiGenerated: isAiGenerated,
  );

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'description': description,
      'tag': tag,
      'artworkTone': artworkTone.name,
      'isAiGenerated': isAiGenerated,
      'tracks': tracks.map((item) => item.toMap()).toList(),
      if (createdAt != null) 'createdAt': createdAt!.millisecondsSinceEpoch / 1000,
      if (updatedAt != null) 'updatedAt': updatedAt!.millisecondsSinceEpoch / 1000,
    };
  }

  factory MusicAiPlaylistDraft.fromMap(Map<String, dynamic> map) {
    DateTime? parseTs(dynamic raw) {
      if (raw is num) {
        return DateTime.fromMillisecondsSinceEpoch((raw * 1000).round());
      }
      final parsed = double.tryParse('$raw');
      if (parsed == null) return null;
      return DateTime.fromMillisecondsSinceEpoch((parsed * 1000).round());
    }

    return MusicAiPlaylistDraft(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      subtitle: (map['subtitle'] ?? '').toString(),
      description: (map['description'] ?? '').toString(),
      tag: (map['tag'] ?? 'AI').toString(),
      artworkTone: musicArtworkToneFromName(
        (map['artworkTone'] ?? MusicArtworkTone.aurora.name).toString(),
      ),
      isAiGenerated: map['isAiGenerated'] != false,
      tracks: ((map['tracks'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map(
            (item) => MusicTrack.fromMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            ),
          )
          .toList(growable: false),
      createdAt: parseTs(map['createdAt']),
      updatedAt: parseTs(map['updatedAt']),
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
