import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../features/contacts/domain/contact.dart';
import '../features/contacts/presentation/contacts_screen.dart';
import '../features/chat/application/chat_session_store.dart';
import '../features/chat/domain/chat_session.dart';
import '../features/chat/presentation/chat_screen.dart';
import '../core/debug/native_debug_bridge.dart';
import '../features/notifications/application/background_connection_service.dart';
import '../features/notifications/application/notification_service.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/music/application/music_platform_store.dart';
import '../features/music/application/music_store.dart';
import '../features/music/presentation/music_screen.dart';
import '../features/webview/presentation/webview_screen.dart';
import '../features/companion/presentation/companion_panel.dart';
import 'theme.dart';

class AliceChatApp extends StatelessWidget {
  const AliceChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ChatSessionStore()),
        ChangeNotifierProvider(create: (_) => MusicStore()),
        ChangeNotifierProvider(create: (_) => MusicPlatformStore()),
      ],
      child: MaterialApp(
        title: 'Alice Chat',
        theme: buildAliceChatTheme(),
        debugShowCheckedModeBanner: false,
        home: const _MainScaffold(),
      ),
    );
  }
}

class _MainScaffold extends StatefulWidget {
  const _MainScaffold();

  @override
  State<_MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<_MainScaffold>
    with WidgetsBindingObserver {
  static const MethodChannel _appControlChannel = MethodChannel(
    'alicechat/app_control',
  );

  int _currentIndex = 0;
  bool _desktopLive2dVisible = false;
  ChatSession? _activeChatSession;
  StreamSubscription<NotificationOpenData>? _notificationOpenSub;
  String _lastConsumedNotificationKey = '';

  // Single source of truth for contacts
  static final List<Contact> _contacts = [
    const Contact(
      id: 'alice',
      name: '晚秋',
      subtitle: '知心姐姐永远都在^^',
      avatarAssetPath: 'assets/avatars/alice.jpg',
      backendSessionId: 'alice',
      isGatewayBacked: true,
    ),
    const Contact(
      id: 'yulinglong',
      name: '玲珑',
      subtitle: '聪明的大脑不休息～',
      avatarAssetPath: 'assets/avatars/linglong.jpg',
      backendSessionId: 'yulinglong',
      isGatewayBacked: true,
    ),
    const Contact(
      id: 'lisuxin',
      name: '素心',
      subtitle: '搬砖永不停歇！',
      avatarAssetPath: 'assets/avatars/lisuxin.jpg',
      backendSessionId: 'lisuxin',
      isGatewayBacked: true,
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.instance.registerContacts(_contacts);
    unawaited(
      NativeDebugBridge.instance.log(
        'app',
        'initState register contacts count=${_contacts.length}',
      ),
    );
    NotificationService.instance.setAppForeground(true);
    unawaited(BackgroundConnectionService.instance.updateAppForeground(true));
    _notificationOpenSub = NotificationService.instance.onNotificationOpened
        .listen(_handleNotificationOpen);
    unawaited(_ensureBackgroundServiceConfigured());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _consumePendingNotificationOpen(source: 'postFrame');
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notificationOpenSub?.cancel();
    super.dispose();
  }

  Future<void> _ensureBackgroundServiceConfigured() async {
    await BackgroundConnectionService.instance.start(
      sessionId: _activeChatSession?.backendSessionId ?? '',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    unawaited(
      NativeDebugBridge.instance.log(
        'app',
        'lifecycle=$state foreground=$isForeground',
      ),
    );
    NotificationService.instance.setAppForeground(isForeground);
    unawaited(
      BackgroundConnectionService.instance.updateAppForeground(isForeground),
    );
    unawaited(
      BackgroundConnectionService.instance.onAppLifecycleChanged(state),
    );
    if (state == AppLifecycleState.resumed) {
      unawaited(_consumePendingNotificationOpen(source: 'resumed'));
      unawaited(context.read<ChatSessionStore>().handleAppResumed());
    }
  }

  void _navigateToChat(Contact contact) {
    final session = _sessionFromContact(contact);
    unawaited(
      NativeDebugBridge.instance.log(
        'app',
        'navigateToChat contact=${contact.name} sessionLocal=${session.id} backend=${session.backendSessionId ?? ''}',
      ),
    );
    setState(() {
      _currentIndex = 0;
      _activeChatSession = session;
    });
    unawaited(
      NativeDebugBridge.instance.log(
        'app',
        'navigateToChat committed contact=${contact.name} sessionLocal=${session.id} backend=${session.backendSessionId ?? ''}',
      ),
    );
  }

  ChatSession _sessionFromContact(Contact contact) {
    return ChatSession(
      id: contact.id,
      title: contact.name,
      subtitle: contact.subtitle ?? '',
      avatarAssetPath: contact.avatarAssetPath,
      backendSessionId:
          (contact.backendSessionId ?? '').trim().isNotEmpty
              ? contact.backendSessionId
              : contact.id,
      contactId: contact.id,
      isGatewayBacked: contact.isGatewayBacked,
    );
  }

  Future<void> _syncActiveSessionFromStore(ChatSession session) async {
    if (!mounted || _activeChatSession?.id != session.id) return;
    final state = context.read<ChatSessionStore>().stateFor(session);
    final backendSessionId = (state.backendSessionId ?? '').trim();
    if (backendSessionId.isEmpty) return;
    final contact = NotificationService.instance.contactForContactId(
      session.contactId ?? session.id,
    );
    if (contact != null) {
      NotificationService.instance.bindSessionToContact(
        sessionId: backendSessionId,
        contact: contact,
      );
      await BackgroundConnectionService.instance.updateSessionMetadata(
        sessionId: backendSessionId,
        title: contact.name,
        avatarAssetPath: contact.avatarAssetPath ?? '',
      );
    }
    await NotificationService.instance.setActiveSession(backendSessionId);
    await BackgroundConnectionService.instance.updateActiveSession(
      backendSessionId,
    );
  }

  Future<void> _consumePendingNotificationOpen({required String source}) async {
    final payload =
        await BackgroundConnectionService.instance
            .consumePendingNotificationOpen();
    await NativeDebugBridge.instance.log(
      'app',
      '$source consumePendingNotificationOpen payload=${payload ?? {}}',
    );
    if (!mounted || payload == null) return;
    final data = NotificationOpenData(
      sessionId: (payload['sessionId'] as String? ?? '').trim(),
      messageId: (payload['messageId'] as String? ?? '').trim(),
    );
    final notificationKey = '${data.sessionId}::${data.messageId}';
    if (notificationKey == '::') return;
    if (notificationKey == _lastConsumedNotificationKey) {
      await NativeDebugBridge.instance.log(
        'app',
        '$source skipDuplicateNotificationOpen key=$notificationKey',
      );
      return;
    }
    _lastConsumedNotificationKey = notificationKey;
    _handleNotificationOpen(data, source: source);
  }

  void _handleNotificationOpen(
    NotificationOpenData data, {
    String source = 'stream',
  }) {
    final sessionId = data.sessionId.trim();
    unawaited(
      NativeDebugBridge.instance.log(
        'app',
        'handleNotificationOpen source=$source session=$sessionId messageId=${data.messageId}',
      ),
    );
    if (sessionId.isEmpty) return;
    final contact =
        NotificationService.instance.contactForSessionId(sessionId) ??
        _findContactBySessionId(sessionId);
    if (contact == null) {
      unawaited(
        NativeDebugBridge.instance.log(
          'app',
          'handleNotificationOpen source=$source unresolvedSession=$sessionId messageId=${data.messageId}',
          level: 'WARN',
        ),
      );
      return;
    }
    _navigateToChat(contact);
  }

  Contact? _findContactBySessionId(String sessionId) {
    for (final item in _contacts) {
      if ((item.backendSessionId ?? '').trim() == sessionId ||
          item.id == sessionId) {
        return item;
      }
    }
    return null;
  }

  void _handleSessionStateChanged() {
    final activeSession = _activeChatSession;
    if (activeSession == null) return;
    unawaited(_syncActiveSessionFromStore(activeSession));
  }

  Future<void> _clearActiveSessionBindings({required String reason}) async {
    await NativeDebugBridge.instance.log(
      'app',
      'clearActiveSessionBindings reason=$reason',
    );
    await NotificationService.instance.clearActiveSession();
    await BackgroundConnectionService.instance.updateActiveSession('');
  }

  Future<void> _prepareForBackgroundTransition({
    required String reason,
    bool clearActiveSession = false,
  }) async {
    await NativeDebugBridge.instance.log(
      'app',
      'prepareForBackgroundTransition reason=$reason clearActiveSession=$clearActiveSession current=${_activeChatSession?.backendSessionId ?? _activeChatSession?.id ?? ''}',
    );
    await NotificationService.instance.setAppForeground(false);
    await BackgroundConnectionService.instance.updateAppForeground(false);
    if (clearActiveSession) {
      await _clearActiveSessionBindings(reason: reason);
    }
  }

  void _closeChat() {
    final currentSessionId =
        _activeChatSession?.backendSessionId ?? _activeChatSession?.id ?? '';
    unawaited(
      NativeDebugBridge.instance.log(
        'app',
        'closeChat current=$currentSessionId',
      ),
    );
    setState(() {
      _activeChatSession = null;
    });
    unawaited(
      NativeDebugBridge.instance.log(
        'app',
        'closeChat committed current_cleared=true',
      ),
    );
    unawaited(_clearActiveSessionBindings(reason: 'closeChat'));
  }

  Future<void> _handleRootBack() async {
    if (_activeChatSession != null) {
      _closeChat();
      return;
    }
    if (!defaultTargetPlatform.name.toLowerCase().contains('android')) {
      return;
    }
    unawaited(
      _prepareForBackgroundTransition(
        reason: 'rootBack',
        clearActiveSession: true,
      ),
    );
    unawaited(
      NativeDebugBridge.instance.log(
        'app',
        'rootBack moveTaskToBack currentIndex=$_currentIndex',
      ),
    );
    try {
      await _appControlChannel.invokeMethod<void>('moveTaskToBack');
    } catch (error) {
      unawaited(
        NativeDebugBridge.instance.log(
          'app',
          'rootBack moveTaskToBack failed error=$error',
          level: 'WARN',
        ),
      );
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatStore = context.watch<ChatSessionStore>();
    final activeState =
        _activeChatSession == null
            ? null
            : chatStore.stateFor(_activeChatSession!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleSessionStateChanged();
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isDesktop = width >= 1200;
        final isTablet = width >= 820;
        final useWorkbenchLayout = isTablet;

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              unawaited(_handleRootBack());
            }
          },
          child:
              useWorkbenchLayout
                  ? _buildWorkbenchScaffold(
                    context,
                    activeState: activeState,
                    isDesktop: isDesktop,
                  )
                  : _buildMobileScaffold(context),
        );
      },
    );
  }

