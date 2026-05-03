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

class MusicLocalCacheStore {
  static const String _cacheKey = 'alicechat.music.local_cache.v1';

  Future<MusicLocalCacheSnapshot?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey)?.trim();
      if (raw == null || raw.isEmpty) {
        return null;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      final map = Map<String, dynamic>.from(decoded.cast<String, dynamic>());
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
          queue: ((stateMap['queue'] as List<dynamic>?) ?? const [])
              .whereType<Map>()
              .map(
                (item) => PlaybackQueueItem.fromMap(
                  Map<String, dynamic>.from(item.cast<String, dynamic>()),
                ),
              )
              .toList(growable: false),
          playlists: ((stateMap['playlists'] as List<dynamic>?) ?? const [])
              .whereType<Map>()
              .map(
                (item) => MusicPlaylist.fromMap(
                  Map<String, dynamic>.from(item.cast<String, dynamic>()),
                ),
              )
              .toList(growable: false),
          recentTracks: ((stateMap['recentTracks'] as List<dynamic>?) ??
                  const [])
              .whereType<Map>()
              .map(
                (item) => MusicTrack.fromMap(
                  Map<String, dynamic>.from(item.cast<String, dynamic>()),
                ),
              )
              .toList(growable: false),
          likedTracks: ((stateMap['likedTracks'] as List<dynamic>?) ?? const [])
              .whereType<Map>()
              .map(
                (item) => MusicTrack.fromMap(
                  Map<String, dynamic>.from(item.cast<String, dynamic>()),
                ),
              )
              .toList(growable: false),
          recentPlaylists: ((stateMap['recentPlaylists'] as List<dynamic>?) ??
                  const [])
              .whereType<Map>()
              .map(
                (item) => MusicPlaylist.fromMap(
                  Map<String, dynamic>.from(item.cast<String, dynamic>()),
                ),
              )
              .toList(growable: false),
          customPlaylists: ((stateMap['customPlaylists'] as List<dynamic>?) ??
                  const [])
              .whereType<Map>()
              .map(
                (item) => CustomMusicPlaylist.fromMap(
                  Map<String, dynamic>.from(item.cast<String, dynamic>()),
                ),
              )
              .toList(growable: false),
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
          (key, value) => MapEntry(
            key,
            ((value as List<dynamic>?) ?? const [])
                .whereType<Map>()
                .map(
                  (item) => MusicTrack.fromMap(
                    Map<String, dynamic>.from(item.cast<String, dynamic>()),
                  ),
                )
                .toList(growable: false),
          ),
        ),
        cachedAt: _nullableDateTime(map['cachedAt']),
        localRevision: _intValue(map['localRevision']),
        lastAckedRevision: _intValue(map['lastAckedRevision']),
        hasPendingSync: map['hasPendingSync'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(MusicLocalCacheSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'cachedAt': (snapshot.cachedAt ?? DateTime.now()).toIso8601String(),
      'state': {
        if (snapshot.state.currentTrack != null)
          'currentTrack': snapshot.state.currentTrack!.toMap(),
        'queue': snapshot.state.queue.map((item) => item.toMap()).toList(),
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
        if (snapshot.state.currentPlaylistId != null)
          'currentPlaylistId': snapshot.state.currentPlaylistId,
        if (snapshot.state.neteaseLikedPlaylistId != null)
          'neteaseLikedPlaylistId': snapshot.state.neteaseLikedPlaylistId,
        if (snapshot.state.neteaseLikedPlaylistOpaqueId != null)
          'neteaseLikedPlaylistOpaqueId':
              snapshot.state.neteaseLikedPlaylistOpaqueId,
        'isPlaying': snapshot.state.isPlaying,
        'positionMs': snapshot.state.position.inMilliseconds,
      },
      if (snapshot.latestAiPlaylist != null)
        'latestAiPlaylist': snapshot.latestAiPlaylist!.toMap(),
      'aiPlaylistHistory':
          snapshot.aiPlaylistHistory.map((item) => item.toMap()).toList(),
      'playlistTracksCache': snapshot.playlistTracksCache.map(
        (key, value) => MapEntry(
          key,
          value.map((item) => item.toMap()).toList(growable: false),
        ),
      ),
      'localRevision': snapshot.localRevision,
      'lastAckedRevision': snapshot.lastAckedRevision,
      'hasPendingSync': snapshot.hasPendingSync,
    };
    await prefs.setString(_cacheKey, jsonEncode(payload));
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
