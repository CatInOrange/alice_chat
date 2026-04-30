import '../domain/music_models.dart';

class MockMusicCatalog {
  static const featuredTrack = MusicTrack(
    id: 'violet-dreams',
    title: 'Violet Dreams',
    artist: 'Alice Signal',
    album: 'Night Session',
    duration: Duration(minutes: 3, seconds: 42),
    category: '电子流光',
    description: '适合夜里写代码时循环的轻电子氛围。',
    artworkTone: MusicArtworkTone.twilight,
    isFavorite: true,
  );

  static const recentTracks = <MusicTrack>[
    featuredTrack,
    MusicTrack(
      id: 'summer-signal',
      title: 'Summer Signal',
      artist: 'Linglong FM',
      album: 'Sunset Drive',
      duration: Duration(minutes: 4, seconds: 5),
      category: '都市流行',
      description: '柔和的人声和鼓点，适合通勤。',
      artworkTone: MusicArtworkTone.sunset,
    ),
    MusicTrack(
      id: 'deep-ocean',
      title: 'Deep Ocean',
      artist: 'Blue Circuit',
      album: 'Midnight Router',
      duration: Duration(minutes: 5, seconds: 1),
      category: '氛围电子',
      description: '带一点深海感的低频与合成器。',
      artworkTone: MusicArtworkTone.ocean,
    ),
    MusicTrack(
      id: 'rose-protocol',
      title: 'Rose Protocol',
      artist: 'Su Wanqiu',
      album: 'Soft Control',
      duration: Duration(minutes: 3, seconds: 18),
      category: '轻盈女声',
      description: '更柔一点，适合深夜独处时听。',
      artworkTone: MusicArtworkTone.rose,
      isFavorite: true,
    ),
    MusicTrack(
      id: 'aurora-pulse',
      title: 'Aurora Pulse',
      artist: 'North Cluster',
      album: 'Cloud Motion',
      duration: Duration(minutes: 4, seconds: 26),
      category: '合成器浪潮',
      description: '亮一点、通透一点，适合做背景音乐。',
      artworkTone: MusicArtworkTone.aurora,
    ),
    MusicTrack(
      id: 'night-trace',
      title: 'Night Trace',
      artist: 'Zero Ping',
      album: 'Latency',
      duration: Duration(minutes: 2, seconds: 56),
      category: 'Lo-fi',
      description: '轻鼓点 + 暖 pad，适合长时间工作。',
      artworkTone: MusicArtworkTone.midnight,
    ),
  ];

  static const playlists = <MusicPlaylist>[
    MusicPlaylist(
      id: 'liked-daily',
      title: '我喜欢的',
      subtitle: '把最近反复回听的歌都收在这里',
      tag: 'LIKED',
      trackCount: 24,
      artworkTone: MusicArtworkTone.rose,
    ),
    MusicPlaylist(
      id: 'focus-coding',
      title: '专注编码',
      subtitle: '给 AliceChat 夜间开发用的稳态 BGM',
      tag: 'FOCUS',
      trackCount: 18,
      artworkTone: MusicArtworkTone.twilight,
    ),
    MusicPlaylist(
      id: 'after-hours',
      title: 'After Hours',
      subtitle: '柔一点、慢一点，适合深夜收尾',
      tag: 'CHILL',
      trackCount: 12,
      artworkTone: MusicArtworkTone.rose,
    ),
    MusicPlaylist(
      id: 'city-run',
      title: '城市夜跑',
      subtitle: '节奏更清晰，适合通勤和散步',
      tag: 'RUN',
      trackCount: 20,
      artworkTone: MusicArtworkTone.sunset,
    ),
  ];

  static const recentPlaylists = <MusicPlaylist>[
    MusicPlaylist(
      id: 'ai-morning-0430',
      title: '今日推荐 · 04/30',
      subtitle: 'AI 按你今天的工作节奏配的轻电子歌单',
      tag: 'AI',
      trackCount: 9,
      artworkTone: MusicArtworkTone.aurora,
      isAiGenerated: true,
    ),
    MusicPlaylist(
      id: 'after-hours',
      title: 'After Hours',
      subtitle: '昨晚听到一半，适合继续慢慢收尾',
      tag: 'CHILL',
      trackCount: 12,
      artworkTone: MusicArtworkTone.rose,
    ),
    MusicPlaylist(
      id: 'focus-coding',
      title: '专注编码',
      subtitle: '前天的专注歌单，还挺适合继续循环',
      tag: 'FOCUS',
      trackCount: 18,
      artworkTone: MusicArtworkTone.twilight,
    ),
  ];

  static const data = MusicCatalogData(
    featuredTrack: featuredTrack,
    playlists: playlists,
    recentTracks: recentTracks,
    queue: recentTracks,
  );

