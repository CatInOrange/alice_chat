import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../../core/openclaw/openclaw_settings.dart';
import '../application/live2d_model_cache.dart';

class WebviewScreen extends StatefulWidget {
  const WebviewScreen({super.key, required this.active});

  final bool active;

  @override
  State<WebviewScreen> createState() => _WebviewScreenState();
}

enum _WebviewBootStage { preparing, downloading, loadingPage, ready, failed }

class _WebviewScreenState extends State<WebviewScreen>
    with AutomaticKeepAliveClientMixin {
  static const List<String> _downloadMessages = <String>[
    '正在检查本地模型…',
    '正在拉取模型清单…',
    '正在下载 Live2D 资源包…',
    '正在整理贴图和表情…',
    '正在做最后校验…',
  ];

  late final WebViewController _controller;
  bool _loading = false;
  bool _pageReady = false;
  _WebviewBootStage _bootStage = _WebviewBootStage.preparing;
  String _bootMessage = _downloadMessages.first;
  String? _bootError;
  int _messageIndex = 0;
  Timer? _messageTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    final platformController = _controller.platform;
    if (platformController is AndroidWebViewController) {
      platformController.setMediaPlaybackRequiresUserGesture(false);
      platformController.setMixedContentMode(MixedContentMode.alwaysAllow);
      debugPrint('WebView Android mediaPlaybackRequiresUserGesture=false');
      debugPrint('WebView Android mixedContentMode=alwaysAllow');
    }
    unawaited(_init());
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    _messageTimer?.cancel();
    _messageTimer = null;
    _pageReady = false;
    if (mounted) {
      setState(() {
        _loading = false;
        _bootStage = _WebviewBootStage.preparing;
        _bootMessage = _downloadMessages.first;
        _bootError = null;
      });
    }

    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (url) {
          if (mounted) {
            setState(() {
              _loading = true;
              _bootStage = _WebviewBootStage.loadingPage;
              _bootMessage = '本地模型已就绪，正在打开页面…';
            });
          }
        },
        onPageFinished: (url) {
          debugPrint('WebView page finished: $url');
          _pageReady = true;
          _syncActiveState();
          if (mounted) {
            setState(() {
              _loading = false;
              _bootStage = _WebviewBootStage.ready;
            });
          }
        },
        onWebResourceError: (error) {
          debugPrint('WebView error: $error');
          if (mounted) {
            setState(() {
              _loading = false;
              _bootStage = _WebviewBootStage.failed;
              _bootError = '页面加载失败：${error.description}';
            });
          }
        },
      ),
    );

    try {
      final config = await OpenClawSettingsStore.load();
      final password = (config.appPassword ?? '').trim();
      const base = 'https://alice.newthu.com';
      final modelId = config.modelId.trim().isNotEmpty
          ? config.modelId.trim()
          : 'bian';

      final localModelUrl = await _ensureLocalModelReady(
        base: base,
        password: password,
        modelId: modelId,
      );
      debugPrint('WebView localModelUrl resolved: $localModelUrl');
      if (localModelUrl == null || localModelUrl.trim().isEmpty) {
        throw StateError('本地模型未准备完成');
      }

      if (mounted) {
        setState(() {
          _bootStage = _WebviewBootStage.loadingPage;
          _bootMessage = '本地模型已就绪，正在打开页面…';
          _loading = true;
        });
      }

      final uri = Uri.parse(base);
      final queryParameters = <String, String>{
        ...uri.queryParameters,
        if (password.isNotEmpty) 'app_password': password,
        'local_model_url': localModelUrl,
        if (modelId.isNotEmpty) 'model': modelId,
      };
      final targetUrl = uri.replace(queryParameters: queryParameters).toString();
      await _controller.loadRequest(
        Uri.parse(targetUrl),
        headers: {
          if (password.isNotEmpty) 'X-AliceChat-Password': password,
        },
      );
    } catch (error) {
      debugPrint('WebView bootstrap failed: $error');
      if (mounted) {
        setState(() {
          _loading = false;
          _bootStage = _WebviewBootStage.failed;
          _bootError = '$error';
        });
      }
    }
  }

  Future<String?> _ensureLocalModelReady({
    required String base,
    required String password,
    required String modelId,
  }) async {
    if (mounted) {
      setState(() {
        _bootStage = _WebviewBootStage.preparing;
        _bootMessage = '正在检查本地模型…';
      });
    }

    final firstProbe = await Live2dModelCache.instance.prepare(
      basePageUrl: base,
      appPassword: password,
      modelId: modelId,
    );
    if (firstProbe.localModelUrl != null) {
      debugPrint('Live2D cache hit modelId=$modelId url=${firstProbe.localModelUrl}');
      return firstProbe.localModelUrl;
    }

    if (!firstProbe.downloadStarted) {
      return null;
    }

    _startDownloadMessageLoop();
    if (mounted) {
      setState(() {
        _bootStage = _WebviewBootStage.downloading;
        _bootMessage = _downloadMessages[2];
      });
    }
    debugPrint('Live2D cache miss modelId=$modelId, waiting for local download');

    final finalProbe = await Live2dModelCache.instance.prepare(
      basePageUrl: base,
      appPassword: password,
      modelId: modelId,
    );
    _messageTimer?.cancel();
    _messageTimer = null;
    return finalProbe.localModelUrl;
  }

  void _startDownloadMessageLoop() {
    _messageTimer?.cancel();
    _messageIndex = 1;
    _messageTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || _bootStage != _WebviewBootStage.downloading) {
        return;
      }
      _messageIndex = (_messageIndex + 1) % _downloadMessages.length;
      setState(() {
        _bootMessage = _downloadMessages[_messageIndex];
      });
    });
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

  Widget _buildBootView() {
    final isFailed = _bootStage == _WebviewBootStage.failed;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 72,
                height: 72,
                child: isFailed
                    ? Icon(
                        Icons.error_outline,
                        size: 48,
                        color: theme.colorScheme.error,
                      )
                    : const CircularProgressIndicator(strokeWidth: 5),
              ),
              const SizedBox(height: 20),
              Text(
                isFailed ? '本地模型加载失败' : '正在准备本地 Live2D 模型',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                _bootError ?? _bootMessage,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              if (!isFailed)
                Text(
                  '首次进入会先把模型完整下载到本地，准备好后再打开页面。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.75),
                  ),
                  textAlign: TextAlign.center,
                ),
              if (isFailed) ...[
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _init,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final canReloadPage = _bootStage == _WebviewBootStage.ready ||
        _bootStage == _WebviewBootStage.loadingPage;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alice'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: canReloadPage ? () => _controller.reload() : _init,
          ),
        ],
      ),
      body: (_bootStage == _WebviewBootStage.ready ||
              _bootStage == _WebviewBootStage.loadingPage)
          ? Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_loading) _buildBootView(),
              ],
            )
          : _buildBootView(),
    );
  }
}
