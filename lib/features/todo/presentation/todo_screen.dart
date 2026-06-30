import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme.dart';
import '../../habits/application/habits_store.dart';
import '../../habits/domain/habits_models.dart';
import '../../habits/presentation/habits_widgets.dart';
import '../application/todo_store.dart';
import '../domain/todo_models.dart';

class TodoScreen extends StatefulWidget {
  const TodoScreen({
    super.key,
    this.embedded = false,
    this.projectConfigOnly = false,
  });

  final bool embedded;
  final bool projectConfigOnly;

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

enum _TaskFeedFilter { all, today, upcoming }

enum _TaskSortMode { smart, dueSoon, priority }

class _TodoScreenState extends State<TodoScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  static const Uuid _uuid = Uuid();
  static const Duration _autoRefreshInterval = Duration(seconds: 45);

  late final String _heroMessage;
  _TaskFeedFilter _activeFilter = _TaskFeedFilter.all;
  _TaskSortMode _sortMode = _TaskSortMode.smart;
  String? _projectFilterId;
  DateTime? _lastAutoRefreshAt;
  bool _refreshInFlight = false;
  bool _autoRefreshQueued = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _heroMessage =
        _todoHeroMessages[Random().nextInt(_todoHeroMessages.length)];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshTodo(forceRemote: true, markAutoRefresh: true));
      final habitsStore = context.read<HabitsStore>();
      unawaited(habitsStore.ensureLoaded());
    });
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    _scheduleAutoRefresh(force: true);
    if (mounted) {
      unawaited(context.read<HabitsStore>().refreshFromRemote(force: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final store = context.watch<TodoStore>();
    final theme = Theme.of(context);

    if (widget.projectConfigOnly) {
      return _ProjectManagementScreen(
        onOpenProjectEditor:
            ({project}) => _openProjectEditor(project: project),
        onOpenProjectSorter: _openProjectSorter,
        onOpenArchivedProjects: _openArchivedProjects,
      );
    }

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

    _scheduleAutoRefresh();
    final habitsStore = context.watch<HabitsStore>();

    var filteredTasks = switch (_activeFilter) {
      _TaskFeedFilter.all => store.tasks
          .where(
            (item) =>
                !item.isDone &&
                !store.archivedProjects.any(
                  (project) => project.id == item.projectId,
                ),
          )
          .toList(growable: false),
      _TaskFeedFilter.today => store.todayTasks,
      _TaskFeedFilter.upcoming => store.upcomingTasks,
    };
    if (_projectFilterId != null) {
      filteredTasks = filteredTasks
          .where((item) => item.projectId == _projectFilterId)
          .toList(growable: false);
    }
    filteredTasks = _sortTasks(filteredTasks);
    final filterLabel = switch (_activeFilter) {
      _TaskFeedFilter.all => '全部',
      _TaskFeedFilter.today => '今天',
      _TaskFeedFilter.upcoming => '未来',
    };

    final body = RefreshIndicator(
      onRefresh: () => _refreshTodo(forceRemote: true, markAutoRefresh: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
              child: _TodoHeroCard(
                store: store,
                message: _heroMessage,
                onOpenCompleted: _openCompletedTasks,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: _PomodoroPlanSummaryCard(onOpen: _openPomodoroPlan),
            ),
          ),
          SliverToBoxAdapter(child: _buildInlineHabitsSection(habitsStore)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
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
              child: _TaskToolbar(
                activeFilter: _activeFilter,
                projects: store.activeProjects,
                selectedProjectId: _projectFilterId,
                sortMode: _sortMode,
                onFilterChanged:
                    (value) => setState(() => _activeFilter = value),
                onProjectChanged:
                    (value) => setState(() => _projectFilterId = value),
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
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      final offsetAnimation = Tween<Offset>(
                        begin: const Offset(0, 0.08),
                        end: Offset.zero,
                      ).animate(animation);
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: offsetAnimation,
                          child: child,
                        ),
                      );
                    },
                    child: Padding(
                      key: ValueKey(
                        'task-row-${task.id}-${task.isDone}-${_activeFilter.name}',
                      ),
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _TaskTile(
                        task: task,
                        project: project,
                        onChanged: (value) => store.toggleTask(task.id, value),
                        onTap: () => _openEditor(task: task),
                        onDelete: () => store.deleteTask(task.id),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );

    if (widget.embedded) {
      return Stack(
        children: [
          body,
          Positioned(
            right: 18,
            bottom: 18,
            child: _AddEntryFab(
              onAddTask: () => _openEditor(),
              onAddHabit: _openHabitEditor,
            ),
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
            onPressed: _openPomodoroPlan,
            icon: const Icon(Icons.playlist_add_check_rounded),
            tooltip: '番茄计划',
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _AddEntryFab(
              onAddTask: () => _openEditor(),
              onAddHabit: _openHabitEditor,
              compact: true,
            ),
          ),
        ],
      ),
      body: body,
      floatingActionButton: _AddEntryFab(
        onAddTask: () => _openEditor(),
        onAddHabit: _openHabitEditor,
      ),
    );
  }

  Widget _buildInlineHabitsSection(HabitsStore habitsStore) {
    final habits = habitsStore.habits.where((habit) => habit.dueToday).toList();
    final doneCount =
        habits
            .where((habit) => habit.todayInstance?.isCompleted ?? false)
            .length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '今日习惯',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              Text(
                '$doneCount/${habits.length}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF7B8496),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _openHabitEditor,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('习惯'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (habitsStore.isLoading && !habitsStore.isLoaded)
            const _InlineHabitPlaceholder()
          else if (habits.isEmpty)
            _InlineHabitEmptyCard(onCreate: _openHabitEditor)
          else
            ...habits.map(
              (habit) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: HabitCard(
                  habit: habit,
                  onToggle: () => unawaited(_toggleHabit(habit)),
                  onEdit: () => _openHabitEditor(habit: habit),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _toggleHabit(Habit habit) async {
    try {
      await context.read<HabitsStore>().toggleHabit(habit.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('习惯打卡失败：$e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _refreshTodo({
    bool forceRemote = false,
    bool markAutoRefresh = false,
  }) async {
    if (!mounted || _refreshInFlight) return;
    _refreshInFlight = true;
    if (markAutoRefresh) {
      _lastAutoRefreshAt = DateTime.now();
    }
    try {
      final store = context.read<TodoStore>();
      await store.ensureLoaded();
      if (forceRemote || store.isLoaded) {
        await store.refreshFromRemote(force: true);
      }
    } finally {
      _refreshInFlight = false;
    }
  }

  void _scheduleAutoRefresh({bool force = false}) {
    if (!mounted ||
        widget.projectConfigOnly ||
        _refreshInFlight ||
        _autoRefreshQueued) {
      return;
    }
    final now = DateTime.now();
    if (!force &&
        _lastAutoRefreshAt != null &&
        now.difference(_lastAutoRefreshAt!) < _autoRefreshInterval) {
      return;
    }
    _autoRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoRefreshQueued = false;
      if (!mounted) return;
      unawaited(_refreshTodo(forceRemote: true, markAutoRefresh: true));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
      MaterialPageRoute<void>(builder: (_) => const _ArchivedProjectsScreen()),
    );
  }

  void _openCompletedTasks() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const _CompletedTasksScreen()),
    );
  }

  void _openPomodoroPlan() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const _PomodoroPlanScreen()),
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
        return tasks.toList(growable: false)..sort((a, b) {
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
        task == null
            ? const <TodoSubtask>[]
            : await store.subtasksForTask(task.id);
    if (!mounted) return;
    final result = await showModalBottomSheet<_TaskEditorResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (context) => _TaskEditorSheet(task: task, initialSubtasks: subtasks),
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
        result.subtasks.isNotEmpty &&
        completedSubtasks == result.subtasks.length;
    await store.saveTask(
      TodoTask(
        id: taskId,
        projectId: result.projectId,
        title: result.title,
        description: result.description,
        priority: result.priority,
        status:
            shouldAutoComplete
                ? TodoStatus.done
                : task?.status ?? TodoStatus.todo,
        dueAt: result.dueAt,
        reminderAt: result.reminderAt,
        createdAt: task?.createdAt,
        updatedAt: task?.updatedAt,
        completedAt:
            shouldAutoComplete
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

  Future<void> _openHabitEditor({Habit? habit}) async {
    final habitsStore = context.read<HabitsStore>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (_) => ChangeNotifierProvider<HabitsStore>.value(
            value: habitsStore,
            child: HabitEditorSheet(habit: habit),
          ),
    );
  }
}

class _TodoHeroCard extends StatelessWidget {
  const _TodoHeroCard({
    required this.store,
    required this.message,
    required this.onOpenCompleted,
  });

  final TodoStore store;
  final String message;
  final VoidCallback onOpenCompleted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF8E73FF), Color(0xFFB08CFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x228E73FF),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '待办',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _HeroQuickAction(
                icon: Icons.check_circle_outline_rounded,
                label: '已完成 ${store.totalCompletedCount}',
                onTap: onOpenCompleted,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFFF4EFFF),
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeroInlineStat(
                label: '待处理',
                value: store.totalPendingCount.toString(),
              ),
              _HeroInlineStat(
                label: '今天',
                value: store.totalDueTodayCount.toString(),
              ),
              _HeroInlineStat(
                label: '项目',
                value: store.activeProjects.length.toString(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

const List<String> _todoHeroMessages = [
  '慢慢收拾，别着急。',
  '今天做一点，也是在认真前进。',
  '先完成最小的一步，节奏就会回来。',
  '把眼前这一件做好，已经很厉害。',
  '不用一口气做完，先动起来就很好。',
  '今天稳一点，事情会慢慢顺。',
  '先整理一个角落，心也会亮一点。',
  '不用完美，完成就很有力量。',
  '把复杂拆小，今天就没那么难。',
  '先做最重要的一件，其他再慢慢来。',
  '你不是来硬扛的，是来一点点解决的。',
  '今天能推进一点点，就已经算赢。',
  '给自己留点呼吸，效率反而会回来。',
  '别急着证明什么，先把这一项做完。',
  '把节奏找回来，比一口气冲更重要。',
  '先完成，再优化，先让事情动起来。',
  '心乱的时候，任务更要一个个做。',
  '把今天理顺，明天就会轻很多。',
  '先处理最卡的那件，后面会顺不少。',
  '一件件清掉，负担会明显变轻。',
  '今天不用爆发，稳定就很强。',
  '别被总量吓到，先看下一步。',
  '哪怕只前进一点，也是在变好。',
  '先把眼前这一小块做好。',
  '每完成一项，都会多一点轻松。',
  '你在收拾任务，也是在收拾状态。',
  '做完一件，再做下一件，事情就会散开。',
  '慢一点没关系，别停下就行。',
  '先把最重的包放下来。',
  '有条理地忙，会比着急更快。',
  '不用同时扛所有事，按顺序来。',
  '开始之后，很多压力会自己变小。',
  '你不需要一下变轻松，只要先变清楚。',
  '清掉一条待办，就是给自己松绑。',
  '专心做一件，今天就会更稳。',
  '把今天过扎实，比想太多更重要。',
  '手上这一步，值得你好好完成。',
  '别跟全部较劲，先赢下一格。',
  '现在开始，也一点都不晚。',
  '先做能做的，力量会跟上来。',
  '你不是拖慢了，只是在重新找节奏。',
  '每个小完成，都会积累成轻松。',
  '先把任务落地，情绪会更安稳。',
  '先开个头，很多事就没那么难了。',
  '今天先稳住，不必逞强。',
  '你已经在处理了，这就很重要。',
  '专注一点，世界就会安静一点。',
  '先整理优先级，心会没那么乱。',
  '做完这一项，就离松快更近一点。',
  '先把最想逃的那件碰一下。',
  '不需要超常发挥，正常发挥就很好。',
  '把难的拆开，办法就会出现。',
  '先让列表变短一点。',
  '做事的时候，别忘了对自己温柔一点。',
  '把注意力放回手上的事。',
  '一项一项来，今天会比想象中顺。',
  '先完成眼前，再担心以后。',
  '收拾任务，也是在收拾生活感。',
  '完成一小步，也值得被肯定。',
  '别怕慢，怕的是一直不开始。',
  '先做一件有结果的事。',
  '有些轻松，是清掉待办之后来的。',
  '你现在做的每一步都算数。',
  '先让自己进入状态，速度自然会来。',
  '今天清一项，明天就少一项。',
  '把要做的事摆平，心情也会跟着好一点。',
  '稳稳推进，本身就是一种厉害。',
  '今天先别追求满分，先有进度。',
  '任务不会一下消失，但会慢慢变少。',
  '先做最能减压的那件事。',
  '把一团乱麻理出第一根线。',
  '先给自己一个清晰的开始。',
  '做完一点，就会更想继续做下去。',
  '今天也可以温柔地高效。',
  '别急着全清空，先看得到进展。',
  '把当前这一段路走稳。',
  '每一项完成，都会让你更松一口气。',
  '先减少混乱，再追求漂亮。',
  '清单不是压力，是帮你减压的。',
  '把难的往前放，后面会轻很多。',
  '先把手伸出去，事情才会开始动。',
  '进度再小，也是在把事情往前推。',
  '先做完一个，再说下一个。',
  '不跟焦虑赛跑，跟节奏站一边。',
  '今天做得稳，比做得猛更有用。',
  '别让脑子同时背太多，交给清单。',
  '先把最现实的一步踩稳。',
  '收拾一点，世界就清爽一点。',
  '你可以慢，但别散。',
  '先给今天一个好开头。',
  '事情一件件落下去，心也会落下来。',
  '先把最具体的任务拿下。',
  '一点点来，反而走得更远。',
  '你不是在赶路，你是在稳稳推进。',
  '先完成，再放松，都会轮到的。',
  '别把今天吓大，先把这一格填上。',
  '每次点掉一项，都会更自在一点。',
  '现在开始收拾，刚刚好。',
  '今天也值得一个清爽的结束。',
  '手头清一点，心里也会亮一点。',
  '先别急，先清楚。',
  '把事情变简单，是很高级的能力。',
  '先做出一点结果，信心就会回来。',
  '今天这一页，也能慢慢翻过去。',
];

class _HeroInlineStat extends StatelessWidget {
  const _HeroInlineStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x22FFFFFF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            TextSpan(
              text: '  $label',
              style: const TextStyle(
                color: Color(0xFFF2EDFF),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroQuickAction extends StatelessWidget {
  const _HeroQuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0x22FFFFFF),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
    required this.activeFilter,
    required this.projects,
    required this.selectedProjectId,
    required this.sortMode,
    required this.onFilterChanged,
    required this.onProjectChanged,
    required this.onSortChanged,
  });

  final _TaskFeedFilter activeFilter;
  final List<TodoProject> projects;
  final String? selectedProjectId;
  final _TaskSortMode sortMode;
  final ValueChanged<_TaskFeedFilter> onFilterChanged;
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
                label: '全部',
                selected: activeFilter == _TaskFeedFilter.all,
                onTap: () => onFilterChanged(_TaskFeedFilter.all),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: '今天',
                selected: activeFilter == _TaskFeedFilter.today,
                onTap: () => onFilterChanged(_TaskFeedFilter.today),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: '未来',
                selected: activeFilter == _TaskFeedFilter.upcoming,
                onTap: () => onFilterChanged(_TaskFeedFilter.upcoming),
              ),
              const SizedBox(width: 8),
              _CompactDropdown<String?>(
                value: selectedProjectId,
                hint: '项目',
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('项目'),
                  ),
                  ...projects.map(
                    (project) => DropdownMenuItem<String?>(
                      value: project.id,
                      child: Text(
                        project.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: onProjectChanged,
              ),
              const SizedBox(width: 6),
              _CompactDropdown<_TaskSortMode>(
                value: sortMode,
                hint: '排序',
                items: const [
                  DropdownMenuItem(
                    value: _TaskSortMode.smart,
                    child: Text('智能'),
                  ),
                  DropdownMenuItem(
                    value: _TaskSortMode.dueSoon,
                    child: Text('到期'),
                  ),
                  DropdownMenuItem(
                    value: _TaskSortMode.priority,
                    child: Text('优先'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) onSortChanged(value);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactDropdown<T> extends StatelessWidget {
  const _CompactDropdown({
    required this.value,
    required this.hint,
    required this.items,
    required this.onChanged,
  });

  final T? value;
  final String hint;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [
          BoxShadow(
            color: Color(0x081F2430),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: Text(hint),
          items: items,
          onChanged: onChanged,
          borderRadius: BorderRadius.circular(16),
          style: const TextStyle(
            color: Color(0xFF2D3443),
            fontWeight: FontWeight.w700,
          ),
          dropdownColor: Colors.white,
          icon: const Icon(Icons.expand_more_rounded, color: Color(0xFF7B8496)),
        ),
      ),
    );
  }
}

class _TaskTile extends StatefulWidget {
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
  State<_TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends State<_TaskTile> {
  bool _expanded = false;
  Future<List<TodoSubtask>>? _subtasksFuture;

  Future<void> _toggleExpanded() async {
    if (!_expanded && widget.task.subtaskCount > 0 && _subtasksFuture == null) {
      _subtasksFuture = context.read<TodoStore>().subtasksForTask(
        widget.task.id,
      );
    }
    setState(() {
      _expanded = !_expanded;
    });
  }

  Future<void> _showTaskMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (context) => SafeArea(
            top: false,
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xFFF8F8FD),
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: const Color(0xFFD9DDEC),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(height: 18),
                    ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      tileColor: Colors.white,
                      leading: const Icon(
                        Icons.edit_outlined,
                        color: Color(0xFF7B6CF6),
                      ),
                      title: const Text('编辑任务'),
                      subtitle: const Text('打开完整编辑面板'),
                      onTap: () => Navigator.of(context).pop('edit'),
                    ),
                    if (widget.onDelete != null) ...[
                      const SizedBox(height: 10),
                      ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        tileColor: Colors.white,
                        leading: const Icon(
                          Icons.delete_outline_rounded,
                          color: Color(0xFFEF4444),
                        ),
                        title: const Text('删除任务'),
                        subtitle: const Text('这条任务会从列表里移除'),
                        onTap: () => Navigator.of(context).pop('delete'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
    );
    if (!mounted) return;
    if (action == 'edit') {
      widget.onTap();
    } else if (action == 'delete') {
      widget.onDelete?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final project = widget.project;
    final color = Color(project.colorValue);
    final theme = Theme.of(context);
    final store = context.watch<TodoStore>();
    final activePomodoro = store.activePomodoro;
    final taskPomodoros = store.pomodorosForTask(task.id);
    final taskPomodoroCount =
        taskPomodoros.where((item) => item.isCompletedFocus).length;
    final isPomodoroRunning =
        activePomodoro?.taskId == task.id &&
        activePomodoro?.status == PomodoroStatus.running;
    final dueTone = _dueTone(task.dueAt, isDone: task.isDone);
    final subtitleBits = <Widget>[
      if (widget.showProjectPill)
        _InlineMetaText(text: project.name, color: color),
      if (task.subtaskCount > 0)
        _InlineMetaText(
          text: '${task.completedSubtaskCount}/${task.subtaskCount}',
          color: const Color(0xFF7C4DFF),
        ),
      if (task.dueAt != null)
        _InlineMetaText(
          text: dueTone?.label ?? _formatDue(task.dueAt!),
          color: dueTone?.color ?? const Color(0xFF8F99AD),
        ),
      if (task.priority == TodoPriority.high ||
          task.priority == TodoPriority.urgent)
        _InlineMetaText(
          text: _priorityLabel(task.priority),
          color: _priorityColor(task.priority),
        ),
      if (taskPomodoroCount > 0)
        _InlineMetaText(
          text: '🍅 $taskPomodoroCount',
          color: const Color(0xFFEF7B45),
        ),
      if (isPomodoroRunning)
        _InlineMetaText(
          text:
              '${activePomodoro!.isFocus ? '专注中' : '休息中'} ${_formatCompactDuration(activePomodoro.endsAt.difference(DateTime.now()))}',
          color: const Color(0xFFEF7B45),
        ),
    ];

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: _toggleExpanded,
        onLongPress: _showTaskMenu,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x061F2430),
                blurRadius: 10,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 12, 0),
                child: Row(
                  children: [
                    Container(
                      width: 4,
                      height: 44,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(4),
                        ),
                      ),
                    ),
                    Transform.scale(
                      scale: 0.88,
                      child: Checkbox(
                        value: task.isDone,
                        onChanged: (value) => widget.onChanged(value ?? false),
                        activeColor: color,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              decoration:
                                  task.isDone
                                      ? TextDecoration.lineThrough
                                      : null,
                              color:
                                  task.isDone
                                      ? const Color(0xFF9BA4B5)
                                      : const Color(0xFF2D3443),
                            ),
                          ),
                          if (subtitleBits.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Wrap(
                              spacing: 6,
                              runSpacing: 2,
                              children: subtitleBits,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: const Color(0xFF9AA3B3),
                    ),
                  ],
                ),
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 180),
                crossFadeState:
                    _expanded
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                firstChild: const SizedBox.shrink(),
                secondChild: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: _TaskExpandedBody(
                    task: task,
                    project: project,
                    dueTone: dueTone,
                    subtasksFuture: _subtasksFuture,
                    pomodoros: taskPomodoros,
                    activePomodoro: activePomodoro,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineMetaText extends StatelessWidget {
  const _InlineMetaText({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: desktopAdjustedFontSize(11),
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _TaskExpandedBody extends StatelessWidget {
  const _TaskExpandedBody({
    required this.task,
    required this.project,
    required this.dueTone,
    required this.subtasksFuture,
    required this.pomodoros,
    required this.activePomodoro,
  });

  final TodoTask task;
  final TodoProject project;
  final _DueTone? dueTone;
  final Future<List<TodoSubtask>>? subtasksFuture;
  final List<TodoPomodoro> pomodoros;
  final TodoPomodoro? activePomodoro;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = Color(project.colorValue);
    final metaItems = <Widget>[
      _ExpandedMetaItem(
        icon: Icons.folder_open_rounded,
        label: project.name,
        color: color,
      ),
      if (task.dueAt != null)
        _ExpandedMetaItem(
          icon:
              dueTone != null
                  ? Icons.timelapse_rounded
                  : Icons.schedule_rounded,
          label: dueTone?.label ?? _formatDue(task.dueAt!),
          color: dueTone?.color ?? const Color(0xFF98A1B3),
          emphasized: dueTone != null,
        ),
      if (task.reminderAt != null)
        const _ExpandedMetaItem(
          icon: Icons.notifications_active_outlined,
          label: '已提醒',
          color: Color(0xFF7B6CF6),
        ),
      _ExpandedMetaItem(
        icon: _priorityIcon(task.priority),
        label: _priorityLabel(task.priority),
        color: _priorityColor(task.priority),
        emphasized:
            task.priority == TodoPriority.high ||
            task.priority == TodoPriority.urgent,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, color: Color(0xFFF0F2F7)),
        const SizedBox(height: 10),
        if (task.description.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              task.description.trim(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF667085),
                height: 1.5,
              ),
            ),
          ),
        Wrap(spacing: 12, runSpacing: 8, children: metaItems),
        const SizedBox(height: 12),
        _PomodoroPanel(
          task: task,
          pomodoros: pomodoros,
          activePomodoro: activePomodoro,
        ),
        if (task.subtaskCount > 0) ...[
          const SizedBox(height: 12),
          Text(
            '子任务',
            style: theme.textTheme.labelMedium?.copyWith(
              color: const Color(0xFF8B93A6),
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<TodoSubtask>>(
            future: subtasksFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                );
              }
              final subtasks = snapshot.data!;
              if (subtasks.isEmpty) {
                return Text(
                  '还没有子任务内容',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF98A2B3),
                  ),
                );
              }
              return Column(
                children: subtasks
                    .map(
                      (item) => _SubtaskLine(
                        item: item,
                        isLast: item == subtasks.last,
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
        ],
      ],
    );
  }
}

class _ExpandedMetaItem extends StatelessWidget {
  const _ExpandedMetaItem({
    required this.icon,
    required this.label,
    required this.color,
    this.emphasized = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 13,
          color: emphasized ? color : const Color(0xFF98A2B3),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: emphasized ? color : const Color(0xFF667085),
            fontWeight: emphasized ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _SubtaskLine extends StatelessWidget {
  const _SubtaskLine({required this.item, required this.isLast});

  final TodoSubtask item;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border:
            isLast
                ? null
                : const Border(bottom: BorderSide(color: Color(0xFFF2F4F7))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              item.isCompleted
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 15,
              color:
                  item.isCompleted
                      ? const Color(0xFF7C4DFF)
                      : const Color(0xFFB0B7C6),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.title,
              style: theme.textTheme.bodySmall?.copyWith(
                color:
                    item.isCompleted
                        ? const Color(0xFF98A2B3)
                        : const Color(0xFF475467),
                height: 1.4,
                decoration:
                    item.isCompleted ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PomodoroPanel extends StatefulWidget {
  const _PomodoroPanel({
    required this.task,
    required this.pomodoros,
    required this.activePomodoro,
  });

  final TodoTask task;
  final List<TodoPomodoro> pomodoros;
  final TodoPomodoro? activePomodoro;

  @override
  State<_PomodoroPanel> createState() => _PomodoroPanelState();
}

class _PomodoroPanelState extends State<_PomodoroPanel> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.activePomodoro?.taskId == widget.task.id) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TodoStore>();
    final active = store.activePomodoro;
    final currentTaskActive = active?.taskId == widget.task.id ? active : null;
    final completed =
        widget.pomodoros.where((item) => item.isCompletedFocus).length;
    final minutes = widget.pomodoros
        .where((item) => item.isCompletedFocus)
        .fold<int>(0, (sum, item) => sum + item.focusPlannedMinutes);
    final recent = widget.pomodoros
        .where((item) => item.isCompletedFocus && item.note.trim().isNotEmpty)
        .take(2)
        .toList(growable: false);
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7F0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFDDC2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.timer_outlined,
                size: 17,
                color: Color(0xFFEF7B45),
              ),
              const SizedBox(width: 7),
              Text(
                '专注',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF8A4A22),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Text(
                '🍅 $completed · ${minutes}min',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: const Color(0xFF8A4A22),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (currentTaskActive != null)
            _ActivePomodoroControls(
              task: widget.task,
              pomodoro: currentTaskActive,
            )
          else if (active != null)
            Text(
              '另一个任务正在专注中，先结束那一轮再开始这里。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF99633A),
                height: 1.35,
              ),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () => store.startPomodoro(widget.task.id),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('开始番茄 25min'),
              ),
            ),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final item in recent)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '· ${item.note.trim()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF99633A),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ActivePomodoroControls extends StatelessWidget {
  const _ActivePomodoroControls({required this.task, required this.pomodoro});

  final TodoTask task;
  final TodoPomodoro pomodoro;

  @override
  Widget build(BuildContext context) {
    final store = context.read<TodoStore>();
    final remaining = pomodoro.endsAt.difference(DateTime.now());
    final expired = remaining.inSeconds <= 0;
    final phaseLabel = pomodoro.isFocus ? '工作中' : '休息中';
    final actionLabel =
        pomodoro.isFocus
            ? (expired ? '记录进展' : '提前完成')
            : (expired ? '继续下一轮' : '跳过休息');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              phaseLabel,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: const Color(0xFF8A4A22),
                fontWeight: FontWeight.w800,
              ),
            ),
            const Spacer(),
            Text(
              _formatCompactDuration(remaining),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: const Color(0xFFEF7B45),
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () async {
                if (pomodoro.isFocus) {
                  final note = await _askPomodoroNote(context);
                  if (note == null) return;
                  await store.markPomodoroFocusDone(pomodoro.id, note: note);
                  return;
                }
                await store.completePomodoroBreak(pomodoro.id);
                if (!context.mounted) return;
                if (pomodoro.planItemId != null) {
                  final next = await store.startNextPomodoroPlanItem();
                  if (next != null) return;
                }
                await store.startPomodoro(task.id);
              },
              child: Text(actionLabel),
            ),
            OutlinedButton(
              onPressed: () => store.cancelPomodoro(pomodoro.id),
              child: const Text('放弃'),
            ),
            if (pomodoro.isBreak)
              TextButton(
                onPressed: () => store.completePomodoroBreak(pomodoro.id),
                child: const Text('结束本次'),
              ),
          ],
        ),
      ],
    );
  }
}

class _PomodoroPlanSummaryCard extends StatelessWidget {
  const _PomodoroPlanSummaryCard({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TodoStore>();
    final items = store.pomodoroPlanItems;
    final total = items.length;
    final completed = store.completedPomodoroPlanCount;
    final next = _nextOpenPlanItem(items);
    final task = next == null ? null : _taskById(store.tasks, next.taskId);
    final theme = Theme.of(context);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFECEFF6)),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF0E7),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.playlist_add_check_rounded,
                  color: Color(0xFFEF7B45),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '番茄计划',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          total == 0 ? '未规划' : '$completed/$total',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: const Color(0xFFEF7B45),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      next == null
                          ? '给接下来的专注排个队。'
                          : '${task?.title ?? '未选择任务'} · ${next.estimatedGoal.isEmpty ? '还没写目标' : next.estimatedGoal}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF7B8496),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF98A2B3)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PomodoroPlanScreen extends StatefulWidget {
  const _PomodoroPlanScreen();

  @override
  State<_PomodoroPlanScreen> createState() => _PomodoroPlanScreenState();
}

class _PomodoroPlanScreenState extends State<_PomodoroPlanScreen> {
  static const Duration _scheduleRefreshInterval = Duration(seconds: 1);

  static const Uuid _uuid = Uuid();

  Timer? _scheduleTimer;
  DateTime _scheduleAnchor = DateTime.now();
  String? _lastExpiredBreakPromptId;

  @override
  void initState() {
    super.initState();
    _scheduleTimer = Timer.periodic(
      _scheduleRefreshInterval,
      (_) => _refreshSchedule(),
    );
  }

  @override
  void dispose() {
    _scheduleTimer?.cancel();
    super.dispose();
  }

  void _refreshSchedule() {
    if (!mounted) return;
    final previousPromptId = _lastExpiredBreakPromptId;
    setState(() => _scheduleAnchor = DateTime.now());
    final active = context.read<TodoStore>().activePomodoro;
    if (active == null || active.isFocus || active.planItemId == null) {
      _lastExpiredBreakPromptId = null;
      return;
    }
    if (active.endsAt.isAfter(_scheduleAnchor)) return;
    if (previousPromptId == active.id) return;
    _lastExpiredBreakPromptId = active.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final hasNext =
          _firstStartablePlanItem(
            context.read<TodoStore>().pomodoroPlanItems,
          ) !=
          null;
      _showPlanSnack(
        context,
        hasNext ? '休息结束了，可以开始下一颗番茄。' : '休息结束了，计划里没有下一颗可开始的番茄。',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TodoStore>();
    final items = store.pomodoroPlanItems;
    final active = store.activePomodoro;
    final timeSlots = _buildPomodoroPlanTimeSlots(
      items,
      store.pomodoros,
      active,
      _scheduleAnchor,
    );
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(
        title: const Text('番茄计划'),
        actions: [
          IconButton(
            onPressed: () => _refreshHistory(context),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新历史',
          ),
          IconButton(
            onPressed: () => _openEditor(context),
            icon: const Icon(Icons.add_rounded),
            tooltip: '新增番茄',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: _PomodoroPlanControlPanel(
              items: items,
              activePomodoro: active,
              now: _scheduleAnchor,
              onPrimary: () => _handlePlanPrimaryAction(context),
              onCancel:
                  active == null
                      ? null
                      : () => unawaited(_cancelPomodoro(context)),
            ),
          ),
          Expanded(
            child:
                items.isEmpty
                    ? ListView(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
                      children: [
                        _EmptyCard(
                          title: '还没有番茄计划',
                          subtitle: '先规划一两颗番茄，写清任务和预计目标，开始后就按顺序推进。',
                        ),
                      ],
                    )
                    : ReorderableListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
                      buildDefaultDragHandles: false,
                      itemCount: items.length,
                      onReorder: (oldIndex, newIndex) {
                        final normalizedNewIndex =
                            newIndex > oldIndex ? newIndex - 1 : newIndex;
                        unawaited(
                          _reorderItems(context, oldIndex, normalizedNewIndex),
                        );
                      },
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return Padding(
                          key: ValueKey('pomodoro-plan-${item.id}'),
                          padding: EdgeInsets.only(
                            bottom: index == items.length - 1 ? 0 : 12,
                          ),
                          child: _PomodoroPlanItemTile(
                            index: index,
                            item: item,
                            activePomodoro: active,
                            timeSlot: timeSlots[item.id],
                            onEdit: () => _openEditor(context, item: item),
                            onSkip:
                                item.isDone
                                    ? null
                                    : () =>
                                        unawaited(_skipItem(context, item.id)),
                            onDelete:
                                () => unawaited(_deleteItem(context, item.id)),
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('新增番茄'),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
          child: Text(
            '完成专注后会回填实际进展；长按拖动图标可以调整顺序。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF8B93A6),
              height: 1.35,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _reorderItems(
    BuildContext context,
    int oldIndex,
    int newIndex,
  ) async {
    await context.read<TodoStore>().reorderPomodoroPlanItems(
      oldIndex,
      newIndex,
    );
    _refreshSchedule();
  }

  Future<void> _skipItem(BuildContext context, String itemId) async {
    await context.read<TodoStore>().skipPomodoroPlanItem(itemId);
    _refreshSchedule();
  }

  Future<void> _deleteItem(BuildContext context, String itemId) async {
    await context.read<TodoStore>().deletePomodoroPlanItem(itemId);
    _refreshSchedule();
  }

  Future<void> _openEditor(
    BuildContext context, {
    TodoPomodoroPlanItem? item,
  }) async {
    final store = context.read<TodoStore>();
    final result = await showModalBottomSheet<_PomodoroPlanEditorResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PomodoroPlanEditorSheet(item: item),
    );
    if (result == null) return;
    if (result.deleteItem && item != null) {
      await store.deletePomodoroPlanItem(item.id);
      _refreshSchedule();
      return;
    }
    final now = DateTime.now();
    await store.savePomodoroPlanItem(
      TodoPomodoroPlanItem(
        id: item?.id ?? 'pomodoro-plan:${_uuid.v4()}',
        taskId: result.taskId,
        sortOrder: item?.sortOrder ?? store.pomodoroPlanItems.length,
        estimatedGoal: result.estimatedGoal,
        actualProgress: result.actualProgress,
        status: item?.status ?? PomodoroPlanItemStatus.planned,
        pomodoroId: item?.pomodoroId,
        createdAt: item?.createdAt ?? now,
        updatedAt: item?.updatedAt ?? now,
        startedAt: item?.startedAt,
        completedAt: item?.completedAt,
        metadata: item?.metadata ?? const {},
      ),
    );
    _refreshSchedule();
  }

  Future<void> _refreshHistory(BuildContext context) async {
    final store = context.read<TodoStore>();
    await store.ensureLoaded();
    await store.refreshFromRemote(force: true);
    _refreshSchedule();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('番茄历史已刷新'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handlePlanPrimaryAction(BuildContext context) async {
    final store = context.read<TodoStore>();
    final pomodoro = store.activePomodoro;
    if (pomodoro == null) {
      final next = _firstOpenPlanItem(store.pomodoroPlanItems);
      if (next == null) {
        _showPlanSnack(context, '先新增一颗番茄。');
        return;
      }
      if (next.taskId == null || next.taskId!.isEmpty) {
        _showPlanSnack(context, '先给下一颗番茄选择一个任务。');
        return;
      }
      await store.startPomodoroPlanItem(next.id);
      _refreshSchedule();
      return;
    }

    if (pomodoro.planItemId == null) {
      _showPlanSnack(context, '当前有独立番茄正在进行，先在对应任务里处理。');
      return;
    }

    if (pomodoro.isFocus) {
      final note = await _askPomodoroNote(context);
      if (note == null) return;
      await store.markPomodoroFocusDone(pomodoro.id, note: note);
      _refreshSchedule();
      return;
    }

    await store.completePomodoroBreak(pomodoro.id);
    final next = await store.startNextPomodoroPlanItem();
    _refreshSchedule();
    if (!context.mounted) return;
    _showPlanSnack(
      context,
      next == null ? '休息结束了，计划里没有下一颗可开始的番茄。' : '休息结束了，已开始下一颗番茄。',
    );
  }

  Future<void> _cancelPomodoro(BuildContext context) async {
    final active = context.read<TodoStore>().activePomodoro;
    if (active == null) return;
    await context.read<TodoStore>().cancelPomodoro(active.id);
    _refreshSchedule();
  }

  void _showPlanSnack(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}

class _PomodoroPlanControlPanel extends StatelessWidget {
  const _PomodoroPlanControlPanel({
    required this.items,
    required this.activePomodoro,
    required this.now,
    required this.onPrimary,
    required this.onCancel,
  });

  final List<TodoPomodoroPlanItem> items;
  final TodoPomodoro? activePomodoro;
  final DateTime now;
  final VoidCallback onPrimary;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TodoStore>();
    final active = activePomodoro;
    final activePlanItem = _planItemById(items, active?.planItemId);
    final nextItem = _firstOpenPlanItem(items);
    final activeTask = _taskById(store.tasks, active?.taskId);
    final nextTask = _taskById(store.tasks, nextItem?.taskId);
    final theme = Theme.of(context);

    final title =
        active == null
            ? '准备开始'
            : active.isFocus
            ? '专注中'
            : '休息中';
    final remaining = active?.endsAt.difference(now);
    final expired = remaining != null && remaining.inSeconds <= 0;
    final primaryLabel =
        active == null
            ? '开始下一颗'
            : active.isFocus
            ? (expired ? '记录进展' : '结束专注')
            : (expired ? '开始下一颗' : '结束休息');
    final subtitle =
        active == null
            ? nextItem == null
                ? '计划里还没有待开始的番茄'
                : nextTask?.title ?? '下一颗还没有选择任务'
            : activePlanItem == null
            ? activeTask?.title ?? '独立番茄正在进行'
            : activeTask?.title ?? '计划番茄正在进行';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFDDC2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF0E7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.timer_outlined,
                  color: Color(0xFFEF7B45),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF2D3443),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF667085),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              if (remaining != null) ...[
                const SizedBox(width: 10),
                Text(
                  _formatCompactDuration(remaining),
                  style: theme.textTheme.titleLarge?.copyWith(
                    color:
                        expired
                            ? const Color(0xFFD64545)
                            : const Color(0xFFEF7B45),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: onPrimary,
                icon: Icon(
                  active == null
                      ? Icons.play_arrow_rounded
                      : active.isFocus
                      ? Icons.stop_circle_outlined
                      : Icons.skip_next_rounded,
                ),
                label: Text(primaryLabel),
              ),
              if (onCancel != null)
                OutlinedButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('放弃当前'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PomodoroPlanItemTile extends StatelessWidget {
  const _PomodoroPlanItemTile({
    required this.index,
    required this.item,
    required this.activePomodoro,
    required this.timeSlot,
    required this.onEdit,
    required this.onDelete,
    this.onSkip,
  });

  final int index;
  final TodoPomodoroPlanItem item;
  final TodoPomodoro? activePomodoro;
  final _PomodoroPlanTimeSlot? timeSlot;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TodoStore>();
    final task = _taskById(store.tasks, item.taskId);
    final activeForItem = activePomodoro?.planItemId == item.id;
    final theme = Theme.of(context);
    final statusColor = _planStatusColor(item.status);
    final dayLabel = _planDayLabel(item, DateTime.now());

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color:
                  activeForItem
                      ? const Color(0xFFFFC89F)
                      : const Color(0xFFECEFF6),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF0E7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${index + 1}',
                      style: const TextStyle(
                        color: Color(0xFFEF7B45),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task?.title ?? '未选择任务',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            color:
                                task == null
                                    ? const Color(0xFF98A2B3)
                                    : const Color(0xFF2D3443),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _planStatusLabel(item.status),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: statusColor,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (dayLabel != null)
                              _PlanBadge(
                                label: dayLabel,
                                color: _planDayColor(dayLabel),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: '编辑',
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (value) {
                      if (value == 'skip') {
                        onSkip?.call();
                      } else if (value == 'delete') {
                        onDelete();
                      }
                    },
                    itemBuilder:
                        (context) => [
                          if (onSkip != null)
                            const PopupMenuItem(
                              value: 'skip',
                              child: Text('跳过'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除'),
                          ),
                        ],
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
              if (timeSlot != null) ...[
                const SizedBox(height: 6),
                _PlanTextLine(
                  icon: Icons.schedule_rounded,
                  label: '时间',
                  text: timeSlot!.summary,
                ),
              ],
              if (item.estimatedGoal.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                _PlanTextLine(
                  icon: Icons.flag_outlined,
                  label: '预计',
                  text: item.estimatedGoal.trim(),
                ),
              ],
              if (item.actualProgress.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                _PlanTextLine(
                  icon: Icons.fact_check_outlined,
                  label: '实际',
                  text: item.actualProgress.trim(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanBadge extends StatelessWidget {
  const _PlanBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
          height: 1.1,
        ),
      ),
    );
  }
}

class _PlanTextLine extends StatelessWidget {
  const _PlanTextLine({
    required this.icon,
    required this.label,
    required this.text,
  });

  final IconData icon;
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: const Color(0xFF8F99AD)),
        const SizedBox(width: 7),
        Text(
          '$label：',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF8F99AD),
            fontWeight: FontWeight.w700,
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF475467),
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

Future<String?> _askPomodoroNote(BuildContext context) async {
  final controller = TextEditingController();
  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      final bottomInset = MediaQuery.of(context).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF8F8FD),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: const Color(0xFFD9DDEC),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '记录这个番茄',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    minLines: 3,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: '进展可以空着，比如：完成接口草稿',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(''),
                          child: const Text('空着继续'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed:
                              () => Navigator.of(
                                context,
                              ).pop(controller.text.trim()),
                          child: const Text('进入休息'),
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
    },
  );
  controller.dispose();
  return result;
}

class _PomodoroPlanEditorSheet extends StatefulWidget {
  const _PomodoroPlanEditorSheet({this.item});

  final TodoPomodoroPlanItem? item;

  @override
  State<_PomodoroPlanEditorSheet> createState() =>
      _PomodoroPlanEditorSheetState();
}

class _PomodoroPlanEditorSheetState extends State<_PomodoroPlanEditorSheet> {
  late String? _taskId;
  late final TextEditingController _goalController;
  late final TextEditingController _progressController;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _taskId = item?.taskId;
    _goalController = TextEditingController(text: item?.estimatedGoal ?? '');
    _progressController = TextEditingController(
      text: item?.actualProgress ?? '',
    );
  }

  @override
  void dispose() {
    _goalController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TodoStore>();
    final tasks = store.tasks
        .where((task) => !task.isDone)
        .toList(growable: false);
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
                  widget.item == null ? '新增番茄' : '编辑番茄',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '任务',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      value:
                          tasks.any((task) => task.id == _taskId)
                              ? _taskId
                              : null,
                      isExpanded: true,
                      hint: const Text('选择一个任务'),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('暂不选择'),
                        ),
                        ...tasks.map(
                          (task) => DropdownMenuItem<String?>(
                            value: task.id,
                            child: Text(
                              task.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (value) => setState(() => _taskId = value),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _goalController,
                  autofocus: widget.item == null,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '预计目标',
                    hintText: '比如：完成番茄计划数据结构和页面入口',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _progressController,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '实际进展',
                    hintText: '完成以后再补，也可以现在先记一点。',
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    if (widget.item != null)
                      Expanded(
                        child: OutlinedButton(
                          onPressed:
                              () => Navigator.of(
                                context,
                              ).pop(const _PomodoroPlanEditorResult.delete()),
                          child: const Text('删除'),
                        ),
                      ),
                    if (widget.item != null) const SizedBox(width: 12),
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

  void _submit() {
    Navigator.of(context).pop(
      _PomodoroPlanEditorResult(
        taskId: _taskId,
        estimatedGoal: _goalController.text.trim(),
        actualProgress: _progressController.text.trim(),
        deleteItem: false,
      ),
    );
  }
}

class _PomodoroPlanEditorResult {
  const _PomodoroPlanEditorResult({
    required this.taskId,
    required this.estimatedGoal,
    required this.actualProgress,
    required this.deleteItem,
  });

  const _PomodoroPlanEditorResult.delete()
    : taskId = null,
      estimatedGoal = '',
      actualProgress = '',
      deleteItem = true;

  final String? taskId;
  final String estimatedGoal;
  final String actualProgress;
  final bool deleteItem;
}

TodoTask? _taskById(List<TodoTask> tasks, String? taskId) {
  if (taskId == null) return null;
  for (final task in tasks) {
    if (task.id == taskId) return task;
  }
  return null;
}

TodoPomodoroPlanItem? _nextOpenPlanItem(List<TodoPomodoroPlanItem> items) {
  for (final item in items) {
    if (item.isOpen) return item;
  }
  return null;
}

TodoPomodoroPlanItem? _firstOpenPlanItem(List<TodoPomodoroPlanItem> items) {
  for (final item in items) {
    if (item.status == PomodoroPlanItemStatus.planned) return item;
  }
  return null;
}

TodoPomodoroPlanItem? _firstStartablePlanItem(
  List<TodoPomodoroPlanItem> items,
) {
  for (final item in items) {
    final taskId = item.taskId;
    if (item.status == PomodoroPlanItemStatus.planned &&
        taskId != null &&
        taskId.isNotEmpty) {
      return item;
    }
  }
  return null;
}

TodoPomodoroPlanItem? _planItemById(
  List<TodoPomodoroPlanItem> items,
  String? id,
) {
  if (id == null || id.isEmpty) return null;
  for (final item in items) {
    if (item.id == id) return item;
  }
  return null;
}

class _PomodoroPlanTimeSlot {
  const _PomodoroPlanTimeSlot(this.summary);

  final String summary;
}

Map<String, _PomodoroPlanTimeSlot> _buildPomodoroPlanTimeSlots(
  List<TodoPomodoroPlanItem> items,
  List<TodoPomodoro> pomodoros,
  TodoPomodoro? active,
  DateTime now,
) {
  final byPlanItemId = <String, TodoPomodoro>{};
  final byPomodoroId = <String, TodoPomodoro>{};
  for (final pomodoro in pomodoros) {
    byPomodoroId[pomodoro.id] = pomodoro;
    final planItemId = pomodoro.planItemId;
    if (planItemId != null && planItemId.isNotEmpty) {
      byPlanItemId.putIfAbsent(planItemId, () => pomodoro);
    }
  }

  final result = <String, _PomodoroPlanTimeSlot>{};
  var cursor = _nextPlanCursor(active, now);
  for (final item in items) {
    final linkedPomodoro =
        byPlanItemId[item.id] ??
        (item.pomodoroId == null ? null : byPomodoroId[item.pomodoroId]);
    final start =
        item.startedAt ??
        linkedPomodoro?.focusStartedAt ??
        linkedPomodoro?.startedAt;
    final end =
        item.completedAt ??
        linkedPomodoro?.completedAt ??
        linkedPomodoro?.focusEndedAt;

    if (item.status == PomodoroPlanItemStatus.completed &&
        (start != null || end != null)) {
      result[item.id] = _PomodoroPlanTimeSlot(
        start == null
            ? '完成 ${_formatPlanClock(end!, now)}'
            : end == null
            ? '实际 ${_formatPlanClock(start, now)}'
            : '实际 ${_formatPlanClock(start, now)}-${_formatPlanClock(end, now)}',
      );
      continue;
    }
    if (item.status == PomodoroPlanItemStatus.skipped) {
      result[item.id] = _PomodoroPlanTimeSlot(
        end == null ? '已跳过' : '跳过 ${_formatPlanClock(end, now)}',
      );
      continue;
    }
    if (item.status == PomodoroPlanItemStatus.running && start != null) {
      final runningEnd = active?.planItemId == item.id ? active?.endsAt : null;
      result[item.id] = _PomodoroPlanTimeSlot(
        runningEnd == null
            ? '开始 ${_formatPlanClock(start, now)}'
            : runningEnd.isBefore(now)
            ? '开始 ${_formatPlanClock(start, now)} · 已超时 ${_formatOverdue(now.difference(runningEnd))}'
            : '开始 ${_formatPlanClock(start, now)} · 预计 ${_formatPlanClock(runningEnd, now)}',
      );
      if (active?.planItemId == item.id) {
        cursor = _nextPlanCursor(active, now);
      }
      continue;
    }
    if (item.status == PomodoroPlanItemStatus.planned) {
      final estimatedStart = cursor;
      final estimatedEnd = estimatedStart.add(const Duration(minutes: 25));
      result[item.id] = _PomodoroPlanTimeSlot(
        '预计 ${_formatPlanClock(estimatedStart, now)}-${_formatPlanClock(estimatedEnd, now)}',
      );
      cursor = estimatedEnd.add(const Duration(minutes: 5));
    }
  }
  return result;
}

DateTime _nextPlanCursor(TodoPomodoro? active, DateTime now) {
  if (active == null) return now;
  final activeEnd = active.endsAt.isAfter(now) ? active.endsAt : now;
  if (active.isFocus) {
    return activeEnd.add(Duration(minutes: active.breakPlannedMinutes));
  }
  return activeEnd;
}

String _formatPlanClock(DateTime time, DateTime reference) {
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');
  if (_isSameDay(time, reference)) return '$hh:$mm';
  return '${time.month.toString().padLeft(2, '0')}/${time.day.toString().padLeft(2, '0')} $hh:$mm';
}

String _formatOverdue(Duration duration) {
  final minutes = duration.inMinutes < 1 ? 1 : duration.inMinutes;
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes ~/ 60;
  final restMinutes = minutes % 60;
  if (restMinutes == 0) return '$hours 小时';
  return '$hours 小时 $restMinutes 分钟';
}

String _planStatusLabel(PomodoroPlanItemStatus status) {
  return switch (status) {
    PomodoroPlanItemStatus.planned => '待开始',
    PomodoroPlanItemStatus.running => '进行中',
    PomodoroPlanItemStatus.completed => '已完成',
    PomodoroPlanItemStatus.skipped => '已跳过',
  };
}

Color _planStatusColor(PomodoroPlanItemStatus status) {
  return switch (status) {
    PomodoroPlanItemStatus.planned => const Color(0xFF7B8496),
    PomodoroPlanItemStatus.running => const Color(0xFFEF7B45),
    PomodoroPlanItemStatus.completed => const Color(0xFF4E9F7A),
    PomodoroPlanItemStatus.skipped => const Color(0xFF98A2B3),
  };
}

String? _planDayLabel(TodoPomodoroPlanItem item, DateTime now) {
  final planDate = _parsePlanDate(item.metadata['planDate']) ?? item.createdAt;
  if (planDate == null) return null;
  final today = DateTime(now.year, now.month, now.day);
  final itemDay = DateTime(planDate.year, planDate.month, planDate.day);
  if (itemDay.isAtSameMomentAs(today)) return '今日新增';
  if (itemDay.isBefore(today)) return '昨日延续';
  return null;
}

Color _planDayColor(String label) {
  return label == '今日新增' ? const Color(0xFF4E9F7A) : const Color(0xFF667085);
}

DateTime? _parsePlanDate(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return DateTime.tryParse(value.trim());
}

class _ProjectManagementScreen extends StatelessWidget {
  const _ProjectManagementScreen({
    required this.onOpenProjectEditor,
    required this.onOpenProjectSorter,
    required this.onOpenArchivedProjects,
  });

  final Future<void> Function({TodoProject? project}) onOpenProjectEditor;
  final Future<void> Function() onOpenProjectSorter;
  final VoidCallback onOpenArchivedProjects;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TodoStore>();
    final projects = store.activeProjects;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(title: const Text('项目管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        children: [
          IgnorePointer(
            child: _TodoHeroCard(
              store: store,
              message: '项目集中管，首页就能更轻。',
              onOpenCompleted: () {},
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => onOpenProjectEditor(),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('新建项目'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: projects.length > 1 ? onOpenProjectSorter : null,
                icon: const Icon(Icons.swap_vert_rounded),
                label: const Text('排序'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed:
                    store.archivedProjects.isNotEmpty
                        ? onOpenArchivedProjects
                        : null,
                icon: const Icon(Icons.inventory_2_outlined),
                label: const Text('归档'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (projects.isEmpty)
            const _EmptyCard(title: '还没有项目', subtitle: '先建一个项目，把待办分门别类收好。')
          else
            ...projects.asMap().entries.map((entry) {
              final index = entry.key;
              final project = entry.value;
              final color = Color(project.colorValue);
              return Padding(
                padding: EdgeInsets.only(
                  bottom: index == projects.length - 1 ? 0 : 12,
                ),
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: () => onOpenProjectEditor(project: project),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              _projectIconFromCodePoint(project.iconCodePoint),
                              color: color,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  project.name,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                if (project.description.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    project.description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFF7B8496),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFF98A2B3),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
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
                              _projectIconFromCodePoint(project.iconCodePoint),
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
      body:
          archivedProjects.isEmpty
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
                            _projectIconFromCodePoint(project.iconCodePoint),
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
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                project.description.isEmpty
                                    ? '这个项目先收起来了。'
                                    : project.description,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed:
                              () => store.archiveProject(
                                project.id,
                                archived: false,
                              ),
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

class _InlineHabitPlaceholder extends StatelessWidget {
  const _InlineHabitPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE8ECF3)),
      ),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class _InlineHabitEmptyCard extends StatelessWidget {
  const _InlineHabitEmptyCard({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onCreate,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE8ECF3)),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F4FA),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.directions_run_rounded,
                  color: Color(0xFF7B8496),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '今天没有待打卡习惯',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF2D3443),
                  ),
                ),
              ),
              const Icon(Icons.add_rounded, color: Color(0xFF7B6CF6)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddEntryFab extends StatelessWidget {
  const _AddEntryFab({
    required this.onAddTask,
    required this.onAddHabit,
    this.compact = false,
  });

  final VoidCallback onAddTask;
  final VoidCallback onAddHabit;
  final bool compact;

  Future<void> _openMenu(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (context) => SafeArea(
            top: false,
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xFFF8F8FD),
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD9DDEC),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 18),
                  ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    tileColor: Colors.white,
                    leading: const Icon(
                      Icons.checklist_rounded,
                      color: Color(0xFF7B6CF6),
                    ),
                    title: const Text('新建任务'),
                    subtitle: const Text('一次性事项、项目任务或提醒'),
                    onTap: () => Navigator.of(context).pop('task'),
                  ),
                  const SizedBox(height: 10),
                  ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    tileColor: Colors.white,
                    leading: const Icon(
                      Icons.directions_run_rounded,
                      color: Color(0xFF4E9F7A),
                    ),
                    title: const Text('新建习惯'),
                    subtitle: const Text('每天或每周重复打卡'),
                    onTap: () => Navigator.of(context).pop('habit'),
                  ),
                ],
              ),
            ),
          ),
    );
    if (action == 'task') {
      onAddTask();
    } else if (action == 'habit') {
      onAddHabit();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AddFabShell(
      compact: compact,
      label: '新建',
      onTap: () => _openMenu(context),
    );
  }
}

class _AddTaskFab extends StatelessWidget {
  const _AddTaskFab({required this.onTap, this.compact = false});

  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return _AddFabShell(compact: compact, label: '新建任务', onTap: onTap);
  }
}

class _AddFabShell extends StatelessWidget {
  const _AddFabShell({
    required this.compact,
    required this.label,
    required this.onTap,
  });

  final bool compact;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final child =
        compact
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.add_rounded, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: child,
      ),
    );
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
    _descriptionController = TextEditingController(
      text: project?.description ?? '',
    );
    _iconData =
        project == null
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
                  decoration: const InputDecoration(
                    hintText: '比如：健康 / 出行 / 创作',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _descriptionController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: '给这个项目留一句说明。'),
                ),
                const SizedBox(height: 18),
                Text(
                  '图标',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
                Text(
                  '颜色',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
                      label: Text(widget.project!.archived ? '取消归档' : '归档项目'),
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
        name:
            _nameController.text.trim().isEmpty
                ? project.name
                : _nameController.text.trim(),
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
          gradient:
              selected
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
        child:
            selected
                ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
                : null,
      ),
    );
  }
}

class _CompletedTasksScreen extends StatelessWidget {
  const _CompletedTasksScreen();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TodoStore>();
    final completed = store.completedTasks;
    final grouped = _groupCompletedTasks(completed);

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(title: const Text('已完成')),
      body:
          completed.isEmpty
              ? Padding(
                padding: const EdgeInsets.all(20),
                child: _EmptyCard(title: '还没有已完成任务', subtitle: '等你点亮第一条完成记录。'),
              )
              : ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: grouped.entries
                    .map((entry) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Text(
                                entry.key,
                                style: Theme.of(
                                  context,
                                ).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: const Color(0xFF495163),
                                ),
                              ),
                            ),
                            ...entry.value.map((task) {
                              final project = store.projects.firstWhere(
                                (item) => item.id == task.projectId,
                              );
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _CompletedTaskRow(
                                  task: task,
                                  project: project,
                                ),
                              );
                            }),
                          ],
                        ),
                      );
                    })
                    .toList(growable: false),
              ),
    );
  }
}

class _CompletedTaskRow extends StatelessWidget {
  const _CompletedTaskRow({required this.task, required this.project});

  final TodoTask task;
  final TodoProject project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = Color(project.colorValue);
    return Container(
      padding: const EdgeInsets.fromLTRB(0, 0, 14, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x051F2430),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 46,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.8),
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(4),
              ),
            ),
          ),
          const Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: Color(0xFF7C4DFF),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF7B8496),
                    decoration: TextDecoration.lineThrough,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${project.name} · ${_formatCompletedAt(task.completedAt ?? task.updatedAt ?? DateTime.now())}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF9AA3B3),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
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
    final today = tasks
        .where((item) => _isSameDay(item.dueAt, DateTime.now()) && !item.isDone)
        .toList(growable: false);
    final upcoming = tasks
        .where(
          (item) => !item.isDone && !_isSameDay(item.dueAt, DateTime.now()),
        )
        .toList(growable: false);
    final completed = tasks
        .where((item) => item.isDone)
        .toList(growable: false);
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
            onPressed:
                () => store.archiveProject(
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
                    color: Color(
                      refreshedProject.colorValue,
                    ).withValues(alpha: 0.16),
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
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.55,
                        ),
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
            onEdit:
                (task) =>
                    _openEditor(task: task, projectId: refreshedProject.id),
            onDelete: (task) => store.deleteTask(task.id),
          ),
          const SizedBox(height: 20),
          _TaskSection(
            title: '接下来',
            tasks: upcoming,
            project: refreshedProject,
            onToggle: (task, value) => store.toggleTask(task.id, value),
            onEdit:
                (task) =>
                    _openEditor(task: task, projectId: refreshedProject.id),
            onDelete: (task) => store.deleteTask(task.id),
          ),
          const SizedBox(height: 20),
          _TaskSection(
            title: '已完成',
            tasks: completed,
            project: refreshedProject,
            onToggle: (task, value) => store.toggleTask(task.id, value),
            onEdit:
                (task) =>
                    _openEditor(task: task, projectId: refreshedProject.id),
            onDelete: (task) => store.deleteTask(task.id),
          ),
        ],
      ),
    );
  }

  Future<void> _openEditor({TodoTask? task, required String projectId}) async {
    final store = context.read<TodoStore>();
    final subtasks =
        task == null
            ? const <TodoSubtask>[]
            : await store.subtasksForTask(task.id);
    if (!mounted) return;
    final result = await showModalBottomSheet<_TaskEditorResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (context) => _TaskEditorSheet(
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
        result.subtasks.isNotEmpty &&
        completedSubtasks == result.subtasks.length;
    await store.saveTask(
      TodoTask(
        id: taskId,
        projectId: result.projectId,
        title: result.title,
        description: result.description,
        priority: result.priority,
        status:
            shouldAutoComplete
                ? TodoStatus.done
                : task?.status ?? TodoStatus.todo,
        dueAt: result.dueAt,
        reminderAt: result.reminderAt,
        createdAt: task?.createdAt,
        updatedAt: task?.updatedAt,
        completedAt:
            shouldAutoComplete
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
    _descriptionController = TextEditingController(
      text: task?.description ?? '',
    );
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
                Text(
                  '所属项目',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final project in projects)
                      ChoiceChip(
                        label: Text(project.name),
                        selected: _projectId == project.id,
                        onSelected:
                            (_) => setState(() => _projectId = project.id),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  '优先级',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
                Text(
                  '时间',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                InkWell(
                  onTap: _pickDueAt,
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.schedule_rounded,
                          color: Color(0xFF7C4DFF),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _dueAt == null
                                ? '还没定时间'
                                : _formatDue(_dueAt!, withDate: true),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
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
                Text(
                  '提醒',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                InkWell(
                  onTap: _pickReminderAt,
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.notifications_active_outlined,
                          color: Color(0xFF7C4DFF),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _reminderAt == null
                                ? '暂时不提醒'
                                : _formatDue(_reminderAt!, withDate: true),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
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
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _ReminderShortcutChip(
                      label: '截止前三天',
                      enabled: _dueAt != null,
                      onTap:
                          () => _applyReminderShortcut(const Duration(days: 3)),
                    ),
                    _ReminderShortcutChip(
                      label: '截止前一天',
                      enabled: _dueAt != null,
                      onTap:
                          () => _applyReminderShortcut(const Duration(days: 1)),
                    ),
                  ],
                ),
                if (_dueAt == null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '先定截止时间，就能一键回填提醒时间。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF8F99AD),
                      height: 1.35,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Text(
                  '子任务',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
                          padding: EdgeInsets.only(
                            bottom: index == _subtasks.length - 1 ? 0 : 10,
                          ),
                          child: _SubtaskDraftTile(
                            draft: _subtasks[index],
                            onChanged:
                                (draft) =>
                                    setState(() => _subtasks[index] = draft),
                            onDelete:
                                () => setState(() => _subtasks.removeAt(index)),
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
                            Navigator.of(
                              context,
                            ).pop(const _TaskEditorResult.delete());
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

  void _applyReminderShortcut(Duration offset) {
    final dueAt = _dueAt;
    if (dueAt == null) return;
    setState(() {
      _reminderAt = dueAt.subtract(offset);
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

class _ReminderShortcutChip extends StatelessWidget {
  const _ReminderShortcutChip({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(999),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: enabled ? const Color(0xFFF4EEFF) : const Color(0xFFF3F5F9),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: enabled ? const Color(0xFFD9CCFF) : const Color(0xFFE5E9F2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: enabled ? const Color(0xFF6E54F7) : const Color(0xFF9AA3B5),
            fontSize: desktopAdjustedFontSize(11),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
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
          onChanged:
              (value) => onChanged(draft.copyWith(isCompleted: value ?? false)),
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
        IconButton(onPressed: onDelete, icon: const Icon(Icons.close_rounded)),
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
      return const Color(0xFF8FAF9B);
    case TodoPriority.medium:
      return const Color(0xFF7B8496);
    case TodoPriority.high:
      return const Color(0xFFF59E0B);
    case TodoPriority.urgent:
      return const Color(0xFFEF4444);
  }
}

IconData _priorityIcon(TodoPriority priority) {
  switch (priority) {
    case TodoPriority.low:
      return Icons.flag_outlined;
    case TodoPriority.medium:
      return Icons.flag_rounded;
    case TodoPriority.high:
      return Icons.priority_high_rounded;
    case TodoPriority.urgent:
      return Icons.warning_amber_rounded;
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

Map<String, List<TodoTask>> _groupCompletedTasks(List<TodoTask> tasks) {
  final now = DateTime.now();
  final yesterday = now.subtract(const Duration(days: 1));
  final grouped = <String, List<TodoTask>>{};
  for (final task in tasks) {
    final completedAt = task.completedAt ?? task.updatedAt ?? now;
    final key =
        _isSameDay(completedAt, now)
            ? '今天'
            : _isSameDay(completedAt, yesterday)
            ? '昨天'
            : '更早';
    grouped.putIfAbsent(key, () => []).add(task);
  }
  final orderedKeys = ['今天', '昨天', '更早'];
  return {
    for (final key in orderedKeys)
      if (grouped.containsKey(key)) key: grouped[key]!,
  };
}

String _formatCompletedAt(DateTime completedAt) {
  final now = DateTime.now();
  if (_isSameDay(completedAt, now)) {
    return '今天 ${completedAt.hour.toString().padLeft(2, '0')}:${completedAt.minute.toString().padLeft(2, '0')}';
  }
  final yesterday = now.subtract(const Duration(days: 1));
  if (_isSameDay(completedAt, yesterday)) {
    return '昨天 ${completedAt.hour.toString().padLeft(2, '0')}:${completedAt.minute.toString().padLeft(2, '0')}';
  }
  return '${completedAt.month.toString().padLeft(2, '0')}-${completedAt.day.toString().padLeft(2, '0')} ${completedAt.hour.toString().padLeft(2, '0')}:${completedAt.minute.toString().padLeft(2, '0')}';
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

String _formatCompactDuration(Duration duration) {
  final seconds = duration.inSeconds <= 0 ? 0 : duration.inSeconds;
  final minutesPart = (seconds ~/ 60).toString().padLeft(2, '0');
  final secondsPart = (seconds % 60).toString().padLeft(2, '0');
  return '$minutesPart:$secondsPart';
}

bool _isSameDay(DateTime? a, DateTime b) {
  if (a == null) return false;
  return a.year == b.year && a.month == b.month && a.day == b.day;
}