  Widget _buildMobileScaffold(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: [
              ContactsScreen(
                contacts: _contacts,
                onContactTap: _navigateToChat,
              ),
              WebviewScreen(
                key: const ValueKey('webview'),
                active: _currentIndex == 1 && _activeChatSession == null,
              ),
              const MusicScreen(),
              const SettingsScreen(),
            ],
          ),
          if (_activeChatSession != null)
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: ChatScreen(
                  key: ValueKey('chat-${_activeChatSession!.id}'),
                  session: _activeChatSession!,
                  onBack: _closeChat,
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar:
          _activeChatSession == null ? _buildBottomNavigationBar() : null,
    );
  }

  Widget _buildWorkbenchScaffold(
    BuildContext context, {
    required ChatViewState? activeState,
    required bool isDesktop,
  }) {
    final theme = Theme.of(context);
    final page = _buildWorkbenchPage();
    final selectedContactId = _activeChatSession?.id;
    final companion = CompanionPanel(
      session: _activeChatSession,
      state: activeState,
      compact: !isDesktop,
      live2dVisible: _desktopLive2dVisible,
      onOpenLive2d: () {
        setState(() {
          _desktopLive2dVisible = !_desktopLive2dVisible;
        });
      },
      onOpenMusic: () {
        setState(() => _currentIndex = 1);
      },
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FB),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFEEF1F8),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Row(
              children: [
                _PrimaryNavRail(
                  currentIndex: _currentIndex,
                  activeChatSession: _activeChatSession,
                  live2dVisible: _desktopLive2dVisible,
                  onSelected: (index) {
                    setState(() {
                      _currentIndex = index;
                      if (index != 0) {
                        _activeChatSession = null;
                      }
                    });
                  },
                  onToggleLive2d: () {
                    setState(() {
                      _desktopLive2dVisible = !_desktopLive2dVisible;
                    });
                  },
                ),
                Container(width: 1, color: const Color(0xFFE1E6F0)),
                SizedBox(
                  width: 300,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _currentIndex == 0
                                        ? '消息'
                                        : _navTitle(_currentIndex),
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: const Color(0xFF2D3443),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _currentIndex == 0
                                        ? '像微信桌面版一样利落，再加一点陪伴感。'
                                        : '保留统一功能，不做花哨分叉。',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFF98A1B3),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child:
                            _currentIndex == 0
                                ? ContactsScreen(
                                  contacts: _contacts,
                                  onContactTap: _navigateToChat,
                                  selectedContactId: selectedContactId,
                                  embedded: true,
                                )
                                : Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    4,
                                    12,
                                    12,
                                  ),
                                  child: _WorkbenchPlaceholderCard(child: page),
                                ),
                      ),
                    ],
                  ),
                ),
                Container(width: 1, color: const Color(0xFFE1E6F0)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _WorkbenchPlaceholderCard(
                      removePadding: _activeChatSession != null,
                      child: _buildCenterPane(activeState),
                    ),
                  ),
                ),
                Container(width: 1, color: const Color(0xFFE1E6F0)),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  width: isDesktop ? 340 : 280,
                  child: companion,
                ),
                if (_desktopLive2dVisible) ...[
                  Container(width: 1, color: const Color(0xFFE1E6F0)),
                  SizedBox(
                    width: isDesktop ? 260 : 220,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: _WorkbenchPlaceholderCard(
                        child: WebviewScreen(
                          key: const ValueKey('webview-live2d-sidecar'),
                          active: _desktopLive2dVisible,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterPane(ChatViewState? activeState) {
    if (_currentIndex == 0 && _activeChatSession != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: ChatScreen(
          key: ValueKey('chat-desktop-${_activeChatSession!.id}'),
          session: _activeChatSession!,
          onBack: _closeChat,
        ),
      );
    }
    return _WorkbenchEmptyState(
      title: _currentIndex == 0 ? '选一个联系人开始聊天' : _navTitle(_currentIndex),
      subtitle:
          _currentIndex == 0
              ? '桌面版保持专业聊天工具的骨架，中间专心干正事。'
              : '这里沿用现有 Flutter 功能，后面再逐步做桌面优化。',
      icon: _navIcon(_currentIndex),
    );
  }

  Widget _buildWorkbenchPage() {
    switch (_currentIndex) {
      case 1:
        return const MusicScreen();
      case 2:
      default:
        return const SettingsScreen();
    }
  }

  Widget _buildBottomNavigationBar() {
    return NavigationBar(
      selectedIndex: _currentIndex,
      onDestinationSelected: (index) {
        unawaited(
          NativeDebugBridge.instance.log(
            'app',
            'bottomNav selectedIndex=$index activeChat=${_activeChatSession?.backendSessionId ?? _activeChatSession?.id ?? ''}',
          ),
        );
        setState(() {
          _currentIndex = index;
        });
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.contacts_outlined),
          selectedIcon: Icon(Icons.contacts),
          label: '通讯录',
        ),
        NavigationDestination(
          icon: Icon(Icons.web_outlined),
          selectedIcon: Icon(Icons.web),
          label: '网页',
        ),
        NavigationDestination(
          icon: Icon(Icons.library_music_outlined),
          selectedIcon: Icon(Icons.library_music),
          label: '音乐',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: '设置',
        ),
      ],
    );
  }

  String _navTitle(int index) {
    switch (index) {
      case 1:
        return '音乐';
      case 2:
        return '设置';
      default:
        return '消息';
    }
  }

  IconData _navIcon(int index) {
    switch (index) {
      case 1:
        return Icons.library_music_rounded;
      case 2:
        return Icons.settings_rounded;
      default:
        return Icons.chat_bubble_rounded;
    }
  }
}

