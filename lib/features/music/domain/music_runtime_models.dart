import 'music_models.dart';

class MusicSourceRef {
  const MusicSourceRef({
    required this.providerId,
    required this.sourceTrackId,
    this.sourceUrl,
  });

  final String providerId;
  final String sourceTrackId;
  final String? sourceUrl;

  Map<String, dynamic> toMap() {
    return {
      'providerId': providerId,
      'sourceTrackId': sourceTrackId,
      if (sourceUrl != null && sourceUrl!.isNotEmpty) 'sourceUrl': sourceUrl,
    };
  }

  factory MusicSourceRef.fromMap(Map<String, dynamic> map) {
    return MusicSourceRef(
      providerId: (map['providerId'] ?? '').toString(),
      sourceTrackId: (map['sourceTrackId'] ?? '').toString(),
      sourceUrl: (map['sourceUrl'] ?? '').toString().trim().isEmpty
          ? null
          : (map['sourceUrl'] ?? '').toString(),
    );
  }
}

class CanonicalTrack {
  const CanonicalTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.artworkTone,
    this.category = '',
    this.description = '',
    this.artworkUrl,
    this.sourceRefs = const [],
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final MusicArtworkTone artworkTone;
  final String category;
  final String description;
  final String? artworkUrl;
  final List<MusicSourceRef> sourceRefs;

  MusicTrack toMusicTrack({bool isFavorite = false}) {
    final preferredRef = sourceRefs.isNotEmpty ? sourceRefs.first : null;
    return MusicTrack(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      category: category,
      description: description,
      artworkTone: artworkTone,
      isFavorite: isFavorite,
      artworkUrl: artworkUrl,
      preferredSourceId: preferredRef?.providerId,
      sourceTrackId: preferredRef?.sourceTrackId,
    );
  }

  factory CanonicalTrack.fromMusicTrack(MusicTrack track) {
    final refs =
        track.preferredSourceId != null && track.sourceTrackId != null
            ? [
                MusicSourceRef(
                  providerId: track.preferredSourceId!,
                  sourceTrackId: track.sourceTrackId!,
                ),
              ]
            : const <MusicSourceRef>[];
    return CanonicalTrack(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.duration,
      artworkTone: track.artworkTone,
      category: track.category,
      description: track.description,
      artworkUrl: track.artworkUrl,
      sourceRefs: refs,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'durationMs': duration.inMilliseconds,
      'artworkTone': artworkTone.name,
      'category': category,
      'description': description,
      if (artworkUrl != null && artworkUrl!.isNotEmpty) 'artworkUrl': artworkUrl,
      'sourceRefs': sourceRefs.map((item) => item.toMap()).toList(),
    };
  }

