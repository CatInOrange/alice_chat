import 'package:flutter/material.dart';

import '../features/chat/presentation/chat_screen.dart';
import 'theme.dart';

class AliceChatApp extends StatelessWidget {
  const AliceChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AliceChat',
      theme: buildAliceChatTheme(),
      home: const ChatScreen(),
    );
  }
}
