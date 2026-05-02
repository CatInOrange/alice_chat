import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../application/music_store.dart';
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
    return Consumer<MusicStore>(
      builder: (context, store, _) {
        final currentTrack = store.currentTrack.copyWith(
          isFavorite: store.isTrackLiked(store.currentTrack.id),
        );
        final currentQueue = store.queue
            .map((item) => item.track)
            .toList(growable: false);
        final theme = Theme.of(context);
        final palette = paletteForTone(currentTrack.artworkTone);
        final nextTracks =
            currentQueue
                .where((item) => item.id != currentTrack.id)
                .take(3)
                .toList();
        final totalDuration =
            store.duration.inMilliseconds > 0
                ? store.duration
                : currentTrack.duration;
        final progress =
            totalDuration.inMilliseconds <= 0
                ? 0.0
                : (store.position.inMilliseconds / totalDuration.inMilliseconds)
                    .clamp(0, 1)
                    .toDouble();
        final currentLyric = store.currentLyricLine;
        final nextLyric = store.nextLyricLine;

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
                                    store.currentPlaybackSourceLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                  if ((store.intelligenceModeHint ?? '')
                                      .trim()
                                      .isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      store.intelligenceModeHint!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 44, height: 44),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                          child: Column(
                            children: [
                              _DiscStage(
                                track: currentTrack,
                                isPlaying: store.isPlaying,
                                isBuffering: store.isBuffering,
                                hasPrevious: store.hasPreviousTrack,
                                hasNext: store.hasNextTrack,
                                onPrevious: store.playPrevious,
                                onNext: store.playNext,
                              ),
                              const SizedBox(height: 20),
                              _LyricsPreviewCard(
                                currentLyric: currentLyric,
                                nextLyric: nextLyric,
                                isLoading: store.isLyricsLoading,
                              ),
                              const SizedBox(height: 28),
                              GestureDetector(
                                onLongPress:
                                    () => _showCollectToPlaylistSheet(
                                      context,
                                      store,
                                      currentTrack,
                                    ),
                                child: Container(
                                  padding: const EdgeInsets.all(22),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.72),
                                    borderRadius: BorderRadius.circular(30),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.72,
                                      ),
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
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  currentTrack.title,
                                                  style: theme
                                                      .textTheme
                                                      .titleLarge
                                                      ?.copyWith(fontSize: 24),
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  '${currentTrack.artist} · ${currentTrack.album}',
                                                  style:
                                                      theme
                                                          .textTheme
                                                          .bodyMedium,
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  store
                                                      .currentPlaybackSourceLabel,
                                                  style:
                                                      theme.textTheme.bodySmall,
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  currentTrack.description,
                                                  style: theme
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(height: 1.5),
                                                ),
                                              ],
                                            ),
                                          ),
                                          IconButton(
                                            onPressed: () {
                                              store.toggleTrackLiked(
                                                currentTrack,
                                              );
                                            },
                                            icon: Icon(
                                              currentTrack.isFavorite
                                                  ? Icons.favorite_rounded
                                                  : Icons
                                                      .favorite_border_rounded,
                                              color:
                                                  currentTrack.isFavorite
                                                      ? const Color(0xFFE91E63)
                                                      : null,
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (store.error != null &&
                                          store.error!.trim().isNotEmpty) ...[
                                        const SizedBox(height: 16),
                                        _PlaybackErrorBanner(
                                          message: store.error!,
                                          onDismiss: store.clearError,
                                          onRetry: () {
                                            final raw = store.error ?? '';
                                            if (raw.contains('加载歌单')) {
                                              store.retryCurrentPlaylist();
                                              return;
                                            }
                                            store.retryCurrentTrack();
                                          },
                                        ),
                                      ],
                                      const SizedBox(height: 22),
                                      _ProgressPanel(
                                        accentColor: palette.gradient.first,
                                        durationLabel: _formatDuration(
                                          totalDuration,
                                        ),
                                        progress: progress,
                                        positionLabel: _formatDuration(
                                          store.position,
                                        ),
                                        onSeek:
                                            (nextProgress) => store.seekTo(
                                              Duration(
                                                milliseconds:
                                                    (totalDuration
                                                                .inMilliseconds *
                                                            nextProgress)
                                                        .round(),
                                              ),
                                            ),
                                      ),
                                      const SizedBox(height: 26),
                                      _PlayerControls(
                                        accentColor: palette.gradient.first,
                                        isPlaying: store.isPlaying,
                                        isBuffering: store.isBuffering,
                                        shuffleEnabled: store.shuffleEnabled,
                                        repeatMode: store.repeatMode,
                                        hasPrevious: store.hasPreviousTrack,
                                        hasNext: store.hasNextTrack,
                                        onPlayPause: store.togglePlayPause,
                                        onPrevious: store.playPrevious,
                                        onNext: store.playNext,
                                        onToggleShuffle: store.toggleShuffle,
                                        onCycleRepeat: store.cycleRepeatMode,
                                        canEnableIntelligence:
                                            store.canEnableIntelligenceMode,
                                        canAttemptIntelligence:
                                            store.canAttemptIntelligenceMode,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 22),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(30),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(
                                    sigmaX: 18,
                                    sigmaY: 18,
                                  ),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.66,
                                      ),
                                      borderRadius: BorderRadius.circular(30),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.72,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '接下来播放',
                                                style:
                                                    theme.textTheme.titleMedium,
                                              ),
                                            ),
                                            Text(
                                              '${currentQueue.length} 首歌曲',
                                              style: theme.textTheme.bodySmall,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 14),
                                        if (nextTracks.isEmpty)
                                          Text(
                                            '当前队列里没有下一首了',
                                            style: theme.textTheme.bodySmall,
                                          )
                                        else
                                          for (final item in nextTracks)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 12,
                                              ),
                                              child: _QueueItem(
                                                track: item,
                                                onTap:
                                                    () => store.playQueueIndex(
                                                      currentQueue.indexWhere(
                                                        (queued) =>
                                                            queued.id ==
                                                            item.id,
                                                      ),
                                                    ),
                                              ),
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
      },
    );
  }
}

