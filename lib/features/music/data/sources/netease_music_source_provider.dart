import 'dart:convert';
import 'dart:io';

import '../../../../core/openclaw/openclaw_settings.dart';
import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';
import 'music_source_provider.dart';

class NeteaseMusicSourceProvider implements MusicSourceProvider {
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14; AliceChat) AppleWebKit/537.36';
  static const _playlistPrefix = 'netease-playlist:';

  @override
  String get id => 'netease';

  @override
  Future<List<SourceCandidate>> searchTracks(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      return const <SourceCandidate>[];
    }

    final payload = await _getJson(
      '/api/v1/search/song/get',
      query: <String, String>{
        's': keyword,
        'offset': '0',
        'limit': '12',
      },
    );
    final result = (payload['result'] as Map?)?.cast<String, dynamic>() ?? const {};
    final songs = ((result['songs'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item.cast<String, dynamic>()))
        .toList(growable: false);

    return songs
        .map(_candidateFromSong)
        .whereType<SourceCandidate>()
        .toList(growable: false);
  }

  @override
  Future<SourceCandidate?> matchTrack(MusicTrack track) async {
    final sourceTrackId = track.sourceTrackId?.trim();
    if ((track.preferredSourceId == id || sourceTrackId != null) &&
        sourceTrackId != null &&
        sourceTrackId.isNotEmpty) {
      return SourceCandidate(
        providerId: id,
        sourceTrackId: sourceTrackId,
        track: CanonicalTrack.fromMusicTrack(
          track.copyWith(
            preferredSourceId: id,
            sourceTrackId: sourceTrackId,
          ),
        ),
      );
    }

    final candidates = await searchTracks('${track.title} ${track.artist}');
    if (candidates.isEmpty) {
      return null;
    }

    SourceCandidate? bestCandidate;
    double bestScore = double.negativeInfinity;
    for (final candidate in candidates) {
      final candidateTrack = candidate.track;
      final score = _matchScore(
        queryTitle: track.title,
        queryArtist: track.artist,
        resultTitle: candidateTrack.title,
        resultArtist: candidateTrack.artist,
      );
      if (score > bestScore) {
        bestScore = score;
        bestCandidate = candidate;
      }
    }
    return bestCandidate;
  }

  @override
  Future<ResolvedPlaybackSource?> resolvePlayback(SourceCandidate candidate) async {
    final cookie = await OpenClawSettingsStore.loadMusicProviderCookie(id);
    final payload = await _getJson(
      '/api/song/enhance/player/url',
      query: <String, String>{
        'ids': '[${candidate.sourceTrackId}]',
        'br': '320000',
      },
      cookieHeader: cookie,
    );
    final data = ((payload['data'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item.cast<String, dynamic>()))
        .toList(growable: false);
    if (data.isEmpty) {
      return null;
    }
    final item = data.first;
    final streamUrl = (item['url'] ?? '').toString().trim();
    if (streamUrl.isEmpty) {
      return null;
    }

    final mimeType = (item['type'] ?? '').toString().trim();
    final headers = <String, String>{
      HttpHeaders.userAgentHeader: _userAgent,
      HttpHeaders.refererHeader: 'https://music.163.com/',
      'origin': 'https://music.163.com',
      if ((cookie ?? '').trim().isNotEmpty) HttpHeaders.cookieHeader: cookie!.trim(),
    };

    return ResolvedPlaybackSource(
      providerId: id,
      sourceTrackId: candidate.sourceTrackId,
      streamUrl: streamUrl,
      artworkUrl: candidate.track.artworkUrl,
      mimeType: mimeType.isEmpty ? _inferMimeType(streamUrl) : 'audio/$mimeType',
      headers: headers,
      expiresAt: DateTime.now().add(const Duration(minutes: 20)),
    );
  }

  @override
  Future<List<MusicPlaylist>> loadUserPlaylists() async {
    final cookie = await OpenClawSettingsStore.loadMusicProviderCookie(id);
    if ((cookie ?? '').trim().isEmpty) {
      return const <MusicPlaylist>[];
    }

    final accountPayload = await _getJson(
      '/api/w/nuser/account/get',
      cookieHeader: cookie,
    );
    final profile = (accountPayload['profile'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final userId = (profile['userId'] ?? '').toString().trim();
    if (userId.isEmpty) {
      return const <MusicPlaylist>[];
    }

    final playlistPayload = await _getJson(
      '/api/user/playlist',
      query: <String, String>{
        'uid': userId,
        'limit': '100',
        'offset': '0',
        'includeVideo': 'false',
      },
      cookieHeader: cookie,
    );
    final playlists = ((playlistPayload['playlist'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item.cast<String, dynamic>()))
        .map(_playlistFromMap)
        .whereType<MusicPlaylist>()
        .toList(growable: false);
    return playlists;
  }

  @override
  Future<MusicPlaylist?> loadLikedPlaylist() async {
    final playlists = await loadUserPlaylists();
    if (playlists.isEmpty) return null;
    return playlists.first;
  }

  @override
  Future<List<MusicTrack>> loadPlaylistTracks(String playlistId) async {
    final normalizedId = playlistId.startsWith(_playlistPrefix)
        ? playlistId.substring(_playlistPrefix.length)
        : playlistId;
    if (normalizedId.isEmpty) {
      return const <MusicTrack>[];
    }
    final cookie = await OpenClawSettingsStore.loadMusicProviderCookie(id);
    final payload = await _getJson(
      '/api/v6/playlist/detail',
      query: <String, String>{'id': normalizedId, 'n': '200'},
      cookieHeader: cookie,
    );
    final playlist = (payload['playlist'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final tracks = ((playlist['tracks'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item.cast<String, dynamic>()))
        .map(_candidateFromSong)
        .whereType<SourceCandidate>()
        .map((candidate) => candidate.track.toMusicTrack())
        .toList(growable: false);
    return tracks;
  }

  SourceCandidate? _candidateFromSong(Map<String, dynamic> song) {
    final sourceTrackId = (song['id'] ?? '').toString().trim();
    final title = (song['name'] ?? '').toString().trim();
    if (sourceTrackId.isEmpty || title.isEmpty) {
      return null;
    }

    final artists = ((song['artists'] as List?) ?? song['ar'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => (item['name'] ?? '').toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final album = (song['album'] as Map?)?.cast<String, dynamic>() ??
        (song['al'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final albumTitle = (album['name'] ?? '').toString().trim();
    final artworkUrl = (album['picUrl'] ?? '').toString().trim();
    final durationRaw = song['duration'] ?? song['dt'] ?? 0;
    final durationMs = durationRaw is num
        ? durationRaw.toInt()
        : int.tryParse('$durationRaw') ?? 0;

    final track = MusicTrack(
      id: 'netease:$sourceTrackId',
      title: title,
      artist: artists.isEmpty ? '未知歌手' : artists.join(' / '),
      album: albumTitle.isEmpty ? '网易云音乐' : albumTitle,
      duration: Duration(milliseconds: durationMs),
      category: '网易云音乐',
      description: albumTitle.isEmpty ? '来自网易云音乐搜索结果' : '专辑：$albumTitle',
      artworkTone: _toneForSeed(sourceTrackId),
      artworkUrl: artworkUrl.isEmpty ? null : artworkUrl,
      preferredSourceId: id,
      sourceTrackId: sourceTrackId,
    );

    return SourceCandidate(
      providerId: id,
      sourceTrackId: sourceTrackId,
      track: CanonicalTrack.fromMusicTrack(track),
    );
  }

  MusicPlaylist? _playlistFromMap(Map<String, dynamic> raw) {
    final rawId = (raw['id'] ?? '').toString().trim();
    final title = (raw['name'] ?? '').toString().trim();
    if (rawId.isEmpty || title.isEmpty) {
      return null;
    }
    final description = (raw['description'] ?? '').toString().trim();
    final trackCountRaw = raw['trackCount'] ?? 0;
    final trackCount = trackCountRaw is num
        ? trackCountRaw.toInt()
        : int.tryParse('$trackCountRaw') ?? 0;
    final isLiked = raw['subscribed'] == false ||
        title.contains('喜欢') ||
        title.contains('收藏');
    return MusicPlaylist(
      id: '$_playlistPrefix$rawId',
      title: title,
      subtitle: description.isEmpty
          ? (isLiked ? '网易云“我喜欢”的歌曲' : '来自网易云音乐')
          : description,
      tag: isLiked ? 'LIKED' : 'NETEASE',
      trackCount: trackCount,
      artworkTone: isLiked ? MusicArtworkTone.rose : _toneForSeed(rawId),
    );
  }

  double _matchScore({
    required String queryTitle,
    required String queryArtist,
    required String resultTitle,
    required String resultArtist,
  }) {
    final normalizedQueryTitle = _normalize(queryTitle);
    final normalizedQueryArtist = _normalize(queryArtist);
    final normalizedResultTitle = _normalize(resultTitle);
    final normalizedResultArtist = _normalize(resultArtist);

    var score = 0.0;
    if (normalizedResultTitle == normalizedQueryTitle) {
      score += 10;
    } else if (normalizedResultTitle.contains(normalizedQueryTitle)) {
      score += 6;
    }
    if (normalizedResultArtist == normalizedQueryArtist) {
      score += 10;
    } else if (normalizedResultArtist.contains(normalizedQueryArtist) ||
        normalizedQueryArtist.contains(normalizedResultArtist)) {
      score += 5;
    }
    final durationPenalty = (normalizedResultTitle.length - normalizedQueryTitle.length).abs() * 0.05;
    return score - durationPenalty;
  }

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '').trim();

  MusicArtworkTone _toneForSeed(String seed) {
    final numeric = int.tryParse(seed) ?? seed.hashCode;
    final index = numeric.abs() % MusicArtworkTone.values.length;
    return MusicArtworkTone.values[index];
  }

  String? _inferMimeType(String url) {
    if (url.endsWith('.flac')) return 'audio/flac';
    if (url.endsWith('.m4a')) return 'audio/mp4';
    if (url.endsWith('.mp3')) return 'audio/mpeg';
    return null;
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String> query = const <String, String>{},
    String? cookieHeader,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.https('music.163.com', path, query));
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
      request.headers.set(HttpHeaders.refererHeader, 'https://music.163.com/');
      request.headers.set('origin', 'https://music.163.com');
      final normalizedCookie = (cookieHeader ?? '').trim();
      if (normalizedCookie.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, normalizedCookie);
      }
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return <String, dynamic>{'raw': body};
    } finally {
      client.close(force: true);
    }
  }
}
