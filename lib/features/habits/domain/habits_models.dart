class HabitStats {
  const HabitStats({required this.done, required this.total});

  final int done;
  final int total;

  double get rate => total > 0 ? done / total : 0.0;

  factory HabitStats.fromJson(Map<String, dynamic> json) => HabitStats(
    done: (json['done'] as num?)?.toInt() ?? 0,
    total: (json['total'] as num?)?.toInt() ?? 0,
  );
}

class HabitInstance {
  const HabitInstance({
    required this.id,
    required this.habitId,
    required this.date,
    required this.status,
    this.completedAt,
    this.createdAt,
  });

  final String id;
  final String habitId;
  final String date;
  final String status; // pending, completed, expired
  final double? completedAt;
  final double? createdAt;

  bool get isCompleted => status == 'completed';
  bool get isPending => status == 'pending';
  bool get isExpired => status == 'expired';

  factory HabitInstance.fromJson(Map<String, dynamic> json) => HabitInstance(
    id: (json['id'] ?? '') as String,
    habitId: (json['habitId'] ?? '') as String,
    date: (json['date'] ?? '') as String,
    status: (json['status'] ?? 'pending') as String,
    completedAt: (json['completedAt'] as num?)?.toDouble(),
    createdAt: (json['createdAt'] as num?)?.toDouble(),
  );
}

class HabitHistoryDay {
  const HabitHistoryDay({required this.date, required this.status});

  final String date;
  final String status;

  bool get isCompleted => status == 'completed';
  bool get isExpired => status == 'expired';
  bool get isPending => status == 'pending';

  factory HabitHistoryDay.fromJson(Map<String, dynamic> json) =>
      HabitHistoryDay(
        date: (json['date'] ?? '') as String,
        status: (json['status'] ?? 'none') as String,
      );
}

class Habit {
  const Habit({
    required this.id,
    required this.title,
    this.description = '',
    this.frequency = 'daily',
    this.weekdays = const [],
    this.reminderTime = '',
    this.active = true,
    this.colorValue = 0,
    this.iconCodePoint = 0,
    this.sortOrder = 0,
    this.createdAt,
    this.updatedAt,
    this.dueToday = false,
    this.todayInstance,
    this.weeklyStats,
    this.monthlyStats,
    this.streak = 0,
    this.history = const [],
  });

  final String id;
  final String title;
  final String description;
  final String frequency; // 'daily' or 'weekly'
  final List<int> weekdays;
  final String reminderTime;
  final bool active;
  final int colorValue;
  final int iconCodePoint;
  final int sortOrder;
  final double? createdAt;
  final double? updatedAt;
  final bool dueToday;
  final HabitInstance? todayInstance;
  final HabitStats? weeklyStats;
  final HabitStats? monthlyStats;
  final int streak;
  final List<HabitHistoryDay> history;

  bool get isDaily => frequency == 'daily';
  bool get isWeekly => frequency == 'weekly';
  HabitStats get recent30Stats {
    final trackedDays = history.where((day) => day.status != 'none');
    return HabitStats(
      done: trackedDays.where((day) => day.isCompleted).length,
      total: trackedDays.length,
    );
  }

  String get frequencyLabel => isDaily ? '每天' : _weekdayLabel;

  String get _weekdayLabel {
    const names = ['', '一', '二', '三', '四', '五', '六', '日'];
    return weekdays.map((d) => names[d]).join('');
  }

  factory Habit.fromJson(Map<String, dynamic> json) {
    final stats = json['stats'] as Map<String, dynamic>?;
    return Habit(
      id: (json['id'] ?? '') as String,
      title: (json['title'] ?? '') as String,
      description: (json['description'] ?? '') as String? ?? '',
      frequency: (json['frequency'] ?? 'daily') as String,
      weekdays:
          (json['weekdays'] as List<dynamic>?)
              ?.map((d) => (d as num).toInt())
              .toList() ??
          [],
      reminderTime: (json['reminderTime'] ?? '') as String? ?? '',
      active: (json['active'] as bool?) ?? true,
      colorValue: (json['colorValue'] as num?)?.toInt() ?? 0,
      iconCodePoint: (json['iconCodePoint'] as num?)?.toInt() ?? 0,
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      createdAt: (json['createdAt'] as num?)?.toDouble(),
      updatedAt: (json['updatedAt'] as num?)?.toDouble(),
      dueToday: json['dueToday'] as bool? ?? false,
      todayInstance:
          json['todayInstance'] != null
              ? HabitInstance.fromJson(
                json['todayInstance'] as Map<String, dynamic>,
              )
              : null,
      weeklyStats:
          stats != null
              ? HabitStats.fromJson(
                (stats['weekly'] ?? {}) as Map<String, dynamic>,
              )
              : null,
      monthlyStats:
          stats != null
              ? HabitStats.fromJson(
                (stats['monthly'] ?? {}) as Map<String, dynamic>,
              )
              : null,
      streak: (json['streak'] as num?)?.toInt() ?? 0,
      history: (json['history'] as List<dynamic>? ?? const [])
          .map((item) => HabitHistoryDay.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}
