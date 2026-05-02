import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/debug/native_debug_bridge.dart';
import '../../domain/music_models.dart';

String? effectiveArtworkUrl(MusicTrack track) {
  final cached = (track.cachedPlayback?.artworkUrl ?? '').trim();
  if (cached.isNotEmpty) return cached;
  final direct = (track.artworkUrl ?? '').trim();
  if (direct.isNotEmpty) return direct;
  return null;
}

String effectiveArtworkSource(MusicTrack track) {
  final cached = (track.cachedPlayback?.artworkUrl ?? '').trim();
  if (cached.isNotEmpty) return 'cachedPlayback';
  final direct = (track.artworkUrl ?? '').trim();
  if (direct.isNotEmpty) return 'track.artworkUrl';
  return 'none';
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
    this.showIconBadge = true,
    this.overlayStrength,
  });

  final MusicTrack track;
  final double size;
  final bool circular;
  final String? heroTag;
  final bool showMeta;
  final bool showIconBadge;
  final double? overlayStrength;

  @override
  Widget build(BuildContext context) {
    final palette = paletteForTone(track.artworkTone);
    final borderRadius = BorderRadius.circular(circular ? size / 2 : 28);
    final artworkUrl = effectiveArtworkUrl(track);
    final artworkSource = effectiveArtworkSource(track);
    final effectiveOverlayStrength = overlayStrength ?? (showMeta ? 0.28 : 0.1);
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
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) {
                    return child;
                  }
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: palette.gradient,
                      ),
                    ),
                  );
                },
                errorBuilder: (_, error, stackTrace) {
                  final payload = <String, dynamic>{
                    'tag': 'music.artwork.image_error',
                    'ts': DateTime.now().toIso8601String(),
                    'trackId': track.id,
                    'title': track.title,
                    'artist': track.artist,
                    'artworkUrl': artworkUrl,
                    'artworkSource': artworkSource,
                    'error': error.toString(),
                  };
                  final message = payload.entries
                      .map((e) => '${e.key}=${e.value}')
                      .join(' | ');
                  NativeDebugBridge.instance.log(
                    'music',
                    message,
                    level: 'ERROR',
                  );
                  return const SizedBox.shrink();
                },
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors:
                      artworkUrl == null
                          ? palette.gradient
                          : [
                            Colors.black.withValues(
                              alpha: effectiveOverlayStrength * 0.45,
                            ),
                            Colors.black.withValues(
                              alpha: effectiveOverlayStrength + 0.08,
                            ),
                          ],
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: Padding(
                  padding: EdgeInsets.all(circular ? size * 0.16 : 18),
                  child: Column(
                    crossAxisAlignment:
                        circular
                            ? CrossAxisAlignment.center
                            : CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (showIconBadge)
                        Container(
                          width: circular ? size * 0.24 : 44,
                          height: circular ? size * 0.24 : 44,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: artworkUrl == null ? 0.18 : 0.24,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            palette.icon,
                            color: Colors.white,
                            size: circular ? size * 0.11 : 22,
                          ),
                        )
                      else
                        const SizedBox.shrink(),
                      if (showMeta)
                        Column(
                          crossAxisAlignment:
                              circular
                                  ? CrossAxisAlignment.center
                                  : CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign:
                                  circular ? TextAlign.center : TextAlign.start,
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
                              textAlign:
                                  circular ? TextAlign.center : TextAlign.start,
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

class MusicArtworkBackdrop extends StatelessWidget {
  const MusicArtworkBackdrop({
    super.key,
    required this.track,
    this.borderRadius,
    this.blurSigma = 24,
    this.opacity = 0.22,
    this.tintOpacity = 0.56,
    this.darkness = 0.2,
  });

  final MusicTrack track;
  final BorderRadius? borderRadius;
  final double blurSigma;
  final double opacity;
  final double tintOpacity;
  final double darkness;

  @override
  Widget build(BuildContext context) {
    final palette = paletteForTone(track.artworkTone);
    final artworkUrl = effectiveArtworkUrl(track);
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  palette.gradient.first,
                  Color.lerp(palette.gradient.last, Colors.black, 0.12)!,
                ],
              ),
            ),
          ),
          if (artworkUrl != null)
            Opacity(
              opacity: opacity,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: blurSigma,
                  sigmaY: blurSigma,
                ),
                child: Transform.scale(
                  scale: 1.14,
                  child: Image.network(
                    artworkUrl,
                    fit: BoxFit.cover,
                    cacheWidth: 1200,
                    cacheHeight: 1200,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  palette.gradient.first.withValues(alpha: tintOpacity),
                  palette.gradient.last.withValues(alpha: tintOpacity * 0.82),
                ],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: darkness * 0.4),
                  Colors.transparent,
                  Colors.black.withValues(alpha: darkness),
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
