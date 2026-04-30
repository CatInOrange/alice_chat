import 'dart:ui';

import 'package:flutter/material.dart';

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

  late MusicTrack _currentTrack;
  bool _isPlaying = true;

  @override
  void initState() {
    super.initState();
    _currentTrack = _catalog.featuredTrack;
  }

  @override
  bool get wantKeepAlive => true;

  void _openPlayer([MusicTrack? track]) {
    if (track != null) {
      setState(() {
        _currentTrack = track;
        _isPlaying = true;
      });
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MusicPlayerScreen(
          track: track ?? _currentTrack,
          queue: _catalog.queue,
        ),
      ),
    );
  }

  void _selectTrack(MusicTrack track) {
    setState(() {
      _currentTrack = track;
      _isPlaying = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('音乐'),
        actions: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.search_rounded)),
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
                onTap: () => _openPlayer(_catalog.featuredTrack),
              ),
              const SizedBox(height: 24),
              _NowPlayingSummary(
                track: _currentTrack,
                isPlaying: _isPlaying,
                onTap: _openPlayer,
              ),
              const SizedBox(height: 28),
              _SectionHeader(
                title: '推荐歌单',
                subtitle: '挑几组适合当前心情的氛围',
                actionLabel: '查看全部',
                onActionTap: () {},
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 176,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _catalog.playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final playlist = _catalog.playlists[index];
                    return _PlaylistCard(playlist: playlist);
                  },
                ),
              ),
              const SizedBox(height: 28),
              _SectionHeader(
                title: '最近播放',
                subtitle: '继续上次的节奏',
                actionLabel: '更多',
                onActionTap: () {},
              ),
              const SizedBox(height: 14),
              ..._catalog.recentTracks.map(
                (track) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _TrackListTile(
                    track: track,
                    active: track.id == _currentTrack.id,
                    onTap: () => _selectTrack(track),
                    onPlayTap: () => _openPlayer(track),
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
              track: _currentTrack,
              isPlaying: _isPlaying,
              onTap: _openPlayer,
              onPlayPause: () {
                setState(() {
                  _isPlaying = !_isPlaying;
                });
              },
            ),
          ),
        ],
      ),
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

class _NowPlayingSummary extends StatelessWidget {
  const _NowPlayingSummary({
    required this.track,
    required this.isPlaying,
    required this.onTap,
  });

  final MusicTrack track;
  final bool isPlaying;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(track.artworkTone);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.72)),
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
          MusicArtwork(track: track, size: 72, showMeta: false),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前播放',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 6),
                Text(track.title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '${track.artist} · ${track.durationLabel}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: 0.42,
                    minHeight: 5,
                    backgroundColor: const Color(0xFFE9EDF5),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      palette.gradient.first,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: palette.gradient),
                ),
                child: Icon(
                  isPlaying ? Icons.equalizer_rounded : Icons.pause_rounded,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              TextButton(onPressed: onTap, child: const Text('展开')),
            ],
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

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({required this.playlist});

  final MusicPlaylist playlist;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(playlist.artworkTone);
    return Container(
      width: 204,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white.withValues(alpha: 0.76)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x100B1220),
            blurRadius: 16,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: palette.gradient),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: palette.glowColor.withValues(alpha: 0.58),
                      blurRadius: 16,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Icon(palette.icon, color: Colors.white),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F5FA),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(playlist.tag, style: theme.textTheme.bodySmall),
              ),
            ],
          ),
          const Spacer(),
          Text(playlist.title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            playlist.subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text('${playlist.trackCount} 首', style: theme.textTheme.bodySmall),
              const Spacer(),
              Icon(
                Icons.arrow_outward_rounded,
                size: 18,
                color: palette.gradient.first,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrackListTile extends StatelessWidget {
  const _TrackListTile({
    required this.track,
    required this.active,
    required this.onTap,
    required this.onPlayTap,
  });

  final MusicTrack track;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onPlayTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(track.artworkTone);
    return Material(
      color: active ? const Color(0xFFF0ECFF) : Colors.white.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              MusicArtwork(track: track, size: 68, showMeta: false),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            track.title,
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (track.isFavorite)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(
                              Icons.favorite_rounded,
                              size: 16,
                              color: Color(0xFFE91E63),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${track.artist} · ${track.category}',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      track.description,
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: palette.gradient),
                    ),
                    child: IconButton(
                      onPressed: onPlayTap,
                      icon: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(track.durationLabel, style: theme.textTheme.bodySmall),
                ],
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
                        isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
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
