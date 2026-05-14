import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme.dart';
import '../application/todo_store.dart';
import '../domain/todo_models.dart';

class TodoScreen extends StatefulWidget {
  const TodoScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

enum _TaskFeedFilter { today, upcoming, completed }
enum _TaskSortMode { smart, dueSoon, priority }

class _TodoScreenState extends State<TodoScreen>
    with AutomaticKeepAliveClientMixin {
  static const Uuid _uuid = Uuid();

  _TaskFeedFilter _activeFilter = _TaskFeedFilter.today;
  _TaskSortMode _sortMode = _TaskSortMode.smart;
  String? _projectFilterId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TodoStore>().ensureLoaded();
    });
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final store = context.watch<TodoStore>();
    final theme = Theme.of(context);

    if (store.isLoading && !store.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (store.error != null && !store.isLoaded) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(store.error!, style: theme.textTheme.bodyMedium),
        ),
      );
    }

    var filteredTasks = switch (_activeFilter) {
      _TaskFeedFilter.today => store.todayTasks,
      _TaskFeedFilter.upcoming => store.upcomingTasks,
      _TaskFeedFilter.completed => store.completedTasks,
    };
    if (_projectFilterId != null) {
      filteredTasks = filteredTasks
          .where((item) => item.projectId == _projectFilterId)
          .toList(growable: false);
    }
    filteredTasks = _sortTasks(filteredTasks);
    final filterLabel = switch (_activeFilter) {
      _TaskFeedFilter.today => '今天',
      _TaskFeedFilter.upcoming => '接下来',
      _TaskFeedFilter.completed => '已完成',
    };

    final body = CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: _TodoHeroCard(store: store),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                Text(
                  '项目',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Wrap(
                  spacing: 4,
                  children: [
                    if (store.activeProjects.length > 1)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF6E63F6),
                          backgroundColor: const Color(0xFFF1EEFF),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        onPressed: _openProjectSorter,
                        icon: const Icon(Icons.swap_vert_rounded, size: 18),
                        label: const Text('排序'),
                      ),
                    if (store.archivedProjects.isNotEmpty)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF7B8496),
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        onPressed: _openArchivedProjects,
                        icon: const Icon(Icons.inventory_2_outlined, size: 18),
                        label: Text('已归档 ${store.archivedProjects.length}'),
                      ),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF7C4DFF),
                        backgroundColor: const Color(0xFFF3EEFF),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      onPressed: () => _openProjectEditor(),
                      icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                      label: const Text('管理项目'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _ProjectBoard(
              projects: store.activeProjects,
              pendingCountForProject: store.pendingCountForProject,
              dueTodayCountForProject: store.dueTodayCountForProject,
              onTap: _openProject,
              onEdit: (project) => _openProjectEditor(project: project),
              onReorder: (oldIndex, newIndex) =>
                  context.read<TodoStore>().reorderProjects(oldIndex, newIndex),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            child: Row(
              children: [
                Text(
                  filterLabel,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  '${filteredTasks.length} 项',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: _TaskFeedFilterBar(
              activeFilter: _activeFilter,
              onChanged: (value) => setState(() => _activeFilter = value),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: _TaskToolbar(
              projects: store.activeProjects,
              selectedProjectId: _projectFilterId,
              sortMode: _sortMode,
              onProjectChanged: (value) => setState(() => _projectFilterId = value),
              onSortChanged: (value) => setState(() => _sortMode = value),
            ),
          ),
        ),
        if (filteredTasks.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _EmptyCard(
                title: '$filterLabel这里空空的',
                subtitle: '要不要顺手补一个新的小目标？',
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
            sliver: SliverList.builder(
              itemCount: filteredTasks.length,
              itemBuilder: (context, index) {
                final task = filteredTasks[index];
                final project = store.projects.firstWhere(
                  (item) => item.id == task.projectId,
                );
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _TaskTile(
                    task: task,
                    project: project,
                    onChanged: (value) => store.toggleTask(task.id, value),
                    onTap: () => _openEditor(task: task),
                    onDelete: () => store.deleteTask(task.id),
                  ),
                );
              },
            ),
          ),
      ],
    );

    if (widget.embedded) {
      return Stack(
        children: [
          body,
          Positioned(
            right: 18,
            bottom: 18,
            child: _AddTaskFab(onTap: () => _openEditor()),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(
        title: const Text('待办'),
        actions: [
          if (store.activeProjects.length > 1)
            IconButton(
              onPressed: _openProjectSorter,
              icon: const Icon(Icons.swap_vert_rounded),
              tooltip: '调整项目顺序',
            ),
          if (store.archivedProjects.isNotEmpty)
            IconButton(
              onPressed: _openArchivedProjects,
              icon: const Icon(Icons.inventory_2_outlined),
              tooltip: '已归档项目',
            ),
          IconButton(
            onPressed: () => _openProjectEditor(),
            icon: const Icon(Icons.dashboard_customize_rounded),
            tooltip: '管理项目',
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _AddTaskFab(onTap: () => _openEditor(), compact: true),
          ),
        ],
      ),
      body: body,
      floatingActionButton: _AddTaskFab(onTap: () => _openEditor()),
    );
  }

  void _openProject(TodoProject project) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ProjectDetailScreen(project: project),
      ),
    );
  }

  Future<void> _openProjectSorter() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const _ProjectSorterSheet(),
    );
  }

  void _openArchivedProjects() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const _ArchivedProjectsScreen(),
      ),
    );
  }

  Future<void> _openProjectEditor({TodoProject? project}) async {
    final store = context.read<TodoStore>();
    final result = await showModalBottomSheet<_ProjectEditorResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ProjectEditorSheet(project: project),
    );
    if (result == null) return;
    await store.saveProject(
      TodoProject(
        id: project?.id ?? _uuid.v4(),
        name: result.name,
        iconCodePoint: result.iconData.codePoint,
        colorValue: result.color.toARGB32(),
        description: result.description,
        sortOrder: project?.sortOrder ?? store.projects.length,
        archived: result.archived,
        createdAt: project?.createdAt ?? DateTime.now(),
        updatedAt: project?.updatedAt ?? DateTime.now(),
      ),
    );
  }

  List<TodoTask> _sortTasks(List<TodoTask> input) {
    final tasks = input.toList(growable: false);
    switch (_sortMode) {
      case _TaskSortMode.smart:
        return tasks;
      case _TaskSortMode.dueSoon:
        return tasks.toList(growable: false)
          ..sort((a, b) {
            if (a.dueAt == null && b.dueAt == null) return 0;
            if (a.dueAt == null) return 1;
            if (b.dueAt == null) return -1;
            return a.dueAt!.compareTo(b.dueAt!);
          });
      case _TaskSortMode.priority:
        return tasks.toList(growable: false)
          ..sort((a, b) => b.priority.index.compareTo(a.priority.index));
    }
  }

  Future<void> _openEditor({TodoTask? task}) async {
    final store = context.read<TodoStore>();
    final subtasks =
        task == null ? const <TodoSubtask>[] : await store.subtasksForTask(task.id);
    if (!mounted) return;
    final result = await showModalBottomSheet<_TaskEditorResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _TaskEditorSheet(task: task, initialSubtasks: subtasks),
    );
    if (result == null) return;
    if (result.deleteTask && task != null) {
      await store.deleteTask(task.id);
      return;
    }
    final taskId = task?.id ?? _uuid.v4();
    final completedSubtasks =
        result.subtasks.where((item) => item.isCompleted).length;
    final shouldAutoComplete =
        result.subtasks.isNotEmpty && completedSubtasks == result.subtasks.length;
    await store.saveTask(
      TodoTask(
        id: taskId,
        projectId: result.projectId,
        title: result.title,
        description: result.description,
        priority: result.priority,
        status: shouldAutoComplete
            ? TodoStatus.done
            : task?.status ?? TodoStatus.todo,
        dueAt: result.dueAt,
        reminderAt: result.reminderAt,
        createdAt: task?.createdAt,
        updatedAt: task?.updatedAt,
        completedAt: shouldAutoComplete
            ? (task?.completedAt ?? DateTime.now())
            : task?.completedAt,
        subtaskCount: result.subtasks.length,
        completedSubtaskCount: completedSubtasks,
      ),
      subtasks: result.subtasks
          .map((item) => item.copyWith(taskId: taskId))
          .toList(growable: false),
    );
  }
}

