import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../application/music_store.dart';
import '../domain/music_models.dart';
import 'music_player_screen.dart';
import 'widgets/music_artwork.dart';

Route<void> _buildMusicPlayerRoute({
  required MusicTrack track,
  required List<MusicTrack> queue,
}) {
  return MaterialPageRoute<void>(
    builder: (_) => MusicPlayerScreen(track: track, queue: queue),
  );
}

class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen>
    with AutomaticKeepAliveClientMixin {
  bool _isNavigatingToPlayer = false;
  bool _isOpeningSearch = false;
  final Set<String> _pendingPlaylistActions = <String>{};

  String _friendlyHomeError(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '出了点小问题，请稍后再试';
    final lower = text.toLowerCase();
    if (lower.contains('baseurl') || lower.contains('no host specified')) {
      return '还没有配置好音乐服务地址，请先去设置页检查 OpenClaw / 后端地址。';
    }
    if (text.contains('401') || text.contains('403') || text.contains('登录')) {
      return '当前登录状态可能已经失效，请重新登录音乐平台后再试。';
    }
    if (text.contains('没有可播放') ||
        text.contains('source') ||
        text.contains('播放')) {
      return '这首歌暂时没法顺利播放，可以重试一次，或者换一首试试。';
    }
    return text;
  }

  _NoticeTone _noticeToneForError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('baseurl') || lower.contains('no host specified')) {
      return _NoticeTone.warning;
    }
    if (raw.contains('401') || raw.contains('403') || raw.contains('登录')) {
      return _NoticeTone.info;
    }
    return _NoticeTone.error;
  }

  String _primaryActionLabelForError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('baseurl') || lower.contains('no host specified')) {
      return '查看提示';
    }
    if (raw.contains('401') || raw.contains('403') || raw.contains('登录')) {
      return '重新加载';
    }
    return '重试';
  }

  Future<void> _handlePrimaryErrorAction(
    BuildContext context,
    MusicStore store,
    String raw,
  ) async {
    final lower = raw.toLowerCase();
    if (lower.contains('baseurl') || lower.contains('no host specified')) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请到设置里检查后端地址、桥接地址和登录状态')));
      return;
    }
    if (raw.contains('没有可播放') ||
        lower.contains('source') ||
        raw.contains('播放')) {
      await store.retryCurrentTrack();
      return;
    }
    await store.retryCurrentPlaylist();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<MusicStore>().ensureReady();
    });
  }

  @override
  bool get wantKeepAlive => true;

  String? _formatAiPlaylistTime(MusicAiPlaylistDraft? playlist) {
    final stamp = playlist?.updatedAt ?? playlist?.createdAt;
    if (stamp == null) return null;
    final local = stamp.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '生成于 $mm-$dd $hh:$min';
  }

  Future<void> _openPlayer(MusicStore store, [MusicTrack? track]) async {
    if (_isNavigatingToPlayer) return;
    _isNavigatingToPlayer = true;
    try {
      if (track != null) {
        unawaited(store.selectTrack(track, autoplay: true));
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        _buildMusicPlayerRoute(
          track: track ?? store.currentTrack,
          queue: store.queue.map((item) => item.track).toList(growable: false),
        ),
      );
    } finally {
      _isNavigatingToPlayer = false;
    }
  }

  bool _beginPlaylistAction(String playlistId) {
    if (playlistId.trim().isEmpty) return false;
    if (_pendingPlaylistActions.contains(playlistId)) {
      return false;
    }
    setState(() {
      _pendingPlaylistActions.add(playlistId);
    });
    return true;
  }

  void _endPlaylistAction(String playlistId) {
    if (!mounted) return;
    if (!_pendingPlaylistActions.contains(playlistId)) return;
    setState(() {
      _pendingPlaylistActions.remove(playlistId);
    });
  }

  bool _isPlaylistActionPending(String playlistId) {
    return _pendingPlaylistActions.contains(playlistId);
  }

  Future<void> _playPlaylist(MusicStore store, MusicPlaylist playlist) async {
    if (!_beginPlaylistAction(playlist.id)) return;
    try {
      await store.playPlaylist(playlist);
      if (!mounted) return;
      unawaited(_openPlayer(store));
    } catch (_) {
      // store.error already updated; keep user on current screen
    } finally {
      _endPlaylistAction(playlist.id);
    }
  }

  Future<void> _openPlaylistDetail(
    MusicStore store,
    MusicPlaylist playlist,
  ) async {
    if (!_beginPlaylistAction(playlist.id)) return;
    final immediateTracks = store.peekPlaylistTracks(playlist);
    try {
      if (!mounted) return;
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder:
                (_) => ChangeNotifierProvider.value(
                  value: store,
                  child: _PlaylistDetailScreen(
                    playlist: playlist,
                    initialTracks: immediateTracks,
                  ),
                ),
          ),
        ),
      );
    } catch (_) {
      // store.error already updated; keep user on current screen
    } finally {
      _endPlaylistAction(playlist.id);
    }
  }

  Future<void> _showCreatePlaylistSheet(
    BuildContext context,
    MusicStore store,
  ) async {
    final nameController = TextEditingController();
    final subtitleController = TextEditingController();
    final descriptionController = TextEditingController();
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('新建歌单', style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '歌单名称',
                  hintText: '例如：睡前循环 / 周末开车',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: subtitleController,
                decoration: const InputDecoration(
                  labelText: '副标题（选填）',
                  hintText: '一句描述这份歌单',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descriptionController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '简介（选填）',
                  hintText: '比如：适合夜里安静听的民谣',
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final title = nameController.text.trim();
                    if (title.isEmpty) return;
                    await store.createCustomPlaylist(
                      title: title,
                      subtitle: subtitleController.text,
                      description: descriptionController.text,
                    );
                    if (!sheetContext.mounted) return;
                    Navigator.of(sheetContext).pop();
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('已创建歌单：$title')));
                  },
                  child: const Text('创建歌单'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showRenamePlaylistSheet(
    BuildContext context,
    MusicStore store,
    MusicPlaylist playlist,
  ) async {
    final custom = store.customPlaylistById(playlist.id);
    if (custom == null) return;
    final nameController = TextEditingController(text: custom.title);
    final subtitleController = TextEditingController(text: custom.subtitle);
    final descriptionController = TextEditingController(
      text: custom.description,
    );
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('编辑歌单', style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '歌单名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: subtitleController,
                decoration: const InputDecoration(labelText: '副标题（选填）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descriptionController,
                maxLines: 2,
                decoration: const InputDecoration(labelText: '简介（选填）'),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final title = nameController.text.trim();
                    if (title.isEmpty) return;
                    await store.renameCustomPlaylist(
                      playlist.id,
                      title: title,
                      subtitle: subtitleController.text.trim(),
                      description: descriptionController.text.trim(),
                    );
                    if (!sheetContext.mounted) return;
                    Navigator.of(sheetContext).pop();
                  },
                  child: const Text('保存修改'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showCustomPlaylistActions(
    BuildContext context,
    MusicStore store,
    MusicPlaylist playlist,
  ) async {
    if (playlist.id == 'netease-fm') {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded),
                title: const Text('播放歌单'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _playPlaylist(store, playlist);
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: const Text('查看详情'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openPlaylistDetail(store, playlist);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('编辑歌单'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showRenamePlaylistSheet(context, store, playlist);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  '删除歌单',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder:
                        (dialogContext) => AlertDialog(
                          title: const Text('删除歌单？'),
                          content: const Text('删除后歌单里的歌曲不会被删除，只会移除这个歌单。'),
                          actions: [
                            TextButton(
                              onPressed:
                                  () => Navigator.of(dialogContext).pop(false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed:
                                  () => Navigator.of(dialogContext).pop(true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                  );
                  if (confirmed == true) {
                    await store.deleteCustomPlaylist(playlist.id);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openSearch(BuildContext context, MusicStore store) async {
    if (_isOpeningSearch) return;
    _isOpeningSearch = true;
    try {
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
    } finally {
      _isOpeningSearch = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Consumer<MusicStore>(
      builder: (context, store, _) {
        final currentTrack = store.currentTrack.copyWith(
          isFavorite: store.isTrackLiked(store.currentTrack.id),
        );
        final isPlaying = store.isPlaying;
        final playlists = store.playlists;
        final recentPlaylists = store.recentPlaylists;
        final likedPlaylist = store.likedPlaylist;
        final latestAiPlaylist = store.latestAiPlaylist;
        final aiPlaylistHistory = store.aiPlaylistHistory;
        final currentPlaybackSourceLabel = store.currentPlaybackSourceLabel;
        final miniSubtitle = store.miniPlayerSubtitle;
        final currentPlaybackModeBadge = store.currentPlaybackModeBadge;
        final currentConfig = store.currentConfig;
        const fmPlaylist = MusicPlaylist(
          id: 'netease-fm',
          title: '私人 FM',
          subtitle: '根据你的喜好连续播放',
          tag: 'FM',
          trackCount: 0,
          artworkTone: MusicArtworkTone.sunset,
        );
        final displayedCustomPlaylists = <MusicPlaylist>[
          fmPlaylist,
          ...store.customPlaylistCards,
        ];
        final latestAiPlaylistActionPending =
            latestAiPlaylist != null &&
            _isPlaylistActionPending(latestAiPlaylist.id);

        return Scaffold(
          appBar: AppBar(
            title: const Text('音乐'),
            actions: [
              IconButton(
                onPressed:
                    _isOpeningSearch ? null : () => _openSearch(context, store),
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
                    track: store.heroTrack,
                    backendBaseUrl: currentConfig.baseUrl,
                    appPassword: currentConfig.appPassword,
                    title:
                        latestAiPlaylist == null
                            ? '今晚推荐'
                            : (latestAiPlaylist.subtitle.trim().isNotEmpty
                                ? latestAiPlaylist.subtitle
                                : 'AI 为你生成'),
                    headline: latestAiPlaylist?.title ?? '给工作和夜色留一点音乐。',
                    subtitle: null,
                    description:
                        latestAiPlaylist?.description ??
                        store.heroTrack.description,
                    buttonLabel: latestAiPlaylist != null ? '播放歌单' : '播放',
                    badgeLabel: latestAiPlaylist != null ? 'AI 最新歌单' : '今晚推荐',
                    timestampLabel: _formatAiPlaylistTime(latestAiPlaylist),
                    isBusy: latestAiPlaylistActionPending,
                    onPlayTap: () async {
                      if (latestAiPlaylist != null) {
                        await _playPlaylist(store, latestAiPlaylist.asPlaylist);
                        return;
                      }
                      await _openPlayer(store, store.heroTrack);
                    },
                    onDetailTap:
                        latestAiPlaylist != null
                            ? () => _openPlaylistDetail(
                              store,
                              latestAiPlaylist.asPlaylist,
                            )
                            : null,
                  ),
                  const SizedBox(height: 24),
                  _FavoritePlaylistCard(
                    playlist: likedPlaylist,
                    currentTrack:
                        store.likedTracks.isNotEmpty
                            ? store.likedTracks.first
                            : currentTrack,
                    isLoading:
                        store.isPlaylistLoading(likedPlaylist.id) ||
                        _isPlaylistActionPending(likedPlaylist.id),
                    isActive: store.isPlaylistActive(likedPlaylist.id),
                    isPlaying: store.isPlaylistPlaying(likedPlaylist.id),
                    onTap: () => _openPlaylistDetail(store, likedPlaylist),
                    onPlayTap:
                        store.isPlaylistPlaying(likedPlaylist.id)
                            ? null
                            : () => _playPlaylist(store, likedPlaylist),
                  ),
                  const SizedBox(height: 28),
                  _SectionHeader(
                    title: '我的歌单',
                    subtitle: '你慢慢收下的歌 都在这里',
                    actionLabel: '添加',
                    isBusy: false,
                    onActionTap: () {
                      _showCreatePlaylistSheet(context, store);
                    },
                  ),
                  const SizedBox(height: 14),
                  _CompactPlaylistGrid(
                    playlists: displayedCustomPlaylists,
                    currentPlaylistId: store.currentPlaylistId,
                    onPlaylistTap: (playlist) {
                      if (playlist.id == 'netease-fm') {
                        _playPlaylist(store, playlist);
                        return;
                      }
                      _openPlaylistDetail(store, playlist);
                    },
                    onPlaylistLongPress: (playlist) {
                      if (playlist.id == 'netease-fm') {
                        return;
                      }
                      _showCustomPlaylistActions(context, store, playlist);
                    },
                  ),
                  if ((store.error ?? '').trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 20, bottom: 12),
                      child: _InlineNotice(
                        message: _friendlyHomeError(store.error!),
                        tone: _noticeToneForError(store.error!),
                        onDismiss: store.clearError,
                        primaryActionLabel: _primaryActionLabelForError(
                          store.error!,
                        ),
                        onPrimaryAction:
                            () => _handlePrimaryErrorAction(
                              context,
                              store,
                              store.error!,
                            ),
                      ),
                    ),
                  if (recentPlaylists.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    _SectionHeader(
                      title: '最近播放',
                      subtitle: '刚刚听过的感觉 还能从这里回去',
                      actionLabel: '刷新',
                      isBusy: store.isRefreshingLibrary,
                      onActionTap: () {
                        store.refreshLibrary();
                      },
                    ),
                    const SizedBox(height: 14),
                    ...recentPlaylists.map(
                      (playlist) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _RecentPlaylistTile(
                          playlist: playlist,
                          isActive: store.isPlaylistActive(playlist.id),
                          isBusy: _isPlaylistActionPending(playlist.id),
                          onTap: () => _openPlaylistDetail(store, playlist),
                          onPlayTap: () => _playPlaylist(store, playlist),
                        ),
                      ),
                    ),
                  ],
                  if (aiPlaylistHistory.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    _SectionHeader(
                      title: 'AI 历史歌单',
                      subtitle: '这次为你整理的在 之前的也还留着',
                      actionLabel: '刷新',
                      isBusy: store.isRefreshingLibrary,
                      onActionTap: () {
                        store.refreshLibrary();
                      },
                    ),
                    const SizedBox(height: 14),
                    ...aiPlaylistHistory.map(
                      (draft) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _RecentPlaylistTile(
                          playlist: draft.asPlaylist,
                          isActive: store.isPlaylistActive(draft.asPlaylist.id),
                          isBusy: _isPlaylistActionPending(draft.asPlaylist.id),
                          metaLabel: _formatAiPlaylistTime(draft),
                          onTap:
                              () =>
                                  _openPlaylistDetail(store, draft.asPlaylist),
                          onPlayTap:
                              () => _playPlaylist(store, draft.asPlaylist),
                        ),
                      ),
                    ),
                  ],
                  if (playlists.isEmpty &&
                      recentPlaylists.isEmpty &&
                      latestAiPlaylist == null)
                    const _EmptyMusicState()
                  else if (recentPlaylists.isEmpty && aiPlaylistHistory.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: _SectionPlaceholder(
                        title: '等你听过几首 这里就会慢慢热闹起来',
                        subtitle: currentPlaybackSourceLabel,
                      ),
                    ),
                ],
              ),
              if (store.hasPlaybackContext)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: _MiniPlayer(
                    track: currentTrack,
                    backendBaseUrl: currentConfig.baseUrl,
                    appPassword: currentConfig.appPassword,
                    sourceLabel: miniSubtitle,
                    modeBadge: currentPlaybackModeBadge,
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
            child: _GlowOrb(size: 220, color: const Color(0x337C4DFF)),
          ),
          Positioned(
            top: 180,
            left: -72,
            child: _GlowOrb(size: 180, color: const Color(0x2200BFA5)),
          ),
          Positioned(
            bottom: 80,
            right: -30,
            child: _GlowOrb(size: 160, color: const Color(0x22FF8A65)),
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
        gradient: RadialGradient(colors: [color, Colors.transparent]),
      ),
    );
  }
}

class _MusicHeroCard extends StatelessWidget {
  const _MusicHeroCard({
    required this.track,
    required this.backendBaseUrl,
    this.appPassword,
    required this.onPlayTap,
    required this.title,
    required this.headline,
    required this.description,
    required this.buttonLabel,
    required this.badgeLabel,
    this.subtitle,
    this.timestampLabel,
    this.onDetailTap,
    this.isBusy = false,
  });

  final MusicTrack track;
  final String backendBaseUrl;
  final String? appPassword;
  final VoidCallback onPlayTap;
  final String title;
  final String headline;
  final String description;
  final String buttonLabel;
  final String badgeLabel;
  final String? subtitle;
  final String? timestampLabel;
  final VoidCallback? onDetailTap;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(track.artworkTone);
    final cardRadius = BorderRadius.circular(36);
    return Container(
      decoration: BoxDecoration(
        borderRadius: cardRadius,
        boxShadow: [
          BoxShadow(
            color: palette.glowColor.withValues(alpha: 0.68),
            blurRadius: 38,
            offset: const Offset(0, 20),
          ),
          const BoxShadow(
            color: Color(0x120B1220),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: cardRadius,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      palette.gradient.first.withValues(alpha: 0.94),
                      palette.gradient.last.withValues(alpha: 0.9),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: MusicArtworkBackdrop(
                track: track,
                borderRadius: cardRadius,
                blurSigma: 30,
                opacity: 0.34,
                tintOpacity: 0.28,
                darkness: 0.34,
                backendBaseUrl: backendBaseUrl,
                appPassword: appPassword,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.08),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.18),
                    ],
                    stops: const [0.0, 0.3, 1.0],
                  ),
                ),
              ),
            ),
            Positioned(
              right: -18,
              top: 10,
              bottom: 10,
              width: 196,
              child: IgnorePointer(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      right: -12,
                      top: 12,
                      child: Container(
                        width: 184,
                        height: 184,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              Colors.white.withValues(alpha: 0.22),
                              Colors.white.withValues(alpha: 0.03),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Transform.translate(
                          offset: const Offset(10, 0),
                          child: SizedBox(
                            width: 176,
                            height: 220,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(40),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.22,
                                        ),
                                      ),
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Colors.white.withValues(alpha: 0.2),
                                          Colors.white.withValues(alpha: 0.05),
                                        ],
                                      ),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Color(0x22000000),
                                          blurRadius: 28,
                                          offset: Offset(0, 16),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: 10,
                                  right: 10,
                                  top: 10,
                                  bottom: 10,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(34),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        MusicArtwork(
                                          track: track,
                                          size: 196,
                                          showMeta: false,
                                          showIconBadge: false,
                                          overlayStrength: 0.05,
                                          backendBaseUrl: backendBaseUrl,
                                          appPassword: appPassword,
                                        ),
                                        DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [
                                                Colors.white.withValues(
                                                  alpha: 0.12,
                                                ),
                                                Colors.transparent,
                                                Colors.black.withValues(
                                                  alpha: 0.12,
                                                ),
                                              ],
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
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withValues(alpha: 0.34),
                      Colors.black.withValues(alpha: 0.18),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.52, 1.0],
                  ),
                ),
              ),
            ),
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: cardRadius,
                onTap: onDetailTap ?? onPlayTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.14),
                              ),
                            ),
                            child: Text(
                              badgeLabel,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if ((timestampLabel ?? '').trim().isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                timestampLabel!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.74),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: 208,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white.withValues(alpha: 0.72),
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              headline,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: Colors.white,
                                fontSize: 24,
                                height: 1.16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if ((subtitle ?? '').trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.9),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            Text(
                              description,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white.withValues(alpha: 0.78),
                                height: 1.42,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white.withValues(alpha: 0.11),
                                  Colors.white.withValues(alpha: 0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white.withValues(alpha: 0.1),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.12,
                                      ),
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.graphic_eq_rounded,
                                    color: Colors.white.withValues(alpha: 0.88),
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '当前主打',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: Colors.white.withValues(
                                                alpha: 0.66,
                                              ),
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.3,
                                            ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        track.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              color: Colors.white,
                                              fontSize: 17,
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${track.artist} · ${track.album}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: Colors.white.withValues(
                                                alpha: 0.74,
                                              ),
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    FilledButton.tonalIcon(
                                      onPressed: isBusy ? null : onPlayTap,
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.white,
                                        foregroundColor: palette.gradient.first,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 12,
                                        ),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      icon:
                                          isBusy
                                              ? SizedBox(
                                                width: 16,
                                                height: 16,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  valueColor:
                                                      AlwaysStoppedAnimation<
                                                        Color
                                                      >(palette.gradient.first),
                                                ),
                                              )
                                              : const Icon(
                                                Icons.play_arrow_rounded,
                                              ),
                                      label: Text(
                                        isBusy ? '处理中...' : buttonLabel,
                                      ),
                                    ),
                                    if (onDetailTap != null) ...[
                                      const SizedBox(height: 4),
                                      TextButton(
                                        onPressed: isBusy ? null : onDetailTap,
                                        style: TextButton.styleFrom(
                                          foregroundColor: Colors.white
                                              .withValues(alpha: 0.92),
                                          visualDensity: VisualDensity.compact,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                        ),
                                        child: const Text('查看歌单'),
                                      ),
                                    ],
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
              ),
            ),
          ],
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
    required this.onPlayTap,
    this.isLoading = false,
    this.isActive = false,
    this.isPlaying = false,
  });

  final MusicPlaylist playlist;
  final MusicTrack currentTrack;
  final VoidCallback onTap;
  final VoidCallback? onPlayTap;
  final bool isLoading;
  final bool isActive;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(playlist.artworkTone);
    return Material(
      color: Colors.white.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        borderRadius: BorderRadius.circular(26),
        onTap: isLoading ? null : onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 15, 14, 15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white.withValues(alpha: 0.78)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.9),
                Colors.white.withValues(alpha: 0.72),
              ],
            ),
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
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: palette.gradient),
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: palette.glowColor.withValues(alpha: 0.38),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.34),
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.favorite_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            isActive ? '当前正在播放的收藏歌单' : '喜欢过的歌 都收在这里',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.35,
                              color: const Color(0xFF5B6476),
                            ),
                          ),
                        ),
                        if (isPlaying)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: palette.gradient.first.withValues(
                                alpha: 0.12,
                              ),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '正在播放',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: palette.gradient.first,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      playlist.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${playlist.trackCount} 首 · ${isPlaying ? '这一刻正从这里继续' : '想听的时候 随时都能回来'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF5B6476),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '想接着听的话 就从《${currentTrack.title}》继续',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF8A93A5),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: isLoading ? null : onPlayTap,
                style: FilledButton.styleFrom(
                  backgroundColor: palette.gradient.first,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(50, 50),
                  shape: const CircleBorder(),
                  padding: EdgeInsets.zero,
                  elevation: 0,
                ),
                child:
                    isLoading
                        ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        )
                        : Icon(
                          isPlaying
                              ? Icons.equalizer_rounded
                              : Icons.play_arrow_rounded,
                          size: 22,
                        ),
              ),
            ],
          ),
        ),
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
    this.isBusy = false,
  });

  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onActionTap;
  final bool isBusy;

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
        TextButton(
          onPressed: isBusy ? null : onActionTap,
          child:
              isBusy
                  ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : Text(actionLabel),
        ),
      ],
    );
  }
}

