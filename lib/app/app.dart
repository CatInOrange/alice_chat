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
  static const MethodChannel _appControlChannel = MethodChannel(
    'alicechat/app_control',
  );

  int _currentIndex = 0;
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

  Future<void> _consumePendingNotificationOpen({
    required String source,
  }) async {
    final payload =
        await BackgroundConnectionService.instance.consumePendingNotificationOpen();
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

  Future<void> _clearActiveSessionBindings({
    required String reason,
  }) async {
    await NativeDebugBridge.instance.log('app', 'clearActiveSessionBindings reason=$reason');
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
    context.watch<ChatSessionStore>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleSessionStateChanged();
    });
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_handleRootBack());
        }
      },
      child: Scaffold(
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
                      icon: Icon(Icons.settings_outlined),
                      selectedIcon: Icon(Icons.settings),
                      label: '设置',
                    ),
                  ],
                )
                : null,
      ),
    );
  }
}
