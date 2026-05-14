import 'package:flutter/material.dart';

import '../../../core/debug/native_debug_bridge.dart';
import '../data/todo_local_store.dart';
import '../domain/todo_models.dart';

class TodoStore extends ChangeNotifier {
  TodoStore({TodoLocalStore? localStore})
    : _localStore = localStore ?? TodoLocalStore();

  final TodoLocalStore _localStore;

  bool _loaded = false;
  bool _loading = false;
  String? _error;
  List<TodoProject> _projects = const [];
  List<TodoTask> _tasks = const [];

  bool get isLoaded => _loaded;
  bool get isLoading => _loading;
  String? get error => _error;
  List<TodoProject> get projects => _projects;
  List<TodoProject> get activeProjects =>
      _projects.where((item) => !item.archived).toList(growable: false);
  List<TodoProject> get archivedProjects =>
      _projects.where((item) => item.archived).toList(growable: false);
  List<TodoTask> get tasks => _tasks;

  Future<List<TodoSubtask>> subtasksForTask(String taskId) {
    return _localStore.listSubtasks(taskId);
  }

  Future<void> ensureLoaded() async {
    if (_loaded || _loading) return;
    _loading = true;
    notifyListeners();
    try {
      final snapshot = await _localStore.load();
      if (snapshot == null) {
        final seeded = _seedSnapshot();
        await _localStore.seedIfEmpty(seeded);
        _projects = seeded.projects;
        _tasks = seeded.tasks;
      } else {
        _projects = snapshot.projects.toList(growable: false)
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
        _tasks = snapshot.tasks.toList(growable: false)..sort(_taskSort);
      }
      _error = null;
      _loaded = true;
    } catch (error) {
      _error = '$error';
      await NativeDebugBridge.instance.log(
        'todo',
        'ensureLoaded failed error=$error',
        level: 'WARN',
      );
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  List<TodoTask> tasksForProject(String projectId) {
    return _tasks
        .where((item) => item.projectId == projectId)
        .toList(growable: false)
      ..sort(_taskSort);
  }

  List<TodoTask> get todayTasks {
    final now = DateTime.now();
    return _tasks
        .where(
          (item) =>
              !_isProjectArchived(item.projectId) &&
              !item.isDone &&
              _isSameDay(item.dueAt, now),
        )
        .toList(growable: false)
      ..sort(_taskSort);
  }

  List<TodoTask> get upcomingTasks {
    final now = DateTime.now();
    return _tasks
        .where(
          (item) =>
              !_isProjectArchived(item.projectId) &&
              !item.isDone &&
              item.dueAt != null &&
              item.dueAt!.isAfter(DateTime(now.year, now.month, now.day, 23, 59)),
        )
        .toList(growable: false)
      ..sort(_taskSort);
  }

  List<TodoTask> get completedTasks {
    return _tasks
        .where((item) => !_isProjectArchived(item.projectId) && item.isDone)
        .toList(growable: false)
      ..sort((a, b) {
        final aTime = a.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });
  }

  int pendingCountForProject(String projectId) {
    return _tasks
        .where((item) => item.projectId == projectId && !item.isDone)
        .length;
  }

  int dueTodayCountForProject(String projectId) {
    final now = DateTime.now();
    return _tasks
        .where(
          (item) =>
              item.projectId == projectId &&
              !item.isDone &&
              _isSameDay(item.dueAt, now),
        )
        .length;
  }

  Future<void> archiveProject(String projectId, {bool archived = true}) async {
    final now = DateTime.now();
    final index = _projects.indexWhere((item) => item.id == projectId);
    if (index < 0) return;
    final mutable = _projects.toList(growable: true);
    mutable[index] = mutable[index].copyWith(archived: archived, updatedAt: now);
    _projects = mutable.toList(growable: false)
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    notifyListeners();
    await _localStore.upsertProject(_projects[index]);
  }

  int get totalPendingCount => _tasks.where((item) => !item.isDone).length;
  int get totalCompletedCount => _tasks.where((item) => item.isDone).length;
  int get totalDueTodayCount => todayTasks.length;

  Future<void> saveProject(TodoProject project) async {
    final now = DateTime.now();
    final existingIndex = _projects.indexWhere((item) => item.id == project.id);
    final normalized = project.copyWith(
      createdAt: existingIndex >= 0 ? _projects[existingIndex].createdAt : project.createdAt,
      updatedAt: now,
      sortOrder: existingIndex >= 0 ? _projects[existingIndex].sortOrder : _projects.length,
    );
    final mutable = _projects.toList(growable: true);
    if (existingIndex >= 0) {
      mutable[existingIndex] = normalized;
    } else {
      mutable.add(normalized);
    }
    mutable.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    _projects = mutable.toList(growable: false);
    notifyListeners();
    await _localStore.upsertProject(normalized);
  }

  Future<void> reorderProjects(int oldIndex, int newIndex) async {
    final mutable = _projects.toList(growable: true)
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    if (oldIndex < 0 || oldIndex >= mutable.length) return;
    if (newIndex < 0 || newIndex >= mutable.length) return;
    final target = mutable.removeAt(oldIndex);
    mutable.insert(newIndex, target);
    final now = DateTime.now();
    _projects = mutable
        .asMap()
        .entries
        .map(
          (entry) => entry.value.copyWith(
            sortOrder: entry.key,
            updatedAt: now,
          ),
        )
        .toList(growable: false);
    notifyListeners();
    await _localStore.replaceProjectOrders(_projects);
  }

  Future<void> toggleTask(String taskId, bool value) async {
    final now = DateTime.now();
    _tasks = _tasks.map((item) {
      if (item.id != taskId) return item;
      return item.copyWith(
        status: value ? TodoStatus.done : TodoStatus.todo,
        completedAt: value ? now : null,
        updatedAt: now,
        completedSubtaskCount: value ? item.subtaskCount : 0,
      );
    }).toList(growable: false);
    notifyListeners();
    final updatedTask = _tasks.firstWhere((item) => item.id == taskId);
    await _localStore.upsertTask(updatedTask);
    final subtasks = await _localStore.listSubtasks(taskId);
    if (subtasks.isEmpty) return;
    final normalized = subtasks
        .asMap()
        .entries
        .map(
          (entry) => entry.value.copyWith(
            isCompleted: value,
            sortOrder: entry.key,
            updatedAt: now,
          ),
        )
        .toList(growable: false);
    await _localStore.replaceSubtasks(taskId, normalized);
  }

  Future<void> saveTask(
    TodoTask task, {
    List<TodoSubtask>? subtasks,
  }) async {
    final now = DateTime.now();
    final existingIndex = _tasks.indexWhere((item) => item.id == task.id);
    final normalizedSubtasks =
        subtasks
            ?.asMap()
            .entries
            .map(
              (entry) => entry.value.copyWith(
                taskId: task.id,
                sortOrder: entry.key,
                updatedAt: now,
                createdAt: entry.value.createdAt ?? now,
              ),
            )
            .toList(growable: false);
    final completedSubtaskCount =
        normalizedSubtasks?.where((item) => item.isCompleted).length ??
        task.completedSubtaskCount;
    final subtaskCount = normalizedSubtasks?.length ?? task.subtaskCount;
    final shouldAutoComplete = subtaskCount > 0 && completedSubtaskCount == subtaskCount;
    final normalized = task.copyWith(
      createdAt: task.createdAt ?? now,
      updatedAt: now,
      status: shouldAutoComplete
          ? TodoStatus.done
          : (task.status == TodoStatus.done && completedSubtaskCount < subtaskCount)
              ? TodoStatus.todo
              : task.status,
      completedAt:
          shouldAutoComplete
              ? (task.completedAt ?? now)
              : (task.status == TodoStatus.done && completedSubtaskCount < subtaskCount)
                  ? null
                  : task.isDone
                      ? (task.completedAt ?? now)
                      : null,
      reminderAt: task.reminderAt,
      subtaskCount: subtaskCount,
      completedSubtaskCount: completedSubtaskCount,
    );
    final mutable = _tasks.toList(growable: true);
    if (existingIndex >= 0) {
      mutable[existingIndex] = normalized;
    } else {
      mutable.add(normalized);
    }
    _tasks = mutable.toList(growable: false)..sort(_taskSort);
    notifyListeners();
    await _localStore.upsertTask(normalized);
    if (normalizedSubtasks != null) {
      await _localStore.replaceSubtasks(task.id, normalizedSubtasks);
    }
  }

  Future<void> deleteTask(String taskId) async {
    _tasks = _tasks.where((item) => item.id != taskId).toList(growable: false);
    notifyListeners();
    await _localStore.deleteTask(taskId);
  }

  Future<void> replaceSubtasks(
    String taskId,
    List<TodoSubtask> subtasks,
  ) async {
    final now = DateTime.now();
    final normalizedSubtasks =
        subtasks
            .asMap()
            .entries
            .map(
              (entry) => entry.value.copyWith(
                taskId: taskId,
                sortOrder: entry.key,
                updatedAt: now,
                createdAt: entry.value.createdAt ?? now,
              ),
            )
            .toList(growable: false);
    final completedCount =
        normalizedSubtasks.where((item) => item.isCompleted).length;
    final shouldAutoComplete =
        normalizedSubtasks.isNotEmpty && completedCount == normalizedSubtasks.length;
    _tasks =
        _tasks.map((item) {
          if (item.id != taskId) return item;
          return item.copyWith(
            updatedAt: now,
            status: shouldAutoComplete
                ? TodoStatus.done
                : (item.status == TodoStatus.done && completedCount < normalizedSubtasks.length)
                    ? TodoStatus.todo
                    : item.status,
            completedAt: shouldAutoComplete
                ? (item.completedAt ?? now)
                : (item.status == TodoStatus.done && completedCount < normalizedSubtasks.length)
                    ? null
                    : item.completedAt,
            subtaskCount: normalizedSubtasks.length,
            completedSubtaskCount: completedCount,
          );
        }).toList(growable: false)
          ..sort(_taskSort);
    notifyListeners();
    final updatedTask = _tasks.firstWhere((item) => item.id == taskId);
    await _localStore.upsertTask(updatedTask);
    await _localStore.replaceSubtasks(taskId, normalizedSubtasks);
  }

  TodoSnapshot _seedSnapshot() {
    final now = DateTime.now();
    final projects = <TodoProject>[
      TodoProject(
        id: 'work',
        name: '工作',
        iconCodePoint: Icons.work_outline_rounded.codePoint,
        colorValue: 0xFF66C5A3,
        description: '推进项目、会议、交付。',
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
      TodoProject(
        id: 'life',
        name: '生活',
        iconCodePoint: Icons.wb_sunny_outlined.codePoint,
        colorValue: 0xFFFFC857,
        description: '日常安排、休息、兴趣。',
        sortOrder: 1,
        createdAt: now,
        updatedAt: now,
      ),
      TodoProject(
        id: 'family',
        name: '家庭',
        iconCodePoint: Icons.home_rounded.codePoint,
        colorValue: 0xFFF28CA6,
        description: '家人、陪伴、采购。',
        sortOrder: 2,
        createdAt: now,
        updatedAt: now,
      ),
      TodoProject(
        id: 'study',
        name: '学习',
        iconCodePoint: Icons.menu_book_rounded.codePoint,
        colorValue: 0xFF7BAAF7,
        description: '阅读、复盘、练习。',
        sortOrder: 3,
        createdAt: now,
        updatedAt: now,
      ),
    ];

    final tasks = <TodoTask>[
      TodoTask(
        id: 'seed-1',
        projectId: 'work',
        title: '整理 AliceChat 待办页结构',
        description: '先把项目卡和今日列表搭起来。',
        priority: TodoPriority.high,
        dueAt: now.add(const Duration(hours: 3)),
        createdAt: now,
        updatedAt: now,
      ),
      TodoTask(
        id: 'seed-2',
        projectId: 'life',
        title: '晚饭前散步 20 分钟',
        priority: TodoPriority.low,
        dueAt: DateTime(now.year, now.month, now.day, 19, 0),
        createdAt: now,
        updatedAt: now,
      ),
      TodoTask(
        id: 'seed-3',
        projectId: 'study',
        title: '看一篇 Flutter 状态管理笔记',
        priority: TodoPriority.medium,
        dueAt: now.add(const Duration(days: 1, hours: 2)),
        createdAt: now,
        updatedAt: now,
      ),
      TodoTask(
        id: 'seed-4',
        projectId: 'family',
        title: '给家里买点水果',
        priority: TodoPriority.medium,
        status: TodoStatus.done,
        dueAt: now.subtract(const Duration(days: 1)),
        createdAt: now.subtract(const Duration(days: 2)),
        updatedAt: now.subtract(const Duration(hours: 6)),
        completedAt: now.subtract(const Duration(hours: 6)),
      ),
    ];

    return TodoSnapshot(projects: projects, tasks: tasks);
  }

  static int _taskSort(TodoTask a, TodoTask b) {
    final aDone = a.isDone ? 1 : 0;
    final bDone = b.isDone ? 1 : 0;
    if (aDone != bDone) return aDone.compareTo(bDone);
    if (a.dueAt == null && b.dueAt != null) return 1;
    if (a.dueAt != null && b.dueAt == null) return -1;
    if (a.dueAt != null && b.dueAt != null) {
      final dueCompare = a.dueAt!.compareTo(b.dueAt!);
      if (dueCompare != 0) return dueCompare;
    }
    return b.priority.index.compareTo(a.priority.index);
  }

  bool _isProjectArchived(String projectId) {
    return _projects.any((item) => item.id == projectId && item.archived);
  }

  static bool _isSameDay(DateTime? a, DateTime b) {
    if (a == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}