class _CompactPlaylistGrid extends StatelessWidget {
  const _CompactPlaylistGrid({
    required this.playlists,
    required this.currentPlaylistId,
    required this.onPlaylistTap,
    this.onPlaylistLongPress,
  });

  final List<MusicPlaylist> playlists;
  final String? currentPlaylistId;
  final ValueChanged<MusicPlaylist> onPlaylistTap;
  final ValueChanged<MusicPlaylist>? onPlaylistLongPress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 172,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: playlists.length,
        padding: EdgeInsets.zero,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final playlist = playlists[index];
          final cardWidth = (MediaQuery.of(context).size.width - 32 - 24) / 3;
          return SizedBox(
            width: cardWidth,
            child: _PlaylistGridCard(
              playlist: playlist,
              isActive: currentPlaylistId == playlist.id,
              onTap: () => onPlaylistTap(playlist),
              onLongPress:
                  onPlaylistLongPress == null
                      ? null
                      : () => onPlaylistLongPress!(playlist),
            ),
          );
        },
      ),
    );
  }
}

class _PlaylistGridCard extends StatelessWidget {
  const _PlaylistGridCard({
    required this.playlist,
    required this.onTap,
    this.onLongPress,
    this.isActive = false,
  });

  final MusicPlaylist playlist;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isActive;

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
        onLongPress: onLongPress,
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
                  boxShadow:
                      playlist.id == 'netease-fm'
                          ? [
                            BoxShadow(
                              color: palette.glowColor.withValues(alpha: 0.28),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ]
                          : null,
                ),
                child: Icon(
                  playlist.id == 'netease-fm'
                      ? Icons.radio_rounded
                      : palette.icon,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                playlist.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(
                isActive
                    ? '当前播放中'
                    : (playlist.id == 'netease-fm' ? '专属推荐' : playlist.tag),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.gradient.first,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                playlist.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF7D879A),
                  height: 1.35,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Text(
                    playlist.id == 'netease-fm'
                        ? '连续播放'
                        : '${playlist.trackCount} 首',
                    style: theme.textTheme.bodySmall,
                  ),
                  const Spacer(),
                  if (isActive)
                    Icon(
                      Icons.graphic_eq_rounded,
                      size: 16,
                      color: palette.gradient.first,
                    ),
                ],
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
    required this.onPlayTap,
    this.isActive = false,
    this.isBusy = false,
    this.metaLabel,
  });

  final MusicPlaylist playlist;
  final VoidCallback onTap;
  final VoidCallback onPlayTap;
  final bool isActive;
  final bool isBusy;
  final String? metaLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(playlist.artworkTone);
    return Material(
      color: Colors.white.withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: palette.gradient),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: palette.glowColor.withValues(alpha: 0.22),
                      blurRadius: 14,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Icon(
                  playlist.isAiGenerated
                      ? Icons.auto_awesome_rounded
                      : palette.icon,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            playlist.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (playlist.isAiGenerated || isActive)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: palette.gradient.first.withValues(
                                alpha: 0.12,
                              ),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              isActive ? '正在播放' : 'AI',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: palette.gradient.first,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      playlist.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        height: 1.25,
                        color: const Color(0xFF5B6476),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      metaLabel?.trim().isNotEmpty == true
                          ? '${playlist.trackCount} 首歌 · ${metaLabel!}'
                          : '${playlist.trackCount} 首歌 · 想听的时候 就从这里开始',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF8A93A5),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 46,
                height: 46,
                child: Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  child: Ink(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: palette.gradient),
                    ),
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      onPressed: isBusy ? null : onPlayTap,
                      icon:
                          isBusy
                              ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                              : const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                    ),
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

