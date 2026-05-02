import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_windows/webview_windows.dart' as windows_webview;

import '../../../core/openclaw/openclaw_settings.dart';
import '../application/live2d_model_cache.dart';

class WebviewScreen extends StatefulWidget {
  const WebviewScreen({super.key, required this.active, this.embedded = false});

  final bool active;
  final bool embedded;

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

  static const String _baseUrl = 'https://alice.newthu.com';
  static const String _modelId = 'bian';

  WebViewController? _mobileController;
  windows_webview.WebviewController? _windowsController;
  bool _loading = false;
  bool _pageReady = false;
  _WebviewBootStage _bootStage = _WebviewBootStage.preparing;
  String _bootMessage = _downloadMessages.first;
  String? _bootError;
  int _messageIndex = 0;
  Timer? _messageTimer;
  bool _windowsRuntimeMissing = false;

  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _initPlatformController();
    unawaited(_init());
  }

  void _initPlatformController() {
    if (_isWindows) {
      _windowsController = windows_webview.WebviewController();
      return;
    }
    _mobileController = WebViewController();
    final platformController = _mobileController!.platform;
    if (platformController is AndroidWebViewController) {
      platformController.setMediaPlaybackRequiresUserGesture(false);
      platformController.setMixedContentMode(MixedContentMode.alwaysAllow);
      debugPrint('WebView Android mediaPlaybackRequiresUserGesture=false');
      debugPrint('WebView Android mixedContentMode=alwaysAllow');
    }
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    _windowsController?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _messageTimer?.cancel();
    _messageTimer = null;
    _pageReady = false;
    _windowsRuntimeMissing = false;
    if (mounted) {
      setState(() {
        _loading = false;
        _bootStage = _WebviewBootStage.preparing;
        _bootMessage = _downloadMessages.first;
        _bootError = null;
      });
    }

    try {
      final targetUrl = await _resolveTargetUrl();
      if (targetUrl == null || targetUrl.trim().isEmpty) {
        throw StateError('本地模型未准备完成');
      }
      await (_isWindows
          ? _initWindowsWebView(targetUrl)
          : _initMobileWebView(targetUrl));
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

  Future<String?> _resolveTargetUrl() async {
    final config = await OpenClawSettingsStore.load();
    final password = (config.appPassword ?? '').trim();

    final localModelUrl = await _ensureLocalModelReady(
      base: _baseUrl,
      password: password,
      modelId: _modelId,
    );
    debugPrint('WebView localModelUrl resolved: $localModelUrl');
    if (localModelUrl == null || localModelUrl.trim().isEmpty) {
      throw StateError(
        Live2dModelCache.instance.lastFailureReason ?? '本地模型未准备完成',
      );
    }

    if (mounted) {
      setState(() {
        _bootStage = _WebviewBootStage.loadingPage;
        _bootMessage = '本地模型已就绪，正在打开页面…';
        _loading = true;
      });
    }

    final uri = Uri.parse(_baseUrl);
    final queryParameters = <String, String>{
      ...uri.queryParameters,
      if (password.isNotEmpty) 'app_password': password,
      'local_model_url': localModelUrl,
      if (_modelId.isNotEmpty) 'model': _modelId,
    };
    return uri.replace(queryParameters: queryParameters).toString();
  }

  Future<void> _initMobileWebView(String targetUrl) async {
    final controller = _mobileController!;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setNavigationDelegate(
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
          unawaited(_syncActiveState());
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

    final config = await OpenClawSettingsStore.load();
    final password = (config.appPassword ?? '').trim();
    await controller.loadRequest(
      Uri.parse(targetUrl),
      headers: {if (password.isNotEmpty) 'X-AliceChat-Password': password},
    );
  }

  Future<void> _initWindowsWebView(String targetUrl) async {
    final controller = _windowsController!;
    final version = await windows_webview.WebviewController.getWebViewVersion();
    if (version == null || version.trim().isEmpty) {
      _windowsRuntimeMissing = true;
      throw StateError(
        'Windows 缺少 WebView2 Runtime，请先安装微软 Edge WebView2 Runtime。',
      );
    }

    try {
      await controller.initialize();
      await controller.setBackgroundColor(Colors.transparent);
      await controller.loadUrl(targetUrl);
      _pageReady = true;
      unawaited(_syncActiveState());
      if (mounted) {
        setState(() {
          _loading = false;
          _bootStage = _WebviewBootStage.ready;
        });
      }
    } on PlatformException catch (error) {
      throw StateError('Windows WebView 初始化失败：${error.message ?? error.code}');
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
      debugPrint(
        'Live2D cache hit modelId=$modelId url=${firstProbe.localModelUrl}',
      );
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
    debugPrint(
      'Live2D cache miss modelId=$modelId, waiting for local download',
    );

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
      unawaited(_syncActiveState());
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
      if (_isWindows) {
        await _windowsController?.executeScript(
          'window.aliceLive2dSetActive?.($activeValue);',
        );
      } else {
        await _mobileController?.runJavaScript(
          'window.aliceLive2dSetActive?.($activeValue);',
        );
      }
    } catch (error) {
      debugPrint('WebView active sync failed: $error');
    }
  }

  Future<void> _reloadPage() async {
    if (_bootStage == _WebviewBootStage.ready ||
        _bootStage == _WebviewBootStage.loadingPage) {
      if (_isWindows) {
        await _windowsController?.reload();
      } else {
        await _mobileController?.reload();
      }
      return;
    }
    await _init();
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
                child:
                    isFailed
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
                    color: theme.textTheme.bodySmall?.color?.withValues(
                      alpha: 0.75,
                    ),
                  ),
                  textAlign: TextAlign.center,
                ),
              if (_windowsRuntimeMissing) ...[
                const SizedBox(height: 12),
                SelectableText(
                  '下载地址：https://developer.microsoft.com/microsoft-edge/webview2/',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
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

  Widget _buildReadyBody() {
    if (_isWindows) {
      return windows_webview.Webview(_windowsController!);
    }
    return WebViewWidget(controller: _mobileController!);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final canReloadPage =
        _bootStage == _WebviewBootStage.ready ||
        _bootStage == _WebviewBootStage.loadingPage;
    final showWebView = _pageReady;
    final body =
        showWebView
            ? Stack(
              children: [
                _buildReadyBody(),
                if (_loading) _buildBootView(),
                if (widget.embedded)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                      child: IconButton(
                        tooltip: '刷新 Live2D',
                        icon: const Icon(Icons.refresh, color: Colors.white),
                        onPressed: canReloadPage ? _reloadPage : _init,
                      ),
                    ),
                  ),
              ],
            )
            : _buildBootView();

    if (widget.embedded) {
      return ColoredBox(color: Colors.white, child: body);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Alice'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: canReloadPage ? _reloadPage : _init,
          ),
        ],
      ),
      body: body,
    );
  }
}