class _TodoHeroCard extends StatelessWidget {
  const _TodoHeroCard({required this.store});

  final TodoStore store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF8E73FF), Color(0xFFB08CFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(30),
        boxShadow: const [
          BoxShadow(
            color: Color(0x268E73FF),
            blurRadius: 28,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '待办',
            style: theme.textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '把今天慢慢做完，我在这陪你收拾节奏。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFFF4EFFF),
              height: 1.55,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _HeroStat(
                  label: '待处理',
                  value: store.totalPendingCount.toString(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _HeroStat(
                  label: '今天',
                  value: store.totalDueTodayCount.toString(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _HeroStat(
                  label: '完成',
                  value: store.totalCompletedCount.toString(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0x26FFFFFF),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFFF2EDFF),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskFeedFilterBar extends StatelessWidget {
  const _TaskFeedFilterBar({
    required this.activeFilter,
    required this.onChanged,
  });

  final _TaskFeedFilter activeFilter;
  final ValueChanged<_TaskFeedFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _FilterChip(
            label: '今天',
            selected: activeFilter == _TaskFeedFilter.today,
            onTap: () => onChanged(_TaskFeedFilter.today),
          ),
          const SizedBox(width: 10),
          _FilterChip(
            label: '接下来',
            selected: activeFilter == _TaskFeedFilter.upcoming,
            onTap: () => onChanged(_TaskFeedFilter.upcoming),
          ),
          const SizedBox(width: 10),
          _FilterChip(
            label: '已完成',
            selected: activeFilter == _TaskFeedFilter.completed,
            onTap: () => onChanged(_TaskFeedFilter.completed),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF7C4DFF) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(
              color: Color(0x081F2430),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFF6F7890),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _TaskToolbar extends StatelessWidget {
  const _TaskToolbar({
    required this.projects,
    required this.selectedProjectId,
    required this.sortMode,
    required this.onProjectChanged,
    required this.onSortChanged,
  });

  final List<TodoProject> projects;
  final String? selectedProjectId;
  final _TaskSortMode sortMode;
  final ValueChanged<String?> onProjectChanged;
  final ValueChanged<_TaskSortMode> onSortChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _FilterChip(
                label: '全部项目',
                selected: selectedProjectId == null,
                onTap: () => onProjectChanged(null),
              ),
              for (final project in projects) ...[
                const SizedBox(width: 10),
                _FilterChip(
                  label: project.name,
                  selected: selectedProjectId == project.id,
                  onTap: () => onProjectChanged(project.id),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _FilterChip(
                label: '智能排序',
                selected: sortMode == _TaskSortMode.smart,
                onTap: () => onSortChanged(_TaskSortMode.smart),
              ),
              const SizedBox(width: 10),
              _FilterChip(
                label: '最近到期',
                selected: sortMode == _TaskSortMode.dueSoon,
                onTap: () => onSortChanged(_TaskSortMode.dueSoon),
              ),
              const SizedBox(width: 10),
              _FilterChip(
                label: '优先级',
                selected: sortMode == _TaskSortMode.priority,
                onTap: () => onSortChanged(_TaskSortMode.priority),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProjectBoard extends StatelessWidget {
  const _ProjectBoard({
    required this.projects,
    required this.pendingCountForProject,
    required this.dueTodayCountForProject,
    required this.onTap,
    required this.onEdit,
    required this.onReorder,
  });

  final List<TodoProject> projects;
  final int Function(String projectId) pendingCountForProject;
  final int Function(String projectId) dueTodayCountForProject;
  final ValueChanged<TodoProject> onTap;
  final ValueChanged<TodoProject> onEdit;
  final Future<void> Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 172,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.only(right: 4),
        itemCount: projects.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final project = projects[index];
          return SizedBox(
            width: 176,
            child: _ProjectCard(
              project: project,
              pendingCount: pendingCountForProject(project.id),
              dueTodayCount: dueTodayCountForProject(project.id),
              onTap: () => onTap(project),
              onEdit: () => onEdit(project),
            ),
          );
        },
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.pendingCount,
    required this.dueTodayCount,
    required this.onTap,
    required this.onEdit,
  });

  final TodoProject project;
  final int pendingCount;
  final int dueTodayCount;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final color = Color(project.colorValue);
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A1F2430),
                blurRadius: 24,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            color.withValues(alpha: 0.22),
                            color.withValues(alpha: 0.10),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Icon(
                        _projectIconFromCodePoint(project.iconCodePoint),
                        color: color,
                        size: 26,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: onEdit,
                      borderRadius: BorderRadius.circular(999),
                      child: Ink(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF6F4FF),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Icon(
                          Icons.edit_outlined,
                          size: 17,
                          color: Color(0xFF7B6CF6),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  project.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF2D3443),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  project.description.isEmpty ? '慢慢把这一块收拾好。' : project.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF8F99AD),
                    height: 1.35,
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF7F8FC),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$pendingCount',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: const Color(0xFF2D3443),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '未完成',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF8F99AD),
                                fontSize: desktopAdjustedFontSize(10),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$dueTodayCount',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: color,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '今日到期',
                              style: TextStyle(
                                color: color,
                                fontSize: desktopAdjustedFontSize(10),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.project,
    required this.onChanged,
    required this.onTap,
    this.onDelete,
    this.showProjectPill = true,
  });

  final TodoTask task;
  final TodoProject project;
  final ValueChanged<bool> onChanged;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final bool showProjectPill;

  @override
  Widget build(BuildContext context) {
    final color = Color(project.colorValue);
    final theme = Theme.of(context);
    final dueTone = _dueTone(task.dueAt, isDone: task.isDone);
    final card = Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: dueTone == null
                ? null
                : Border.all(
                    color: dueTone.color.withValues(alpha: 0.24),
                  ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A1F2430),
                blurRadius: 18,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              Transform.scale(
                scale: 0.94,
                child: Checkbox(
                  value: task.isDone,
                  onChanged: (value) => onChanged(value ?? false),
                  activeColor: color,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        decoration:
                            task.isDone ? TextDecoration.lineThrough : null,
                        color:
                            task.isDone
                                ? const Color(0xFF9BA4B5)
                                : const Color(0xFF2D3443),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (showProjectPill)
                          _MiniPill(
                            label: project.name,
                            color: color,
                            filled: true,
                            icon: Icons.folder_open_rounded,
                          ),
                        if (task.dueAt != null)
                          _MiniPill(
                            label: dueTone?.label ?? _formatDue(task.dueAt!),
                            color: dueTone?.color ?? const Color(0xFF98A1B3),
                            filled: dueTone != null,
                            icon: dueTone != null ? Icons.timelapse_rounded : Icons.schedule_rounded,
                          ),
                        if (task.reminderAt != null)
                          const _MiniPill(
                            label: '已提醒',
                            color: Color(0xFF7B6CF6),
                            icon: Icons.notifications_active_outlined,
                          ),
                        _MiniPill(
                          label: _priorityLabel(task.priority),
                          color: _priorityColor(task.priority),
                          icon: Icons.flag_rounded,
                        ),
                        if (task.subtaskCount > 0)
                          _MiniPill(
                            label:
                                '子任务 ${task.completedSubtaskCount}/${task.subtaskCount}',
                            color: const Color(0xFF7C4DFF),
                            icon: Icons.checklist_rounded,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (onDelete == null) {
      return card;
    }

    return Dismissible(
      key: ValueKey('todo-task-${task.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFEF4444),
          borderRadius: BorderRadius.circular(24),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        onDelete?.call();
        return false;
      },
      child: card,
    );
  }
}

class _MiniPill extends StatelessWidget {
  const _MiniPill({
    required this.label,
    required this.color,
    this.filled = false,
    this.icon,
  });

  final String label;
  final Color color;
  final bool filled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final foreground = filled ? color : const Color(0xFF7B8496);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: 0.14) : const Color(0xFFF4F6FB),
        border: filled ? Border.all(color: color.withValues(alpha: 0.10)) : null,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: desktopAdjustedFontSize(11),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectSorterSheet extends StatelessWidget {
  const _ProjectSorterSheet();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TodoStore>();
    final projects = store.activeProjects;
    final theme = Theme.of(context);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF8F8FD),
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 46,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD9DDEC),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                '调整项目顺序',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '长按拖动，首页会按这个顺序横向展示。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF7B8496),
                ),
              ),
              const SizedBox(height: 18),
              Flexible(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  buildDefaultDragHandles: false,
                  itemCount: projects.length,
                  onReorder: (oldIndex, newIndex) async {
                    final normalizedNewIndex =
                        newIndex > oldIndex ? newIndex - 1 : newIndex;
                    await context.read<TodoStore>().reorderProjects(
                      oldIndex,
                      normalizedNewIndex,
                    );
                  },
                  itemBuilder: (context, index) {
                    final project = projects[index];
                    final color = Color(project.colorValue);
                    return Container(
                      key: ValueKey('project-sort-${project.id}'),
                      margin: EdgeInsets.only(
                        bottom: index == projects.length - 1 ? 0 : 12,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x081F2430),
                            blurRadius: 16,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(
                              IconData(
                                project.iconCodePoint,
                                fontFamily: 'MaterialIcons',
                              ),
                              color: color,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              project.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          ReorderableDragStartListener(
                            index: index,
                            child: const Icon(
                              Icons.drag_indicator_rounded,
                              color: Color(0xFF9AA3B5),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArchivedProjectsScreen extends StatelessWidget {
  const _ArchivedProjectsScreen();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TodoStore>();
    final archivedProjects = store.archivedProjects;

    return Scaffold(
      appBar: AppBar(title: const Text('已归档项目')),
      body: archivedProjects.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(20),
              child: _EmptyCard(
                title: '这里还空着',
                subtitle: '归档的项目会收在这里，想恢复随时都行。',
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              itemCount: archivedProjects.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final project = archivedProjects[index];
                final color = Color(project.colorValue);
                return Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x081F2430),
                        blurRadius: 18,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          IconData(project.iconCodePoint, fontFamily: 'MaterialIcons'),
                          color: color,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              project.name,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              project.description.isEmpty ? '这个项目先收起来了。' : project.description,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () => store.archiveProject(project.id, archived: false),
                        icon: const Icon(Icons.unarchive_outlined),
                        label: const Text('恢复'),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(
            color: Color(0x081F2430),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: const Color(0xFFF2ECFF),
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Icon(
              Icons.sentiment_satisfied_alt_rounded,
              color: Color(0xFF7C4DFF),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
          ),
        ],
      ),
    );
  }
}

class _AddTaskFab extends StatelessWidget {
  const _AddTaskFab({
    required this.onTap,
    this.compact = false,
  });

  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final child = compact
        ? Container(
          width: 42,
          height: 42,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [Color(0xFF8E73FF), Color(0xFFB08CFF)],
            ),
          ),
          child: const Icon(Icons.add_rounded, color: Colors.white),
        )
        : Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF8E73FF), Color(0xFFB08CFF)],
            ),
            borderRadius: BorderRadius.circular(999),
            boxShadow: const [
              BoxShadow(
                color: Color(0x268E73FF),
                blurRadius: 18,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, color: Colors.white),
              SizedBox(width: 6),
              Text(
                '新建任务',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );

    return Material(color: Colors.transparent, child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(999), child: child));
  }
}

class _ProjectEditorResult {
  const _ProjectEditorResult({
    required this.name,
    required this.description,
    required this.iconData,
    required this.color,
    required this.archived,
  });

  final String name;
  final String description;
  final IconData iconData;
  final Color color;
  final bool archived;
}

class _ProjectEditorSheet extends StatefulWidget {
  const _ProjectEditorSheet({this.project});

  final TodoProject? project;

  @override
  State<_ProjectEditorSheet> createState() => _ProjectEditorSheetState();
}

class _ProjectEditorSheetState extends State<_ProjectEditorSheet> {
  static const _iconChoices = <IconData>[
    Icons.work_history_rounded,
    Icons.self_improvement_rounded,
    Icons.home_rounded,
    Icons.favorite_rounded,
    Icons.auto_stories_rounded,
    Icons.palette_rounded,
    Icons.luggage_rounded,
    Icons.spa_rounded,
  ];

  static const _colorChoices = <Color>[
    Color(0xFF6E63F6),
    Color(0xFF55C59A),
    Color(0xFFF08BAF),
    Color(0xFF6FA8FF),
    Color(0xFFFFC768),
    Color(0xFFEF8E66),
    Color(0xFF8D7CFF),
    Color(0xFF7FD1C8),
  ];

  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late IconData _iconData;
  late Color _color;

  @override
  void initState() {
    super.initState();
    final project = widget.project;
    _nameController = TextEditingController(text: project?.name ?? '');
    _descriptionController = TextEditingController(text: project?.description ?? '');
    _iconData = project == null
        ? _iconChoices.first
        : _projectIconFromCodePoint(project.iconCodePoint);
    _color = project == null ? _colorChoices[1] : Color(project.colorValue);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF8F8FD),
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 46,
                    height: 5,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD9DDEC),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.project == null ? '新建项目' : '编辑项目',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(hintText: '比如：健康 / 出行 / 创作'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _descriptionController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: '给这个项目留一句说明。'),
                ),
                const SizedBox(height: 18),
                Text('图标', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final icon in _iconChoices)
                        _SelectableIconChip(
                          icon: icon,
                          selected: _iconData.codePoint == icon.codePoint,
                          color: _color,
                          onTap: () => setState(() => _iconData = icon),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Text('颜色', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final color in _colorChoices)
                        _SelectableColorDot(
                          color: color,
                          selected: _color.toARGB32() == color.toARGB32(),
                          onTap: () => setState(() => _color = color),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                if (widget.project != null) ...[
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _toggleArchived,
                      icon: Icon(
                        widget.project!.archived
                            ? Icons.unarchive_outlined
                            : Icons.archive_outlined,
                      ),
                      label: Text(
                        widget.project!.archived ? '取消归档' : '归档项目',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _submit,
                    child: const Text('保存项目'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toggleArchived() {
    final project = widget.project;
    if (project == null) return;
    Navigator.of(context).pop(
      _ProjectEditorResult(
        name: _nameController.text.trim().isEmpty ? project.name : _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        iconData: _iconData,
        color: _color,
        archived: !project.archived,
      ),
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(
      _ProjectEditorResult(
        name: name,
        description: _descriptionController.text.trim(),
        iconData: _iconData,
        color: _color,
        archived: widget.project?.archived ?? false,
      ),
    );
  }
}

class _SelectableIconChip extends StatelessWidget {
  const _SelectableIconChip({
    required this.icon,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          gradient: selected
              ? LinearGradient(
                  colors: [
                    color.withValues(alpha: 0.24),
                    color.withValues(alpha: 0.08),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: selected ? null : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? color : const Color(0xFFE6EAF4),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Icon(icon, color: selected ? color : const Color(0xFF8A94A8)),
      ),
    );
  }
}

class _SelectableColorDot extends StatelessWidget {
  const _SelectableColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? const Color(0xFF2D3443) : Colors.transparent,
            width: 2,
          ),
        ),
        child: selected
            ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
            : null,
      ),
    );
  }
}

class _ProjectDetailScreen extends StatefulWidget {
  const _ProjectDetailScreen({required this.project});

  final TodoProject project;

  @override
  State<_ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<_ProjectDetailScreen> {
  static const Uuid _uuid = Uuid();

  Future<void> _openProjectEditor({required TodoProject project}) async {
    final store = context.read<TodoStore>();
    final result = await showModalBottomSheet<_ProjectEditorResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ProjectEditorSheet(project: project),
    );
    if (result == null) return;
    await store.saveProject(
      TodoProject(
        id: project.id,
        name: result.name,
        iconCodePoint: result.iconData.codePoint,
        colorValue: result.color.toARGB32(),
        description: result.description,
        sortOrder: project.sortOrder,
        archived: result.archived,
        createdAt: project.createdAt,
        updatedAt: project.updatedAt,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TodoStore>();
    final project = widget.project;
    final refreshedProject = store.projects.firstWhere(
      (item) => item.id == project.id,
      orElse: () => project,
    );
    final tasks = store.tasksForProject(refreshedProject.id);
    final today =
        tasks
            .where((item) => _isSameDay(item.dueAt, DateTime.now()) && !item.isDone)
            .toList(growable: false);
    final upcoming =
        tasks
            .where((item) => !item.isDone && !_isSameDay(item.dueAt, DateTime.now()))
            .toList(growable: false);
    final completed =
        tasks.where((item) => item.isDone).toList(growable: false);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(refreshedProject.name),
        actions: [
          IconButton(
            onPressed: () => _openProjectEditor(project: refreshedProject),
            icon: const Icon(Icons.edit_outlined),
            tooltip: '编辑项目',
          ),
          IconButton(
            onPressed: () => store.archiveProject(
              refreshedProject.id,
              archived: !refreshedProject.archived,
            ),
            icon: Icon(
              refreshedProject.archived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
            ),
            tooltip: refreshedProject.archived ? '取消归档' : '归档项目',
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _AddTaskFab(
              onTap: () => _openEditor(projectId: refreshedProject.id),
              compact: true,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x081F2430),
                  blurRadius: 18,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Color(refreshedProject.colorValue).withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    _projectIconFromCodePoint(refreshedProject.iconCodePoint),
                    color: Color(refreshedProject.colorValue),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        refreshedProject.name,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        refreshedProject.description,
                        style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _TaskSection(
            title: '今天',
            tasks: today,
            project: refreshedProject,
            onToggle: (task, value) => store.toggleTask(task.id, value),
            onEdit: (task) => _openEditor(task: task, projectId: refreshedProject.id),
            onDelete: (task) => store.deleteTask(task.id),
          ),
          const SizedBox(height: 20),
          _TaskSection(
            title: '接下来',
            tasks: upcoming,
            project: refreshedProject,
            onToggle: (task, value) => store.toggleTask(task.id, value),
            onEdit: (task) => _openEditor(task: task, projectId: refreshedProject.id),
            onDelete: (task) => store.deleteTask(task.id),
          ),
          const SizedBox(height: 20),
          _TaskSection(
            title: '已完成',
            tasks: completed,
            project: refreshedProject,
            onToggle: (task, value) => store.toggleTask(task.id, value),
            onEdit: (task) => _openEditor(task: task, projectId: refreshedProject.id),
            onDelete: (task) => store.deleteTask(task.id),
          ),
        ],
      ),
    );
  }

  Future<void> _openEditor({TodoTask? task, required String projectId}) async {
    final store = context.read<TodoStore>();
    final subtasks =
        task == null ? const <TodoSubtask>[] : await store.subtasksForTask(task.id);
    if (!mounted) return;
    final result = await showModalBottomSheet<_TaskEditorResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _TaskEditorSheet(
        task: task,
        initialProjectId: projectId,
        initialSubtasks: subtasks,
      ),
    );
    if (result == null) return;
    if (result.deleteTask && task != null) {
      await store.deleteTask(task.id);
      return;
    }
    final taskId = task?.id ?? _uuid.v4();
    final completedSubtasks =
        result.subtasks.where((item) => item.isCompleted).length;
    final shouldAutoComplete =
        result.subtasks.isNotEmpty && completedSubtasks == result.subtasks.length;
    await store.saveTask(
      TodoTask(
        id: taskId,
        projectId: result.projectId,
        title: result.title,
        description: result.description,
        priority: result.priority,
        status: shouldAutoComplete
            ? TodoStatus.done
            : task?.status ?? TodoStatus.todo,
        dueAt: result.dueAt,
        reminderAt: result.reminderAt,
        createdAt: task?.createdAt,
        updatedAt: task?.updatedAt,
        completedAt: shouldAutoComplete
            ? (task?.completedAt ?? DateTime.now())
            : task?.completedAt,
        subtaskCount: result.subtasks.length,
        completedSubtaskCount: completedSubtasks,
      ),
      subtasks: result.subtasks
          .map((item) => item.copyWith(taskId: taskId))
          .toList(growable: false),
    );
  }
}

class _TaskSection extends StatelessWidget {
  const _TaskSection({
    required this.title,
    required this.tasks,
    required this.project,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final String title;
  final List<TodoTask> tasks;
  final TodoProject project;
  final Future<void> Function(TodoTask task, bool value) onToggle;
  final Future<void> Function(TodoTask task) onEdit;
  final Future<void> Function(TodoTask task) onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 12),
        if (tasks.isEmpty)
          _EmptyCard(title: '$title 暂时空着', subtitle: '留白也挺好。')
        else
          ...tasks.map(
            (task) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _TaskTile(
                task: task,
                project: project,
                showProjectPill: false,
                onChanged: (value) => onToggle(task, value),
                onTap: () => onEdit(task),
                onDelete: () => onDelete(task),
              ),
            ),
          ),
      ],
    );
  }
}

class _TaskEditorSheet extends StatefulWidget {
  const _TaskEditorSheet({
    this.task,
    this.initialProjectId,
    this.initialSubtasks = const [],
  });

  final TodoTask? task;
  final String? initialProjectId;
  final List<TodoSubtask> initialSubtasks;

  @override
  State<_TaskEditorSheet> createState() => _TaskEditorSheetState();
}

class _TaskEditorSheetState extends State<_TaskEditorSheet> {
  static const Uuid _uuid = Uuid();

  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late String _projectId;
  late TodoPriority _priority;
  late List<TodoSubtaskDraft> _subtasks;
  DateTime? _dueAt;
  DateTime? _reminderAt;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _titleController = TextEditingController(text: task?.title ?? '');
    _descriptionController = TextEditingController(text: task?.description ?? '');
    _projectId = task?.projectId ?? widget.initialProjectId ?? 'work';
    _priority = task?.priority ?? TodoPriority.medium;
    _dueAt = task?.dueAt;
    _reminderAt = task?.reminderAt;
    _subtasks = widget.initialSubtasks
        .map(
          (item) => TodoSubtaskDraft(
            id: item.id,
            title: item.title,
            isCompleted: item.isCompleted,
            createdAt: item.createdAt,
          ),
        )
        .toList(growable: true);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final projects = context.watch<TodoStore>().projects;
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF8F8FD),
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 46,
                    height: 5,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD9DDEC),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.task == null ? '新建任务' : '编辑任务',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _titleController,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '比如：整理今天的开发计划'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _descriptionController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(hintText: '备注一点细节，会更从容。'),
                ),
                const SizedBox(height: 18),
                Text('所属项目', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final project in projects)
                      ChoiceChip(
                        label: Text(project.name),
                        selected: _projectId == project.id,
                        onSelected: (_) => setState(() => _projectId = project.id),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text('优先级', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  children: [
                    for (final priority in TodoPriority.values)
                      ChoiceChip(
                        label: Text(_priorityLabel(priority)),
                        selected: _priority == priority,
                        onSelected: (_) => setState(() => _priority = priority),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text('时间', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                InkWell(
                  onTap: _pickDueAt,
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.schedule_rounded, color: Color(0xFF7C4DFF)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _dueAt == null ? '还没定时间' : _formatDue(_dueAt!, withDate: true),
                            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (_dueAt != null)
                          IconButton(
                            onPressed: () => setState(() => _dueAt = null),
                            icon: const Icon(Icons.close_rounded),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text('提醒', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                InkWell(
                  onTap: _pickReminderAt,
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.notifications_active_outlined, color: Color(0xFF7C4DFF)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _reminderAt == null
                                ? '暂时不提醒'
                                : _formatDue(_reminderAt!, withDate: true),
                            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (_reminderAt != null)
                          IconButton(
                            onPressed: () => setState(() => _reminderAt = null),
                            icon: const Icon(Icons.close_rounded),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text('子任务', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      for (var index = 0; index < _subtasks.length; index++)
                        Padding(
                          padding: EdgeInsets.only(bottom: index == _subtasks.length - 1 ? 0 : 10),
                          child: _SubtaskDraftTile(
                            draft: _subtasks[index],
                            onChanged: (draft) => setState(() => _subtasks[index] = draft),
                            onDelete: () => setState(() => _subtasks.removeAt(index)),
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _addSubtask,
                          icon: const Icon(Icons.add_task_rounded),
                          label: const Text('添加子任务'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    if (widget.task != null)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.of(context).pop(
                              const _TaskEditorResult.delete(),
                            );
                          },
                          child: const Text('删除'),
                        ),
                      ),
                    if (widget.task != null) const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: _submit,
                        child: const Text('保存'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickDueAt() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dueAt ?? now),
    );
    if (!mounted) return;
    setState(() {
      _dueAt = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? 9,
        time?.minute ?? 0,
      );
    });
  }

  Future<void> _pickReminderAt() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _reminderAt ?? _dueAt ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_reminderAt ?? _dueAt ?? now),
    );
    if (!mounted) return;
    setState(() {
      _reminderAt = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? 9,
        time?.minute ?? 0,
      );
    });
  }

  void _submit() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop(
      _TaskEditorResult(
        title: title,
        description: _descriptionController.text.trim(),
        projectId: _projectId,
        priority: _priority,
        dueAt: _dueAt,
        reminderAt: _reminderAt,
        deleteTask: false,
        subtasks: _subtasks
            .map(
              (item) => TodoSubtask(
                id: item.id,
                taskId: widget.task?.id ?? '',
                title: item.title.trim(),
                isCompleted: item.isCompleted,
                sortOrder: 0,
                createdAt: item.createdAt,
              ),
            )
            .where((item) => item.title.trim().isNotEmpty)
            .toList(growable: false),
      ),
    );
  }

  void _addSubtask() {
    setState(() {
      _subtasks.add(TodoSubtaskDraft(id: _uuid.v4()));
    });
  }
}

class _TaskEditorResult {
  const _TaskEditorResult({
    required this.title,
    required this.description,
    required this.projectId,
    required this.priority,
    required this.dueAt,
    required this.reminderAt,
    required this.deleteTask,
    required this.subtasks,
  });

  const _TaskEditorResult.delete()
    : title = '',
      description = '',
      projectId = '',
      priority = TodoPriority.medium,
      dueAt = null,
      reminderAt = null,
      deleteTask = true,
      subtasks = const [];

  final String title;
  final String description;
  final String projectId;
  final TodoPriority priority;
  final DateTime? dueAt;
  final DateTime? reminderAt;
  final bool deleteTask;
  final List<TodoSubtask> subtasks;
}

const Object _editorSentinel = Object();

class TodoSubtaskDraft {
  const TodoSubtaskDraft({
    required this.id,
    this.title = '',
    this.isCompleted = false,
    this.createdAt,
  });

  final String id;
  final String title;
  final bool isCompleted;
  final DateTime? createdAt;

  TodoSubtaskDraft copyWith({
    String? id,
    String? title,
    bool? isCompleted,
    Object? createdAt = _editorSentinel,
  }) {
    return TodoSubtaskDraft(
      id: id ?? this.id,
      title: title ?? this.title,
      isCompleted: isCompleted ?? this.isCompleted,
      createdAt:
          identical(createdAt, _editorSentinel)
              ? this.createdAt
              : createdAt as DateTime?,
    );
  }
}

class _SubtaskDraftTile extends StatelessWidget {
  const _SubtaskDraftTile({
    required this.draft,
    required this.onChanged,
    required this.onDelete,
  });

  final TodoSubtaskDraft draft;
  final ValueChanged<TodoSubtaskDraft> onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Checkbox(
          value: draft.isCompleted,
          onChanged: (value) => onChanged(
            draft.copyWith(isCompleted: value ?? false),
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        Expanded(
          child: TextField(
            controller: TextEditingController(text: draft.title)
              ..selection = TextSelection.collapsed(offset: draft.title.length),
            onChanged: (value) => onChanged(draft.copyWith(title: value)),
            decoration: const InputDecoration(
              hintText: '拆一个更小的动作',
              isDense: true,
              border: InputBorder.none,
            ),
          ),
        ),
        IconButton(
          onPressed: onDelete,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }
}

IconData _projectIconFromCodePoint(int codePoint) {
  for (final icon in _ProjectEditorSheetState._iconChoices) {
    if (icon.codePoint == codePoint) {
      return icon;
    }
  }
  return Icons.auto_awesome_rounded;
}

String _priorityLabel(TodoPriority priority) {
  switch (priority) {
    case TodoPriority.low:
      return '低优先';
    case TodoPriority.medium:
      return '正常';
    case TodoPriority.high:
      return '重要';
    case TodoPriority.urgent:
      return '紧急';
  }
}

Color _priorityColor(TodoPriority priority) {
  switch (priority) {
    case TodoPriority.low:
      return const Color(0xFF7BB58D);
    case TodoPriority.medium:
      return const Color(0xFF7C4DFF);
    case TodoPriority.high:
      return const Color(0xFFF59E0B);
    case TodoPriority.urgent:
      return const Color(0xFFEF4444);
  }
}

class _DueTone {
  const _DueTone({required this.label, required this.color});

  final String label;
  final Color color;
}

_DueTone? _dueTone(DateTime? dueAt, {required bool isDone}) {
  if (dueAt == null || isDone) return null;
  final now = DateTime.now();
  final startOfToday = DateTime(now.year, now.month, now.day);
  final startOfDueDay = DateTime(dueAt.year, dueAt.month, dueAt.day);
  final diffDays = startOfDueDay.difference(startOfToday).inDays;

  if (dueAt.isBefore(now) && diffDays <= 0) {
    return const _DueTone(label: '已逾期', color: Color(0xFFEF4444));
  }
  if (diffDays == 0) {
    return const _DueTone(label: '今天截止', color: Color(0xFFF59E0B));
  }
  if (diffDays == 1) {
    return const _DueTone(label: '明天截止', color: Color(0xFF3B82F6));
  }
  return null;
}

String _formatDue(DateTime dueAt, {bool withDate = false}) {
  final now = DateTime.now();
  final isToday = _isSameDay(dueAt, now);
  final mm = dueAt.month.toString().padLeft(2, '0');
  final dd = dueAt.day.toString().padLeft(2, '0');
  final hh = dueAt.hour.toString().padLeft(2, '0');
  final min = dueAt.minute.toString().padLeft(2, '0');
  if (!withDate && isToday) {
    return '今天 $hh:$min';
  }
  return '${isToday ? '今天' : '$mm/$dd'} $hh:$min';
}

bool _isSameDay(DateTime? a, DateTime b) {
  if (a == null) return false;
  return a.year == b.year && a.month == b.month && a.day == b.day;
}
