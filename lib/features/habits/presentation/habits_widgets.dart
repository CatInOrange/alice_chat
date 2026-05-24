import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    int bestStreak = 0;
    for (final h in habits) {
      weekDone += h.weeklyStats?.done ?? 0;
      weekTotal += h.weeklyStats?.total ?? 0;
      monthDone += h.monthlyStats?.done ?? 0;
      monthTotal += h.monthlyStats?.total ?? 0;
      if (h.streak > bestStreak) bestStreak = h.streak;
    }

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
            color: const Color(0xFF7BAAF7).withOpacity(0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '📊 本月习惯',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
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
            border: Border.all(color: Colors.white.withOpacity(0.4), width: 2),
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
            color: Colors.white.withOpacity(0.8),
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
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF1F8),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Center(
        child: Column(
          children: [
            Text('🏃', style: TextStyle(fontSize: 32)),
            SizedBox(height: 8),
            Text(
              '还没有习惯，创建一个吧',
              style: TextStyle(color: Color(0xFF7B8496), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Habit Card ──────────────────────────────────────────────

class HabitCard extends StatelessWidget {
  const HabitCard({super.key, required this.habit, required this.onToggle});

  final Habit habit;
  final VoidCallback onToggle;

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
    final isDone = habit.todayInstance?.isCompleted ?? false;
    final rate = habit.weeklyStats?.rate ?? 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDone ? _accentColor.withOpacity(0.3) : const Color(0xFFE8ECF3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _accentColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _iconForHabit(habit.title),
                    style: const TextStyle(fontSize: 20),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        habit.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${habit.frequencyLabel}${habit.reminderTime.isNotEmpty ? ' · ${habit.reminderTime}' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF7B8496),
                        ),
                      ),
                    ],
                  ),
                ),
                _TodayToggle(isDone: isDone, onToggle: onToggle),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _ProgressBar(rate: rate, color: _accentColor),
                const SizedBox(width: 10),
                Text(
                  '${(rate * 100).toInt()}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: _accentColor,
                  ),
                ),
                const Spacer(),
                if (habit.streak > 0)
                  Row(
                    children: [
                      const Text('🔥', style: TextStyle(fontSize: 12)),
                      const SizedBox(width: 2),
                      Text(
                        '${habit.streak}天',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFFFF9A3C),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
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
}

class _TodayToggle extends StatelessWidget {
  const _TodayToggle({required this.isDone, required this.onToggle});

  final bool isDone;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 72,
        height: 36,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: isDone ? const Color(0xFF66C5A3) : const Color(0xFFE8ECF3),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isDone ? Icons.check : Icons.check,
              size: 16,
              color: isDone ? Colors.white : const Color(0xFF7B8496),
            ),
            const SizedBox(width: 4),
            Text(
              isDone ? '已打卡' : '打卡',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isDone ? Colors.white : const Color(0xFF2D3443),
              ),
            ),
          ],
        ),
      ),
    );
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
          backgroundColor: color.withOpacity(0.1),
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
  late String _frequency;
  late List<int> _weekdays;
  late String _reminderTime;
  bool _saving = false;

  bool get _isEditing => widget.habit != null;

  static const _allWeekdays = [1, 2, 3, 4, 5, 6, 7];
  static const _weekdayNames = ['', '一', '二', '三', '四', '五', '六', '日'];

  @override
  void initState() {
    super.initState();
    final h = widget.habit;
    _titleCtrl = TextEditingController(text: h?.title ?? '');
    _frequency = h?.frequency ?? 'daily';
    _weekdays = List<int>.from(h?.weekdays ?? [1, 2, 3, 4, 5]);
    _reminderTime = h?.reminderTime ?? '';
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                    color: const Color(0xFFDDE1EB),
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
                  children: _allWeekdays.map((d) {
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
                          color: selected
                              ? const Color(0xFF7BAAF7)
                              : const Color(0xFFF2F4FA),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _weekdayNames[d],
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: selected
                                ? Colors.white
                                : const Color(0xFF7B8496),
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
                controller: TextEditingController(text: _reminderTime),
                onChanged: (v) => _reminderTime = v,
                keyboardType: TextInputType.datetime,
                decoration: const InputDecoration(
                  hintText: '如 07:00（留空不提醒）',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                  suffixIcon: Icon(Icons.access_time, size: 20),
                ),
              ),
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
                  child: _saving
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
    if (title.isEmpty) return;
    setState(() => _saving = true);
    final store = context.read<HabitsStore>();
    final payload = <String, dynamic>{
      'title': title,
      'frequency': _frequency,
      'weekdays': _frequency == 'weekly' ? _weekdays : [],
      'reminderTime': _reminderTime,
    };
    if (_isEditing) {
      await store.updateHabit(widget.habit!.id, payload);
    } else {
      await store.createHabit(payload);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
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
    await context.read<HabitsStore>().deleteHabit(widget.habit!.id);
    if (mounted) Navigator.of(context).pop();
  }
}

class _FreqChip extends StatelessWidget {
  const _FreqChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: selected ? const Color(0xFF7BAAF7) : const Color(0xFFF2F4FA),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: selected ? Colors.white : const Color(0xFF7B8496),
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
                color: const Color(0xFF2D3443),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '创建一个习惯，开始打卡吧',
              style: TextStyle(color: Color(0xFF7B8496), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
