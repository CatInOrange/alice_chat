import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/debug/native_debug_bridge.dart';
import '../../domain/music_models.dart';

String _normalizeArtworkUrl(String? value) {
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty) return '';
  return trimmed.replaceFirst(
    RegExp(r'^http://p(?=\d+\.music\.126\.net/)'),
    'https://p',
  );
}

String? effectiveArtworkUrl(MusicTrack track) {
  final cached = _normalizeArtworkUrl(track.cachedPlayback?.artworkUrl);
  if (cached.isNotEmpty) return cached;
  final direct = _normalizeArtworkUrl(track.artworkUrl);
  if (direct.isNotEmpty) return direct;
  return null;
}

bool _shouldProxyArtworkUrl(String url) {
  final uri = Uri.tryParse(url);
  final host = (uri?.host ?? '').toLowerCase();
  return host == 'p1.music.126.net' ||
      host == 'p2.music.126.net' ||
      host == 'p3.music.126.net' ||
      host == 'p4.music.126.net';
}

String? buildProxiedArtworkUrl(
  String? rawUrl, {
  required String backendBaseUrl,
}) {
  final normalized = _normalizeArtworkUrl(rawUrl);
  final base = backendBaseUrl.trim();
  if (normalized.isEmpty || base.isEmpty || !_shouldProxyArtworkUrl(normalized)) {
    return normalized.isEmpty ? null : normalized;
  }
  final cleanBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  return Uri.parse('$cleanBase/api/music/artwork').replace(
    queryParameters: {'url': normalized},
  ).toString();
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

class MusicArtwork extends StatefulWidget {
  const MusicArtwork({
    super.key,
    required this.track,
    required this.size,
    this.circular = false,
    this.heroTag,
    this.showMeta = true,
    this.showIconBadge = true,
    this.overlayStrength,
    this.backendBaseUrl,
    this.appPassword,
  });

  final MusicTrack track;
  final double size;
  final bool circular;
  final String? heroTag;
  final bool showMeta;
  final bool showIconBadge;
  final double? overlayStrength;
  final String? backendBaseUrl;
  final String? appPassword;

  @override
  State<MusicArtwork> createState() => _MusicArtworkState();
}

class _MusicArtworkState extends State<MusicArtwork> {
  bool _useProxy = false;

  @override
  void didUpdateWidget(covariant MusicArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (effectiveArtworkUrl(oldWidget.track) != effectiveArtworkUrl(widget.track)) {
      _useProxy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final palette = paletteForTone(track.artworkTone);
    final borderRadius = BorderRadius.circular(widget.circular ? widget.size / 2 : 28);
    final rawArtworkUrl = effectiveArtworkUrl(track);
    final proxiedArtworkUrl = buildProxiedArtworkUrl(
      rawArtworkUrl,
      backendBaseUrl: widget.backendBaseUrl ?? '',
    );
    final artworkUrl = _useProxy ? proxiedArtworkUrl : rawArtworkUrl;
    final artworkSource = effectiveArtworkSource(track);
    final effectiveOverlayStrength = widget.overlayStrength ?? (widget.showMeta ? 0.28 : 0.1);
    final proxyEligible = rawArtworkUrl != null &&
        proxiedArtworkUrl != null &&
        proxiedArtworkUrl != rawArtworkUrl;

    final body = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: widget.circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: widget.circular ? null : borderRadius,
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
                headers:
                    _useProxy && (widget.appPassword ?? '').trim().isNotEmpty
                        ? {
                          'X-AliceChat-Password': (widget.appPassword ?? '').trim(),
                        }
                        : null,
                fit: BoxFit.cover,
                cacheWidth: (widget.size * 3).round(),
                cacheHeight: (widget.size * 3).round(),
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
                  final shouldRetryWithProxy = !_useProxy && proxyEligible;
                  final payload = <String, dynamic>{
                    'tag': shouldRetryWithProxy
                        ? 'music.artwork.image_retry_proxy'
                        : 'music.artwork.image_error',
                    'ts': DateTime.now().toIso8601String(),
                    'trackId': track.id,
                    'title': track.title,
                    'artist': track.artist,
                    'artworkUrl': artworkUrl,
                    'rawArtworkUrl': rawArtworkUrl,
                    'proxiedArtworkUrl': proxiedArtworkUrl,
                    'artworkSource': artworkSource,
                    'usingProxy': _useProxy,
                    'error': error.toString(),
                  };
                  final message = payload.entries
                      .map((e) => '${e.key}=${e.value}')
                      .join(' | ');
                  NativeDebugBridge.instance.log(
                    'music',
                    message,
                    level: shouldRetryWithProxy ? 'WARN' : 'ERROR',
                  );
                  if (shouldRetryWithProxy) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      setState(() {
                        _useProxy = true;
                      });
                    });
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: palette.gradient,
                        ),
                      ),
                    );
                  }
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: palette.gradient,
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: widget.circular ? widget.size * 0.26 : 48,
                        height: widget.circular ? widget.size * 0.26 : 48,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.album_rounded,
                          color: Colors.white.withValues(alpha: 0.92),
                          size: widget.circular ? widget.size * 0.12 : 24,
                        ),
                      ),
                    ),
                  );
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
                  padding: EdgeInsets.all(widget.circular ? widget.size * 0.16 : 18),
                  child: Column(
                    crossAxisAlignment:
                        widget.circular
                            ? CrossAxisAlignment.center
                            : CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (widget.showIconBadge)
                        Container(
                          width: widget.circular ? widget.size * 0.24 : 44,
                          height: widget.circular ? widget.size * 0.24 : 44,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: artworkUrl == null ? 0.18 : 0.24,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            palette.icon,
                            color: Colors.white,
                            size: widget.circular ? widget.size * 0.11 : 22,
                          ),
                        )
                      else
                        const SizedBox.shrink(),
                      if (widget.showMeta)
                        Column(
                          crossAxisAlignment:
                              widget.circular
                                  ? CrossAxisAlignment.center
                                  : CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign:
                                  widget.circular ? TextAlign.center : TextAlign.start,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: widget.circular ? widget.size * 0.08 : 18,
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
                                  widget.circular ? TextAlign.center : TextAlign.start,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.84),
                                fontSize: widget.circular ? widget.size * 0.042 : 13,
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

    if (widget.heroTag == null) {
      return body;
    }
    return Hero(tag: widget.heroTag!, child: body);
  }
}

