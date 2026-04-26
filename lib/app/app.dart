import 'dart:async';

import 'package:flutter/material.dart';
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
      isGatewayBacked: true,
    ),
    const Contact(
      id: 'yulinglong',
      name: '玲珑',
      subtitle: '聪明的大脑不休息～',
      avatarAssetPath: 'assets/avatars/linglong.jpg',
      isGatewayBacked: true,
    ),
    const Contact(
      id: 'lisuxin',
      name: '素心',
      subtitle: '搬砖永不停歇！',
      avatarAssetPath: 'assets/avatars/lisuxin.jpg',
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
    _notificationOpenSub = NotificationService.instance.onNotificationOpened
        .listen(_handleNotificationOpen);
    unawaited(_ensureBackgroundServiceConfigured());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final sessionId =
          await BackgroundConnectionService.instance
              .consumePendingNotificationOpen();
      await NativeDebugBridge.instance.log(
        'app',
        'postFrame consumePendingNotificationOpen session=${sessionId ?? ''}',
      );
      if (!mounted || sessionId == null) return;
      _handleNotificationOpen(NotificationOpenData(sessionId: sessionId));
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
      BackgroundConnectionService.instance.onAppLifecycleChanged(state),
    );
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
    }
    await NotificationService.instance.setActiveSession(backendSessionId);
    await BackgroundConnectionService.instance.updateActiveSession(
      backendSessionId,
    );
  }

  void _handleNotificationOpen(NotificationOpenData data) {
    final sessionId = data.sessionId.trim();
    unawaited(
      NativeDebugBridge.instance.log(
        'app',
        'handleNotificationOpen session=$sessionId messageId=${data.messageId}',
      ),
    );
    if (sessionId.isEmpty) return;
    final contact =
        NotificationService.instance.contactForSessionId(sessionId) ??
        _findContactBySessionId(sessionId);
    if (contact == null) return;
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

  void _closeChat() {
    unawaited(
      NativeDebugBridge.instance.log(
        'app',
        'closeChat current=${_activeChatSession?.backendSessionId ?? _activeChatSession?.id ?? ''}',
      ),
    );
    setState(() {
      _activeChatSession = null;
    });
    unawaited(NotificationService.instance.clearActiveSession());
    unawaited(BackgroundConnectionService.instance.updateActiveSession(''));
  }

  @override
  Widget build(BuildContext context) {
    context.watch<ChatSessionStore>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleSessionStateChanged();
    });
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
      bottomNavigationBar:
          _activeChatSession == null
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