  static MusicPlaylist get likedPlaylist => playlists.first;

  static List<MusicTrack> tracksForPlaylist(String playlistId) {
    switch (playlistId) {
      case 'liked-daily':
        return const [
          featuredTrack,
          MusicTrack(
            id: 'rose-protocol',
            title: 'Rose Protocol',
            artist: 'Su Wanqiu',
            album: 'Soft Control',
            duration: Duration(minutes: 3, seconds: 18),
            category: '轻盈女声',
            description: '更柔一点，适合深夜独处时听。',
            artworkTone: MusicArtworkTone.rose,
            isFavorite: true,
          ),
          MusicTrack(
            id: 'aurora-pulse',
            title: 'Aurora Pulse',
            artist: 'North Cluster',
            album: 'Cloud Motion',
            duration: Duration(minutes: 4, seconds: 26),
            category: '合成器浪潮',
            description: '亮一点、通透一点，适合做背景音乐。',
            artworkTone: MusicArtworkTone.aurora,
          ),
        ];
      case 'focus-coding':
        return const [
          featuredTrack,
          MusicTrack(
            id: 'deep-ocean',
            title: 'Deep Ocean',
            artist: 'Blue Circuit',
            album: 'Midnight Router',
            duration: Duration(minutes: 5, seconds: 1),
            category: '氛围电子',
            description: '带一点深海感的低频与合成器。',
            artworkTone: MusicArtworkTone.ocean,
          ),
          MusicTrack(
            id: 'night-trace',
            title: 'Night Trace',
            artist: 'Zero Ping',
            album: 'Latency',
            duration: Duration(minutes: 2, seconds: 56),
            category: 'Lo-fi',
            description: '轻鼓点 + 暖 pad，适合长时间工作。',
            artworkTone: MusicArtworkTone.midnight,
          ),
        ];
      case 'after-hours':
        return const [
          MusicTrack(
            id: 'rose-protocol',
            title: 'Rose Protocol',
            artist: 'Su Wanqiu',
            album: 'Soft Control',
            duration: Duration(minutes: 3, seconds: 18),
            category: '轻盈女声',
            description: '更柔一点，适合深夜独处时听。',
            artworkTone: MusicArtworkTone.rose,
            isFavorite: true,
          ),
          featuredTrack,
          MusicTrack(
            id: 'night-trace',
            title: 'Night Trace',
            artist: 'Zero Ping',
            album: 'Latency',
            duration: Duration(minutes: 2, seconds: 56),
            category: 'Lo-fi',
            description: '轻鼓点 + 暖 pad，适合长时间工作。',
            artworkTone: MusicArtworkTone.midnight,
          ),
        ];
      case 'city-run':
        return const [
          MusicTrack(
            id: 'summer-signal',
            title: 'Summer Signal',
            artist: 'Linglong FM',
            album: 'Sunset Drive',
            duration: Duration(minutes: 4, seconds: 5),
            category: '都市流行',
            description: '柔和的人声和鼓点，适合通勤。',
            artworkTone: MusicArtworkTone.sunset,
          ),
          MusicTrack(
            id: 'aurora-pulse',
            title: 'Aurora Pulse',
            artist: 'North Cluster',
            album: 'Cloud Motion',
            duration: Duration(minutes: 4, seconds: 26),
            category: '合成器浪潮',
            description: '亮一点、通透一点，适合做背景音乐。',
            artworkTone: MusicArtworkTone.aurora,
          ),
          MusicTrack(
            id: 'deep-ocean',
            title: 'Deep Ocean',
            artist: 'Blue Circuit',
            album: 'Midnight Router',
            duration: Duration(minutes: 5, seconds: 1),
            category: '氛围电子',
            description: '带一点深海感的低频与合成器。',
            artworkTone: MusicArtworkTone.ocean,
          ),
        ];
      case 'ai-morning-0430':
        return const [
          MusicTrack(
            id: 'aurora-pulse',
            title: 'Aurora Pulse',
            artist: 'North Cluster',
            album: 'Cloud Motion',
            duration: Duration(minutes: 4, seconds: 26),
            category: '合成器浪潮',
            description: '亮一点、通透一点，适合做背景音乐。',
            artworkTone: MusicArtworkTone.aurora,
          ),
          featuredTrack,
          MusicTrack(
            id: 'deep-ocean',
            title: 'Deep Ocean',
            artist: 'Blue Circuit',
            album: 'Midnight Router',
            duration: Duration(minutes: 5, seconds: 1),
            category: '氛围电子',
            description: '带一点深海感的低频与合成器。',
            artworkTone: MusicArtworkTone.ocean,
          ),
        ];
      default:
        return recentTracks.take(3).toList(growable: false);
    }
  }
}
