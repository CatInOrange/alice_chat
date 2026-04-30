import 'dart:ui';

import 'package:flutter/material.dart';

import '../domain/music_models.dart';
import 'widgets/music_artwork.dart';

class MusicPlayerScreen extends StatelessWidget {
  const MusicPlayerScreen({
    super.key,
    required this.track,
    required this.queue,
  });

  final MusicTrack track;
  final List<MusicTrack> queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(track.artworkTone);
    final nextTracks = queue.where((item) => item.id != track.id).take(3).toList();

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(palette.gradient.first, Colors.white, 0.78)!,
              const Color(0xFFF7F8FC),
              Colors.white,
            ],
            stops: const [0, 0.32, 1],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -80,
              left: -40,
              child: _Aura(size: 220, color: palette.glowColor),
            ),
            Positioned(
              right: -80,
              top: 220,
              child: _Aura(
                size: 240,
                color: palette.gradient.last.withValues(alpha: 0.16),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                    child: Row(
                      children: [
                        _GlassIconButton(
                          icon: Icons.keyboard_arrow_down_rounded,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              Text(
                                '正在播放',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  letterSpacing: 1.2,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                track.album,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ),
                        const _GlassIconButton(
                          icon: Icons.more_horiz_rounded,
                          onPressed: _noop,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                      child: Column(
                        children: [
                          _DiscStage(track: track),
                          const SizedBox(height: 28),
                          Container(
                            padding: const EdgeInsets.all(22),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(30),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.72),
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x140B1220),
                                  blurRadius: 20,
                                  offset: Offset(0, 12),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            track.title,
                                            style: theme.textTheme.titleLarge?.copyWith(
                                              fontSize: 24,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            '${track.artist} · ${track.category}',
                                            style: theme.textTheme.bodyMedium,
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            track.description,
                                            style: theme.textTheme.bodySmall?.copyWith(
                                              height: 1.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () {},
                                      icon: Icon(
                                        track.isFavorite
                                            ? Icons.favorite_rounded
                                            : Icons.favorite_border_rounded,
                                        color: track.isFavorite
                                            ? const Color(0xFFE91E63)
                                            : null,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 22),
                                _ProgressPanel(
                                  accentColor: palette.gradient.first,
                                  durationLabel: track.durationLabel,
                                ),
                                const SizedBox(height: 26),
                                _PlayerControls(accentColor: palette.gradient.first),
                              ],
                            ),
                          ),
                          const SizedBox(height: 22),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(30),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.66),
                                  borderRadius: BorderRadius.circular(30),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.72),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '接下来播放',
                                            style: theme.textTheme.titleMedium,
                                          ),
                                        ),
                                        Text(
                                          '${queue.length} 首歌曲',
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 14),
                                    for (final item in nextTracks)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 12),
                                        child: _QueueItem(track: item),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscStage extends StatelessWidget {
  const _DiscStage({required this.track});

  final MusicTrack track;

  @override
  Widget build(BuildContext context) {
    final palette = paletteForTone(track.artworkTone);
    return SizedBox(
      height: 352,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 338,
            height: 338,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  palette.glowColor.withValues(alpha: 0.42),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          Container(
            width: 286,
            height: 286,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Colors.white.withValues(alpha: 0.86),
                  Colors.white.withValues(alpha: 0.22),
                ],
              ),
            ),
          ),
          Container(
            width: 266,
            height: 266,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.42),
                width: 12,
              ),
            ),
          ),
          MusicArtwork(
            track: track,
            size: 238,
            circular: true,
            heroTag: 'music-artwork-${track.id}',
          ),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.92),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x22000000),
                  blurRadius: 12,
                  offset: Offset(0, 6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({
    required this.accentColor,
    required this.durationLabel,
  });

  final Color accentColor;
  final String durationLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: 0.42,
            minHeight: 7,
            backgroundColor: const Color(0xFFE7EBF4),
            valueColor: AlwaysStoppedAnimation<Color>(accentColor),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('1:34', style: theme.textTheme.bodySmall),
            Text(durationLabel, style: theme.textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}

class _PlayerControls extends StatelessWidget {
  const _PlayerControls({required this.accentColor});

  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        const _PlayerActionButton(icon: Icons.shuffle_rounded, onPressed: _noop),
        const _PlayerActionButton(
          icon: Icons.skip_previous_rounded,
          onPressed: _noop,
        ),
        _PrimaryPlayButton(
          icon: Icons.pause_rounded,
          color: accentColor,
          onPressed: _noop,
        ),
        const _PlayerActionButton(icon: Icons.skip_next_rounded, onPressed: _noop),
        const _PlayerActionButton(icon: Icons.repeat_rounded, onPressed: _noop),
      ],
    );
  }
}

class _QueueItem extends StatelessWidget {
  const _QueueItem({required this.track});

  final MusicTrack track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(track.artworkTone);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          MusicArtwork(track: track, size: 56, showMeta: false),
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
                Text(track.artist, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: palette.gradient.first.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(track.durationLabel, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _Aura extends StatelessWidget {
  const _Aura({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, Colors.transparent]),
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.66)),
          ),
          child: IconButton(onPressed: onPressed, icon: Icon(icon)),
        ),
      ),
    );
  }
}

class _PlayerActionButton extends StatelessWidget {
  const _PlayerActionButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    );
  }
}

class _PrimaryPlayButton extends StatelessWidget {
  const _PrimaryPlayButton({
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 78,
      height: 78,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [color, color.withValues(alpha: 0.84)]),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.34),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white, size: 34),
      ),
    );
  }
}

void _noop() {}