  factory CanonicalTrack.fromMap(Map<String, dynamic> map) {
    final durationMsRaw = map['durationMs'] ?? 0;
    return CanonicalTrack(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      artist: (map['artist'] ?? '').toString(),
      album: (map['album'] ?? '').toString(),
      duration: Duration(
        milliseconds: durationMsRaw is num
            ? durationMsRaw.toInt()
            : int.tryParse('$durationMsRaw') ?? 0,
      ),
      artworkTone: musicArtworkToneFromName(
        (map['artworkTone'] ?? MusicArtworkTone.twilight.name).toString(),
      ),
      category: (map['category'] ?? '').toString(),
      description: (map['description'] ?? '').toString(),
      artworkUrl: (map['artworkUrl'] ?? '').toString().trim().isEmpty
          ? null
          : (map['artworkUrl'] ?? '').toString(),
      sourceRefs: ((map['sourceRefs'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map(
            (item) => MusicSourceRef.fromMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            ),
          )
          .toList(growable: false),
    );
  }
}

class SourceCandidate {
  const SourceCandidate({
    required this.providerId,
    required this.sourceTrackId,
    required this.track,
    this.matchScore = 1,
    this.available = true,
    this.sourceUrl,
  });

  final String providerId;
  final String sourceTrackId;
  final CanonicalTrack track;
  final double matchScore;
  final bool available;
  final String? sourceUrl;

  Map<String, dynamic> toMap() {
    return {
      'providerId': providerId,
      'sourceTrackId': sourceTrackId,
      'track': track.toMap(),
      'matchScore': matchScore,
      'available': available,
      if (sourceUrl != null && sourceUrl!.isNotEmpty) 'sourceUrl': sourceUrl,
    };
  }

  factory SourceCandidate.fromMap(Map<String, dynamic> map) {
    final scoreRaw = map['matchScore'] ?? 1;
    return SourceCandidate(
      providerId: (map['providerId'] ?? '').toString(),
      sourceTrackId: (map['sourceTrackId'] ?? '').toString(),
      track: CanonicalTrack.fromMap(
        Map<String, dynamic>.from((map['track'] as Map?)?.cast<String, dynamic>() ?? const {}),
      ),
      matchScore: scoreRaw is num ? scoreRaw.toDouble() : double.tryParse('$scoreRaw') ?? 1,
      available: map['available'] != false,
      sourceUrl: (map['sourceUrl'] ?? '').toString().trim().isEmpty
          ? null
          : (map['sourceUrl'] ?? '').toString(),
    );
  }
}

class ResolvedPlaybackSource {
  const ResolvedPlaybackSource({
    required this.providerId,
    required this.sourceTrackId,
    required this.streamUrl,
    this.artworkUrl,
    this.mimeType,
    this.headers = const {},
    this.expiresAt,
  });

  final String providerId;
  final String sourceTrackId;
  final String streamUrl;
  final String? artworkUrl;
  final String? mimeType;
  final Map<String, String> headers;
  final DateTime? expiresAt;

  Map<String, dynamic> toMap() {
    return {
      'providerId': providerId,
      'sourceTrackId': sourceTrackId,
      'streamUrl': streamUrl,
      if (artworkUrl != null && artworkUrl!.isNotEmpty) 'artworkUrl': artworkUrl,
      if (mimeType != null && mimeType!.isNotEmpty) 'mimeType': mimeType,
      if (headers.isNotEmpty) 'headers': headers,
      if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
    };
  }

  factory ResolvedPlaybackSource.fromMap(Map<String, dynamic> map) {
    final rawHeaders = (map['headers'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ResolvedPlaybackSource(
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
    );
  }
}

class PlaybackQueueItem {
  const PlaybackQueueItem({
    required this.track,
    this.candidate,
    this.resolvedSource,
    this.requestedBy = '',
  });

  final MusicTrack track;
  final SourceCandidate? candidate;
  final ResolvedPlaybackSource? resolvedSource;
  final String requestedBy;

  PlaybackQueueItem copyWith({
    MusicTrack? track,
    SourceCandidate? candidate,
    ResolvedPlaybackSource? resolvedSource,
    String? requestedBy,
  }) {
    return PlaybackQueueItem(
      track: track ?? this.track,
      candidate: candidate ?? this.candidate,
      resolvedSource: resolvedSource ?? this.resolvedSource,
      requestedBy: requestedBy ?? this.requestedBy,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'track': track.toMap(),
      if (candidate != null) 'candidate': candidate!.toMap(),
      if (resolvedSource != null) 'resolvedSource': resolvedSource!.toMap(),
      if (requestedBy.isNotEmpty) 'requestedBy': requestedBy,
    };
  }

  factory PlaybackQueueItem.fromMap(Map<String, dynamic> map) {
    return PlaybackQueueItem(
      track: MusicTrack.fromMap(
        Map<String, dynamic>.from((map['track'] as Map?)?.cast<String, dynamic>() ?? const {}),
      ),
      candidate: map['candidate'] is Map
          ? SourceCandidate.fromMap(
              Map<String, dynamic>.from((map['candidate'] as Map).cast<String, dynamic>()),
            )
          : null,
      resolvedSource: map['resolvedSource'] is Map
          ? ResolvedPlaybackSource.fromMap(
              Map<String, dynamic>.from((map['resolvedSource'] as Map).cast<String, dynamic>()),
            )
          : null,
      requestedBy: (map['requestedBy'] ?? '').toString(),
    );
  }
}
