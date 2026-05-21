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
      final today = await _client.getDiaryEntry(
        agentId: 'alice',
        date: _selectedDate,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries.entries;
        _entry = today.entry;
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
          color: Color(0xFFF7F5FB),
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
                  return Column(
                    children: [
                      SizedBox(
                        height: 136,
                        child: _buildHistorySidebar(theme, isWide: false),
                      ),
                      const Divider(height: 1),
                      Expanded(child: _buildContent(theme)),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFEDE7FF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.menu_book_rounded,
              color: Color(0xFF7C4DFF),
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '晚秋日记',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  _entries.isEmpty ? '暂无历史日记' : '共 ${_entries.length} 篇，新的在前',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF667085),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close_rounded),
            tooltip: '关闭',
          ),
        ],
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
                size: 36,
                color: theme.disabledColor,
              ),
              const SizedBox(height: 10),
              Text(
                '暂无历史日记',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF7C8494),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      scrollDirection: isWide ? Axis.vertical : Axis.horizontal,
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
          width: isWide ? double.infinity : 180,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: date.isEmpty ? null : () => _openEntry(date),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFFEDE7FF) : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color:
                        selected
                            ? const Color(0xFF7C4DFF).withValues(alpha: 0.35)
                            : const Color(0xFFE8E4F2),
                  ),
                  boxShadow:
                      selected
                          ? [
                            BoxShadow(
                              color: const Color(
                                0xFF7C4DFF,
                              ).withValues(alpha: 0.10),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ]
                          : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.02),
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
                                      ? const Color(0xFF7C4DFF)
                                      : const Color(0xFF2D3443),
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
          color:
              selected
                  ? const Color(0xFF7C4DFF).withValues(alpha: 0.7)
                  : const Color(0xFFA0ABC0),
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
                  selected
                      ? const Color(0xFF7C4DFF).withValues(alpha: 0.8)
                      : const Color(0xFFA0ABC0),
            ),
          ),
        ),
      ],
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
                        color: const Color(0xFF2D3443),
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
                            color: Color(0xFF667085),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '生成于 ${_formatDiaryTime(generatedAt)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: const Color(0xFF667085),
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
                  backgroundColor: const Color(0xFF7C4DFF),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
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
                              size: 40,
                              color: Color(0xFFA0ABC0),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              error,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium,
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
                              size: 40,
                              color: Color(0xFFA0ABC0),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              status == 'generating' ? '日记生成中…' : '今天还没有日记',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: const Color(0xFF7C8494),
                              ),
                            ),
                            if (status != 'generating') ...[
                              const SizedBox(height: 8),
                              Text(
                                '点击右上角「立即生成」来写一篇',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFFA0ABC0),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                    : DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFFE8E4F2)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Markdown(
                        data: content,
                        padding: const EdgeInsets.all(20),
                        selectable: true,
                        styleSheet: MarkdownStyleSheet.fromTheme(
                          theme,
                        ).copyWith(
                          h1: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF2D3443),
                          ),
                          h2: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF2D3443),
                          ),
                          p: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
                        ),
                      ),
                    ),
          ),
        ],
      ),
    );
  }
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
