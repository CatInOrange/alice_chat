import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../application/music_store.dart';
import '../data/mock_music_catalog.dart';
import '../domain/music_models.dart';
import 'music_player_screen.dart';
import 'widgets/music_artwork.dart';

class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen>
    with AutomaticKeepAliveClientMixin {
  static const _catalog = MockMusicCatalog.data;
  MusicPlaylist? _likedPlaylist;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final store = context.read<MusicStore>();
      await store.ensureReady();
      final liked = await store.getLikedPlaylist();
      if (!mounted) return;
      setState(() {
        _likedPlaylist = liked;
      });
    });
  }

  @override
  bool get wantKeepAlive => true;

  void _openPlayer(MusicStore store, [MusicTrack? track]) {
    if (track != null) {
      store.selectTrack(track, autoplay: false);
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MusicPlayerScreen(
          track: track ?? store.currentTrack,
          queue: store.queue.map((item) => item.track).toList(growable: false),
        ),
      ),
    );
  }

  Future<void> _openPlaylist(MusicStore store, MusicPlaylist playlist) async {
    await store.playPlaylist(playlist);
    if (!mounted) return;
    _openPlayer(store);
  }

  Future<void> _openSearch(BuildContext context, MusicStore store) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return ChangeNotifierProvider.value(
          value: store,
          child: const _MusicSearchSheet(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Consumer<MusicStore>(
      builder: (context, store, _) {
        final currentTrack = store.currentTrack;
        final isPlaying = store.isPlaying;
        final playlists =
            store.playlists.isEmpty ? _catalog.playlists : store.playlists;
        final recentPlaylists = store.recentPlaylists;
        final likedPlaylist =
            _likedPlaylist ??
            (playlists.isNotEmpty ? playlists.first : MockMusicCatalog.likedPlaylist);

        return Scaffold(
          appBar: AppBar(
            title: const Text('音乐'),
            actions: [
              IconButton(
                onPressed: () => _openSearch(context, store),
                icon: const Icon(Icons.search_rounded),
              ),
            ],
          ),
          body: Stack(
            children: [
              const _MusicScreenBackdrop(),
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 148),
                children: [
                  _MusicHeroCard(
                    track: _catalog.featuredTrack,
                    onTap: () => _openPlayer(store, _catalog.featuredTrack),
                  ),
                  const SizedBox(height: 24),
                  _FavoritePlaylistCard(
                    playlist: likedPlaylist,
                    currentTrack: currentTrack,
                    onTap: () => _openPlaylist(store, likedPlaylist),
                  ),
                  const SizedBox(height: 28),
                  _SectionHeader(
                    title: '我的歌单',
                    subtitle: likedPlaylist.id.startsWith('netease-playlist:')
                        ? '已接入网易云歌单，优先展示你的真实收藏'
                        : '以后你可以自己创建、收藏和整理',
                    actionLabel: '新建',
                    onActionTap: () {},
                  ),
                  const SizedBox(height: 14),
                  _CompactPlaylistGrid(
                    playlists: playlists,
                    onPlaylistTap: (playlist) => _openPlaylist(store, playlist),
                  ),
                  const SizedBox(height: 28),
                  _SectionHeader(
                    title: '最近播放',
                    subtitle: '按歌单回到你最近听过的氛围',
                    actionLabel: '更多',
                    onActionTap: () {},
                  ),
                  const SizedBox(height: 14),
                  ...recentPlaylists.map(
                    (playlist) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _RecentPlaylistTile(
                        playlist: playlist,
                        onTap: () => _openPlaylist(store, playlist),
                      ),
                    ),
                  ),
                ],
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: _MiniPlayer(
                  track: currentTrack,
                  isPlaying: isPlaying,
                  onTap: () => _openPlayer(store),
                  onPlayPause: store.togglePlayPause,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MusicScreenBackdrop extends StatelessWidget {
  const _MusicScreenBackdrop();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: -80,
            right: -40,
            child: _GlowOrb(
              size: 220,
              color: const Color(0x337C4DFF),
            ),
          ),
          Positioned(
            top: 180,
            left: -72,
            child: _GlowOrb(
              size: 180,
              color: const Color(0x2200BFA5),
            ),
          ),
          Positioned(
            bottom: 80,
            right: -30,
            child: _GlowOrb(
              size: 160,
              color: const Color(0x22FF8A65),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, Colors.transparent],
        ),
      ),
    );
  }
}

class _MusicHeroCard extends StatelessWidget {
  const _MusicHeroCard({required this.track, required this.onTap});

  final MusicTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(track.artworkTone);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(36),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            palette.gradient.first,
            Color.lerp(palette.gradient.last, Colors.black, 0.12)!,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: palette.glowColor.withValues(alpha: 0.82),
            blurRadius: 34,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(36),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.16),
                              ),
                            ),
                            child: Text(
                              '今晚推荐',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '给工作和夜色留一点音乐。',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: Colors.white,
                              fontSize: 24,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            track.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withValues(alpha: 0.82),
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    MusicArtwork(
                      track: track,
                      size: 108,
                      heroTag: 'music-artwork-${track.id}',
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.white,
                                fontSize: 18,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${track.artist} · ${track.album}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white.withValues(alpha: 0.78),
                              ),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: onTap,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: palette.gradient.first,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 14,
                          ),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('播放'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FavoritePlaylistCard extends StatelessWidget {
  const _FavoritePlaylistCard({
    required this.playlist,
    required this.currentTrack,
    required this.onTap,
  });

  final MusicPlaylist playlist;
  final MusicTrack currentTrack;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(playlist.artworkTone);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white.withValues(alpha: 0.78)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120B1220),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: palette.gradient),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: palette.glowColor.withValues(alpha: 0.45),
                  blurRadius: 18,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: const Icon(
              Icons.favorite_rounded,
              color: Colors.white,
              size: 30,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '我喜欢的歌单',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 6),
                Text(playlist.title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${playlist.trackCount} 首 · 快速开始今天最常听的收藏',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                Text(
                  '上次停在：${currentTrack.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF7D879A),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              backgroundColor: palette.gradient.first,
              foregroundColor: Colors.white,
              minimumSize: const Size(56, 56),
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
            ),
            child: const Icon(Icons.play_arrow_rounded),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onActionTap,
  });

  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onActionTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(subtitle, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        TextButton(onPressed: onActionTap, child: Text(actionLabel)),
      ],
    );
  }
}