class _PrimaryNavRail extends StatelessWidget {
  const _PrimaryNavRail({
    required this.currentIndex,
    required this.activeChatSession,
    required this.live2dVisible,
    required this.onSelected,
    required this.onToggleLive2d,
  });

  final int currentIndex;
  final ChatSession? activeChatSession;
  final bool live2dVisible;
  final ValueChanged<int> onSelected;
  final VoidCallback onToggleLive2d;

  @override
  Widget build(BuildContext context) {
    final items = <({IconData icon, String label})>[
      (icon: Icons.chat_bubble_outline_rounded, label: '聊天'),
      (icon: Icons.library_music_outlined, label: '音乐'),
      (icon: Icons.settings_outlined, label: '设置'),
    ];

    return Container(
      width: 88,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                colors: [Color(0xFF8B5CF6), Color(0xFFA78BFA)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x338B5CF6),
                  blurRadius: 18,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
          ),
          const SizedBox(height: 18),
          ...List.generate(items.length, (index) {
            final item = items[index];
            final selected = currentIndex == index && activeChatSession == null;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: InkWell(
                onTap: () => onSelected(index),
                borderRadius: BorderRadius.circular(18),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 56,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color:
                        selected ? const Color(0xFFEFE8FF) : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        item.icon,
                        color:
                            selected
                                ? const Color(0xFF7C4DFF)
                                : const Color(0xFF7B8496),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w600,
                          color:
                              selected
                                  ? const Color(0xFF7C4DFF)
                                  : const Color(0xFF7B8496),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: onToggleLive2d,
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 56,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color:
                      live2dVisible
                          ? const Color(0xFFEFE8FF)
                          : const Color(0xFFF3F5FA),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Icon(
                      live2dVisible
                          ? Icons.auto_awesome
                          : Icons.auto_awesome_outlined,
                      color:
                          live2dVisible
                              ? const Color(0xFF7C4DFF)
                              : const Color(0xFF7B8496),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Live2D',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color:
                            live2dVisible
                                ? const Color(0xFF7C4DFF)
                                : const Color(0xFF7B8496),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFEFF2F8),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.person_outline_rounded,
              color: Color(0xFF7B8496),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkbenchPlaceholderCard extends StatelessWidget {
  const _WorkbenchPlaceholderCard({
    required this.child,
    this.removePadding = false,
  });

  final Widget child;
  final bool removePadding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A1F2430),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child:
          removePadding
              ? child
              : Padding(padding: const EdgeInsets.all(4), child: child),
    );
  }
}

class _WorkbenchEmptyState extends StatelessWidget {
  const _WorkbenchEmptyState({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFFF3EEFF),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(icon, size: 34, color: const Color(0xFF7C4DFF)),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: const Color(0xFF2D3443),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF7B8496),
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
