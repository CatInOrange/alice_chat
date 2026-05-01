import 'dart:convert';
import 'dart:io';

import '../../../../core/openclaw/openclaw_settings.dart';
import '../../domain/music_models.dart';
import '../../domain/music_runtime_models.dart';
import 'music_source_provider.dart';

class MiguMusicSourceProvider extends MusicSourceProvider {
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14; AliceChat) AppleWebKit/537.36';

  @override
  String get id => 'migu';

  @override
  Future<List<SourceCandidate>> searchTracks(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      return const <SourceCandidate>[];
    }

    final payload = await _getJson(
      host: 'app.u.nf.migu.cn',
      path: '/pc/resource/song/item/search/v1.0',
      query: <String, String>{
        'text': keyword,
        'pageNo': '1',
        'pageSize': '12',
      },
    );
    final items = _listFromPayload(payload);
    return items
        .map(_candidateFromSong)
        .whereType<SourceCandidate>()
        .toList(growable: false);
  }

  @override
  Future<SourceCandidate?> matchTrack(MusicTrack track) async {
    final sourceTrackId = track.sourceTrackId?.trim();
    if (track.preferredSourceId == id && sourceTrackId != null && sourceTrackId.isNotEmpty) {
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
    final sourceTrackId = candidate.sourceTrackId.trim();
    if (sourceTrackId.isEmpty) {
      return null;
    }
    final parts = sourceTrackId.split(':');
    if (parts.length < 2) {
      return null;
    }
    final copyrightId = parts.first;
    final contentId = parts.sublist(1).join(':');
    final track = candidate.track.toMusicTrack();
    final toneFlag = _toneFlagForTrack(track);
    final payload = await _getJson(
      host: 'app.c.nf.migu.cn',
      path: '/MIGUM3.0/strategy/pc/listen/v1.0',
      query: <String, String>{
        'scene': '',
        'netType': '01',
        'resourceType': '2',
        'copyrightId': copyrightId,
        'contentId': contentId,
        'toneFlag': toneFlag,
      },
      extraHeaders: const <String, String>{
        'channel': '0146951',
        'uid': '1234',
      },
    );
    final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    var streamUrl = (data['url'] ?? data['playUrl'] ?? '').toString().trim();
    if (streamUrl.isEmpty) {
      return null;
    }
    if (streamUrl.startsWith('//')) {
      streamUrl = 'https:$streamUrl';
    }
    streamUrl = streamUrl.replaceAll('+', '%2B');
    return ResolvedPlaybackSource(
      providerId: id,
      sourceTrackId: sourceTrackId,
      streamUrl: streamUrl,
      artworkUrl: track.artworkUrl,
      mimeType: _inferMimeType(streamUrl),
      headers: const <String, String>{
        HttpHeaders.userAgentHeader: _userAgent,
        HttpHeaders.refererHeader: 'https://music.migu.cn/',
        'origin': 'https://music.migu.cn',
        'channel': '0146951',
        'uid': '1234',
      },
      expiresAt: DateTime.now().add(const Duration(minutes: 20)),
    );
  }

  @override
  Future<List<MusicPlaylist>> loadUserPlaylists() async {
    final cookie = await OpenClawSettingsStore.loadMusicProviderCookie(id);
    if ((cookie ?? '').trim().isEmpty) {
      return const <MusicPlaylist>[];
    }
    return const <MusicPlaylist>[];
  }

  @override
  Future<MusicPlaylist?> loadLikedPlaylist() async => null;

  @override
  Future<List<MusicTrack>> loadPlaylistTracks(String playlistId) async =>
      const <MusicTrack>[];

  @override
  Future<bool> setTrackLiked(MusicTrack track, bool liked) async => false;

  List<Map<String, dynamic>> _listFromPayload(dynamic payload) {
    if (payload is List) {
      return payload
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item.cast<String, dynamic>()))
          .toList(growable: false);
    }
    if (payload is Map<String, dynamic>) {
      final data = payload['data'];
      if (data is List) {
        return data
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item.cast<String, dynamic>()))
            .toList(growable: false);
      }
      if (data is Map<String, dynamic>) {
        for (final key in const ['songs', 'songResultData', 'list']) {
          final nested = data[key];
          if (nested is List) {
            return nested
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item.cast<String, dynamic>()))
                .toList(growable: false);
          }
        }
      }
    }
    return const <Map<String, dynamic>>[];
  }

  SourceCandidate? _candidateFromSong(Map<String, dynamic> raw) {
    final copyrightId = (raw['copyrightId'] ?? '').toString().trim();
    final contentId = (raw['contentId'] ?? raw['songId'] ?? '').toString().trim();
    final title = (raw['songName'] ?? raw['name'] ?? '').toString().trim();
    if (copyrightId.isEmpty || contentId.isEmpty || title.isEmpty) {
      return null;
    }
    final singerList = ((raw['singerList'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => (item['name'] ?? '').toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final artist = singerList.isEmpty ? '未知歌手' : singerList.join(' / ');
    final album = (raw['album'] ?? '').toString().trim();
    final durationRaw = raw['duration'] ?? 0;
    final durationSeconds = durationRaw is num
        ? durationRaw.toInt()
        : int.tryParse('$durationRaw') ?? 0;
    final artworkUrl = [raw['img3'], raw['img2'], raw['img1']]
        .map((item) => (item ?? '').toString().trim())
        .firstWhere((item) => item.isNotEmpty, orElse: () => '');
    final sourceTrackId = '$copyrightId:$contentId';
    final track = MusicTrack(
      id: 'migu:$copyrightId',
      title: title,
      artist: artist,
      album: album.isEmpty ? '咪咕音乐' : album,
      duration: Duration(seconds: durationSeconds),
      category: '咪咕音乐',
      description: album.isEmpty ? '来自咪咕音乐搜索结果' : '专辑：$album',
      artworkTone: _toneForSeed(copyrightId),
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

  String _toneFlagForTrack(MusicTrack track) {
    final description = track.description.toLowerCase();
    if (description.contains('zq') || description.contains('24bit')) return 'ZQ';
    if (description.contains('sq') || description.contains('无损')) return 'SQ';
    if (description.contains('hq') || description.contains('320')) return 'HQ';
    return 'PQ';
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
    return score -
        (normalizedResultTitle.length - normalizedQueryTitle.length).abs() * 0.05;
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

  Future<dynamic> _getJson({
    required String host,
    required String path,
    Map<String, String> query = const <String, String>{},
    String? cookieHeader,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.https(host, path, query));
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
      request.headers.set(HttpHeaders.refererHeader, 'https://music.migu.cn/');
      request.headers.set('origin', 'https://music.migu.cn');
      extraHeaders.forEach(request.headers.set);
      final normalizedCookie = (cookieHeader ?? '').trim();
      if (normalizedCookie.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, normalizedCookie);
      }
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }
}