class _CompactPlaylistGrid extends StatelessWidget {
  const _CompactPlaylistGrid({
    required this.playlists,
    required this.onPlaylistTap,
  });

  final List<MusicPlaylist> playlists;
  final ValueChanged<MusicPlaylist> onPlaylistTap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: playlists.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.8,
      ),
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        return _PlaylistGridCard(
          playlist: playlist,
          onTap: () => onPlaylistTap(playlist),
        );
      },
    );
  }
}

class _PlaylistGridCard extends StatelessWidget {
  const _PlaylistGridCard({
    required this.playlist,
    required this.onTap,
  });

  final MusicPlaylist playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(playlist.artworkTone);
    return Material(
      color: Colors.white.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        borderRadius: BorderRadius.circular(26),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: palette.gradient),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(palette.icon, color: Colors.white, size: 22),
              ),
              const SizedBox(height: 12),
              Text(
                playlist.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(
                playlist.tag,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.gradient.first,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '${playlist.trackCount} 首',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentPlaylistTile extends StatelessWidget {
  const _RecentPlaylistTile({
    required this.playlist,
    required this.onTap,
  });

  final MusicPlaylist playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(playlist.artworkTone);
    return Material(
      color: Colors.white.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: palette.gradient),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(
                  playlist.isAiGenerated
                      ? Icons.auto_awesome_rounded
                      : palette.icon,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            playlist.title,
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (playlist.isAiGenerated)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: palette.gradient.first.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'AI',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: palette.gradient.first,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      playlist.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${playlist.trackCount} 首歌 · 点一下继续播放这个歌单',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF7D879A),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: palette.gradient),
                ),
                child: IconButton(
                  onPressed: onTap,
                  icon: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer({
    required this.track,
    required this.isPlaying,
    required this.onTap,
    required this.onPlayPause,
  });

  final MusicTrack track;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback onPlayPause;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(track.artworkTone);
    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(32),
            onTap: onTap,
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(color: Colors.white.withValues(alpha: 0.72)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x180B1220),
                    blurRadius: 22,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: [
                  MusicArtwork(
                    track: track,
                    size: 56,
                    showMeta: false,
                    heroTag: 'music-artwork-${track.id}',
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: palette.gradient),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      onPressed: onPlayPause,
                      icon: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MusicSearchSheet extends StatefulWidget {
  const _MusicSearchSheet();

  @override
  State<_MusicSearchSheet> createState() => _MusicSearchSheetState();
}

class _MusicSearchSheetState extends State<_MusicSearchSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MusicStore>();
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomInset + 16),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('搜索网易云', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '先接真实搜索和直连解析。输入歌名或歌手，点结果就会尝试播放。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: store.searchTracks,
                    decoration: InputDecoration(
                      hintText: '例如：晴天 周杰伦',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _controller.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _controller.clear();
                                store.clearSearchResults();
                                setState(() {});
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: store.isSearching
                      ? null
                      : () => store.searchTracks(_controller.text),
                  child: const Text('搜索'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (store.isSearching)
              const LinearProgressIndicator()
            else if ((store.searchError ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '搜索失败：${store.searchError}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: store.searchResults.isEmpty
                  ? Center(
                      child: Text(
                        _controller.text.trim().isEmpty ? '还没开始搜索' : '没有找到结果',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  : ListView.separated(
                      itemCount: store.searchResults.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final track = store.searchResults[index];
                        return _SearchResultTile(track: track);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({required this.track});

  final MusicTrack track;

  @override
  Widget build(BuildContext context) {
    final palette = paletteForTone(track.artworkTone);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          final store = context.read<MusicStore>();
          await store.selectTrack(track);
          if (!context.mounted) return;
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MusicPlayerScreen(
                track: track,
                queue: store.queue.map((item) => item.track).toList(growable: false),
              ),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE7EAF4)),
          ),
          child: Row(
            children: [
              MusicArtwork(
                track: track,
                size: 58,
                showMeta: false,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${track.artist} · ${track.album}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      track.durationLabel,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: palette.gradient.first,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.play_circle_fill_rounded, color: palette.gradient.first),
            ],
          ),
        ),
      ),
    );
  }
}