class MusicArtworkBackdrop extends StatefulWidget {
  const MusicArtworkBackdrop({
    super.key,
    required this.track,
    this.borderRadius,
    this.blurSigma = 24,
    this.opacity = 0.22,
    this.tintOpacity = 0.56,
    this.darkness = 0.2,
    this.backendBaseUrl,
    this.appPassword,
  });

  final MusicTrack track;
  final BorderRadius? borderRadius;
  final double blurSigma;
  final double opacity;
  final double tintOpacity;
  final double darkness;
  final String? backendBaseUrl;
  final String? appPassword;

  @override
  State<MusicArtworkBackdrop> createState() => _MusicArtworkBackdropState();
}

class _MusicArtworkBackdropState extends State<MusicArtworkBackdrop> {
  bool _useProxy = false;

  @override
  void didUpdateWidget(covariant MusicArtworkBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (effectiveArtworkUrl(oldWidget.track) != effectiveArtworkUrl(widget.track)) {
      _useProxy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = paletteForTone(widget.track.artworkTone);
    final rawArtworkUrl = effectiveArtworkUrl(widget.track);
    final proxiedArtworkUrl = buildProxiedArtworkUrl(
      rawArtworkUrl,
      backendBaseUrl: widget.backendBaseUrl ?? '',
    );
    final artworkUrl = _useProxy ? proxiedArtworkUrl : rawArtworkUrl;
    final proxyEligible = rawArtworkUrl != null &&
        proxiedArtworkUrl != null &&
        proxiedArtworkUrl != rawArtworkUrl;

    return ClipRRect(
      borderRadius: widget.borderRadius ?? BorderRadius.zero,
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
              opacity: widget.opacity,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: widget.blurSigma,
                  sigmaY: widget.blurSigma,
                ),
                child: Transform.scale(
                  scale: 1.14,
                  child: Image.network(
                    artworkUrl,
                    headers:
                        _useProxy && (widget.appPassword ?? '').trim().isNotEmpty
                            ? {
                              'X-AliceChat-Password': (widget.appPassword ?? '').trim(),
                            }
                            : null,
                    fit: BoxFit.cover,
                    cacheWidth: 1200,
                    cacheHeight: 1200,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, error, __) {
                      if (!_useProxy && proxyEligible) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          setState(() {
                            _useProxy = true;
                          });
                        });
                      }
                      NativeDebugBridge.instance.log(
                        'music',
                        'tag=${(!_useProxy && proxyEligible) ? 'music.artwork.backdrop_retry_proxy' : 'music.artwork.backdrop_error'} | trackId=${widget.track.id} | title=${widget.track.title} | artworkUrl=$artworkUrl | rawArtworkUrl=$rawArtworkUrl | proxiedArtworkUrl=$proxiedArtworkUrl | usingProxy=$_useProxy | error=$error',
                        level: (!_useProxy && proxyEligible) ? 'WARN' : 'ERROR',
                      );
                      return const SizedBox.shrink();
                    },
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
                  palette.gradient.first.withValues(alpha: widget.tintOpacity),
                  palette.gradient.last.withValues(alpha: widget.tintOpacity * 0.82),
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
                  Colors.black.withValues(alpha: widget.darkness * 0.4),
                  Colors.transparent,
                  Colors.black.withValues(alpha: widget.darkness),
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