Future<void> _showCollectToPlaylistSheet(
  BuildContext context,
  MusicStore store,
  MusicTrack track,
) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final playlists = store.customPlaylists;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('收藏到歌单'),
              subtitle: Text('“喜欢”仍然由右上角红心单独管理'),
            ),
            if (playlists.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('你还没有自建歌单，先去首页创建一个吧。'),
              )
            else
              ...playlists.map(
                (playlist) => ListTile(
                  leading: const Icon(Icons.queue_music_rounded),
                  title: Text(playlist.title),
                  subtitle: Text('${playlist.tracks.length} 首歌曲'),
                  trailing:
                      playlist.tracks.any((item) => item.id == track.id)
                          ? const Icon(Icons.check_rounded, color: Colors.green)
                          : null,
                  onTap: () async {
                    final added = await store.addTrackToCustomPlaylist(
                      playlist.id,
                      track,
                    );
                    if (!sheetContext.mounted) return;
                    Navigator.of(sheetContext).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          added
                              ? '已收藏到 ${playlist.title}'
                              : '这首歌已经在 ${playlist.title} 里了',
                        ),
                      ),
                    );
                  },
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('新建歌单并收藏'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _showCreateAndCollectSheet(context, store, track);
              },
            ),
          ],
        ),
      );
    },
  );
}

Future<void> _showCreateAndCollectSheet(
  BuildContext context,
  MusicStore store,
  MusicTrack track,
) async {
  final controller = TextEditingController();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 8, 20, bottomInset + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: '新歌单名称'),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  final title = controller.text.trim();
                  if (title.isEmpty) return;
                  await store.createCustomPlaylist(title: title);
                  final created =
                      store.customPlaylists.isEmpty
                          ? null
                          : store.customPlaylists.first;
                  if (created != null) {
                    await store.addTrackToCustomPlaylist(created.id, track);
                  }
                  if (!sheetContext.mounted) return;
                  Navigator.of(sheetContext).pop();
                },
                child: const Text('创建并收藏'),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _LyricsPreviewCard extends StatelessWidget {
  const _LyricsPreviewCard({
    required this.currentLyric,
    required this.nextLyric,
    required this.isLoading,
  });

  final String? currentLyric;
  final String? nextLyric;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCurrent = (currentLyric ?? '').trim().isNotEmpty;
    final hasNext = (nextLyric ?? '').trim().isNotEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.72)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '歌词',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(minHeight: 3),
                )
              else if (!hasCurrent)
                Text('这首歌暂时还没有可用歌词', style: theme.textTheme.bodyMedium)
              else ...[
                Text(
                  currentLyric!.replaceAll('\n', ' · '),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.45,
                  ),
                ),
                if (hasNext) ...[
                  const SizedBox(height: 8),
                  Text(
                    nextLyric!.replaceAll('\n', ' · '),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.black54,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscStage extends StatefulWidget {
  const _DiscStage({
    required this.track,
    required this.isPlaying,
    required this.isBuffering,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
  });

  final MusicTrack track;
  final bool isPlaying;
  final bool isBuffering;
  final bool hasPrevious;
  final bool hasNext;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;

  @override
  State<_DiscStage> createState() => _DiscStageState();
}

class _DiscStageState extends State<_DiscStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    if (widget.isPlaying && !widget.isBuffering) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DiscStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldSpin = widget.isPlaying && !widget.isBuffering;
    if (shouldSpin && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!shouldSpin && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = paletteForTone(widget.track.artworkTone);
    return SizedBox(
      height: 352,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (details) async {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity <= -180 && widget.hasNext) {
            await widget.onNext();
            return;
          }
          if (velocity >= 180 && widget.hasPrevious) {
            await widget.onPrevious();
          }
        },
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
            RotationTransition(
              turns: _controller,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 286,
                    height: 286,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0.9),
                          Colors.white.withValues(alpha: 0.26),
                        ],
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x16000000),
                          blurRadius: 18,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 266,
                    height: 266,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.5),
                        width: 10,
                      ),
                    ),
                  ),
                  Container(
                    width: 248,
                    height: 248,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.14),
                        width: 1.5,
                      ),
                    ),
                  ),
                  MusicArtwork(
                    track: widget.track,
                    size: 238,
                    circular: true,
                    heroTag: 'music-artwork-${widget.track.id}',
                    showMeta: false,
                    showIconBadge: false,
                    overlayStrength: 0.06,
                    backendBaseUrl: context.read<MusicStore>().currentConfig.baseUrl,
                    appPassword: context.read<MusicStore>().currentConfig.appPassword,
                  ),
                ],
              ),
            ),
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.78),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.7),
                  width: 1,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 10,
                    offset: Offset(0, 4),
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

