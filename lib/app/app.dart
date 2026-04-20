import 'package:flutter/material.dart';

import '../features/contacts/domain/contact.dart';
import '../features/contacts/presentation/contacts_screen.dart';
import '../features/chat/domain/chat_session.dart';
import '../features/chat/presentation/chat_screen.dart';
import '../features/webview/presentation/webview_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import 'theme.dart';

void main() {
  runApp(const AliceChatApp());
}

class AliceChatApp extends StatelessWidget {
  const AliceChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alice Chat',
      theme: buildAliceChatTheme(),
      debugShowCheckedModeBanner: false,
      home: const _MainScaffold(),
    );
  }
}

class _MainScaffold extends StatefulWidget {
  const _MainScaffold();

  @override
  State<_MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<_MainScaffold> {
  int _currentIndex = 0;

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
  ];

  void _navigateToChat(Contact contact) {
    final session = ChatSession(
      id: contact.id,
      title: contact.name,
      subtitle: contact.subtitle ?? '',
      avatarAssetPath: contact.avatarAssetPath,
      backendSessionId: contact.backendSessionId,
      isGatewayBacked: contact.isGatewayBacked,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(session: session),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          ContactsScreen(
            contacts: _contacts,
            onContactTap: _navigateToChat,
          ),
          const WebviewScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
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
      ),
    );
  }
}
