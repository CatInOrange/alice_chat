import 'dart:convert';
import 'dart:io';

import '../../../../core/openclaw/openclaw_settings.dart';
import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';
import 'music_source_provider.dart';

class NeteaseMusicSourceProvider extends MusicSourceProvider {
  final Map<String, MusicLyrics?> _lyricsCache = <String, MusicLyrics?>{};
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14; AliceChat) AppleWebKit/537.36';
  static const _playlistPrefix = 'netease-playlist:';
  static const _seedCookieKeys = <String>['NMTID', '_ntes_nuid', '_ntes_nnid3'];

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
  Future<MusicLyrics?> loadLyrics(MusicTrack track) async {
    final key = '${track.preferredSourceId ?? id}:${track.sourceTrackId ?? track.id}';
    if (_lyricsCache.containsKey(key)) {
      return _lyricsCache[key];
    }
    final candidate = await matchTrack(track);
    final sourceTrackId =
        candidate?.sourceTrackId.trim() ?? track.sourceTrackId?.trim() ?? '';
    if (sourceTrackId.isEmpty) {
      _lyricsCache[key] = null;
      return null;
    }
    try {
      final payload = await _getJson(
        '/api/song/lyric',
        query: <String, String>{'id': sourceTrackId, 'lv': '1', 'tv': '0'},
        cookieHeader: _seedCookieHeader(
          await OpenClawSettingsStore.loadMusicProviderCookie(id),
        ),
      );
      final lyric = ((payload['lrc'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{})['lyric']
          ?.toString() ??
          '';
      final translated = ((payload['tlyric'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{})['lyric']
          ?.toString() ??
          '';
      final parsed = _parseLyrics(lyric, translated: translated);
      _lyricsCache[key] = parsed;
      return parsed;
    } catch (_) {
      _lyricsCache[key] = null;
      return null;
    }
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
      cookieHeader: _seedCookieHeader(cookie),
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
      if ((_seedCookieHeader(cookie) ?? '').trim().isNotEmpty)
        HttpHeaders.cookieHeader: _seedCookieHeader(cookie)!.trim(),
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

    final seededCookie = _seedCookieHeader(cookie);
    final accountPayload = await _getJson(
      '/api/nuser/account/get',
      cookieHeader: seededCookie,
    );
    final account = (accountPayload['account'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final profile = (accountPayload['profile'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final userId = (profile['userId'] ?? account['id'] ?? '').toString().trim();
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
      cookieHeader: seededCookie,
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
    return playlists.firstWhere(
      (item) => item.tag == 'LIKED',
      orElse: () => playlists.first,
    );
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
      cookieHeader: _seedCookieHeader(cookie),
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

  @override
  Future<bool> setTrackLiked(MusicTrack track, bool liked) async {
    final cookie = await OpenClawSettingsStore.loadMusicProviderCookie(id);
    final seededCookie = _seedCookieHeader(cookie);
    if ((seededCookie ?? '').trim().isEmpty) {
      return false;
    }
    final csrf = _parseCookieMap(seededCookie!)['__csrf']?.trim();
    if ((csrf ?? '').isEmpty) {
      return false;
    }
    final candidate = await matchTrack(track);
    final sourceTrackId = candidate?.sourceTrackId.trim() ?? '';
    if (sourceTrackId.isEmpty) {
      return false;
    }
    final payload = await _getJson(
      '/api/song/like',
      query: <String, String>{
        'id': sourceTrackId,
        'like': liked ? 'true' : 'false',
        'alg': 'itembased',
        'time': '3',
        'csrf_token': csrf!,
      },
      cookieHeader: seededCookie,
    );
    final codeRaw = payload['code'];
    final code = codeRaw is num ? codeRaw.toInt() : int.tryParse('$codeRaw');
    return code == 200;
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
      title: isLiked ? '喜欢' : title,
      subtitle: description.isEmpty
          ? (isLiked ? '网易云喜欢的歌曲' : '来自网易云音乐')
          : description,
      tag: isLiked ? 'LIKED' : 'NETEASE',
      trackCount: trackCount,
      artworkTone: isLiked ? MusicArtworkTone.rose : _toneForSeed(rawId),
    );
  }


  MusicLyrics? _parseLyrics(String raw, {String translated = ''}) {
    final lines = <MusicLyricsLine>[];
    final text = raw.trim();
    if (text.isEmpty) {
      final plain = translated.trim();
      return plain.isEmpty
          ? null
          : MusicLyrics(synced: false, plainText: plain);
    }
    final reg = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{1,3}))?\]');
    final translatedMap = <int, String>{};
    for (final row in translated.split('\n')) {
      final matches = reg.allMatches(row).toList(growable: false);
      if (matches.isEmpty) continue;
      final content = row.replaceAll(reg, '').trim();
      if (content.isEmpty) continue;
      for (final match in matches) {
        final ts = _lyricTimestamp(match);
        translatedMap[ts.inMilliseconds] = content;
      }
    }
    for (final row in text.split('\n')) {
      final matches = reg.allMatches(row).toList(growable: false);
      if (matches.isEmpty) continue;
      final content = row.replaceAll(reg, '').trim();
      for (final match in matches) {
        final ts = _lyricTimestamp(match);
        final translatedText = translatedMap[ts.inMilliseconds]?.trim();
        final merged = translatedText != null &&
                translatedText.isNotEmpty &&
                translatedText != content
            ? '$content\n$translatedText'
            : content;
        lines.add(MusicLyricsLine(timestamp: ts, text: merged));
      }
    }
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (lines.isEmpty) {
      return MusicLyrics(synced: false, plainText: text);
    }
    return MusicLyrics(
      synced: true,
      lines: List<MusicLyricsLine>.unmodifiable(lines),
      plainText: text,
    );
  }

  Duration _lyricTimestamp(RegExpMatch match) {
    final min = int.tryParse(match.group(1) ?? '0') ?? 0;
    final sec = int.tryParse(match.group(2) ?? '0') ?? 0;
    final fracRaw = (match.group(3) ?? '0').padRight(3, '0');
    final ms = int.tryParse(fracRaw) ?? 0;
    return Duration(minutes: min, seconds: sec, milliseconds: ms);
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
    final durationPenalty =
        (normalizedResultTitle.length - normalizedQueryTitle.length).abs() * 0.05;
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

  Map<String, String> _parseCookieMap(String cookieHeader) {
    final map = <String, String>{};
    for (final segment in cookieHeader.split(';')) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) continue;
      final separator = trimmed.indexOf('=');
      if (separator <= 0) continue;
      final key = trimmed.substring(0, separator).trim();
      final value = trimmed.substring(separator + 1).trim();
      if (key.isEmpty || value.isEmpty) continue;
      map[key] = value;
    }
    return map;
  }

  String? _seedCookieHeader(String? cookieHeader) {
    final normalized = (cookieHeader ?? '').trim();
    if (normalized.isEmpty) return null;
    final map = _parseCookieMap(normalized);
    for (final key in _seedCookieKeys) {
      map.putIfAbsent(key, () => _syntheticSeedFor(key));
    }
    map.putIfAbsent('os', () => 'pc');
    return map.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
  }

  String _syntheticSeedFor(String key) {
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    return '${key.toLowerCase()}_$stamp';
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
