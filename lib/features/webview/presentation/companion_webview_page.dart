import 'package:flutter/material.dart';

import '../application/webview_host_controller.dart';
import 'webview_screen.dart';

class CompanionWebviewPage extends StatefulWidget {
  const CompanionWebviewPage({
    super.key,
    required this.hostController,
  });

  final WebviewHostController hostController;

  @override
  State<CompanionWebviewPage> createState() => _CompanionWebviewPageState();
}

class _CompanionWebviewPageState extends State<CompanionWebviewPage> {
  @override
  void initState() {
    super.initState();
    widget.hostController.setKeepAliveRequested(true, reason: 'companionOpen');
  }

  @override
  void dispose() {
    widget.hostController.setKeepAliveRequested(false, reason: 'companionClose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.hostController,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: const Color(0xFFF6F7FB),
          appBar: AppBar(
            title: const Text('晚秋'),
          ),
          body: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child:
                widget.hostController.mountedView
                    ? WebviewScreen(
                      key: ValueKey('companion-webview-${widget.hostController.seed}'),
                      active: widget.hostController.isActive,
                    )
                    : const ColoredBox(color: Colors.white),
          ),
        );
      },
    );
  }
}
