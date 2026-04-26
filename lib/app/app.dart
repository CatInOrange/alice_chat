import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/contacts/domain/contact.dart';
import '../features/contacts/presentation/contacts_screen.dart';
import '../features/chat/application/chat_session_store.dart';
import '../features/chat/domain/chat_session.dart';
import '../features/chat/presentation/chat_screen.dart';
import '../features/notifications/application/background_connection_service.dart';
import '../features/notifications/application/notification_service.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/webview/presentation/webview_screen.dart';
import 'theme.dart';

class AliceChatApp extends StatelessWidget {
  const AliceChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatSessionStore(),
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
  int _currentIndex = 0;
  ChatSession? _activeChatSession;
  StreamSubscription<NotificationOpenData>? _notificationOpenSub;

  // Single source of truth for contacts
  static final List<Contact> _contacts = [
    const Contact(
      id: 'alice',
      name: 'alice',
      subtitle: '点击进入真实聊天',
      avatarAssetPath: 'assets/avatars/alice.jpg',
      backendSessionId: 'alice:main',
      isGatewayBacked: true,
    ),
    const Contact(
      id: 'yulinglong',
      name: '玲珑',
      subtitle: '聪明的大脑不休息～',
      avatarAssetPath: 'assets/avatars/linglong.jpg',
      backendSessionId: 'yulinglong:main',
      isGatewayBacked: true,
    ),
    const Contact(
      id: 'lisuxin',
      name: '素心',
      subtitle: '搬砖永不停歇！',
      avatarAssetPath: 'assets/avatars/lisuxin.jpg',
      backendSessionId: 'lisuxin:main',
      isGatewayBacked: true,
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.instance.setAppForeground(true);
    _notificationOpenSub = NotificationService.instance.onNotificationOpened
        .listen(_handleNotificationOpen);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final sessionId = await BackgroundConnectionService.instance
          .consumePendingNotificationOpen();
      if (!mounted || sessionId == null) return;
      _handleNotificationOpen(
        NotificationOpenData(sessionId: sessionId),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notificationOpenSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    NotificationService.instance.setAppForeground(isForeground);
    unawaited(BackgroundConnectionService.instance.onAppLifecycleChanged(state));
  }

  void _navigateToChat(Contact contact) {
    final session = _sessionFromContact(contact);
    setState(() {
      _activeChatSession = session;
    });
    final resolvedSessionId = session.backendSessionId ?? session.id;
    unawaited(NotificationService.instance.setActiveSession(resolvedSessionId));
    unawaited(
      BackgroundConnectionService.instance.updateActiveSession(
        resolvedSessionId,
        session: session,
      ),
    );
  }

  ChatSession _sessionFromContact(Contact contact) {
    return ChatSession(
      id: contact.id,
      title: contact.name,
      subtitle: contact.subtitle ?? '',
      avatarAssetPath: contact.avatarAssetPath,
      backendSessionId: contact.backendSessionId,
      contactId: contact.id,
      isGatewayBacked: contact.isGatewayBacked,
    );
  }

  void _handleNotificationOpen(NotificationOpenData data) {
    final sessionId = data.sessionId.trim();
    if (sessionId.isEmpty) return;
    Contact? contact;
    for (final item in _contacts) {
      if ((item.backendSessionId ?? '').trim() == sessionId || item.id == sessionId) {
        contact = item;
        break;
      }
    }
    if (contact == null) {
      return;
    }
    _navigateToChat(contact);
  }

  void _closeChat() {
    setState(() {
      _activeChatSession = null;
    });
    unawaited(NotificationService.instance.clearActiveSession());
    unawaited(BackgroundConnectionService.instance.updateActiveSession(''));
  }

  @override
  Widget build(BuildContext context) {
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
              const WebviewScreen(key: ValueKey('webview')),
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
      bottomNavigationBar: _activeChatSession == null
          ? NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (index) {
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
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '设置',
                ),
              ],
            )
          : null,
    );
  }
}