class _PlaybackErrorBanner extends StatelessWidget {
  const _PlaybackErrorBanner({
    required this.message,
    required this.onDismiss,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onDismiss;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4F2),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFFD8D2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.error_outline_rounded,
              color: Color(0xFFD94F41),
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF9A3C33),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF9A3C33),
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onDismiss,
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(
                Icons.close_rounded,
                size: 18,
                color: Color(0xFF9A3C33),
              ),
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
    required this.progress,
    required this.positionLabel,
    required this.onSeek,
  });

  final Color accentColor;
  final String durationLabel;
  final double progress;
  final String positionLabel;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 7,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            inactiveTrackColor: const Color(0xFFE7EBF4),
            activeTrackColor: accentColor,
            thumbColor: accentColor,
            overlayColor: accentColor.withValues(alpha: 0.16),
          ),
          child: Slider(value: progress, onChanged: onSeek),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(positionLabel, style: theme.textTheme.bodySmall),
            Text(durationLabel, style: theme.textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}

class _PlayerControls extends StatelessWidget {
  const _PlayerControls({
    required this.accentColor,
    required this.isPlaying,
    required this.isBuffering,
    required this.shuffleEnabled,
    required this.repeatMode,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onToggleShuffle,
    required this.onCycleRepeat,
    required this.canEnableIntelligence,
    required this.canAttemptIntelligence,
  });

  final Color accentColor;
  final bool isPlaying;
  final bool isBuffering;
  final bool shuffleEnabled;
  final MusicRepeatMode repeatMode;
  final bool hasPrevious;
  final bool hasNext;
  final Future<void> Function() onPlayPause;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final Future<void> Function() onToggleShuffle;
  final VoidCallback onCycleRepeat;
  final bool canEnableIntelligence;
  final bool canAttemptIntelligence;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _PlayerActionButton(
          icon: Icons.shuffle_rounded,
          isActive: shuffleEnabled,
          onPressed: () {
            onToggleShuffle();
          },
        ),
        _PlayerActionButton(
          icon: Icons.skip_previous_rounded,
          onPressed:
              hasPrevious
                  ? () {
                    onPrevious();
                  }
                  : null,
        ),
        _PrimaryPlayButton(
          color: accentColor,
          onPressed: () {
            onPlayPause();
          },
          child:
              isBuffering
                  ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.8,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                  : Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
        ),
        _PlayerActionButton(
          icon: Icons.skip_next_rounded,
          onPressed:
              hasNext
                  ? () {
                    onNext();
                  }
                  : null,
        ),
        _PlayerActionButton(
          icon:
              repeatMode == MusicRepeatMode.one
                  ? Icons.repeat_one_rounded
                  : repeatMode == MusicRepeatMode.intelligence
                  ? Icons.auto_awesome_rounded
                  : Icons.repeat_rounded,
          isActive: repeatMode != MusicRepeatMode.off,
          onPressed: onCycleRepeat,
        ),
      ],
    );
  }
}

class _QueueItem extends StatelessWidget {
  const _QueueItem({required this.track, required this.onTap});

  final MusicTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(track.artworkTone);
    return Material(
      color: Colors.white.withValues(alpha: 0.66),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              MusicArtwork(
                track: track,
                size: 56,
                showMeta: false,
                backendBaseUrl: context.read<MusicStore>().currentConfig.baseUrl,
                appPassword: context.read<MusicStore>().currentConfig.appPassword,
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
                    Text(track.artist, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: palette.gradient.first.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  track.durationLabel,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
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
  const _PlayerActionButton({
    required this.icon,
    required this.onPressed,
    this.isActive = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color:
            onPressed == null
                ? Colors.white.withValues(alpha: 0.45)
                : isActive
                ? const Color(0xFF111827)
                : Colors.white.withValues(alpha: 0.9),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: isActive ? Colors.white : null),
      ),
    );
  }
}

class _PrimaryPlayButton extends StatelessWidget {
  const _PrimaryPlayButton({
    required this.color,
    required this.onPressed,
    required this.child,
  });

  final Color color;
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 78,
      height: 78,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [color, color.withValues(alpha: 0.84)],
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.34),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: IconButton(onPressed: onPressed, icon: child),
    );
  }
}

String _formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
