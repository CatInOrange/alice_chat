import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/todo_models.dart';

class TodoLocalStore {
  static const String _legacyStorageKey = 'alicechat.todo.snapshot.v1';
  static const String _dbName = 'alicechat_todo.db';
  static const int _dbVersion = 3;

  Database? _database;

  Future<TodoSnapshot?> load() async {
    final db = await _openDatabase();
    await _maybeMigrateLegacyPrefs(db);

    final projectRows = await db.query('todo_projects', orderBy: 'sort_order ASC');
    final taskRows = await db.query('todo_tasks');
    final subtaskRows = await db.query(
      'todo_subtasks',
      orderBy: 'task_id ASC, sort_order ASC, created_at ASC',
    );
    if (projectRows.isEmpty && taskRows.isEmpty) {
      return null;
    }

    final subtasks = subtaskRows.map(_subtaskFromRow).toList(growable: false);
    return TodoSnapshot(
      projects: projectRows.map(_projectFromRow).toList(growable: false),
      tasks: taskRows
          .map((row) => _taskFromRow(row, subtasks: subtasks))
          .toList(growable: false),
      subtasks: subtasks,
    );
  }

  Future<void> seedIfEmpty(TodoSnapshot snapshot) async {
    final db = await _openDatabase();
    final counts = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM todo_projects'),
    );
    if ((counts ?? 0) > 0) {
      return;
    }
    await _replaceAll(db, snapshot);
  }

  Future<void> upsertTask(TodoTask task) async {
    final db = await _openDatabase();
    await db.insert(
      'todo_tasks',
      _taskToRow(task),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertProject(TodoProject project) async {
    final db = await _openDatabase();
    await db.insert(
      'todo_projects',
      _projectToRow(project),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> replaceProjectOrders(List<TodoProject> projects) async {
    final db = await _openDatabase();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var index = 0; index < projects.length; index++) {
        final project = projects[index];
        batch.update(
          'todo_projects',
          {
            'sort_order': index,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [project.id],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<TodoSubtask>> listSubtasks(String taskId) async {
    final db = await _openDatabase();
    final rows = await db.query(
      'todo_subtasks',
      where: 'task_id = ?',
      whereArgs: [taskId],
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return rows.map(_subtaskFromRow).toList(growable: false);
  }

  Future<void> replaceSubtasks(
    String taskId,
    List<TodoSubtask> subtasks,
  ) async {
    final db = await _openDatabase();
    await db.transaction((txn) async {
      await txn.delete('todo_subtasks', where: 'task_id = ?', whereArgs: [taskId]);
      final batch = txn.batch();
      for (final subtask in subtasks) {
        batch.insert(
          'todo_subtasks',
          _subtaskToRow(subtask),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteTask(String taskId) async {
    final db = await _openDatabase();
    await db.delete('todo_tasks', where: 'id = ?', whereArgs: [taskId]);
  }

  Future<Database> _openDatabase() async {
    final existing = _database;
    if (existing != null) return existing;
    final dbPath = path.join(await getDatabasesPath(), _dbName);
    final db = await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: (db, version) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createSubtaskTable(db);
        }
        if (oldVersion < 3) {
          await _migrateReminderAndProjectOrder(db);
        }
      },
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
    _database = db;
    return db;
  }

  Future<void> _maybeMigrateLegacyPrefs(Database db) async {
    final projectCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM todo_projects'),
    );
    if ((projectCount ?? 0) > 0) return;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_legacyStorageKey)?.trim();
    if (raw == null || raw.isEmpty) return;

    try {
      final snapshot = TodoSnapshot.decode(raw);
      await _replaceAll(db, snapshot);
      await prefs.remove(_legacyStorageKey);
    } catch (_) {
      // Ignore broken legacy payloads and let seed logic handle first boot.
    }
  }

  Future<void> _replaceAll(Database db, TodoSnapshot snapshot) async {
    await db.transaction((txn) async {
      await txn.delete('todo_subtasks');
      await txn.delete('todo_tasks');
      await txn.delete('todo_projects');

      final batch = txn.batch();
      for (final project in snapshot.projects) {
        batch.insert(
          'todo_projects',
          _projectToRow(project),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final task in snapshot.tasks) {
        batch.insert(
          'todo_tasks',
          _taskToRow(task),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final subtask in snapshot.subtasks) {
        batch.insert(
          'todo_subtasks',
          _subtaskToRow(subtask),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Map<String, Object?> _projectToRow(TodoProject project) => {
    'id': project.id,
    'name': project.name,
    'icon_code_point': project.iconCodePoint,
    'color_value': project.colorValue,
    'description': project.description,
    'sort_order': project.sortOrder,
    'archived': project.archived ? 1 : 0,
    'created_at': project.createdAt.millisecondsSinceEpoch,
    'updated_at': project.updatedAt.millisecondsSinceEpoch,
  };

  TodoProject _projectFromRow(Map<String, Object?> row) => TodoProject(
    id: row['id'] as String,
    name: row['name'] as String,
    iconCodePoint: row['icon_code_point'] as int,
    colorValue: row['color_value'] as int,
    description: row['description'] as String? ?? '',
    sortOrder: row['sort_order'] as int? ?? 0,
    archived: (row['archived'] as int? ?? 0) == 1,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
  );

  Map<String, Object?> _taskToRow(TodoTask task) => {
    'id': task.id,
    'project_id': task.projectId,
    'title': task.title,
    'description': task.description,
    'priority': task.priority.name,
    'status': task.status.name,
    'due_at': task.dueAt?.millisecondsSinceEpoch,
    'reminder_at': task.reminderAt?.millisecondsSinceEpoch,
    'created_at': task.createdAt?.millisecondsSinceEpoch,
    'updated_at': task.updatedAt?.millisecondsSinceEpoch,
    'completed_at': task.completedAt?.millisecondsSinceEpoch,
  };

  Map<String, Object?> _subtaskToRow(TodoSubtask subtask) => {
    'id': subtask.id,
    'task_id': subtask.taskId,
    'title': subtask.title,
    'is_completed': subtask.isCompleted ? 1 : 0,
    'sort_order': subtask.sortOrder,
    'created_at': subtask.createdAt?.millisecondsSinceEpoch,
    'updated_at': subtask.updatedAt?.millisecondsSinceEpoch,
  };

  TodoTask _taskFromRow(
    Map<String, Object?> row, {
    required List<TodoSubtask> subtasks,
  }) => TodoTask(
    id: row['id'] as String,
    projectId: row['project_id'] as String,
    title: row['title'] as String,
    description: row['description'] as String? ?? '',
    priority: TodoPriority.values.firstWhere(
      (item) => item.name == (row['priority'] as String? ?? 'medium'),
      orElse: () => TodoPriority.medium,
    ),
    status: TodoStatus.values.firstWhere(
      (item) => item.name == (row['status'] as String? ?? 'todo'),
      orElse: () => TodoStatus.todo,
    ),
    dueAt: _dateFromEpoch(row['due_at']),
    reminderAt: _dateFromEpoch(row['reminder_at']),
    createdAt: _dateFromEpoch(row['created_at']),
    updatedAt: _dateFromEpoch(row['updated_at']),
    completedAt: _dateFromEpoch(row['completed_at']),
    subtaskCount:
        subtasks.where((item) => item.taskId == row['id'] as String).length,
    completedSubtaskCount:
        subtasks
            .where(
              (item) =>
                  item.taskId == row['id'] as String && item.isCompleted,
            )
            .length,
  );

  TodoSubtask _subtaskFromRow(Map<String, Object?> row) => TodoSubtask(
    id: row['id'] as String,
    taskId: row['task_id'] as String,
    title: row['title'] as String,
    isCompleted: (row['is_completed'] as int? ?? 0) == 1,
    sortOrder: row['sort_order'] as int? ?? 0,
    createdAt: _dateFromEpoch(row['created_at']),
    updatedAt: _dateFromEpoch(row['updated_at']),
  );

  Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE todo_projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        icon_code_point INTEGER NOT NULL,
        color_value INTEGER NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE todo_tasks (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        title TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        priority TEXT NOT NULL,
        status TEXT NOT NULL,
        due_at INTEGER,
        reminder_at INTEGER,
        created_at INTEGER,
        updated_at INTEGER,
        completed_at INTEGER,
        FOREIGN KEY(project_id) REFERENCES todo_projects(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_todo_tasks_project_id ON todo_tasks(project_id)',
    );
    await db.execute(
      'CREATE INDEX idx_todo_tasks_due_at ON todo_tasks(due_at)',
    );
    await _createSubtaskTable(db);
  }

  Future<void> _migrateReminderAndProjectOrder(DatabaseExecutor db) async {
    await db.execute(
      'ALTER TABLE todo_tasks ADD COLUMN reminder_at INTEGER',
    );
  }

  Future<void> _createSubtaskTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS todo_subtasks (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        title TEXT NOT NULL,
        is_completed INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER,
        updated_at INTEGER,
        FOREIGN KEY(task_id) REFERENCES todo_tasks(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_todo_subtasks_task_id ON todo_subtasks(task_id)',
    );
  }

  DateTime? _dateFromEpoch(Object? value) {
    final epoch = value as int?;
    if (epoch == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(epoch);
  }
}
