import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_http_client.dart';

Future<void> showDiarySheet(
  BuildContext context, {
  required OpenClawConfig config,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => DiarySheet(config: config),
  );
}

class DiarySheet extends StatefulWidget {
  const DiarySheet({super.key, required this.config});

  final OpenClawConfig config;

  @override
  State<DiarySheet> createState() => _DiarySheetState();
}

class _DiarySheetState extends State<DiarySheet> {
  late final OpenClawHttpClient _client;
  List<Map<String, dynamic>> _entries = const [];
  Map<String, dynamic>? _entry;
  String _selectedDate = _todayString();
  bool _loading = true;
  bool _generating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = OpenClawHttpClient(widget.config);
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _client.listDiaryEntries(agentId: 'alice');
      final latestDate =
          entries.entries.isNotEmpty
              ? '${entries.entries.first['date'] ?? ''}'
              : _todayString();
      final selectedDate = latestDate.isNotEmpty ? latestDate : _todayString();
      final selected = await _client.getDiaryEntry(
        agentId: 'alice',
        date: selectedDate,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries.entries;
        _selectedDate = selectedDate;
        _entry = selected.entry;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _openEntry(String date) async {
    setState(() {
      _selectedDate = date;
      _loading = true;
      _error = null;
    });
    try {
      final result = await _client.getDiaryEntry(agentId: 'alice', date: date);
      if (!mounted) return;
      setState(() {
        _entry = result.entry;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _generateNow() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final result = await _client.generateDiaryEntry(
        agentId: 'alice',
        date: _selectedDate,
        force: true,
      );
      final entries = await _client.listDiaryEntries(agentId: 'alice');
      if (!mounted) return;
      setState(() {
        _entry = result.entry;
        _entries = entries.entries;
        _generating = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _generating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.sizeOf(context).height * 0.88;
    return SafeArea(
      child: Container(
        height: height,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFFBF6FF), Color(0xFFF6F0FC), Color(0xFFF3EDF8)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: Column(
          children: [
            _buildHeader(theme),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 720;
                  if (wide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 260,
                          child: _buildHistorySidebar(theme, isWide: true),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: _buildContent(theme)),
                      ],
                    );
                  }
                  return _buildDiaryFeed(theme);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFF7F0FF), Color(0xFFF5F0FA)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFD4B8FF), Color(0xFFC4A0FF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFD4B8FF).withValues(alpha: 0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.menu_book_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '🌸 晚秋日记',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF5B3A8C),
                    ),
                  ),
                  Text(
                    _entries.isEmpty
                        ? '还没有写过日记呢…'
                        : '✨ 共 ${_entries.length} 篇，新的在前',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF8B6BAE),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded, color: Color(0xFF8B6BAE)),
              tooltip: '关闭',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistorySidebar(ThemeData theme, {required bool isWide}) {
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_stories_outlined,
                size: 40,
                color: const Color(0xFFC4B8D4),
              ),
              const SizedBox(height: 12),
              Text(
                '📖 暂无历史日记',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF8B6BAE),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      scrollDirection: Axis.vertical,
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10, height: 8),
      itemBuilder: (context, index) {
        final item = _entries[index];
        final date = '${item['date'] ?? ''}';
        final title = '${item['title'] ?? ''}'.trim();
        final selected = date == _selectedDate;
        final generatedAt = _parseDiaryTime(item['generatedAt']);
        final status = '${item['status'] ?? ''}';
        final displayTitle = title.isNotEmpty ? title : date;

        return SizedBox(
          width: double.infinity,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: date.isEmpty ? null : () => _openEntry(date),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                decoration: BoxDecoration(
                  color:
                      selected
                          ? const Color(0xFFF3EAFF)
                          : const Color(0xFFFFFDFF),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color:
                        selected
                            ? const Color(0xFFC4A0FF).withValues(alpha: 0.45)
                            : const Color(0xFFE8E0F5),
                  ),
                  boxShadow:
                      selected
                          ? [
                            BoxShadow(
                              color: const Color(
                                0xFFC4A0FF,
                              ).withValues(alpha: 0.15),
                              blurRadius: 12,
                              offset: const Offset(0, 3),
                            ),
                          ]
                          : [
                            BoxShadow(
                              color: const Color(
                                0xFFB8A0D0,
                              ).withValues(alpha: 0.04),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color:
                                  selected
                                      ? const Color(0xFF8B5CF6)
                                      : const Color(0xFF4A3A60),
                            ),
                          ),
                        ),
                        if (status == 'generating')
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _diaryMetaChip(
                      theme: theme,
                      icon: Icons.calendar_today_outlined,
                      label: date,
                      selected: selected,
                    ),
                    if (generatedAt != null) ...[
                      const SizedBox(height: 4),
                      _diaryMetaChip(
                        theme: theme,
                        icon: Icons.schedule_outlined,
                        label: _formatDiaryTime(generatedAt),
                        selected: selected,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _diaryMetaChip({
    required ThemeData theme,
    required IconData icon,
    required String label,
    required bool selected,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 12,
          color: selected ? const Color(0xFFA78BFA) : const Color(0xFFB8A0D0),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color:
                  selected ? const Color(0xFFA78BFA) : const Color(0xFFB8A0D0),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDiaryFeed(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _entries.isEmpty) {
      return _buildEmptyState(
        theme,
        icon: Icons.error_outline,
        message: _error!,
      );
    }
    if (_entries.isEmpty) {
      return _buildEmptyState(
        theme,
        icon: Icons.auto_stories_outlined,
        message: '📖 还没有日记',
        detail: '点右上角「立即生成」写下今天这一篇',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (context, index) {
        final item = _entries[index];
        final date = '${item['date'] ?? ''}';
        final content = '${item['content'] ?? ''}'.trim();
        final status = '${item['status'] ?? ''}';
        final error = '${item['error'] ?? ''}'.trim();
        final generatedAt = _parseDiaryTime(item['generatedAt']);
        return _buildDiaryEntryCard(
          theme: theme,
          date: date,
          content: content,
          status: status,
          error: error,
          generatedAt: generatedAt,
          latest: index == 0,
          compact: index > 0,
        );
      },
    );
  }

  Widget _buildEmptyState(
    ThemeData theme, {
    required IconData icon,
    required String message,
    String? detail,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: const Color(0xFFD4B8D8)),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF8B6BAE),
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFFA78BFA),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDiaryEntryCard({
    required ThemeData theme,
    required String date,
    required String content,
    required String status,
    required String error,
    required DateTime? generatedAt,
    required bool latest,
    bool compact = false,
  }) {
    final hasContent = content.isNotEmpty;
    final displayedContent =
        compact && content.length > 900
            ? '${content.substring(0, 900).trimRight()}…'
            : content;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFCFD),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color:
              latest
                  ? const Color(0xFFE9B7D0).withValues(alpha: 0.85)
                  : const Color(0xFFF0DDEA),
          width: latest ? 1.4 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(
              0xFFC77EA8,
            ).withValues(alpha: latest ? 0.16 : 0.08),
            blurRadius: latest ? 18 : 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _DiaryPaperPainter())),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFEEF6),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: const Color(0xFFF2C7DC)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.favorite_rounded,
                              size: 13,
                              color: Color(0xFFE58AB5),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              latest ? '最新一篇' : date,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: const Color(0xFFAA5D86),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Text(
                        date,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFA98FA1),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  if (generatedAt != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.lock_clock_rounded,
                          size: 13,
                          color: Color(0xFFC98FAF),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '写于 ${_formatDiaryTime(generatedAt)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFFC98FAF),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (error.isNotEmpty && !hasContent)
                    Text(
                      error,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF9B5D7C),
                      ),
                    )
                  else if (!hasContent)
                    Text(
                      status == 'generating' ? '✍️ 日记生成中…' : '📖 这一天还没有写下内容',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF9B5D7C),
                      ),
                    )
                  else
                    MarkdownBody(
                      data: displayedContent,
                      selectable: true,
                      styleSheet: _diaryMarkdownStyle(theme),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  MarkdownStyleSheet _diaryMarkdownStyle(ThemeData theme) {
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      h1: theme.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w800,
        color: const Color(0xFF6E3D59),
      ),
      h2: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: const Color(0xFF8B4C73),
      ),
      p: theme.textTheme.bodyMedium?.copyWith(
        height: 1.78,
        color: const Color(0xFF4F3F4A),
      ),
      strong: const TextStyle(
        color: Color(0xFF7C3E63),
        fontWeight: FontWeight.w800,
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    final entry = _entry;
    final status = '${entry?['status'] ?? ''}';
    final content = '${entry?['content'] ?? ''}'.trim();
    final error = _error ?? '${entry?['error'] ?? ''}'.trim();
    final generatedAt = _parseDiaryTime(entry?['generatedAt']);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _selectedDate,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF5B3A8C),
                      ),
                    ),
                    if (generatedAt != null) ...[
                      const SizedBox(height: 3),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.schedule_outlined,
                            size: 13,
                            color: Color(0xFFA78BFA),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '生成于 ${_formatDiaryTime(generatedAt)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: const Color(0xFFA78BFA),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _generating ? null : _generateNow,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFA78BFA),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                ),
                icon:
                    _generating
                        ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                        : const Icon(Icons.auto_awesome_rounded, size: 18),
                label: Text(_generating ? '生成中…' : '立即生成'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child:
                _loading
                    ? const Center(child: CircularProgressIndicator())
                    : error.isNotEmpty && content.isEmpty
                    ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              size: 44,
                              color: Color(0xFFD4B8D8),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              error,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: const Color(0xFF8B6BAE),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    : content.isEmpty
                    ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.auto_stories_outlined,
                              size: 44,
                              color: Color(0xFFC4B8D4),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              status == 'generating'
                                  ? '✍️ 日记生成中…'
                                  : '📖 今天还没有日记',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: const Color(0xFF8B6BAE),
                              ),
                            ),
                            if (status != 'generating') ...[
                              const SizedBox(height: 8),
                              Text(
                                '点击右上角「立即生成」来写一篇吧 ✨',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFFA78BFA),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                    : SingleChildScrollView(
                      child: _buildDiaryEntryCard(
                        theme: theme,
                        date: _selectedDate,
                        content: content,
                        status: status,
                        error: error,
                        generatedAt: generatedAt,
                        latest: true,
                      ),
                    ),
          ),
        ],
      ),
    );
  }
}

