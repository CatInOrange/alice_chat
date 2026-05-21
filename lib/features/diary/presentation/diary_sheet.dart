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
    final height = MediaQuery.sizeOf(context).height * 0.86;
    return SafeArea(
      child: Container(
        height: height,
        decoration: const BoxDecoration(
          color: Color(0xFFF7F5FB),
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
              child: Row(
                children: [
                  const Icon(Icons.menu_book_rounded, color: Color(0xFF7C4DFF)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '晚秋日记',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 720;
                  if (wide) {
                    return Row(
                      children: [
                        SizedBox(width: 230, child: _buildHistory(theme)),
                        const VerticalDivider(width: 1),
                        Expanded(child: _buildContent(theme)),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      SizedBox(height: 104, child: _buildHistory(theme)),
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

  Widget _buildHistory(ThemeData theme) {
    if (_entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '暂无历史日记',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: const Color(0xFF7C8494),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      scrollDirection:
          MediaQuery.sizeOf(context).width >= 720
              ? Axis.vertical
              : Axis.horizontal,
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8, height: 8),
      itemBuilder: (context, index) {
        final item = _entries[index];
        final date = '${item['date'] ?? ''}';
        final title = '${item['title'] ?? date}';
        final selected = date == _selectedDate;
        return SizedBox(
          width:
              MediaQuery.sizeOf(context).width >= 720 ? double.infinity : 164,
          child: ListTile(
            dense: true,
            selected: selected,
            selectedTileColor: const Color(0xFFEDE7FF),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            title: Text(
              title.isNotEmpty ? title : date,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(date, maxLines: 1),
            onTap: date.isEmpty ? null : () => _openEntry(date),
          ),
        );
      },
    );
  }

  Widget _buildContent(ThemeData theme) {
    final entry = _entry;
    final status = '${entry?['status'] ?? ''}';
    final content = '${entry?['content'] ?? ''}'.trim();
    final error = _error ?? '${entry?['error'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _selectedDate,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF2D3443),
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: _generating ? null : _generateNow,
                icon:
                    _generating
                        ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.auto_awesome_rounded, size: 18),
                label: Text(_generating ? '生成中' : '立即生成'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (error.isNotEmpty && content.isEmpty)
            Expanded(child: Center(child: Text(error)))
          else if (content.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  status == 'generating' ? '日记生成中' : '今天还没有日记',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF7C8494),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE8E4F2)),
                ),
                child: Markdown(
                  data: content,
                  padding: const EdgeInsets.all(18),
                  selectable: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                    h1: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF2D3443),
                    ),
                    p: theme.textTheme.bodyMedium?.copyWith(height: 1.65),
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
