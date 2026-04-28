import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../../core/openclaw/openclaw_settings.dart';

class WebviewScreen extends StatefulWidget {
  const WebviewScreen({super.key, required this.active});

  final bool active;

  @override
  State<WebviewScreen> createState() => _WebviewScreenState();
}

class _WebviewScreenState extends State<WebviewScreen>
    with AutomaticKeepAliveClientMixin {
  late final WebViewController _controller;
  bool _loading = true;
  bool _pageReady = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    final platformController = _controller.platform;
    if (platformController is AndroidWebViewController) {
      platformController.setMediaPlaybackRequiresUserGesture(false);
      debugPrint('WebView Android mediaPlaybackRequiresUserGesture=false');
    }
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
          debugPrint('WebView page finished: $url');
          _pageReady = true;
          _syncActiveState();
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (error) {
          debugPrint('WebView error: $error');
        },
      ),
    );

    final config = await OpenClawSettingsStore.load();
    final password = (config.appPassword ?? '').trim();
    const base = 'https://alice.newthu.com';
    final uri = Uri.parse(base);
    final targetUrl = password.isNotEmpty
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
  void didUpdateWidget(covariant WebviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      debugPrint(
        'WebView active changed: ${oldWidget.active} -> ${widget.active}',
      );
      _syncActiveState();
    }
  }

  Future<void> _syncActiveState() async {
    if (!_pageReady) {
      debugPrint('WebView active sync skipped: page not ready');
      return;
    }
    final activeValue = widget.active ? 'true' : 'false';
    debugPrint('WebView syncing active state to page: $activeValue');
    try {
      await _controller.runJavaScript(
        'window.aliceLive2dSetActive?.($activeValue);',
      );
    } catch (error) {
      debugPrint('WebView active sync failed: $error');
    }
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
