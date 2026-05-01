import 'package:flutter/material.dart';

import '../../domain/music_models.dart';

String? effectiveArtworkUrl(MusicTrack track) {
  final cached = (track.cachedPlayback?.artworkUrl ?? '').trim();
  if (cached.isNotEmpty) return cached;
  final direct = (track.artworkUrl ?? '').trim();
  if (direct.isNotEmpty) return direct;
  return null;
}

class MusicArtworkPalette {
  const MusicArtworkPalette({
    required this.gradient,
    required this.glowColor,
    required this.icon,
  });

  final List<Color> gradient;
  final Color glowColor;
  final IconData icon;
}

MusicArtworkPalette paletteForTone(MusicArtworkTone tone) {
  switch (tone) {
    case MusicArtworkTone.twilight:
      return const MusicArtworkPalette(
        gradient: [Color(0xFF7C4DFF), Color(0xFF4E7BFF)],
        glowColor: Color(0x667C4DFF),
        icon: Icons.graphic_eq_rounded,
      );
    case MusicArtworkTone.sunset:
      return const MusicArtworkPalette(
        gradient: [Color(0xFFFF8A65), Color(0xFFFFB74D)],
        glowColor: Color(0x66FF8A65),
        icon: Icons.wb_twilight_rounded,
      );
    case MusicArtworkTone.aurora:
      return const MusicArtworkPalette(
        gradient: [Color(0xFF00BFA5), Color(0xFF69F0AE)],
        glowColor: Color(0x6600BFA5),
        icon: Icons.auto_awesome_rounded,
      );
    case MusicArtworkTone.ocean:
      return const MusicArtworkPalette(
        gradient: [Color(0xFF1976D2), Color(0xFF00ACC1)],
        glowColor: Color(0x661976D2),
        icon: Icons.water_drop_rounded,
      );
    case MusicArtworkTone.rose:
      return const MusicArtworkPalette(
        gradient: [Color(0xFFE91E63), Color(0xFFFF80AB)],
        glowColor: Color(0x66E91E63),
        icon: Icons.favorite_rounded,
      );
    case MusicArtworkTone.midnight:
      return const MusicArtworkPalette(
        gradient: [Color(0xFF263238), Color(0xFF455A64)],
        glowColor: Color(0x6637464F),
        icon: Icons.nights_stay_rounded,
      );
  }
}

class MusicArtwork extends StatelessWidget {
  const MusicArtwork({
    super.key,
    required this.track,
    required this.size,
    this.circular = false,
    this.heroTag,
    this.showMeta = true,
  });

  final MusicTrack track;
  final double size;
  final bool circular;
  final String? heroTag;
  final bool showMeta;

  @override
  Widget build(BuildContext context) {
    final palette = paletteForTone(track.artworkTone);
    final borderRadius = BorderRadius.circular(circular ? size / 2 : 28);
    final artworkUrl = effectiveArtworkUrl(track);
    final body = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circular ? null : borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.gradient,
        ),
        boxShadow: [
          BoxShadow(
            color: palette.glowColor,
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (artworkUrl != null)
              Image.network(
                artworkUrl,
                fit: BoxFit.cover,
                cacheWidth: (size * 3).round(),
                cacheHeight: (size * 3).round(),
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: artworkUrl == null
                      ? palette.gradient
                      : [
                          Colors.black.withValues(alpha: showMeta ? 0.12 : 0.02),
                          Colors.black.withValues(alpha: showMeta ? 0.34 : 0.08),
                        ],
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: Padding(
                  padding: EdgeInsets.all(circular ? size * 0.16 : 18),
                  child: Column(
                    crossAxisAlignment: circular
                        ? CrossAxisAlignment.center
                        : CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        width: circular ? size * 0.24 : 44,
                        height: circular ? size * 0.24 : 44,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: artworkUrl == null ? 0.18 : 0.24),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          palette.icon,
                          color: Colors.white,
                          size: circular ? size * 0.11 : 22,
                        ),
                      ),
                      if (showMeta)
                        Column(
                          crossAxisAlignment: circular
                              ? CrossAxisAlignment.center
                              : CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: circular ? TextAlign.center : TextAlign.start,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: circular ? size * 0.08 : 18,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: circular ? TextAlign.center : TextAlign.start,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.84),
                                fontSize: circular ? size * 0.042 : 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (heroTag == null) {
      return body;
    }
    return Hero(tag: heroTag!, child: body);
  }
}