class _DiaryPaperPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint =
        Paint()
          ..color = const Color(0xFFF6DCE9).withValues(alpha: 0.55)
          ..strokeWidth = 0.8;
    for (double y = 78; y < size.height; y += 30) {
      canvas.drawLine(Offset(18, y), Offset(size.width - 18, y), linePaint);
    }

    final marginPaint =
        Paint()
          ..color = const Color(0xFFEFAFCB).withValues(alpha: 0.32)
          ..strokeWidth = 1;
    canvas.drawLine(const Offset(42, 0), Offset(42, size.height), marginPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

String _todayString() {
  final now = DateTime.now();
  final month = now.month.toString().padLeft(2, '0');
  final day = now.day.toString().padLeft(2, '0');
  return '${now.year}-$month-$day';
}

DateTime? _parseDiaryTime(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      (raw.toDouble() * 1000).toInt(),
    ).toLocal();
  }
  final parsed = DateTime.tryParse(raw.toString());
  if (parsed != null) return parsed.toLocal();
  final asNum = double.tryParse(raw.toString());
  if (asNum != null) {
    return DateTime.fromMillisecondsSinceEpoch(
      (asNum * 1000).toInt(),
    ).toLocal();
  }
  return null;
}

String _formatDiaryTime(DateTime time) {
  final year = time.year.toString().padLeft(4, '0');
  final month = time.month.toString().padLeft(2, '0');
  final day = time.day.toString().padLeft(2, '0');
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute';
}
