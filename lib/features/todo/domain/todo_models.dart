import 'dart:convert';

class TodoProject {
  const TodoProject({
    required this.id,
    required this.name,
    required this.iconCodePoint,
    required this.colorValue,
    this.description = '',
    this.sortOrder = 0,
    this.archived = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final int iconCodePoint;
  final int colorValue;
  final String description;
  final int sortOrder;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;

  TodoProject copyWith({
    String? id,
    String? name,
    int? iconCodePoint,
    int? colorValue,
    String? description,
    int? sortOrder,
    bool? archived,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TodoProject(
      id: id ?? this.id,
      name: name ?? this.name,
      iconCodePoint: iconCodePoint ?? this.iconCodePoint,
      colorValue: colorValue ?? this.colorValue,
      description: description ?? this.description,
      sortOrder: sortOrder ?? this.sortOrder,
      archived: archived ?? this.archived,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'iconCodePoint': iconCodePoint,
    'colorValue': colorValue,
    'description': description,
    'sortOrder': sortOrder,
    'archived': archived,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory TodoProject.fromJson(Map<String, dynamic> json) => TodoProject(
    id: json['id'] as String,
    name: json['name'] as String,
    iconCodePoint: json['iconCodePoint'] as int,
    colorValue: json['colorValue'] as int,
    description: json['description'] as String? ?? '',
    sortOrder: json['sortOrder'] as int? ?? 0,
    archived: json['archived'] as bool? ?? false,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

class TodoTask {
  const TodoTask({
    required this.id,
    required this.projectId,
    required this.title,
    this.description = '',
    this.priority = TodoPriority.medium,
    this.status = TodoStatus.todo,
    this.dueAt,
    this.reminderAt,
    this.createdAt,
    this.updatedAt,
    this.completedAt,
    this.subtaskCount = 0,
    this.completedSubtaskCount = 0,
  });

  final String id;
  final String projectId;
  final String title;
  final String description;
  final TodoPriority priority;
  final TodoStatus status;
  final DateTime? dueAt;
  final DateTime? reminderAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? completedAt;
  final int subtaskCount;
  final int completedSubtaskCount;

  bool get isDone => status == TodoStatus.done;

  TodoTask copyWith({
    String? id,
    String? projectId,
    String? title,
    String? description,
    TodoPriority? priority,
    TodoStatus? status,
    Object? dueAt = _sentinel,
    Object? reminderAt = _sentinel,
    Object? createdAt = _sentinel,
    Object? updatedAt = _sentinel,
    Object? completedAt = _sentinel,
    int? subtaskCount,
    int? completedSubtaskCount,
  }) {
    return TodoTask(
      id: id ?? this.id,
      projectId: projectId ?? this.projectId,
      title: title ?? this.title,
      description: description ?? this.description,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      dueAt: identical(dueAt, _sentinel) ? this.dueAt : dueAt as DateTime?,
      reminderAt:
          identical(reminderAt, _sentinel)
              ? this.reminderAt
              : reminderAt as DateTime?,
      createdAt:
          identical(createdAt, _sentinel)
              ? this.createdAt
              : createdAt as DateTime?,
      updatedAt:
          identical(updatedAt, _sentinel)
              ? this.updatedAt
              : updatedAt as DateTime?,
      completedAt:
          identical(completedAt, _sentinel)
              ? this.completedAt
              : completedAt as DateTime?,
      subtaskCount: subtaskCount ?? this.subtaskCount,
      completedSubtaskCount:
          completedSubtaskCount ?? this.completedSubtaskCount,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'projectId': projectId,
    'title': title,
    'description': description,
    'priority': priority.name,
    'status': status.name,
    'dueAt': dueAt?.toIso8601String(),
    'reminderAt': reminderAt?.toIso8601String(),
    'createdAt': createdAt?.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
    'subtaskCount': subtaskCount,
    'completedSubtaskCount': completedSubtaskCount,
  };

  factory TodoTask.fromJson(Map<String, dynamic> json) => TodoTask(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    title: json['title'] as String,
    description: json['description'] as String? ?? '',
    priority: TodoPriority.values.firstWhere(
      (item) => item.name == (json['priority'] as String? ?? 'medium'),
      orElse: () => TodoPriority.medium,
    ),
    status: TodoStatus.values.firstWhere(
      (item) => item.name == (json['status'] as String? ?? 'todo'),
      orElse: () => TodoStatus.todo,
    ),
    dueAt:
        (json['dueAt'] as String?) == null
            ? null
            : DateTime.parse(json['dueAt'] as String),
    reminderAt:
        (json['reminderAt'] as String?) == null
            ? null
            : DateTime.parse(json['reminderAt'] as String),
    createdAt:
        (json['createdAt'] as String?) == null
            ? null
            : DateTime.parse(json['createdAt'] as String),
    updatedAt:
        (json['updatedAt'] as String?) == null
            ? null
            : DateTime.parse(json['updatedAt'] as String),
    completedAt:
        (json['completedAt'] as String?) == null
            ? null
            : DateTime.parse(json['completedAt'] as String),
    subtaskCount: json['subtaskCount'] as int? ?? 0,
    completedSubtaskCount: json['completedSubtaskCount'] as int? ?? 0,
  );
}

class TodoSubtask {
  const TodoSubtask({
    required this.id,
    required this.taskId,
    required this.title,
    this.isCompleted = false,
    this.sortOrder = 0,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String taskId;
  final String title;
  final bool isCompleted;
  final int sortOrder;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  TodoSubtask copyWith({
    String? id,
    String? taskId,
    String? title,
    bool? isCompleted,
    int? sortOrder,
    Object? createdAt = _sentinel,
    Object? updatedAt = _sentinel,
  }) {
    return TodoSubtask(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      title: title ?? this.title,
      isCompleted: isCompleted ?? this.isCompleted,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt:
          identical(createdAt, _sentinel)
              ? this.createdAt
              : createdAt as DateTime?,
      updatedAt:
          identical(updatedAt, _sentinel)
              ? this.updatedAt
              : updatedAt as DateTime?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'taskId': taskId,
    'title': title,
    'isCompleted': isCompleted,
    'sortOrder': sortOrder,
    'createdAt': createdAt?.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
  };

  factory TodoSubtask.fromJson(Map<String, dynamic> json) => TodoSubtask(
    id: json['id'] as String,
    taskId: json['taskId'] as String,
    title: json['title'] as String,
    isCompleted: json['isCompleted'] as bool? ?? false,
    sortOrder: json['sortOrder'] as int? ?? 0,
    createdAt:
        (json['createdAt'] as String?) == null
            ? null
            : DateTime.parse(json['createdAt'] as String),
    updatedAt:
        (json['updatedAt'] as String?) == null
            ? null
            : DateTime.parse(json['updatedAt'] as String),
  );
}

enum TodoPriority { low, medium, high, urgent }

enum TodoStatus { todo, doing, done, archived }

class TodoSnapshot {
  const TodoSnapshot({
    required this.projects,
    required this.tasks,
    this.subtasks = const [],
  });

  final List<TodoProject> projects;
  final List<TodoTask> tasks;
  final List<TodoSubtask> subtasks;

  Map<String, dynamic> toJson() => {
    'projects': projects.map((item) => item.toJson()).toList(growable: false),
    'tasks': tasks.map((item) => item.toJson()).toList(growable: false),
    'subtasks': subtasks.map((item) => item.toJson()).toList(growable: false),
  };

  String encode() => jsonEncode(toJson());

  factory TodoSnapshot.fromJson(Map<String, dynamic> json) => TodoSnapshot(
    projects:
        (json['projects'] as List<dynamic>? ?? const [])
            .map((item) => TodoProject.fromJson(item as Map<String, dynamic>))
            .toList(growable: false),
    tasks:
        (json['tasks'] as List<dynamic>? ?? const [])
            .map((item) => TodoTask.fromJson(item as Map<String, dynamic>))
            .toList(growable: false),
    subtasks:
        (json['subtasks'] as List<dynamic>? ?? const [])
            .map((item) => TodoSubtask.fromJson(item as Map<String, dynamic>))
            .toList(growable: false),
  );

  factory TodoSnapshot.decode(String raw) =>
      TodoSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

const Object _sentinel = Object();
