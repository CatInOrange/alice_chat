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
  static const Duration _minimumLoadingDuration = Duration(seconds: 6);

  static const List<String> _bootMessages = <String>[
    '正在化妆呢，马上见你',
    '发饰还没戴好，再等一小会儿',
    '裙摆正在整理，不许偷看',
    '口红还差最后一下下',
  ];

  static const String _baseUrl = 'https://alice.newthu.com';
  static const String _modelId = 'bian';
  static const String _loadingArtworkAsset = 'assets/avatars/wanqiu_loading.jpg';

  WebViewController? _mobileController;
  windows_webview.WebviewController? _windowsController;
  bool _loading = false;
  bool _pageReady = false;
  _WebviewBootStage _bootStage = _WebviewBootStage.preparing;
  String _bootMessage = _bootMessages.first;
  String? _bootError;
  int _messageIndex = 0;
  Timer? _messageTimer;
  bool _windowsRuntimeMissing = false;
  DateTime? _loadingStartedAt;
  bool _pageFinishReady = false;
  static const Duration _pageReadyPollInterval = Duration(milliseconds: 250);
  static const Duration _pageReadyTimeout = Duration(seconds: 12);

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
    _pageFinishReady = false;
    _windowsRuntimeMissing = false;
    _loadingStartedAt = DateTime.now();
    if (mounted) {
      setState(() {
        _loading = true;
        _bootStage = _WebviewBootStage.preparing;
        _bootMessage = _bootMessages.first;
        _bootError = null;
      });
    }

    try {
      final targetUrl = await _resolveTargetUrl();
      if (targetUrl == null || targetUrl.trim().isEmpty) {
        throw StateError('页面还没准备好');
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
        Live2dModelCache.instance.lastFailureReason ?? '页面还没准备好',
      );
    }

    if (mounted) {
      setState(() {
        _bootStage = _WebviewBootStage.loadingPage;
        _bootMessage = _bootMessages.first;
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
              _bootMessage = _bootMessages.first;
            });
          }
        },
        onPageFinished: (url) {
          debugPrint('WebView page finished: $url');
          _pageReady = true;
          _pageFinishReady = true;
          unawaited(_syncActiveState());
          unawaited(_completeLoadingWhenReady());
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
      _pageFinishReady = true;
      unawaited(_syncActiveState());
      await _completeLoadingWhenReady();
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
        _bootMessage = _bootMessages.first;
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

    _startBootMessageLoop();
    if (mounted) {
      setState(() {
        _bootStage = _WebviewBootStage.downloading;
        _bootMessage = _bootMessages.first;
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

  void _startBootMessageLoop() {
    _messageTimer?.cancel();
    _messageIndex = 0;
    _messageTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (!mounted ||
          _bootStage == _WebviewBootStage.ready ||
          _bootStage == _WebviewBootStage.failed) {
        return;
      }
      _messageIndex = (_messageIndex + 1) % _bootMessages.length;
      setState(() {
        _bootMessage = _bootMessages[_messageIndex];
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

  Future<void> _completeLoadingWhenReady() async {
    if (!_pageFinishReady) return;
    final startedAt = _loadingStartedAt;
    if (startedAt != null) {
      final elapsed = DateTime.now().difference(startedAt);
      if (elapsed < _minimumLoadingDuration) {
        await Future<void>.delayed(_minimumLoadingDuration - elapsed);
      }
    }

    final live2dReady = await _waitForLive2dReadyFlag();
    if (!mounted || !_pageFinishReady) {
      return;
    }
    if (!live2dReady) {
      debugPrint('WebView ready flag timeout, falling back to page-finished state');
    }
    setState(() {
      _loading = false;
      _bootStage = _WebviewBootStage.ready;
    });
  }

  Future<bool> _waitForLive2dReadyFlag() async {
    final deadline = DateTime.now().add(_pageReadyTimeout);
    while (mounted && _pageFinishReady) {
      final ready = await _readLive2dReadyFlag();
      if (ready) {
        return true;
      }
      if (DateTime.now().isAfter(deadline)) {
        return false;
      }
      await Future<void>.delayed(_pageReadyPollInterval);
    }
    return false;
  }

  Future<bool> _readLive2dReadyFlag() async {
    const js = 'window.__aliceLive2dReady === true';
    try {
      if (_isWindows) {
        final raw = await _windowsController?.executeScript(js);
        return _parseJsBoolResult(raw);
      }
      final raw = await _mobileController?.runJavaScriptReturningResult(js);
      return _parseJsBoolResult(raw);
    } catch (error) {
      debugPrint('WebView read ready flag failed: $error');
      return false;
    }
  }

  bool _parseJsBoolResult(Object? raw) {
    final text = '$raw'.trim().toLowerCase();
    return text == 'true' || text == '1';
  }

  Future<void> _reloadPage() async {
    if (_bootStage == _WebviewBootStage.ready ||
        _bootStage == _WebviewBootStage.loadingPage) {
      _loadingStartedAt = DateTime.now();
      _pageFinishReady = false;
      if (mounted) {
        setState(() {
          _loading = true;
          _bootStage = _WebviewBootStage.loadingPage;
          _bootMessage = _bootMessages.first;
        });
      }
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
    final title = isFailed ? '哎呀，刚刚没接稳' : '等我一下下';
    final subtitle =
        isFailed
            ? (_bootError ?? '刚刚补妆时手滑了一下，你点一下，我马上重新来过。')
            : _bootMessage;

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF5F5F3), Color(0xFFF0F0EE), Color(0xFFE9E9E6)],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final imageWidth = constraints.maxWidth.clamp(280.0, 520.0);
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 320),
                        curve: Curves.easeOutCubic,
                        width: imageWidth,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: const Color(0x99F2F1EE),
                          borderRadius: BorderRadius.circular(26),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(25),
                          child: AspectRatio(
                            aspectRatio: 1182 / 838,
                            child: Image.asset(
                              _loadingArtworkAsset,
                              fit: BoxFit.contain,
                              alignment: Alignment.center,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF3A3130),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                    child: Text(
                      subtitle,
                      key: ValueKey(subtitle),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        height: 1.6,
                        color: const Color(0xFF6B6260),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (!isFailed)
                    Text(
                      '很快啦，这次想好好收拾一下再出来见你。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF8A817E),
                        height: 1.55,
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
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _init,
                      icon: const Icon(Icons.refresh),
                      label: const Text('再试一次'),
                    ),
                  ],
                ],
              ),
            ),
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
