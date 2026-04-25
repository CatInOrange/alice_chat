import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/openclaw/openclaw_settings.dart';

class WebviewScreen extends StatefulWidget {
  const WebviewScreen({super.key});

  @override
  State<WebviewScreen> createState() => _WebviewScreenState();
}

class _WebviewScreenState extends State<WebviewScreen>
    with AutomaticKeepAliveClientMixin {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    _init();
  }

  Future<void> _init() async {
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);

    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (url) {
          if (mounted) setState(() => _loading = true);
        },
        onPageFinished: (url) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (error) {
          debugPrint('WebView error: $error');
        },
      ),
    );

    final config = await OpenClawSettingsStore.load();
    final password = (config.appPassword ?? '').trim();
    final base = config.baseUrl.trim();
    if (base.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final uri = Uri.parse(base);
    final isAliceClaw = uri.port == 18080 || uri.host == 'alice.newthu.com';
    final targetUrl = isAliceClaw && password.isNotEmpty
        ? uri.replace(queryParameters: {
            ...uri.queryParameters,
            'app_password': password,
          }).toString()
        : uri.toString();
    await _controller.loadRequest(
      Uri.parse(targetUrl),
      headers: {
        if (password.isNotEmpty) 'X-AliceChat-Password': password,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alice'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
