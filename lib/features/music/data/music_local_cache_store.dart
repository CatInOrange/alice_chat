import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../application/music_store.dart';
import '../domain/music_models.dart';
import '../domain/music_runtime_models.dart';

class MusicLocalCacheSnapshot {
  const MusicLocalCacheSnapshot({
    required this.state,
    this.latestAiPlaylist,
    this.aiPlaylistHistory = const [],
    this.playlistTracksCache = const {},
    this.cachedAt,
    this.localRevision = 0,
    this.lastAckedRevision = 0,
    this.hasPendingSync = false,
  });

  final MusicStateSnapshot state;
  final MusicAiPlaylistDraft? latestAiPlaylist;
  final List<MusicAiPlaylistDraft> aiPlaylistHistory;
  final Map<String, List<MusicTrack>> playlistTracksCache;
  final DateTime? cachedAt;
  final int localRevision;
  final int lastAckedRevision;
  final bool hasPendingSync;
}

class MusicLikedCacheBucket {
  const MusicLikedCacheBucket({
    this.likedTracks = const [],
    this.neteaseLikedPlaylistId,
    this.neteaseLikedPlaylistOpaqueId,
    this.cachedAt,
  });

  final List<MusicTrack> likedTracks;
  final String? neteaseLikedPlaylistId;
  final String? neteaseLikedPlaylistOpaqueId;
  final DateTime? cachedAt;
}

class MusicLocalCacheStore {
  static const String _legacyCacheKey = 'alicechat.music.local_cache.v1';
  static const String _v2Prefix = 'alicechat.music.local_cache.v2';
  static const String _metaKey = '$_v2Prefix.meta';
  static const String _playbackKey = '$_v2Prefix.playback';
  static const String _libraryKey = '$_v2Prefix.library';
  static const String _likedKey = '$_v2Prefix.liked';
  static const String _aiKey = '$_v2Prefix.ai';
  static const String _playlistTracksKey = '$_v2Prefix.playlist_tracks';

  Future<MusicLocalCacheSnapshot?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final snapshot = _loadV2(prefs);
      if (snapshot != null) {
        return snapshot;
      }
      return _loadLegacyV1(prefs);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(MusicLocalCacheSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    final playbackPayload = <String, dynamic>{
      if (snapshot.state.currentTrack != null)
        'currentTrack': snapshot.state.currentTrack!.toMap(),
      'queue': snapshot.state.queue.map((item) => item.toMap()).toList(),
      if (snapshot.state.currentPlaylistId != null)
        'currentPlaylistId': snapshot.state.currentPlaylistId,
      'isPlaying': snapshot.state.isPlaying,
      'positionMs': snapshot.state.position.inMilliseconds,
    };
    final libraryPayload = <String, dynamic>{
      'playlists':
          snapshot.state.playlists.map((item) => item.toMap()).toList(),
      'recentTracks':
          snapshot.state.recentTracks.map((item) => item.toMap()).toList(),
      'likedTracks':
          snapshot.state.likedTracks.map((item) => item.toMap()).toList(),
      'recentPlaylists':
          snapshot.state.recentPlaylists.map((item) => item.toMap()).toList(),
      'customPlaylists':
          snapshot.state.customPlaylists.map((item) => item.toMap()).toList(),
      if (snapshot.state.neteaseLikedPlaylistId != null)
        'neteaseLikedPlaylistId': snapshot.state.neteaseLikedPlaylistId,
      if (snapshot.state.neteaseLikedPlaylistOpaqueId != null)
        'neteaseLikedPlaylistOpaqueId':
            snapshot.state.neteaseLikedPlaylistOpaqueId,
    };
    final likedPayload = <String, dynamic>{
      'likedTracks':
          snapshot.state.likedTracks.map((item) => item.toMap()).toList(),
      if (snapshot.state.neteaseLikedPlaylistId != null)
        'neteaseLikedPlaylistId': snapshot.state.neteaseLikedPlaylistId,
      if (snapshot.state.neteaseLikedPlaylistOpaqueId != null)
        'neteaseLikedPlaylistOpaqueId':
            snapshot.state.neteaseLikedPlaylistOpaqueId,
      'cachedAt': (snapshot.cachedAt ?? DateTime.now()).toIso8601String(),
    };
    final aiPayload = <String, dynamic>{
      if (snapshot.latestAiPlaylist != null)
        'latestAiPlaylist': snapshot.latestAiPlaylist!.toMap(),
      'aiPlaylistHistory':
          snapshot.aiPlaylistHistory.map((item) => item.toMap()).toList(),
    };
    final playlistTracksPayload = snapshot.playlistTracksCache.map(
      (key, value) => MapEntry(
        key,
        value.map((item) => item.toMap()).toList(growable: false),
      ),
    );
    final metaPayload = <String, dynamic>{
      'version': 2,
      'cachedAt': (snapshot.cachedAt ?? DateTime.now()).toIso8601String(),
      'localRevision': snapshot.localRevision,
      'lastAckedRevision': snapshot.lastAckedRevision,
      'hasPendingSync': snapshot.hasPendingSync,
    };

    await _setStringIfChanged(prefs, _metaKey, jsonEncode(metaPayload));
    await _setStringIfChanged(prefs, _playbackKey, jsonEncode(playbackPayload));
    await _setStringIfChanged(prefs, _libraryKey, jsonEncode(libraryPayload));
    await _setStringIfChanged(prefs, _likedKey, jsonEncode(likedPayload));
    await _setStringIfChanged(prefs, _aiKey, jsonEncode(aiPayload));
    await _setStringIfChanged(
      prefs,
      _playlistTracksKey,
      jsonEncode(playlistTracksPayload),
    );
  }

