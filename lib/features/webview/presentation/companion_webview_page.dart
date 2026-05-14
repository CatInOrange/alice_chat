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
          body: Stack(
            children: [
              Positioned.fill(
                child: widget.hostController.mountedView
                    ? WebviewScreen(
                        key: ValueKey('companion-webview-${widget.hostController.seed}'),
                        active: widget.hostController.isActive,
                      )
                    : const ColoredBox(color: Colors.white),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                      child: InkWell(
                        onTap: () => Navigator.of(context).maybePop(),
                        borderRadius: BorderRadius.circular(999),
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(
                            Icons.arrow_back_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
