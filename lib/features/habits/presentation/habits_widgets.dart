import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/theme.dart';
import '../application/habits_store.dart';
import '../domain/habits_models.dart';

// ── Hero Stats Card ─────────────────────────────────────────

class HabitsHeroCard extends StatelessWidget {
  const HabitsHeroCard({super.key, required this.habits});

  final List<Habit> habits;

  @override
  Widget build(BuildContext context) {
    if (habits.isEmpty) {
      return _EmptyHeroCard();
    }

    int weekDone = 0, weekTotal = 0;
    int monthDone = 0, monthTotal = 0;
    int todayDone = 0, todayTotal = 0;
    int bestStreak = 0;
    for (final h in habits) {
      weekDone += h.weeklyStats?.done ?? 0;
      weekTotal += h.weeklyStats?.total ?? 0;
      monthDone += h.monthlyStats?.done ?? 0;
      monthTotal += h.monthlyStats?.total ?? 0;
      if (h.dueToday) {
        todayTotal += 1;
        if (h.todayInstance?.isCompleted ?? false) {
          todayDone += 1;
        }
      }
      if (h.streak > bestStreak) bestStreak = h.streak;
    }
    final todayRate = todayTotal == 0 ? 0.0 : todayDone / todayTotal;

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF7BAAF7), Color(0xFF5B8DEF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF7BAAF7).withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '今日习惯',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$todayDone/$todayTotal',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${(todayRate * 100).round()}%',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _StatCircle(label: '本周', done: weekDone, total: weekTotal),
              const SizedBox(width: 24),
              _StatCircle(label: '本月', done: monthDone, total: monthTotal),
              const SizedBox(width: 24),
              _StatCircle(label: '最长', value: '$bestStreak天'),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCircle extends StatelessWidget {
  const _StatCircle({required this.label, this.done, this.total, this.value});

  final String label;
  final int? done;
  final int? total;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final text = value ?? '${done ?? 0}/${total ?? 0}';
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.4),
              width: 2,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _EmptyHeroCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.aliceColors;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.border),
      ),
      child: Center(
        child: Column(
          children: [
            const Text('🏃', style: TextStyle(fontSize: 32)),
            const SizedBox(height: 8),
            Text(
              '还没有习惯，创建一个吧',
              style: TextStyle(color: colors.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Habit Card ──────────────────────────────────────────────

class HabitCard extends StatefulWidget {
  const HabitCard({
    super.key,
    required this.habit,
    required this.onToggle,
    this.onEdit,
  });

  final Habit habit;
  final VoidCallback onToggle;
  final VoidCallback? onEdit;

  @override
  State<HabitCard> createState() => _HabitCardState();
}

class _HabitCardState extends State<HabitCard> {
  bool _expanded = false;

  Habit get habit => widget.habit;

  Color get _accentColor {
    try {
      return Color(habit.colorValue);
    } catch (_) {
      return const Color(0xFF7BAAF7);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.aliceColors;
    final isDone = habit.todayInstance?.isCompleted ?? false;
    final dueToday = habit.dueToday;
    final summaryText =
        habit.streak >= 3
            ? '连续 ${habit.streak} 天'
            : '近30天 ${((habit.recent30Stats.rate) * 100).round()}%';
    final summaryColor =
        habit.streak >= 3 ? const Color(0xFFFF9A3C) : _accentColor;

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        onLongPress: widget.onEdit == null ? null : _showActionMenu,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: colors.border),
            boxShadow: [
              BoxShadow(
                color: colors.shadowAt(0.42),
                blurRadius: 12,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _iconForHabit(habit.title),
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            habit.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Wrap(
                            spacing: 8,
                            runSpacing: 2,
                            children: [
                              if (habit.reminderTime.isNotEmpty)
                                _CompactMetaText(
                                  text: habit.reminderTime,
                                  color: colors.textMuted,
                                ),
                              _CompactMetaText(
                                text: summaryText,
                                color: summaryColor,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _TodayToggle(
                      isDone: isDone,
                      enabled: dueToday,
                      onToggle: widget.onToggle,
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 20,
                        color: colors.icon,
                      ),
                    ),
                  ],
                ),
                AnimatedCrossFade(
                  firstChild: const SizedBox(width: double.infinity),
                  secondChild: _HabitDetailPanel(
                    habit: habit,
                    color: _accentColor,
                    onEdit: widget.onEdit,
                  ),
                  crossFadeState:
                      _expanded
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 180),
                  firstCurve: Curves.easeOutCubic,
                  secondCurve: Curves.easeOutCubic,
                  sizeCurve: Curves.easeOutCubic,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _iconForHabit(String title) {
    final lower = title.toLowerCase();
    if (lower.contains('跑') || lower.contains('步')) return '🏃';
    if (lower.contains('读') || lower.contains('书')) return '📖';
    if (lower.contains('水') || lower.contains('喝')) return '💧';
    if (lower.contains('冥') || lower.contains('想')) return '🧘';
    if (lower.contains('睡') || lower.contains('眠')) return '😴';
    if (lower.contains('运动') || lower.contains('健身')) return '💪';
    if (lower.contains('写') || lower.contains('记')) return '✍️';
    return '⭐';
  }

  Future<void> _showActionMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (context) => SafeArea(
            child: Container(
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.aliceColors.surfaceElevated,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.edit_rounded),
                    title: const Text('编辑习惯'),
                    onTap: () => Navigator.pop(context, 'edit'),
                  ),
                ],
              ),
            ),
          ),
    );
    if (action == 'edit') {
      widget.onEdit?.call();
    }
  }
}

class _CompactMetaText extends StatelessWidget {
  const _CompactMetaText({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w700,
        height: 1.1,
      ),
    );
  }
}

class _HabitDetailPanel extends StatelessWidget {
  const _HabitDetailPanel({
    required this.habit,
    required this.color,
    required this.onEdit,
  });

  final Habit habit;
  final Color color;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final weekly = habit.weeklyStats;
    final monthly = habit.monthlyStats;
    final colors = context.aliceColors;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (habit.description.isNotEmpty) ...[
            Text(
              habit.description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textMuted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(
                child: _HabitMetricTile(
                  label: '本周',
                  value: _formatStats(weekly),
                  color: color,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _HabitMetricTile(
                  label: '本月',
                  value: _formatStats(monthly),
                  color: color,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _HabitMetricTile(
                  label: '连续',
                  value: '${habit.streak}天',
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _ProgressBar(rate: weekly?.rate ?? 0.0, color: color),
              ),
              const SizedBox(width: 10),
              Text(
                '周完成率 ${(((weekly?.rate ?? 0.0) * 100).round())}%',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.textMuted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (habit.history.isNotEmpty) ...[
            const SizedBox(height: 10),
            _HabitHistoryGrid(history: habit.history, color: color),
          ],
          if (onEdit != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_rounded, size: 16),
                label: const Text('编辑'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: colors.textSubtle,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatStats(HabitStats? stats) {
    if (stats == null || stats.total == 0) return '0/0';
    return '${stats.done}/${stats.total}';
  }
}

class _HabitMetricTile extends StatelessWidget {
  const _HabitMetricTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.aliceColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: colors.text,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _TodayToggle extends StatelessWidget {
  const _TodayToggle({
    required this.isDone,
    required this.enabled,
    required this.onToggle,
  });

  final bool isDone;
  final bool enabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.aliceColors;
    final inactiveForeground = enabled ? colors.text : colors.textMuted;
    return GestureDetector(
      onTap: enabled ? onToggle : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: enabled ? 72 : 88,
        height: 36,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color:
              !enabled
                  ? colors.surfaceSoft
                  : isDone
                  ? const Color(0xFF66C5A3)
                  : colors.surfaceSoft,
          border: Border.all(
            color: enabled && isDone ? Colors.transparent : colors.border,
          ),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              !enabled ? Icons.remove_rounded : Icons.check,
              size: 16,
              color: enabled && isDone ? Colors.white : inactiveForeground,
            ),
            const SizedBox(width: 4),
            Text(
              !enabled
                  ? '今日不需要'
                  : isDone
                  ? '已打卡'
                  : '打卡',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: enabled && isDone ? Colors.white : inactiveForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HabitHistoryGrid extends StatelessWidget {
  const _HabitHistoryGrid({required this.history, required this.color});

  final List<HabitHistoryDay> history;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.aliceColors;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: history
          .map((day) {
            final fill = switch (day.status) {
              'completed' => color,
              'expired' => const Color(0xFFF28CA6),
              'pending' => const Color(0xFFFFC857),
              _ => colors.surfaceSoft,
            };
            return Tooltip(
              message: '${day.date} ${_statusLabel(day.status)}',
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          })
          .toList(growable: false),
    );
  }

  String _statusLabel(String status) {
    return switch (status) {
      'completed' => '已完成',
      'expired' => '未完成',
      'pending' => '待完成',
      _ => '无计划',
    };
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.rate, required this.color});

  final double rate;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: rate,
          minHeight: 6,
          backgroundColor: color.withValues(alpha: 0.1),
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ),
    );
  }
}

// ── Create / Edit Habit Dialog ──────────────────────────────

class HabitEditorSheet extends StatefulWidget {
  const HabitEditorSheet({super.key, this.habit});

  final Habit? habit;

  @override
  State<HabitEditorSheet> createState() => _HabitEditorSheetState();
}

class _HabitEditorSheetState extends State<HabitEditorSheet> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _descriptionCtrl;
  late final TextEditingController _reminderCtrl;
  late String _frequency;
  late List<int> _weekdays;
  late String _reminderTime;
  bool _saving = false;
  String? _backfillBusyDate;
  Habit? _currentHabit;

  bool get _isEditing => widget.habit != null;

  static const _allWeekdays = [1, 2, 3, 4, 5, 6, 7];
  static const _weekdayNames = ['', '一', '二', '三', '四', '五', '六', '日'];

  @override
  void initState() {
    super.initState();
    final h = widget.habit;
    _titleCtrl = TextEditingController(text: h?.title ?? '');
    _descriptionCtrl = TextEditingController(text: h?.description ?? '');
    _frequency = h?.frequency ?? 'daily';
    _weekdays = List<int>.from(h?.weekdays ?? [1, 2, 3, 4, 5]);
    _reminderTime = h?.reminderTime ?? '';
    _reminderCtrl = TextEditingController(text: _reminderTime);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descriptionCtrl.dispose();
    _reminderCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.aliceColors;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.borderStrong,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _isEditing ? '编辑习惯' : '新建习惯',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _titleCtrl,
                autofocus: !_isEditing,
                decoration: const InputDecoration(
                  hintText: '习惯名称',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionCtrl,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: '备注（可选）',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('频率', style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  _FreqChip(
                    label: '每天',
                    selected: _frequency == 'daily',
                    onTap: () => setState(() => _frequency = 'daily'),
                  ),
                  const SizedBox(width: 8),
                  _FreqChip(
                    label: '每周',
                    selected: _frequency == 'weekly',
                    onTap: () => setState(() => _frequency = 'weekly'),
                  ),
                ],
              ),
              if (_frequency == 'weekly') ...[
                const SizedBox(height: 14),
                Text('选择星期', style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children:
                      _allWeekdays.map((d) {
                        final selected = _weekdays.contains(d);
                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              if (selected) {
                                _weekdays.remove(d);
                              } else {
                                _weekdays.add(d);
                                _weekdays.sort();
                              }
                            });
                          },
                          child: Container(
                            width: 40,
                            height: 40,
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color:
                                  selected
                                      ? const Color(0xFF7BAAF7)
                                      : colors.surfaceSoft,
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              _weekdayNames[d],
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color:
                                    selected ? Colors.white : colors.textMuted,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                ),
              ],
              const SizedBox(height: 16),
              Text('提醒时间', style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              TextField(
                controller: _reminderCtrl,
                readOnly: true,
                onTap: _pickReminderTime,
                decoration: InputDecoration(
                  hintText: '如 07:00（留空不提醒）',
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                  suffixIcon:
                      _reminderTime.isEmpty
                          ? const Icon(Icons.access_time, size: 20)
                          : IconButton(
                            icon: const Icon(Icons.close_rounded, size: 20),
                            tooltip: '清除提醒',
                            onPressed:
                                () => setState(() {
                                  _reminderTime = '';
                                  _reminderCtrl.clear();
                                }),
                          ),
                ),
              ),
              if (_isEditing) ...[
                const SizedBox(height: 18),
                _buildBackfillSection(theme),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF7BAAF7),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child:
                      _saving
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                          : Text(
                            _isEditing ? '保存' : '创建',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                ),
              ),
              const SizedBox(height: 8),
              if (_isEditing)
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton(
                    onPressed: _delete,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade400,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('删除习惯'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _showError('先写一个习惯名称');
      return;
    }
    if (_frequency == 'weekly' && _weekdays.isEmpty) {
      _showError('每周习惯至少选择一天');
      return;
    }
    setState(() => _saving = true);
    final store = context.read<HabitsStore>();
    final payload = <String, dynamic>{
      'title': title,
      'description': _descriptionCtrl.text.trim(),
      'frequency': _frequency,
      'weekdays': _frequency == 'weekly' ? _weekdays : [],
      'reminderTime': _reminderTime,
    };
    try {
      if (_isEditing) {
        await store.updateHabit(widget.habit!.id, payload);
      } else {
        await store.createHabit(payload);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _showError('保存失败：$e');
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('删除习惯'),
            content: Text('确定删除「${widget.habit?.title}」吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('删除', style: TextStyle(color: Colors.red.shade400)),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await context.read<HabitsStore>().deleteHabit(widget.habit!.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _showError('删除失败：$e');
      }
    }
  }

  Widget _buildBackfillSection(ThemeData theme) {
    final habit = _currentHabit ?? widget.habit;
    if (habit == null) return const SizedBox.shrink();
    final days =
        habit.history.length > 7
            ? habit.history.sublist(habit.history.length - 7)
            : habit.history;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('补打卡', style: theme.textTheme.bodySmall),
            Text(
              '最近7天',
              style: theme.textTheme.bodySmall?.copyWith(
                color: context.aliceColors.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final day in days) ...[
              Expanded(child: _buildBackfillDay(day)),
              if (day != days.last) const SizedBox(width: 6),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildBackfillDay(HabitHistoryDay day) {
    final colors = context.aliceColors;
    final habit = _currentHabit ?? widget.habit!;
    final parsed = DateTime.tryParse(day.date);
    final scheduled =
        parsed != null &&
        (habit.isDaily || habit.weekdays.contains(parsed.weekday));
    final completed = day.isCompleted;
    final busy = _backfillBusyDate == day.date;
    final label = parsed == null ? '--' : '${parsed.month}/${parsed.day}';
    final weekday = parsed == null ? '' : _weekdayNames[parsed.weekday];
    final color = completed ? const Color(0xFF66C5A3) : const Color(0xFF7BAAF7);
    return Tooltip(
      message:
          scheduled
              ? (completed ? '取消 ${day.date} 打卡' : '补打卡 ${day.date}')
              : '${day.date} 不需要打卡',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: scheduled && !busy ? () => _toggleBackfillDay(day) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 58,
          decoration: BoxDecoration(
            color:
                !scheduled
                    ? colors.surface
                    : completed
                    ? color.withValues(alpha: 0.14)
                    : colors.surfaceSoft,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  !scheduled
                      ? colors.border
                      : completed
                      ? color
                      : colors.borderStrong,
            ),
          ),
          child:
              busy
                  ? const Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                  : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        weekday,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color:
                              scheduled
                                  ? colors.textMuted
                                  : colors.borderStrong,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color:
                              !scheduled
                                  ? colors.borderStrong
                                  : completed
                                  ? color
                                  : colors.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Icon(
                        completed
                            ? Icons.check_circle_rounded
                            : scheduled
                            ? Icons.add_circle_outline_rounded
                            : Icons.remove_circle_outline_rounded,
                        size: 14,
                        color:
                            !scheduled
                                ? colors.borderStrong
                                : completed
                                ? color
                                : colors.textMuted,
                      ),
                    ],
                  ),
        ),
      ),
    );
  }

  Future<void> _toggleBackfillDay(HabitHistoryDay day) async {
    final habit = widget.habit;
    if (habit == null || _backfillBusyDate != null) return;
    setState(() => _backfillBusyDate = day.date);
    try {
      final store = context.read<HabitsStore>();
      Habit? updated;
      if (day.isCompleted) {
        updated = await store.reopenHabitOnDate(habit.id, day.date);
      } else {
        updated = await store.completeHabitOnDate(habit.id, day.date);
      }
      if (mounted) {
        setState(() {
          _currentHabit = updated ?? _currentHabit;
          _backfillBusyDate = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _backfillBusyDate = null);
        _showError('补打卡失败：$e');
      }
    }
  }

  Future<void> _pickReminderTime() async {
    final initial = _parseReminderTime(_reminderTime) ?? TimeOfDay.now();
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    final text =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    setState(() {
      _reminderTime = text;
      _reminderCtrl.text = text;
    });
  }

  TimeOfDay? _parseReminderTime(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return TimeOfDay(hour: hour, minute: minute);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}

class _FreqChip extends StatelessWidget {
  const _FreqChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.aliceColors;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: selected ? const Color(0xFF7BAAF7) : colors.surfaceSoft,
          border: Border.all(
            color: selected ? Colors.transparent : colors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: selected ? Colors.white : colors.textMuted,
          ),
        ),
      ),
    );
  }
}

// ── Empty State ─────────────────────────────────────────────

class HabitsEmptyState extends StatelessWidget {
  const HabitsEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.aliceColors;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
        child: Column(
          children: [
            const Text('🏃', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(
              '还没有习惯',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '创建一个习惯，开始打卡吧',
              style: TextStyle(color: colors.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