enum _NoticeTone { error, warning, info }

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.message,
    required this.onDismiss,
    this.primaryActionLabel,
    this.onPrimaryAction,
    this.tone = _NoticeTone.error,
  });

  final String message;
  final VoidCallback onDismiss;
  final String? primaryActionLabel;
  final VoidCallback? onPrimaryAction;
  final _NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final backgroundColor = switch (tone) {
      _NoticeTone.error => const Color(0xFFFFF6F3),
      _NoticeTone.warning => const Color(0xFFFFF8E8),
      _NoticeTone.info => const Color(0xFFF3F7FF),
    };
    final foregroundColor = switch (tone) {
      _NoticeTone.error => const Color(0xFF9A3C33),
      _NoticeTone.warning => const Color(0xFF8A5A12),
      _NoticeTone.info => const Color(0xFF305E9A),
    };
    final iconColor = switch (tone) {
      _NoticeTone.error => const Color(0xFFD55A4A),
      _NoticeTone.warning => const Color(0xFFE6A23C),
      _NoticeTone.info => const Color(0xFF5B8DEF),
    };
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: iconColor, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: foregroundColor,
                      height: 1.4,
                    ),
                  ),
                  if ((primaryActionLabel ?? '').trim().isNotEmpty &&
                      onPrimaryAction != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: TextButton(
                        onPressed: onPrimaryAction,
                        style: TextButton.styleFrom(
                          foregroundColor: foregroundColor,
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 0),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(primaryActionLabel!),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionPlaceholder extends StatelessWidget {
  const _SectionPlaceholder({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(subtitle, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _EmptyMusicState extends StatelessWidget {
  const _EmptyMusicState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.music_off_rounded,
            size: 36,
            color: Color(0xFF7D879A),
          ),
          const SizedBox(height: 12),
          Text('这里还安静着', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '先连上你的音乐 或者让 AI 先为你排一份歌单',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _MiniPlayer extends StatefulWidget {
  const _MiniPlayer({
    required this.track,
    required this.sourceLabel,
    required this.isPlaying,
    required this.onTap,
    required this.onPlayPause,
    required this.backendBaseUrl,
    this.appPassword,
    this.modeBadge,
  });

  final MusicTrack track;
  final String sourceLabel;
  final bool isPlaying;
  final String? modeBadge;
  final VoidCallback onTap;
  final VoidCallback onPlayPause;
  final String backendBaseUrl;
  final String? appPassword;

  @override
  State<_MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<_MiniPlayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    if (widget.isPlaying) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _MiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.isPlaying && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteForTone(widget.track.artworkTone);
    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(32),
            onTap: widget.onTap,
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
                  MusicArtworkHero(
                    tag: musicMiniPlayerArtworkHeroTag,
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: RotationTransition(
                        turns: _controller,
                        child: ClipOval(
                          child: MusicArtwork(
                            track: widget.track,
                            size: 56,
                            circular: true,
                            showMeta: false,
                            backendBaseUrl: widget.backendBaseUrl,
                            appPassword: widget.appPassword,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                            if ((widget.modeBadge ?? '').trim().isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: palette.gradient.first.withValues(
                                    alpha: 0.10,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: palette.gradient.first.withValues(
                                      alpha: 0.14,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  widget.modeBadge!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF5E6780),
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.sourceLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onPlayPause,
                    child: SizedBox(
                      width: 60,
                      height: 60,
                      child: Center(
                        child: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: palette.gradient),
                            shape: BoxShape.circle,
                          ),
                          child: IgnorePointer(
                            child: Icon(
                              widget.isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                            ),
                          ),
                        ),
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

class _PlaylistDetailScreen extends StatefulWidget {
  const _PlaylistDetailScreen({
    required this.playlist,
    this.initialTracks = const <MusicTrack>[],
  });

  final MusicPlaylist playlist;
  final List<MusicTrack> initialTracks;

  @override
  State<_PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<_PlaylistDetailScreen> {
  bool _isPlayingAll = false;
  bool _isSyncingLikedPlaylist = false;
  bool _isLoadingTracks = false;
  final Set<int> _pendingTrackIndexes = <int>{};
  List<MusicTrack> _tracks = const <MusicTrack>[];

  Future<void> _showTrackActions(
    BuildContext context,
    MusicStore store,
    MusicPlaylist playlist,
    MusicTrack track,
  ) async {
    if (!store.isCustomPlaylist(playlist.id)) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder:
          (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.play_arrow_rounded),
                  title: const Text('播放这首歌'),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await store.playLoadedPlaylist(
                      playlist,
                      _tracks,
                      startIndex: _tracks.indexWhere(
                        (item) => item.id == track.id,
                      ),
                    );
                    if (!context.mounted) return;
                    await _openPlayer(context, store);
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.playlist_remove_rounded,
                    color: Colors.redAccent,
                  ),
                  title: const Text(
                    '从歌单移除',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await store.removeTrackFromCustomPlaylist(
                      playlist.id,
                      track.id,
                    );
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                    final updatedPlaylist =
                        store.customPlaylistById(playlist.id)?.asPlaylist ??
                        playlist;
                    final updatedTracks = await store.loadPlaylistTracks(
                      updatedPlaylist,
                    );
                    if (!context.mounted) return;
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder:
                            (_) => ChangeNotifierProvider.value(
                              value: store,
                              child: _PlaylistDetailScreen(
                                playlist: updatedPlaylist,
                                initialTracks: updatedTracks,
                              ),
                            ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
    );
  }

  Future<void> _openPlayer(BuildContext context, MusicStore store) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      _buildMusicPlayerRoute(
        track: store.currentTrack,
        queue: store.queue.map((item) => item.track).toList(growable: false),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _tracks = widget.initialTracks;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadTracks());
    });
  }

  Future<void> _loadTracks() async {
    if (_isLoadingTracks) return;
    setState(() {
      _isLoadingTracks = true;
    });
    try {
      final store = context.read<MusicStore>();
      final tracks = await store.loadPlaylistTracks(widget.playlist);
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
      });
    } catch (_) {
      // store.error already updated
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingTracks = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MusicStore>(
      builder: (context, store, _) {
        final playlist = widget.playlist;
        final liveTracks = store.peekPlaylistTracks(playlist);
        final tracks = liveTracks.isNotEmpty ? liveTracks : _tracks;
        return Scaffold(
          appBar: AppBar(
            title: Text(playlist.title),
            actions:
                store.isCustomPlaylist(playlist.id)
                    ? [
                      IconButton(
                        onPressed:
                            () => _showCustomPlaylistDetailActions(
                              context,
                              store,
                              playlist,
                            ),
                        icon: const Icon(Icons.more_horiz_rounded),
                      ),
                    ]
                    : null,
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(playlist.subtitle),
                          const SizedBox(height: 6),
                          Text(
                            '${tracks.length} 首歌曲',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (playlist.id == store.likedPlaylist.id)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: OutlinedButton.icon(
                          onPressed:
                              _isSyncingLikedPlaylist
                                  ? null
                                  : () async {
                                    setState(() {
                                      _isSyncingLikedPlaylist = true;
                                    });
                                    try {
                                      await store
                                          .syncLikedPlaylistFromNetease();
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('已同步网易云喜欢歌单'),
                                        ),
                                      );
                                    } catch (error) {
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(content: Text('同步失败：$error')),
                                      );
                                    } finally {
                                      if (mounted) {
                                        setState(() {
                                          _isSyncingLikedPlaylist = false;
                                        });
                                      }
                                    }
                                  },
                          icon:
                              _isSyncingLikedPlaylist
                                  ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : const Icon(Icons.sync_rounded),
                          label: Text(_isSyncingLikedPlaylist ? '同步中' : '同步'),
                        ),
                      ),
                    FilledButton.icon(
                      onPressed:
                          tracks.isEmpty ||
                                  store.isPlaylistLoading(playlist.id) ||
                                  _isPlayingAll
                              ? null
                              : () async {
                                setState(() {
                                  _isPlayingAll = true;
                                });
                                try {
                                  await store.playLoadedPlaylist(
                                    playlist,
                                    tracks,
                                  );
                                  if (!context.mounted) return;
                                  unawaited(_openPlayer(context, store));
                                } finally {
                                  if (mounted) {
                                    setState(() {
                                      _isPlayingAll = false;
                                    });
                                  }
                                }
                              },
                      icon:
                          _isPlayingAll
                              ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : const Icon(Icons.play_arrow_rounded),
                      label: Text(_isPlayingAll ? '处理中...' : '播放全部'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child:
                    tracks.isEmpty && _isLoadingTracks
                        ? const Center(child: CircularProgressIndicator())
                        : tracks.isEmpty
                        ? Center(
                          child: Text(
                            store.isCustomPlaylist(playlist.id)
                                ? '这个歌单还没有歌曲\n去播放器长按当前歌曲，就能收藏到这里'
                                : '这个歌单暂时没有可播放的歌曲',
                            textAlign: TextAlign.center,
                          ),
                        )
                        : ListView.separated(
                          itemCount: tracks.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final track = tracks[index].copyWith(
                              isFavorite: store.isTrackLiked(tracks[index].id),
                            );
                            final isCurrentTrack =
                                store.currentTrack.id == track.id &&
                                store.currentPlaylistId == playlist.id;
                            return Container(
                              decoration:
                                  isCurrentTrack
                                      ? BoxDecoration(
                                        border: Border(
                                          left: BorderSide(
                                            color:
                                                Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                            width: 3,
                                          ),
                                        ),
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: 0.05),
                                      )
                                      : null,
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 2,
                                ),
                                minLeadingWidth: 0,
                                horizontalTitleGap: 12,
                                visualDensity: const VisualDensity(
                                  horizontal: 0,
                                  vertical: -2,
                                ),
                                enabled: !_pendingTrackIndexes.contains(index),
                                onLongPress:
                                    store.isCustomPlaylist(playlist.id)
                                        ? () => _showTrackActions(
                                          context,
                                          store,
                                          playlist,
                                          track,
                                        )
                                        : null,
                                onTap:
                                    _pendingTrackIndexes.contains(index)
                                        ? null
                                        : () async {
                                          setState(() {
                                            _pendingTrackIndexes.add(index);
                                          });
                                          try {
                                            await store.playLoadedPlaylist(
                                              playlist,
                                              tracks,
                                              startIndex: index,
                                            );
                                            if (!context.mounted) return;
                                            unawaited(
                                              _openPlayer(context, store),
                                            );
                                          } finally {
                                            if (mounted) {
                                              setState(() {
                                                _pendingTrackIndexes.remove(
                                                  index,
                                                );
                                              });
                                            }
                                          }
                                        },
                                leading: MusicArtwork(
                                  track: track,
                                  size: 46,
                                  showMeta: false,
                                  overlayStrength: 0.08,
                                  backendBaseUrl: store.currentConfig.baseUrl,
                                  appPassword: store.currentConfig.appPassword,
                                ),
                                title: Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color:
                                        isCurrentTrack
                                            ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                            : null,
                                  ),
                                ),
                                subtitle: Text(
                                  '${track.artist} · ${track.album}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF7D879A),
                                  ),
                                ),
                                trailing:
                                    _pendingTrackIndexes.contains(index)
                                        ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                        : isCurrentTrack
                                        ? Icon(
                                          Icons.graphic_eq_rounded,
                                          size: 18,
                                          color:
                                              Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                        )
                                        : Text(
                                          track.durationLabel,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall?.copyWith(
                                            color: const Color(0xFF8A93A5),
                                            fontFeatures: const [],
                                          ),
                                        ),
                              ),
                            );
                          },
                        ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<void> _showEditPlaylistSheetFromDetail(
  BuildContext context,
  MusicStore store,
  MusicPlaylist playlist,
) async {
  final custom = store.customPlaylistById(playlist.id);
  if (custom == null) return;
  final nameController = TextEditingController(text: custom.title);
  final subtitleController = TextEditingController(text: custom.subtitle);
  final descriptionController = TextEditingController(text: custom.description);
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
              controller: nameController,
              decoration: const InputDecoration(labelText: '歌单名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: subtitleController,
              decoration: const InputDecoration(labelText: '副标题（选填）'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descriptionController,
              maxLines: 2,
              decoration: const InputDecoration(labelText: '简介（选填）'),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  final title = nameController.text.trim();
                  if (title.isEmpty) return;
                  await store.renameCustomPlaylist(
                    playlist.id,
                    title: title,
                    subtitle: subtitleController.text.trim(),
                    description: descriptionController.text.trim(),
                  );
                  if (!sheetContext.mounted) return;
                  Navigator.of(sheetContext).pop();
                },
                child: const Text('保存修改'),
              ),
            ),
          ],
        ),
      );
    },
  );
}

Future<void> _showCustomPlaylistDetailActions(
  BuildContext context,
  MusicStore store,
  MusicPlaylist playlist,
) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder:
        (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('编辑歌单'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showEditPlaylistSheetFromDetail(context, store, playlist);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  '删除歌单',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder:
                        (dialogContext) => AlertDialog(
                          title: const Text('删除歌单？'),
                          content: const Text('删除后歌单里的歌曲不会被删除，只会移除这个歌单。'),
                          actions: [
                            TextButton(
                              onPressed:
                                  () => Navigator.of(dialogContext).pop(false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed:
                                  () => Navigator.of(dialogContext).pop(true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                  );
                  if (confirmed == true) {
                    await store.deleteCustomPlaylist(playlist.id);
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
              ),
            ],
          ),
        ),
  );
}

class _MusicSearchSheet extends StatefulWidget {
  const _MusicSearchSheet();

  @override
  State<_MusicSearchSheet> createState() => _MusicSearchSheetState();
}

class _MusicSearchSheetState extends State<_MusicSearchSheet> {
  late final TextEditingController _controller;
  String? _pendingTrackId;
  final Set<String> _pendingLikeTrackIds = <String>{};

  Future<void> _playSearchTrack(BuildContext context, MusicTrack track) async {
    if (_pendingTrackId == track.id) return;
    setState(() {
      _pendingTrackId = track.id;
    });
    final store = context.read<MusicStore>();
    try {
      unawaited(store.selectTrack(track));
      if (!context.mounted) return;
      Navigator.of(context).pop();
      await Navigator.of(context).push(
        _buildMusicPlayerRoute(
          track: track,
          queue: store.queue.map((item) => item.track).toList(growable: false),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _pendingTrackId = null;
        });
      }
    }
  }

  Future<void> _toggleSearchTrackLiked(MusicTrack track) async {
    if (_pendingLikeTrackIds.contains(track.id)) return;
    setState(() {
      _pendingLikeTrackIds.add(track.id);
    });
    try {
      await context.read<MusicStore>().toggleTrackLiked(track);
    } finally {
      if (mounted) {
        setState(() {
          _pendingLikeTrackIds.remove(track.id);
        });
      }
    }
  }

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
            Text('搜索音乐', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('先帮你把想听的歌找回来', style: Theme.of(context).textTheme.bodySmall),
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
                      suffixIcon:
                          _controller.text.isEmpty
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
                  onPressed:
                      store.isSearching
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
            if (store.recentSearches.isNotEmpty &&
                _controller.text.trim().isEmpty) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '最近搜索',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: store.clearRecentSearches,
                    child: const Text('清空'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: store.recentSearches
                    .map(
                      (keyword) => ActionChip(
                        label: Text(keyword),
                        onPressed: () {
                          _controller.text = keyword;
                          setState(() {});
                          store.searchTracks(keyword);
                        },
                      ),
                    )
                    .toList(growable: false),
              ),
              const SizedBox(height: 16),
            ],
            Expanded(
              child:
                  store.searchResults.isEmpty
                      ? Center(
                        child: Text(
                          _controller.text.trim().isEmpty
                              ? '写下一首歌 一个名字 或者一种心情'
                              : ((store.searchError ?? '').trim().isNotEmpty
                                  ? '刚刚没替你找到 换个词再试试'
                                  : '还没找到想听的 试试更短一点的词'),
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      )
                      : ListView.separated(
                        itemCount: store.searchResults.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final track = store.searchResults[index];
                          return _SearchResultTile(
                            track: track,
                            isBusy: _pendingTrackId == track.id,
                            isLiking: _pendingLikeTrackIds.contains(track.id),
                            onOpen: () async {
                              await _showSearchTrackPreview(
                                context,
                                track,
                                _playSearchTrack,
                              );
                            },
                            onPlay: () async {
                              await _playSearchTrack(context, track);
                            },
                            onToggleLike: () async {
                              await _toggleSearchTrackLiked(track);
                            },
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showSearchTrackPreview(
  BuildContext context,
  MusicTrack track,
  Future<void> Function(BuildContext context, MusicTrack track) playTrack,
) async {
  final theme = Theme.of(context);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final palette = paletteForTone(track.artworkTone);
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                MusicArtwork(
                  track: track,
                  size: 72,
                  showMeta: false,
                  backendBaseUrl:
                      context.read<MusicStore>().currentConfig.baseUrl,
                  appPassword:
                      context.read<MusicStore>().currentConfig.appPassword,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(track.title, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 6),
                      Text(
                        '${track.artist} · ${track.album}',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        track.category,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.gradient.first,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              track.description,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  Navigator.of(sheetContext).pop();
                  await playTrack(context, track);
                },
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('立即播放'),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.track,
    required this.onOpen,
    required this.onPlay,
    required this.onToggleLike,
    this.isBusy = false,
    this.isLiking = false,
  });

  final MusicTrack track;
  final VoidCallback onOpen;
  final VoidCallback onPlay;
  final VoidCallback onToggleLike;
  final bool isBusy;
  final bool isLiking;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MusicStore>();
    final effectiveTrack = track.copyWith(
      isFavorite: store.isTrackLiked(track.id),
    );
    final palette = paletteForTone(effectiveTrack.artworkTone);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE7EAF4)),
          ),
          child: Row(
            children: [
              Stack(
                children: [
                  MusicArtwork(
                    track: effectiveTrack,
                    size: 58,
                    showMeta: false,
                  ),
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Material(
                      color: Colors.white,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: isLiking ? null : onToggleLike,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child:
                              isLiking
                                  ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : Icon(
                                    effectiveTrack.isFavorite
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    size: 16,
                                    color:
                                        effectiveTrack.isFavorite
                                            ? const Color(0xFFE91E63)
                                            : const Color(0xFF7D879A),
                                  ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      effectiveTrack.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${effectiveTrack.artist} · ${effectiveTrack.album} · ${effectiveTrack.category}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      effectiveTrack.durationLabel,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: palette.gradient.first,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                onPressed: isBusy || isLiking ? null : onPlay,
                icon:
                    isBusy
                        ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              palette.gradient.first,
                            ),
                          ),
                        )
                        : Icon(
                          Icons.play_circle_fill_rounded,
                          color: palette.gradient.first,
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