  MusicLocalCacheSnapshot? _loadV2(SharedPreferences prefs) {
    final meta = _decodeMap(prefs.getString(_metaKey));
    final playback = _decodeMap(prefs.getString(_playbackKey));
    final library = _decodeMap(prefs.getString(_libraryKey));
    final ai = _decodeMap(prefs.getString(_aiKey));
    final playlistTracks = _decodeMap(prefs.getString(_playlistTracksKey));
    if (meta == null &&
        playback == null &&
        library == null &&
        ai == null &&
        playlistTracks == null) {
      return null;
    }

    final latestAiMap =
        (ai?['latestAiPlaylist'] as Map?)?.cast<String, dynamic>();
    final aiHistoryRaw =
        (ai?['aiPlaylistHistory'] as List<dynamic>?) ?? const [];
    final playlistCacheRaw =
        (playlistTracks ?? const <String, dynamic>{}).cast<String, dynamic>();

    return MusicLocalCacheSnapshot(
      state: MusicStateSnapshot(
        currentTrack:
            playback?['currentTrack'] is Map
                ? MusicTrack.fromMap(
                  Map<String, dynamic>.from(
                    (playback!['currentTrack'] as Map).cast<String, dynamic>(),
                  ),
                )
                : null,
        queue: _queueFromList(playback?['queue'] as List<dynamic>?),
        playlists: _playlistsFromList(library?['playlists'] as List<dynamic>?),
        recentTracks: _tracksFromList(
          library?['recentTracks'] as List<dynamic>?,
        ),
        likedTracks: _tracksFromList(library?['likedTracks'] as List<dynamic>?),
        recentPlaylists: _playlistsFromList(
          library?['recentPlaylists'] as List<dynamic>?,
        ),
        customPlaylists: _customPlaylistsFromList(
          library?['customPlaylists'] as List<dynamic>?,
        ),
        currentPlaylistId: _nullableString(playback?['currentPlaylistId']),
        neteaseLikedPlaylistId: _nullableString(
          library?['neteaseLikedPlaylistId'],
        ),
        neteaseLikedPlaylistOpaqueId: _nullableString(
          library?['neteaseLikedPlaylistOpaqueId'] ??
              library?['neteaseLikedPlaylistEncryptedId'],
        ),
        isPlaying: playback?['isPlaying'] == true,
        position: Duration(milliseconds: _intValue(playback?['positionMs'])),
      ),
      latestAiPlaylist:
          latestAiMap == null
              ? null
              : MusicAiPlaylistDraft.fromMap(latestAiMap),
      aiPlaylistHistory: aiHistoryRaw
          .whereType<Map>()
          .map(
            (item) => MusicAiPlaylistDraft.fromMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            ),
          )
          .toList(growable: false),
      playlistTracksCache: playlistCacheRaw.map(
        (key, value) => MapEntry(key, _tracksFromList(value as List<dynamic>?)),
      ),
      cachedAt: _nullableDateTime(meta?['cachedAt']),
      localRevision: _intValue(meta?['localRevision']),
      lastAckedRevision: _intValue(meta?['lastAckedRevision']),
      hasPendingSync: meta?['hasPendingSync'] == true,
    );
  }

  Future<MusicLikedCacheBucket?> loadLikedCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final liked = _decodeMap(prefs.getString(_likedKey));
      if (liked != null) {
        return MusicLikedCacheBucket(
          likedTracks: _tracksFromList(liked['likedTracks'] as List<dynamic>?),
          neteaseLikedPlaylistId: _nullableString(
            liked['neteaseLikedPlaylistId'],
          ),
          neteaseLikedPlaylistOpaqueId: _nullableString(
            liked['neteaseLikedPlaylistOpaqueId'] ??
                liked['neteaseLikedPlaylistEncryptedId'],
          ),
          cachedAt: _nullableDateTime(liked['cachedAt']),
        );
      }

      final library = _decodeMap(prefs.getString(_libraryKey));
      if (library != null) {
        return MusicLikedCacheBucket(
          likedTracks: _tracksFromList(
            library['likedTracks'] as List<dynamic>?,
          ),
          neteaseLikedPlaylistId: _nullableString(
            library['neteaseLikedPlaylistId'],
          ),
          neteaseLikedPlaylistOpaqueId: _nullableString(
            library['neteaseLikedPlaylistOpaqueId'] ??
                library['neteaseLikedPlaylistEncryptedId'],
          ),
        );
      }

      final legacy = _loadLegacyV1(prefs);
      if (legacy == null) {
        return null;
      }
      return MusicLikedCacheBucket(
        likedTracks: legacy.state.likedTracks,
        neteaseLikedPlaylistId: legacy.state.neteaseLikedPlaylistId,
        neteaseLikedPlaylistOpaqueId: legacy.state.neteaseLikedPlaylistOpaqueId,
        cachedAt: legacy.cachedAt,
      );
    } catch (_) {
      return null;
    }
  }

  MusicLocalCacheSnapshot? _loadLegacyV1(SharedPreferences prefs) {
    final map = _decodeMap(prefs.getString(_legacyCacheKey));
    if (map == null) {
      return null;
    }
    final stateMap =
        (map['state'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final latestAiMap =
        (map['latestAiPlaylist'] as Map?)?.cast<String, dynamic>();
    final aiHistoryRaw =
        (map['aiPlaylistHistory'] as List<dynamic>?) ?? const [];
    final playlistCacheRaw =
        (map['playlistTracksCache'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    return MusicLocalCacheSnapshot(
      state: MusicStateSnapshot(
        currentTrack:
            stateMap['currentTrack'] is Map
                ? MusicTrack.fromMap(
                  Map<String, dynamic>.from(
                    (stateMap['currentTrack'] as Map).cast<String, dynamic>(),
                  ),
                )
                : null,
        queue: _queueFromList(stateMap['queue'] as List<dynamic>?),
        playlists: _playlistsFromList(stateMap['playlists'] as List<dynamic>?),
        recentTracks: _tracksFromList(
          stateMap['recentTracks'] as List<dynamic>?,
        ),
        likedTracks: _tracksFromList(stateMap['likedTracks'] as List<dynamic>?),
        recentPlaylists: _playlistsFromList(
          stateMap['recentPlaylists'] as List<dynamic>?,
        ),
        customPlaylists: _customPlaylistsFromList(
          stateMap['customPlaylists'] as List<dynamic>?,
        ),
        currentPlaylistId: _nullableString(stateMap['currentPlaylistId']),
        neteaseLikedPlaylistId: _nullableString(
          stateMap['neteaseLikedPlaylistId'],
        ),
        neteaseLikedPlaylistOpaqueId: _nullableString(
          stateMap['neteaseLikedPlaylistOpaqueId'] ??
              stateMap['neteaseLikedPlaylistEncryptedId'],
        ),
        isPlaying: stateMap['isPlaying'] == true,
        position: Duration(milliseconds: _intValue(stateMap['positionMs'])),
      ),
      latestAiPlaylist:
          latestAiMap == null
              ? null
              : MusicAiPlaylistDraft.fromMap(latestAiMap),
      aiPlaylistHistory: aiHistoryRaw
          .whereType<Map>()
          .map(
            (item) => MusicAiPlaylistDraft.fromMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            ),
          )
          .toList(growable: false),
      playlistTracksCache: playlistCacheRaw.map(
        (key, value) => MapEntry(key, _tracksFromList(value as List<dynamic>?)),
      ),
      cachedAt: _nullableDateTime(map['cachedAt']),
      localRevision: _intValue(map['localRevision']),
      lastAckedRevision: _intValue(map['lastAckedRevision']),
      hasPendingSync: map['hasPendingSync'] == true,
    );
  }

  static Future<void> _setStringIfChanged(
    SharedPreferences prefs,
    String key,
    String nextValue,
  ) async {
    if (prefs.getString(key) == nextValue) {
      return;
    }
    await prefs.setString(key, nextValue);
  }

  static Map<String, dynamic>? _decodeMap(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(value);
    if (decoded is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(decoded.cast<String, dynamic>());
  }

  static List<MusicTrack> _tracksFromList(List<dynamic>? raw) {
    return (raw ?? const [])
        .whereType<Map>()
        .map(
          (item) => MusicTrack.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
  }

  static List<MusicPlaylist> _playlistsFromList(List<dynamic>? raw) {
    return (raw ?? const [])
        .whereType<Map>()
        .map(
          (item) => MusicPlaylist.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
  }

  static List<CustomMusicPlaylist> _customPlaylistsFromList(
    List<dynamic>? raw,
  ) {
    return (raw ?? const [])
        .whereType<Map>()
        .map(
          (item) => CustomMusicPlaylist.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
  }

  static List<PlaybackQueueItem> _queueFromList(List<dynamic>? raw) {
    return (raw ?? const [])
        .whereType<Map>()
        .map(
          (item) => PlaybackQueueItem.fromMap(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);
  }

  static int _intValue(dynamic raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse('$raw') ?? 0;
  }

  static String? _nullableString(dynamic raw) {
    final value = (raw ?? '').toString().trim();
    return value.isEmpty ? null : value;
  }

  static DateTime? _nullableDateTime(dynamic raw) {
    final value = (raw ?? '').toString().trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
}
