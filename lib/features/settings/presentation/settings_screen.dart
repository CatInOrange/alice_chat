import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/debug/native_debug_bridge.dart';
import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../../chat/application/chat_session_store.dart';
import '../../music/application/music_platform_store.dart';
import '../../notifications/application/notification_service.dart';
import '../../tavern/presentation/tavern_screen.dart';
import '../../todo/presentation/todo_screen.dart';
import '../../voice/data/sherpa_wake_word_service.dart';
import 'debug_logs_panel.dart';
import '../../../app/theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlController = TextEditingController();
  final _passwordController = TextEditingController();
  final _voiceWakeWordService = SherpaWakeWordService();
  final _voiceTencentAppIdController = TextEditingController();
  final _voiceTencentSecretIdController = TextEditingController();
  final _voiceTencentSecretKeyController = TextEditingController();
  final _voiceTencentTokenController = TextEditingController();
  final _voiceTencentEngineController = TextEditingController(text: '16k_zh');
  final _voiceMinimaxApiKeyController = TextEditingController();
  final _voiceMinimaxBaseUrlController = TextEditingController(
    text: 'https://api.minimaxi.com',
  );
  final _voiceMinimaxModelController = TextEditingController(
    text: 'speech-2.8-hd',
  );
  final _voiceMinimaxDefaultVoiceController = TextEditingController(
    text: 'wumei_yujie',
  );
  final _voiceMinimaxAliceVoiceController = TextEditingController();
  final _voiceMinimaxYulinglongVoiceController = TextEditingController();
  final _voiceMinimaxLisuxinVoiceController = TextEditingController();
  final _voiceMinimaxGuqinggeVoiceController = TextEditingController();
  final _voiceWakeModelController = TextEditingController(
    text: VoiceWakeWordSettings.defaultModelId,
  );
  final _voiceWakeModelAssetPathController = TextEditingController(
    text: VoiceWakeWordSettings.defaultModelAssetPath,
  );
  final _voiceWakeKeywordsScoreController = TextEditingController(text: '1');
  final _voiceWakeKeywordsThresholdController = TextEditingController(
    text: '0.25',
  );
  final _voiceWakeMaxActivePathsController = TextEditingController(text: '4');
  final _voiceWakeNumTrailingBlanksController = TextEditingController(
    text: '1',
  );
  final _voiceWakeNumThreadsController = TextEditingController(text: '1');
  final Map<String, TextEditingController> _voiceWakeKeywordControllers = {
    for (final target in VoiceWakeWordSettings.defaultTargets)
      target.sessionId: TextEditingController(),
  };
  final Map<String, TextEditingController> _voiceWakeThresholdControllers = {
    for (final target in VoiceWakeWordSettings.defaultTargets)
      target.sessionId: TextEditingController(),
  };
  final ValueNotifier<int> _detailRefreshTick = ValueNotifier<int>(0);
  bool _obscurePassword = true;
  bool _obscureVoiceSecretKey = true;
  bool _obscureVoiceMinimaxApiKey = true;
  bool _backgroundServiceEnabled = true;
  bool _voiceInputEnabled = false;
  bool _voiceAutoSendAfterRecognition = false;
  bool _voiceOutputEnabled = false;
  bool _voiceOutputAutoPlayAfterVoiceInput = true;
  bool _voiceWakeWordEnabled = false;
  List<VoiceWakeWordTargetSettings> _voiceWakeTargets =
      VoiceWakeWordSettings.defaultTargets;
  SherpaWakeWordTestSession? _voiceWakeTestSession;
  StreamSubscription<SherpaWakeWordHit>? _voiceWakeHitSubscription;
  bool _isVoiceWakeTesting = false;
  String _voiceWakeTestStatus = '尚未测试';
  final List<String> _voiceWakeTestLogs = [];
  bool _isSaving = false;
  bool _isRestartingBackend = false;
  bool _isRestartingGateway = false;
  String? _adminActionMessage;
  bool _didLoad = false;

  void _notifyDetailPages() {
    _detailRefreshTick.value += 1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didLoad) return;
    _didLoad = true;
    _loadSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<MusicPlatformStore>().ensureReady();
    });
  }

  Future<void> _loadSettings() async {
    final config = await OpenClawSettingsStore.load();
    if (!mounted) return;
    _urlController.text = config.baseUrl;
    _passwordController.text = config.appPassword ?? '';
    _backgroundServiceEnabled =
        await OpenClawSettingsStore.loadBackgroundServiceEnabled();
    final voiceSettings = await OpenClawSettingsStore.loadVoiceSettings();
    _voiceInputEnabled = voiceSettings.inputEnabled;
    _voiceAutoSendAfterRecognition = voiceSettings.autoSendAfterRecognition;
    _voiceTencentAppIdController.text = voiceSettings.tencentAppId;
    _voiceTencentSecretIdController.text = voiceSettings.tencentSecretId;
    _voiceTencentSecretKeyController.text = voiceSettings.tencentSecretKey;
    _voiceTencentTokenController.text = voiceSettings.tencentToken;
    _voiceTencentEngineController.text = voiceSettings.tencentEngineModelType;
    _voiceOutputEnabled = voiceSettings.outputEnabled;
    _voiceOutputAutoPlayAfterVoiceInput =
        voiceSettings.outputAutoPlayAfterVoiceInput;
    _voiceMinimaxApiKeyController.text = voiceSettings.minimaxApiKey;
    _voiceMinimaxBaseUrlController.text = voiceSettings.minimaxBaseUrl;
    _voiceMinimaxModelController.text = voiceSettings.minimaxModel;
    _voiceMinimaxDefaultVoiceController.text =
        voiceSettings.minimaxDefaultVoice;
    _voiceMinimaxAliceVoiceController.text =
        voiceSettings.minimaxVoiceBySession['alice'] ?? '';
    _voiceMinimaxYulinglongVoiceController.text =
        voiceSettings.minimaxVoiceBySession['yulinglong'] ?? '';
    _voiceMinimaxLisuxinVoiceController.text =
        voiceSettings.minimaxVoiceBySession['lisuxin'] ?? '';
    _voiceMinimaxGuqinggeVoiceController.text =
        voiceSettings.minimaxVoiceBySession['guqingge'] ?? '';
    _voiceWakeWordEnabled = voiceSettings.wakeWord.enabled;
    _voiceWakeModelController.text = voiceSettings.wakeWord.modelId;
    _voiceWakeModelAssetPathController.text =
        voiceSettings.wakeWord.modelAssetPath;
    _voiceWakeKeywordsScoreController.text = _formatVoiceNumber(
      voiceSettings.wakeWord.keywordsScore,
    );
    _voiceWakeKeywordsThresholdController.text = _formatVoiceNumber(
      voiceSettings.wakeWord.keywordsThreshold,
    );
    _voiceWakeMaxActivePathsController.text =
        voiceSettings.wakeWord.maxActivePaths.toString();
    _voiceWakeNumTrailingBlanksController.text =
        voiceSettings.wakeWord.numTrailingBlanks.toString();
    _voiceWakeNumThreadsController.text =
        voiceSettings.wakeWord.numThreads.toString();
    _voiceWakeTargets = voiceSettings.wakeWord.targets;
    _syncVoiceWakeTargetControllers();
    setState(() {});
    _notifyDetailPages();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _passwordController.dispose();
    unawaited(_stopVoiceWakeTest(silent: true));
    unawaited(_voiceWakeWordService.dispose());
    _voiceTencentAppIdController.dispose();
    _voiceTencentSecretIdController.dispose();
    _voiceTencentSecretKeyController.dispose();
    _voiceTencentTokenController.dispose();
    _voiceTencentEngineController.dispose();
    _voiceMinimaxApiKeyController.dispose();
    _voiceMinimaxBaseUrlController.dispose();
    _voiceMinimaxModelController.dispose();
    _voiceMinimaxDefaultVoiceController.dispose();
    _voiceMinimaxAliceVoiceController.dispose();
    _voiceMinimaxYulinglongVoiceController.dispose();
    _voiceMinimaxLisuxinVoiceController.dispose();
    _voiceMinimaxGuqinggeVoiceController.dispose();
    _voiceWakeModelController.dispose();
    _voiceWakeModelAssetPathController.dispose();
    _voiceWakeKeywordsScoreController.dispose();
    _voiceWakeKeywordsThresholdController.dispose();
    _voiceWakeMaxActivePathsController.dispose();
    _voiceWakeNumTrailingBlanksController.dispose();
    _voiceWakeNumThreadsController.dispose();
    for (final controller in _voiceWakeKeywordControllers.values) {
      controller.dispose();
    }
    for (final controller in _voiceWakeThresholdControllers.values) {
      controller.dispose();
    }
    _detailRefreshTick.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    final baseUrl = _urlController.text.trim();
    final password = _passwordController.text;
    if (baseUrl.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写后端地址')));
      return;
    }

    setState(() => _isSaving = true);
    try {
      await OpenClawSettingsStore.save(baseUrl: baseUrl, appPassword: password);
      await OpenClawSettingsStore.saveBackgroundServiceEnabled(
        _backgroundServiceEnabled,
      );
      await OpenClawSettingsStore.saveVoiceSettings(_currentVoiceSettings());
      if (!mounted) return;
      final chatStore = context.read<ChatSessionStore>();
      final musicPlatformStore = context.read<MusicPlatformStore>();
      await chatStore.reloadConfig();
      await musicPlatformStore.reloadConfig();
      await musicPlatformStore.ensureReady(forceRefresh: true);
      await NotificationService.instance.refreshConfig();
      await NativeDebugBridge.instance.log(
        'settings',
        'settings saved baseUrl=${baseUrl.isEmpty ? '(empty)' : baseUrl} backgroundService=$_backgroundServiceEnabled',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('设置已保存，通知注册也会同步刷新')));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
        _notifyDetailPages();
      }
    }
  }

  VoiceSettings _currentVoiceSettings() {
    final engine = _voiceTencentEngineController.text.trim();
    final voiceBySession = <String, String>{
      if (_voiceMinimaxAliceVoiceController.text.trim().isNotEmpty)
        'alice': _voiceMinimaxAliceVoiceController.text.trim(),
      if (_voiceMinimaxYulinglongVoiceController.text.trim().isNotEmpty)
        'yulinglong': _voiceMinimaxYulinglongVoiceController.text.trim(),
      if (_voiceMinimaxLisuxinVoiceController.text.trim().isNotEmpty)
        'lisuxin': _voiceMinimaxLisuxinVoiceController.text.trim(),
      if (_voiceMinimaxGuqinggeVoiceController.text.trim().isNotEmpty)
        'guqingge': _voiceMinimaxGuqinggeVoiceController.text.trim(),
    };
    return VoiceSettings(
      inputEnabled: _voiceInputEnabled,
      tencentAppId: _voiceTencentAppIdController.text.trim(),
      tencentSecretId: _voiceTencentSecretIdController.text.trim(),
      tencentSecretKey: _voiceTencentSecretKeyController.text,
      tencentToken: _voiceTencentTokenController.text.trim(),
      tencentEngineModelType: engine.isEmpty ? '16k_zh' : engine,
      autoSendAfterRecognition: _voiceAutoSendAfterRecognition,
      outputEnabled: _voiceOutputEnabled,
      outputAutoPlayAfterVoiceInput: _voiceOutputAutoPlayAfterVoiceInput,
      minimaxApiKey: _voiceMinimaxApiKeyController.text,
      minimaxBaseUrl:
          _voiceMinimaxBaseUrlController.text.trim().isEmpty
              ? 'https://api.minimaxi.com'
              : _voiceMinimaxBaseUrlController.text.trim(),
      minimaxModel:
          _voiceMinimaxModelController.text.trim().isEmpty
              ? 'speech-2.8-hd'
              : _voiceMinimaxModelController.text.trim(),
      minimaxDefaultVoice:
          _voiceMinimaxDefaultVoiceController.text.trim().isEmpty
              ? 'wumei_yujie'
              : _voiceMinimaxDefaultVoiceController.text.trim(),
      minimaxVoiceBySession: voiceBySession,
      wakeWord: _currentVoiceWakeWordSettings(),
    );
  }

  VoiceWakeWordSettings _currentVoiceWakeWordSettings() {
    return VoiceWakeWordSettings(
      enabled: _voiceWakeWordEnabled,
      modelId:
          _voiceWakeModelController.text.trim().isEmpty
              ? VoiceWakeWordSettings.defaultModelId
              : _voiceWakeModelController.text.trim(),
      modelAssetPath:
          _voiceWakeModelAssetPathController.text.trim().isEmpty
              ? VoiceWakeWordSettings.defaultModelAssetPath
              : _voiceWakeModelAssetPathController.text.trim(),
      keywordsScore: _parseVoiceDouble(
        _voiceWakeKeywordsScoreController.text,
        1,
      ),
      keywordsThreshold: _parseVoiceDouble(
        _voiceWakeKeywordsThresholdController.text,
        0.25,
      ),
      maxActivePaths: _parseVoiceInt(
        _voiceWakeMaxActivePathsController.text,
        4,
      ),
      numTrailingBlanks: _parseVoiceInt(
        _voiceWakeNumTrailingBlanksController.text,
        1,
      ),
      numThreads: _parseVoiceInt(_voiceWakeNumThreadsController.text, 1),
      targets:
          _voiceWakeTargets.map((target) {
            final keywords =
                (_voiceWakeKeywordControllers[target.sessionId]?.text ?? '')
                    .split(RegExp(r'[\n,，]'))
                    .map((item) => item.trim())
                    .where((item) => item.isNotEmpty)
                    .toList();
            final thresholdText =
                _voiceWakeThresholdControllers[target.sessionId]?.text.trim() ??
                '';
            return VoiceWakeWordTargetSettings(
              sessionId: target.sessionId,
              label: target.label,
              enabled: target.enabled,
              keywords: keywords.isEmpty ? target.keywords : keywords,
              thresholdOverride:
                  thresholdText.isEmpty ? null : double.tryParse(thresholdText),
              navigateToChat: target.navigateToChat,
              startVoiceInput: target.startVoiceInput,
              autoSendAfterRecognition: target.autoSendAfterRecognition,
              autoPlayReply: target.autoPlayReply,
            );
          }).toList(),
    );
  }

  void _syncVoiceWakeTargetControllers() {
    for (final target in _voiceWakeTargets) {
      final keywordController = _voiceWakeKeywordControllers.putIfAbsent(
        target.sessionId,
        TextEditingController.new,
      );
      keywordController.text = target.keywords.join('\n');
      final thresholdController = _voiceWakeThresholdControllers.putIfAbsent(
        target.sessionId,
        TextEditingController.new,
      );
      thresholdController.text =
          target.thresholdOverride == null
              ? ''
              : _formatVoiceNumber(target.thresholdOverride!);
    }
  }

  String _formatVoiceNumber(num value) {
    final text = value.toStringAsFixed(3);
    return text.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  double _parseVoiceDouble(String value, double fallback) {
    return double.tryParse(value.trim()) ?? fallback;
  }

  int _parseVoiceInt(String value, int fallback) {
    return int.tryParse(value.trim()) ?? fallback;
  }

  Future<void> _saveVoiceSettingsOnly() async {
    setState(() => _isSaving = true);
    try {
      await OpenClawSettingsStore.saveVoiceSettings(_currentVoiceSettings());
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('语音设置已保存到本机')));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
        _notifyDetailPages();
      }
    }
  }

  Future<void> _startVoiceWakeTest() async {
    setState(() {
      _isVoiceWakeTesting = true;
      _voiceWakeTestStatus = '正在启动监听…';
      _voiceWakeTestLogs.insert(0, '启动测试监听');
    });
    _notifyDetailPages();
    try {
      await OpenClawSettingsStore.saveVoiceSettings(_currentVoiceSettings());
      final settings = _currentVoiceWakeWordSettings();
      final status = await _voiceWakeWordService.modelStatus(settings);
      if (!mounted) return;
      if (!status.ready) {
        setState(() {
          _isVoiceWakeTesting = false;
          _voiceWakeTestStatus = '模型未就绪：${status.missingFiles.join(', ')}';
          _voiceWakeTestLogs.insert(0, '模型目录：${status.directory}');
          _voiceWakeTestLogs.insert(
            0,
            '下载：${SherpaWakeWordService.modelDownloadUrl}',
          );
        });
        _notifyDetailPages();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('KWS 模型未就绪：${status.missingFiles.first}')),
        );
        return;
      }
      final session = await _voiceWakeWordService.startTest(settings);
      await _voiceWakeHitSubscription?.cancel();
      _voiceWakeTestSession = session;
      _voiceWakeHitSubscription = session.hits.listen(
        (hit) {
          if (!mounted) return;
          final line = '${_formatClock(hit.at)} 命中 ${hit.label}：${hit.keyword}';
          setState(() {
            _voiceWakeTestStatus = line;
            _voiceWakeTestLogs.insert(0, line);
            if (_voiceWakeTestLogs.length > 8) {
              _voiceWakeTestLogs.removeRange(8, _voiceWakeTestLogs.length);
            }
          });
          _notifyDetailPages();
        },
        onError: (Object error) {
          if (!mounted) return;
          setState(() {
            _isVoiceWakeTesting = false;
            _voiceWakeTestStatus = '测试失败：$error';
            _voiceWakeTestLogs.insert(0, '测试失败：$error');
          });
          _notifyDetailPages();
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('唤醒测试失败：$error')));
        },
      );
      if (!mounted) return;
      setState(() {
        _voiceWakeTestStatus = '正在监听，说出已配置的角色唤醒词';
        _voiceWakeTestLogs.insert(0, '模型已就绪：${status.directory}');
      });
      _notifyDetailPages();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isVoiceWakeTesting = false;
        _voiceWakeTestStatus = '测试失败：$error';
        _voiceWakeTestLogs.insert(0, '测试失败：$error');
      });
      _notifyDetailPages();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('唤醒测试失败：$error')));
    }
  }

  Future<void> _installBundledVoiceWakeModel() async {
    setState(() {
      _voiceWakeTestStatus = '正在安装内置默认模型…';
      _voiceWakeTestLogs.insert(0, '安装内置默认模型');
    });
    _notifyDetailPages();
    try {
      final status = await _voiceWakeWordService.installBundledDefaultModel(
        _currentVoiceWakeWordSettings(),
        overwrite: true,
      );
      if (!mounted) return;
      setState(() {
        _voiceWakeTestStatus = status.ready ? '默认模型已就绪' : '默认模型安装不完整';
        _voiceWakeTestLogs.insert(0, '模型目录：${status.directory}');
        if (status.missingFiles.isNotEmpty) {
          _voiceWakeTestLogs.insert(
            0,
            '缺少文件：${status.missingFiles.join(', ')}',
          );
        }
      });
      _notifyDetailPages();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(status.ready ? '默认模型已安装' : '默认模型安装不完整')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _voiceWakeTestStatus = '安装默认模型失败：$error';
        _voiceWakeTestLogs.insert(0, '安装默认模型失败：$error');
      });
      _notifyDetailPages();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('安装默认模型失败：$error')));
    }
  }

  Future<void> _stopVoiceWakeTest({bool silent = false}) async {
    await _voiceWakeHitSubscription?.cancel();
    _voiceWakeHitSubscription = null;
    final session = _voiceWakeTestSession;
    _voiceWakeTestSession = null;
    await session?.stop();
    if (!mounted || silent) return;
    setState(() {
      _isVoiceWakeTesting = false;
      _voiceWakeTestStatus = '已停止监听';
      _voiceWakeTestLogs.insert(0, '停止测试监听');
    });
    _notifyDetailPages();
  }

  String _formatClock(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  Future<bool> _confirmAdminAction({
    required String title,
    required String message,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认执行'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  Future<void> _runAdminAction({
    required String actionLabel,
    required Future<Map<String, dynamic>> Function() submit,
    required bool isBackend,
  }) async {
    final confirmed = await _confirmAdminAction(
      title: actionLabel,
      message:
          isBackend
              ? '这会同时重启 AliceChat chat backend 和 Live2D backend。若其中任一当前没在运行，会直接尝试拉起。执行中连接可能短暂中断。'
              : '这会重启 OpenClaw Gateway。执行中桥接与消息链路可能短暂中断。',
    );
    if (!confirmed || !mounted) return;

    setState(() {
      if (isBackend) {
        _isRestartingBackend = true;
      } else {
        _isRestartingGateway = true;
      }
      _adminActionMessage = '$actionLabel 已提交，正在等待结果…';
    });
    _notifyDetailPages();

    final store = context.read<ChatSessionStore>();
    final musicPlatformStore = context.read<MusicPlatformStore>();
    try {
      final submitResult = await submit();
      final task =
          (submitResult['task'] as Map?)?.cast<String, dynamic>() ?? const {};
      final taskId = (task['id'] ?? '').toString();
      if (taskId.isEmpty) {
        throw Exception('未拿到任务 ID');
      }

      Map<String, dynamic> latestTask = task;
      final deadline = DateTime.now().add(
        Duration(seconds: isBackend ? 90 : 120),
      );
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        try {
          final client = OpenClawHttpClient(store.currentConfig);
          final taskResult = await client.getAdminTask(taskId);
          latestTask =
              (taskResult['task'] as Map?)?.cast<String, dynamic>() ??
              latestTask;
        } catch (_) {
          if (!isBackend) rethrow;
          continue;
        }
        final state = (latestTask['state'] ?? '').toString();
        final message = (latestTask['message'] ?? '').toString();
        if (mounted) {
          setState(() {
            _adminActionMessage =
                message.isNotEmpty
                    ? '$actionLabel：$message'
                    : '$actionLabel 执行中…';
          });
          _notifyDetailPages();
        }
        if (state == 'succeeded') {
          if (isBackend) {
            await store.reloadConfig();
            await musicPlatformStore.reloadConfig();
            await musicPlatformStore.ensureReady(forceRefresh: true);
            await NotificationService.instance.refreshConfig();
          }
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message.isNotEmpty ? message : '$actionLabel 完成'),
            ),
          );
          return;
        }
        if (state == 'failed') {
          throw Exception(message.isNotEmpty ? message : '$actionLabel 失败');
        }
      }
      throw Exception('$actionLabel 超时，请稍后查看服务状态');
    } catch (exc) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$actionLabel 失败：$exc')));
    } finally {
      if (mounted) {
        setState(() {
          if (isBackend) {
            _isRestartingBackend = false;
          } else {
            _isRestartingGateway = false;
          }
        });
        _notifyDetailPages();
      }
    }
  }

  Future<void> _showCookieImportSheet(MusicPlatformLocalState platform) async {
    final controller = TextEditingController(text: platform.rawCookie ?? '');
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '导入 ${platform.provider.displayName} Cookie',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(platform.detail),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText: '粘贴完整 Cookie 字符串',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        final store = context.read<MusicPlatformStore>();
                        await store.saveProviderCookie(
                          providerId: platform.provider.providerId,
                          cookie: controller.text,
                        );
                        if (!sheetContext.mounted) return;
                        Navigator.of(sheetContext).pop();
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              controller.text.trim().isEmpty
                                  ? '${platform.provider.displayName} Cookie 已清空'
                                  : '${platform.provider.displayName} Cookie 已保存到本地',
                            ),
                          ),
                        );
                      },
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );

    controller.dispose();
  }

  Future<void> _showQrLoginDialog(MusicPlatformLocalState platform) async {
    final providerId = platform.provider.providerId;
    final store = context.read<MusicPlatformStore>();
    unawaited(store.startQrLogin(providerId));

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Consumer<MusicPlatformStore>(
          builder: (context, musicPlatforms, _) {
            final qrState = musicPlatforms.qrStateFor(providerId);
            return AlertDialog(
              title: Text('${platform.provider.displayName} 二维码登录'),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '第一版已经接上真实网易云扫码链路：生成 key、轮询状态、成功后把 Cookie 落到本地。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    _QrLoginStatusCard(state: qrState),
                    const SizedBox(height: 16),
                    if (qrState?.canRenderQr ?? false)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFFE6EAF3)),
                          ),
                          child: QrImageView(
                            data: qrState!.qrData!,
                            size: 220,
                            backgroundColor: Colors.white,
                          ),
                        ),
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    const SizedBox(height: 16),
                    const Text('使用方法：'),
                    const SizedBox(height: 6),
                    const Text('1. 打开网易云音乐 App'),
                    const Text('2. 扫描上面的二维码'),
                    const Text('3. 在手机上确认登录'),
                    const SizedBox(height: 10),
                    if ((qrState?.unikey ?? '').isNotEmpty)
                      SelectableText(
                        'codekey: ${qrState!.unikey!}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await store.closeQrLogin(providerId, clearState: true);
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: const Text('关闭'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      (qrState?.canRenderQr ?? false)
                          ? () => _saveQrImage(
                            platform.provider.displayName,
                            qrState!.qrData!,
                          )
                          : null,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('下载二维码'),
                ),
                FilledButton.icon(
                  onPressed:
                      qrState?.phase == MusicPlatformQrLoginPhase.preparing
                          ? null
                          : () => store.refreshQrLogin(providerId),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新生成'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _startCliLogin(MusicPlatformLocalState platform) async {
    final store = context.read<MusicPlatformStore>();
    await store.startCliLogin(platform.provider.providerId);
    if (!mounted) return;
    final cliState = store.cliStateFor(platform.provider.providerId);
    final url = (cliState?.loginUrl ?? '').trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('还没有拿到 CLI 登录链接')));
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('CLI 登录链接无效：$url')));
      return;
    }
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          launched
              ? '已打开网易云官方授权网页，请完成登录后回来点“检查 CLI 状态”'
              : '无法自动打开网页，请手动访问：$url',
        ),
      ),
    );
  }

  Future<void> _saveQrImage(String displayName, String qrData) async {
    try {
      final qrPainter = QrPainter(
        data: qrData,
        version: QrVersions.auto,
        gapless: true,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
      );
      final imageData = await qrPainter.toImageData(
        1024,
        format: ui.ImageByteFormat.png,
      );
      if (imageData == null) {
        throw Exception('二维码渲染失败');
      }
      final directory = await getApplicationDocumentsDirectory();
      final exportDir = Directory(p.join(directory.path, 'music_provider_qr'));
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }
      final filename =
          'qr_${displayName}_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File(p.join(exportDir.path, filename));
      await file.writeAsBytes(imageData.buffer.asUint8List(), flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('二维码已保存到 ${file.path}')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存二维码失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final musicPlatforms = context.watch<MusicPlatformStore>();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _SettingsHeroCard(
            title: 'AliceChat 控制台',
            subtitle: '把连接、音乐平台、服务控制和调试入口拆开，常用设置更好找，危险操作也不会混在一起。',
            icon: Icons.tune_rounded,
            accentColor: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          _SettingsEntryCard(
            icon: Icons.link_rounded,
            accentColor: const Color(0xFF4F46E5),
            title: '连接设置',
            subtitle: _connectionSummary(),
            onTap:
                () => _openDetailPage(
                  title: '连接设置',
                  icon: Icons.link_rounded,
                  accentColor: const Color(0xFF4F46E5),
                  builder:
                      (context) => _buildConnectionSettingsContent(context),
                ),
          ),
          const SizedBox(height: 12),
          _SettingsEntryCard(
            icon: Icons.library_music_rounded,
            accentColor: const Color(0xFF0F766E),
            title: '音乐平台',
            subtitle: _musicSummary(musicPlatforms),
            badge: musicPlatforms.isLoading ? '刷新中' : null,
            onTap:
                () => _openDetailPage(
                  title: '音乐平台',
                  icon: Icons.library_music_rounded,
                  accentColor: const Color(0xFF0F766E),
                  builder: (context) => _buildMusicPlatformsContent(context),
                ),
          ),
          const SizedBox(height: 12),
          _SettingsEntryCard(
            icon: Icons.graphic_eq_rounded,
            accentColor: const Color(0xFFDB2777),
            title: '语音',
            subtitle: _voiceSummary(),
            onTap:
                () => _openDetailPage(
                  title: '语音',
                  icon: Icons.graphic_eq_rounded,
                  accentColor: const Color(0xFFDB2777),
                  builder: (context) => _buildVoiceSettingsContent(context),
                ),
          ),
          const SizedBox(height: 12),
          _SettingsEntryCard(
            icon: Icons.admin_panel_settings_rounded,
            accentColor: const Color(0xFFD97706),
            title: '服务管理',
            subtitle: _serviceSummary(),
            badge: (_adminActionMessage ?? '').trim().isNotEmpty ? '进行中' : null,
            onTap:
                () => _openDetailPage(
                  title: '服务管理',
                  icon: Icons.admin_panel_settings_rounded,
                  accentColor: const Color(0xFFD97706),
                  builder: (context) => _buildServiceManagementContent(context),
                ),
          ),
          const SizedBox(height: 12),
          _SettingsEntryCard(
            icon: Icons.dashboard_customize_rounded,
            accentColor: const Color(0xFFB45309),
            title: '项目管理',
            subtitle: '统一管理待办项目：新建、编辑、归档与排序。',
            onTap:
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TodoScreen(projectConfigOnly: true),
                  ),
                ),
          ),
          const SizedBox(height: 12),
          _SettingsEntryCard(
            icon: Icons.auto_awesome_rounded,
            accentColor: const Color(0xFF2563EB),
            title: '酒馆配置',
            subtitle:
                '把 Presets、Prompt Order、Prompt Blocks、WorldBooks 收到全局设置页里。',
            onTap:
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TavernScreen(configOnly: true),
                  ),
                ),
          ),
          const SizedBox(height: 12),
          _SettingsEntryCard(
            icon: Icons.bug_report_rounded,
            accentColor: const Color(0xFF7C3AED),
            title: '调试与日志',
            subtitle: '查看客户端调试日志，方便排查聊天链路和连接问题。',
            onTap:
                () => _openDetailPage(
                  title: '调试与日志',
                  icon: Icons.bug_report_rounded,
                  accentColor: const Color(0xFF7C3AED),
                  builder: (context) => const DebugLogsPanel(),
                ),
          ),
        ],
      ),
    );
  }

  String _connectionSummary() {
    final baseUrl = _urlController.text.trim();
    final host = Uri.tryParse(baseUrl)?.host ?? baseUrl;
    final parts = <String>[];
    parts.add(host.isEmpty ? '未配置 OpenClaw 地址' : host);
    parts.add((_passwordController.text).isEmpty ? '未设置密码' : '已设置密码');
    parts.add(_backgroundServiceEnabled ? '后台常驻已开启' : '后台常驻已关闭');
    return parts.join(' · ');
  }

  String _musicSummary(MusicPlatformStore store) {
    if (store.isLoading) return '正在刷新平台状态…';
    if ((store.error ?? '').trim().isNotEmpty) return '平台状态读取失败';
    final total = store.platformStates.length;
    if (total == 0) return '暂未发现可用音乐平台';
    final active = store.platformStates.where((item) => item.hasCookie).length;
    final cliReady =
        store.platformStates.where((item) {
          final cli = store.cliStateFor(item.provider.providerId);
          return cli?.loginValid == true;
        }).length;
    return '$total 个平台 · $active 个已接入 Cookie · $cliReady 个 CLI 可用';
  }

  String _voiceSummary() {
    if (!_voiceInputEnabled && !_voiceOutputEnabled) {
      return '语音输入未启用 · 语音输出未启用';
    }
    final hasSecret =
        _voiceTencentAppIdController.text.trim().isNotEmpty &&
        _voiceTencentSecretIdController.text.trim().isNotEmpty &&
        _voiceTencentSecretKeyController.text.trim().isNotEmpty;
    final hasMiniMax = _voiceMinimaxApiKeyController.text.trim().isNotEmpty;
    final engine = _voiceTencentEngineController.text.trim();
    return [
      _voiceInputEnabled ? '输入已启用' : '输入未启用',
      _voiceWakeWordEnabled ? '前台唤醒已启用' : '前台唤醒未启用',
      hasSecret ? '腾讯云已配置' : '腾讯云未配置',
      _voiceOutputEnabled ? '输出已启用' : '输出未启用',
      hasMiniMax ? 'MiniMax 已配置' : 'MiniMax 未配置',
      _voiceInputEnabled ? (engine.isEmpty ? '16k_zh' : engine) : '',
    ].where((item) => item.isNotEmpty).join(' · ');
  }

  String _serviceSummary() {
    if (_isRestartingBackend) return 'Backend 正在重启中';
    if (_isRestartingGateway) return 'Gateway 正在重启中';
    if ((_adminActionMessage ?? '').trim().isNotEmpty) {
      return _adminActionMessage!.trim();
    }
    return '重启 Chat Backend、Live2D Backend 与 OpenClaw Gateway';
  }

  Future<void> _openDetailPage({
    required String title,
    required IconData icon,
    required Color accentColor,
    required WidgetBuilder builder,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (context) => _SettingsDetailScaffold(
              title: title,
              icon: icon,
              accentColor: accentColor,
              refreshListenable: _detailRefreshTick,
              childBuilder: builder,
            ),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  Widget _buildConnectionSettingsContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SettingsSectionCard(
          title: '连接凭据',
          subtitle: '这里管理 AliceChat 连接 OpenClaw 所需的地址和访问密码。',
          icon: Icons.vpn_key_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('OpenClaw Base URL'),
              const SizedBox(height: 8),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'https://your-openclaw-host',
                ),
              ),
              const SizedBox(height: 20),
              const Text('Password'),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: 'Enter password',
                  helperText: '该密码会随请求发送到 AliceChat 后端，用于访问校验。',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                      _notifyDetailPages();
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsSectionCard(
          title: '后台连接',
          subtitle: '控制应用退到后台后是否继续维持长连接监听。',
          icon: Icons.notifications_active_rounded,
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('后台常驻连接'),
            subtitle: const Text('退到后台后启用 Android 前台服务维持消息监听'),
            value: _backgroundServiceEnabled,
            onChanged: (value) {
              setState(() {
                _backgroundServiceEnabled = value;
              });
              _notifyDetailPages();
            },
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isSaving ? null : _saveSettings,
            icon:
                _isSaving
                    ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.save_rounded),
            label: Text(_isSaving ? '保存中…' : '保存连接设置'),
          ),
        ),
      ],
    );
  }

  Widget _buildMusicPlatformsContent(BuildContext context) {
    final musicPlatforms = context.watch<MusicPlatformStore>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SettingsSectionCard(
          title: '音乐平台状态',
          subtitle: '网易云相关登录集中在这里管理。Cookie、二维码登录、CLI 登录是三条独立链路，别混用。',
          icon: Icons.library_music_rounded,
          trailing: IconButton(
            onPressed:
                musicPlatforms.isLoading
                    ? null
                    : () => context.read<MusicPlatformStore>().ensureReady(
                      forceRefresh: true,
                    ),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新平台状态',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (musicPlatforms.isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                )
              else if ((musicPlatforms.error ?? '').trim().isNotEmpty)
                _PlatformErrorBanner(message: musicPlatforms.error!)
              else if (musicPlatforms.platformStates.isEmpty)
                const Text('暂未发现可用音乐平台')
              else
                ...musicPlatforms.platformStates.map(
                  (platform) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _MusicProviderCard(
                      platform: platform,
                      qrState: musicPlatforms.qrStateFor(
                        platform.provider.providerId,
                      ),
                      onImportCookie: () => _showCookieImportSheet(platform),
                      onQrLogin:
                          platform.provider.supportedAuthMethods.contains(
                                'qrCode',
                              )
                              ? () => _showQrLoginDialog(platform)
                              : null,
                      cliState: musicPlatforms.cliStateFor(
                        platform.provider.providerId,
                      ),
                      onCliLogin:
                          platform.provider.supportedAuthMethods.contains(
                                'cliLogin',
                              )
                              ? () => _startCliLogin(platform)
                              : null,
                      onRefreshCliLogin:
                          platform.provider.supportedAuthMethods.contains(
                                'cliLogin',
                              )
                              ? () => context
                                  .read<MusicPlatformStore>()
                                  .refreshCliLoginStatus(
                                    platform.provider.providerId,
                                  )
                              : null,
                      onClearCookie:
                          platform.hasCookie
                              ? () async {
                                await context
                                    .read<MusicPlatformStore>()
                                    .clearProviderCookie(
                                      platform.provider.providerId,
                                    );
                              }
                              : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVoiceSettingsContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SettingsSectionCard(
          title: '语音输入',
          subtitle: '长按聊天输入栏的麦克风，实时把语音转成文字。',
          icon: Icons.mic_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用语音输入'),
                subtitle: const Text('启用并配置密钥后，可在移动端长按麦克风转文字'),
                value: _voiceInputEnabled,
                onChanged: (value) {
                  setState(() => _voiceInputEnabled = value);
                  _notifyDetailPages();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('松手后自动发送'),
                subtitle: const Text('关闭时只把识别结果填进输入框，确认后再发送'),
                value: _voiceAutoSendAfterRecognition,
                onChanged: (value) {
                  setState(() => _voiceAutoSendAfterRecognition = value);
                  _notifyDetailPages();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsSectionCard(
          title: '前台唤醒',
          subtitle: '使用 sherpa-onnx 本地关键词检测；仅 App 前台监听，不上传唤醒阶段音频。',
          icon: Icons.record_voice_over_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用前台语音唤醒'),
                subtitle: const Text('命中角色关键词后，后续可跳转聊天并进入语音输入'),
                value: _voiceWakeWordEnabled,
                onChanged: (value) {
                  setState(() => _voiceWakeWordEnabled = value);
                  _notifyDetailPages();
                },
              ),
              const SizedBox(height: 8),
              const Text('模型'),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceWakeModelController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: VoiceWakeWordSettings.defaultModelId,
                  helperText: '默认使用中文 WenetSpeech 3.3M KWS 模型',
                ),
              ),
              const SizedBox(height: 16),
              const Text('模型资源路径'),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceWakeModelAssetPathController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: VoiceWakeWordSettings.defaultModelAssetPath,
                  helperText: '后续监听服务会从这里读取 encoder、decoder、joiner 和 tokens',
                ),
              ),
              const SizedBox(height: 16),
              _buildVoiceWakeNumberGrid(),
              const SizedBox(height: 16),
              const Text('角色唤醒词'),
              const SizedBox(height: 8),
              ..._voiceWakeTargets.map(_buildVoiceWakeTargetCard),
              const SizedBox(height: 12),
              _buildVoiceWakeTestPanel(),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsSectionCard(
          title: '腾讯云 ASR',
          subtitle: '密钥仅保存在本机，适合个人使用；公共分发版本建议改用服务端临时凭证。',
          icon: Icons.cloud_queue_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('AppID'),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceTencentAppIdController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '腾讯云 AppID，实时识别必填',
                ),
              ),
              const SizedBox(height: 16),
              const Text('SecretID'),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceTencentSecretIdController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'AKID...',
                ),
              ),
              const SizedBox(height: 16),
              const Text('SecretKey'),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceTencentSecretKeyController,
                obscureText: _obscureVoiceSecretKey,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: '腾讯云 SecretKey',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureVoiceSecretKey
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureVoiceSecretKey = !_obscureVoiceSecretKey;
                      });
                      _notifyDetailPages();
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Token（可选）'),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceTencentTokenController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '当前实时 WebSocket 直连可留空',
                ),
              ),
              const SizedBox(height: 16),
              const Text('识别引擎'),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceTencentEngineController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '16k_zh',
                  helperText: '常用：16k_zh 普通话，16k_zh-PY 中英粤，16k_en 英语',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SettingsSectionCard(
          title: '语音输出',
          subtitle: '使用 MiniMax 直接在前端生成语音。语音输入发送后，可自动朗读下一条回复。',
          icon: Icons.volume_up_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用语音输出'),
                subtitle: const Text('长按消息可朗读；语音输入触发的下一条回复也可自动播放'),
                value: _voiceOutputEnabled,
                onChanged: (value) {
                  setState(() => _voiceOutputEnabled = value);
                  _notifyDetailPages();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('语音输入后自动朗读回复'),
                subtitle: const Text('只有上一条消息来自语音输入时，才自动播放下一条 AI 回复'),
                value: _voiceOutputAutoPlayAfterVoiceInput,
                onChanged: (value) {
                  setState(() => _voiceOutputAutoPlayAfterVoiceInput = value);
                  _notifyDetailPages();
                },
              ),
              const SizedBox(height: 12),
              const Text('MiniMax API Key'),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceMinimaxApiKeyController,
                obscureText: _obscureVoiceMinimaxApiKey,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: 'MiniMax API Key，仅保存在本机',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureVoiceMinimaxApiKey
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureVoiceMinimaxApiKey =
                            !_obscureVoiceMinimaxApiKey;
                      });
                      _notifyDetailPages();
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Base URL'),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceMinimaxBaseUrlController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'https://api.minimaxi.com',
                ),
              ),
              const SizedBox(height: 16),
              const Text('模型'),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceMinimaxModelController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'speech-2.8-hd',
                ),
              ),
              const SizedBox(height: 16),
              const Text('默认音色'),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceMinimaxDefaultVoiceController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'wumei_yujie',
                ),
              ),
              const SizedBox(height: 16),
              const Text('角色音色'),
              const SizedBox(height: 8),
              _buildVoiceIdField('晚秋', _voiceMinimaxAliceVoiceController),
              const SizedBox(height: 10),
              _buildVoiceIdField('玲珑', _voiceMinimaxYulinglongVoiceController),
              const SizedBox(height: 10),
              _buildVoiceIdField('素心', _voiceMinimaxLisuxinVoiceController),
              const SizedBox(height: 10),
              _buildVoiceIdField('清歌', _voiceMinimaxGuqinggeVoiceController),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isSaving ? null : _saveVoiceSettingsOnly,
            icon:
                _isSaving
                    ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.save_rounded),
            label: Text(_isSaving ? '保存中…' : '保存语音设置'),
          ),
        ),
      ],
    );
  }

  Widget _buildVoiceIdField(String label, TextEditingController controller) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
        hintText: '留空则使用默认音色',
      ),
    );
  }

  Widget _buildVoiceWakeNumberGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 560;
        final fields = [
          _buildVoiceWakeNumberField(
            'keywordsScore',
            _voiceWakeKeywordsScoreController,
            '默认 1',
          ),
          _buildVoiceWakeNumberField(
            'keywordsThreshold',
            _voiceWakeKeywordsThresholdController,
            '默认 0.25',
          ),
          _buildVoiceWakeNumberField(
            'maxActivePaths',
            _voiceWakeMaxActivePathsController,
            '默认 4',
            integerOnly: true,
          ),
          _buildVoiceWakeNumberField(
            'numTrailingBlanks',
            _voiceWakeNumTrailingBlanksController,
            '默认 1',
            integerOnly: true,
          ),
          _buildVoiceWakeNumberField(
            'numThreads',
            _voiceWakeNumThreadsController,
            '默认 1',
            integerOnly: true,
          ),
        ];
        if (!isWide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children:
                fields
                    .map(
                      (field) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: field,
                      ),
                    )
                    .toList(),
          );
        }
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children:
              fields
                  .map(
                    (field) => SizedBox(
                      width: (constraints.maxWidth - 12) / 2,
                      child: field,
                    ),
                  )
                  .toList(),
        );
      },
    );
  }

  Widget _buildVoiceWakeNumberField(
    String label,
    TextEditingController controller,
    String hint, {
    bool integerOnly = false,
  }) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
        hintText: hint,
        helperText: integerOnly ? '整数' : '可填小数',
      ),
    );
  }

  Widget _buildVoiceWakeTargetCard(VoiceWakeWordTargetSettings target) {
    final keywordController = _voiceWakeKeywordControllers.putIfAbsent(
      target.sessionId,
      TextEditingController.new,
    );
    final thresholdController = _voiceWakeThresholdControllers.putIfAbsent(
      target.sessionId,
      TextEditingController.new,
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  target.label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Switch(
                value: target.enabled,
                onChanged: (value) {
                  _updateVoiceWakeTarget(
                    target.sessionId,
                    (current) => VoiceWakeWordTargetSettings(
                      sessionId: current.sessionId,
                      label: current.label,
                      enabled: value,
                      keywords: current.keywords,
                      thresholdOverride: current.thresholdOverride,
                      navigateToChat: current.navigateToChat,
                      startVoiceInput: current.startVoiceInput,
                      autoSendAfterRecognition:
                          current.autoSendAfterRecognition,
                      autoPlayReply: current.autoPlayReply,
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: keywordController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '唤醒词',
              helperText: '每行一个，也支持用逗号分隔；建议使用重复词降低误唤醒',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: thresholdController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '单独阈值覆盖',
              hintText: '留空则使用全局 keywordsThreshold',
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('命中后跳转到聊天页'),
            value: target.navigateToChat,
            onChanged: (value) {
              _updateVoiceWakeTarget(
                target.sessionId,
                (current) => VoiceWakeWordTargetSettings(
                  sessionId: current.sessionId,
                  label: current.label,
                  enabled: current.enabled,
                  keywords: current.keywords,
                  thresholdOverride: current.thresholdOverride,
                  navigateToChat: value ?? true,
                  startVoiceInput: current.startVoiceInput,
                  autoSendAfterRecognition: current.autoSendAfterRecognition,
                  autoPlayReply: current.autoPlayReply,
                ),
              );
            },
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('命中后进入语音输入'),
            value: target.startVoiceInput,
            onChanged: (value) {
              _updateVoiceWakeTarget(
                target.sessionId,
                (current) => VoiceWakeWordTargetSettings(
                  sessionId: current.sessionId,
                  label: current.label,
                  enabled: current.enabled,
                  keywords: current.keywords,
                  thresholdOverride: current.thresholdOverride,
                  navigateToChat: current.navigateToChat,
                  startVoiceInput: value ?? true,
                  autoSendAfterRecognition: current.autoSendAfterRecognition,
                  autoPlayReply: current.autoPlayReply,
                ),
              );
            },
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('AI 回复后自动朗读'),
            value: target.autoPlayReply,
            onChanged: (value) {
              _updateVoiceWakeTarget(
                target.sessionId,
                (current) => VoiceWakeWordTargetSettings(
                  sessionId: current.sessionId,
                  label: current.label,
                  enabled: current.enabled,
                  keywords: current.keywords,
                  thresholdOverride: current.thresholdOverride,
                  navigateToChat: current.navigateToChat,
                  startVoiceInput: current.startVoiceInput,
                  autoSendAfterRecognition: current.autoSendAfterRecognition,
                  autoPlayReply: value ?? true,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceWakeTestPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '测试监听',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(_voiceWakeTestStatus),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed:
                    _isVoiceWakeTesting ? null : () => _startVoiceWakeTest(),
                icon:
                    _isVoiceWakeTesting
                        ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.play_arrow_rounded),
                label: const Text('开始测试监听'),
              ),
              OutlinedButton.icon(
                onPressed:
                    _voiceWakeTestSession == null
                        ? null
                        : () => _stopVoiceWakeTest(),
                icon: const Icon(Icons.stop_rounded),
                label: const Text('停止'),
              ),
              OutlinedButton.icon(
                onPressed:
                    _isVoiceWakeTesting
                        ? null
                        : () => _installBundledVoiceWakeModel(),
                icon: const Icon(Icons.install_mobile_rounded),
                label: const Text('重新安装默认模型'),
              ),
            ],
          ),
          if (_voiceWakeTestLogs.isNotEmpty) ...[
            const SizedBox(height: 12),
            ..._voiceWakeTestLogs.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  line,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF475569),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          const Text(
            '默认 3.3M 中文模型已随安装包内置，首次测试会自动安装到本机目录。自定义中文词暂时需要填入 tokenized 行。',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
        ],
      ),
    );
  }

  void _updateVoiceWakeTarget(
    String sessionId,
    VoiceWakeWordTargetSettings Function(VoiceWakeWordTargetSettings current)
    update,
  ) {
    setState(() {
      _voiceWakeTargets =
          _voiceWakeTargets
              .map(
                (target) =>
                    target.sessionId == sessionId ? update(target) : target,
              )
              .toList();
    });
    _notifyDetailPages();
  }

  Widget _buildServiceManagementContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SettingsSectionCard(
          title: '敏感操作',
          subtitle: '下面的操作会重启服务，可能造成短暂断连。确认影响范围后再执行。',
          icon: Icons.warning_amber_rounded,
          accentColor: Colors.orange.shade700,
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed:
                      (_isRestartingBackend || _isRestartingGateway)
                          ? null
                          : () => _runAdminAction(
                            actionLabel: '重启 Backend',
                            submit:
                                () =>
                                    OpenClawHttpClient(
                                      context
                                          .read<ChatSessionStore>()
                                          .currentConfig,
                                    ).restartBackend(),
                            isBackend: true,
                          ),
                  icon:
                      _isRestartingBackend
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(Icons.restart_alt),
                  label: Text(
                    _isRestartingBackend ? '后端重启中…' : '重启后端（Chat + Live2D）',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed:
                      (_isRestartingBackend || _isRestartingGateway)
                          ? null
                          : () => _runAdminAction(
                            actionLabel: '重启 Gateway',
                            submit:
                                () =>
                                    OpenClawHttpClient(
                                      context
                                          .read<ChatSessionStore>()
                                          .currentConfig,
                                    ).restartGateway(),
                            isBackend: false,
                          ),
                  icon:
                      _isRestartingGateway
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(Icons.settings_ethernet),
                  label: Text(
                    _isRestartingGateway ? 'Gateway 重启中…' : '重启 Gateway',
                  ),
                ),
              ),
              if ((_adminActionMessage ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Text(
                    _adminActionMessage!,
                    style: TextStyle(color: Colors.orange.shade900),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsHeroCard extends StatelessWidget {
  const _SettingsHeroCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [
            accentColor.withValues(alpha: 0.16),
            accentColor.withValues(alpha: 0.06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: accentColor.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: accentColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF5B6475),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsEntryCard extends StatelessWidget {
  const _SettingsEntryCard({
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final Color accentColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFE8ECF4)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A101828),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: accentColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if ((badge ?? '').trim().isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: accentColor.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              badge!,
                              style: TextStyle(
                                color: accentColor,
                                fontSize: desktopAdjustedFontSize(12),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF667085),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF98A2B3)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsDetailScaffold extends StatelessWidget {
  const _SettingsDetailScaffold({
    required this.title,
    required this.icon,
    required this.accentColor,
    required this.refreshListenable,
    required this.childBuilder,
  });

  final String title;
  final IconData icon;
  final Color accentColor;
  final ValueListenable<int> refreshListenable;
  final WidgetBuilder childBuilder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ValueListenableBuilder<int>(
        valueListenable: refreshListenable,
        builder: (context, _, __) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _SettingsHeroCard(
                title: title,
                subtitle: '这一页只保留和“$title”相关的内容，减少来回滚动和误触。',
                icon: icon,
                accentColor: accentColor,
              ),
              const SizedBox(height: 16),
              childBuilder(context),
            ],
          );
        },
      ),
    );
  }
}

class _SettingsSectionCard extends StatelessWidget {
  const _SettingsSectionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
    this.trailing,
    this.accentColor,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;
  final Widget? trailing;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final color = accentColor ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE8ECF4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF667085),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _PlatformErrorBanner extends StatelessWidget {
  const _PlatformErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '音乐平台加载失败：$message',
        style: TextStyle(color: Colors.red.shade800),
      ),
    );
  }
}

class _MusicProviderCard extends StatelessWidget {
  const _MusicProviderCard({
    required this.platform,
    required this.qrState,
    required this.onImportCookie,
    required this.onQrLogin,
    required this.cliState,
    required this.onCliLogin,
    required this.onRefreshCliLogin,
    required this.onClearCookie,
  });

  final MusicPlatformLocalState platform;
  final MusicPlatformQrLoginState? qrState;
  final MusicPlatformCliLoginState? cliState;
  final Future<void> Function() onImportCookie;
  final Future<void> Function()? onQrLogin;
  final Future<void> Function()? onCliLogin;
  final Future<void> Function()? onRefreshCliLogin;
  final Future<void> Function()? onClearCookie;

  @override
  Widget build(BuildContext context) {
    final provider = platform.provider;
    final statusColor = switch (platform.authState) {
      MusicPlatformAuthStateKind.imported => const Color(0xFF2E7D32),
      MusicPlatformAuthStateKind.suspicious => const Color(0xFFB26A00),
      MusicPlatformAuthStateKind.missing => const Color(0xFF7B8190),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FD),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.12),
                child: Icon(
                  Icons.graphic_eq_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      provider.displayName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      platform.summary,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              _ProviderStatusChip(
                label: platform.statusLabel,
                color: statusColor,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _CapabilityChip(label: 'auth:${provider.authMode}'),
              if (provider.supportsSearch)
                const _CapabilityChip(label: 'search'),
              if (provider.supportsResolve)
                const _CapabilityChip(label: 'resolve'),
              if (provider.supportsLyrics)
                const _CapabilityChip(label: 'lyrics'),
              ...provider.supportedAuthMethods.map(
                (item) => _CapabilityChip(label: item),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(platform.detail, style: Theme.of(context).textTheme.bodySmall),
          if (platform.detectedKeys.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: platform.detectedKeys
                  .take(6)
                  .map((key) => _CapabilityChip(label: key))
                  .toList(growable: false),
            ),
          ],
          if (qrState != null) ...[
            const SizedBox(height: 12),
            _InlineQrStateBanner(state: qrState!),
          ],
          if (cliState != null) ...[
            const SizedBox(height: 12),
            _InlineCliStateBanner(state: cliState!),
          ],
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final useVerticalLayout = constraints.maxWidth < 420;

              Widget buildPrimaryRow() {
                final children = <Widget>[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onImportCookie,
                      icon: const Icon(Icons.cookie_outlined),
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          platform.hasCookie ? '更新 Cookie' : '导入 Cookie',
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: useVerticalLayout ? 0 : 12,
                    height: useVerticalLayout ? 10 : 0,
                  ),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onQrLogin,
                      icon: const Icon(Icons.qr_code_2),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('二维码登录'),
                      ),
                    ),
                  ),
                ];

                return useVerticalLayout
                    ? Column(children: children)
                    : Row(children: children);
              }

              Widget buildCliRow() {
                final children = <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onCliLogin,
                      icon: const Icon(Icons.open_in_browser_rounded),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('CLI 官方登录'),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: useVerticalLayout ? 0 : 12,
                    height: useVerticalLayout ? 10 : 0,
                  ),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: onRefreshCliLogin,
                      icon: const Icon(Icons.verified_user_outlined),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('检查 CLI 状态'),
                      ),
                    ),
                  ),
                ];

                return useVerticalLayout
                    ? Column(children: children)
                    : Row(children: children);
              }

              return Column(
                children: [
                  buildPrimaryRow(),
                  if (onCliLogin != null || onRefreshCliLogin != null) ...[
                    const SizedBox(height: 10),
                    buildCliRow(),
                  ],
                ],
              );
            },
          ),
          if (onClearCookie != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onClearCookie,
                icon: const Icon(Icons.delete_outline),
                label: const Text('清空本地 Cookie'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _QrLoginStatusCard extends StatelessWidget {
  const _QrLoginStatusCard({required this.state});

  final MusicPlatformQrLoginState? state;

  @override
  Widget build(BuildContext context) {
    final currentState = state;
    if (currentState == null) {
      return const _InlineQrStateBanner(
        state: MusicPlatformQrLoginState(
          providerId: 'unknown',
          phase: MusicPlatformQrLoginPhase.preparing,
          statusLabel: '准备中',
          detail: '正在初始化二维码登录…',
        ),
      );
    }
    return _InlineQrStateBanner(state: currentState, dense: false);
  }
}

class _InlineCliStateBanner extends StatelessWidget {
  const _InlineCliStateBanner({required this.state});

  final MusicPlatformCliLoginState state;

  @override
  Widget build(BuildContext context) {
    final color =
        state.loginValid
            ? const Color(0xFF2E7D32)
            : state.statusLabel.contains('失败')
            ? const Color(0xFFC62828)
            : const Color(0xFFB26A00);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            state.loginValid
                ? Icons.verified_user_rounded
                : Icons.open_in_browser_rounded,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.statusLabel,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  state.detail,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (state.hasLoginUrl) ...[
                  const SizedBox(height: 6),
                  SelectableText(
                    state.loginUrl!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (state.isLoading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

class _InlineQrStateBanner extends StatelessWidget {
  const _InlineQrStateBanner({required this.state, this.dense = true});

  final MusicPlatformQrLoginState state;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = switch (state.phase) {
      MusicPlatformQrLoginPhase.authorized => const Color(0xFF2E7D32),
      MusicPlatformQrLoginPhase.expired ||
      MusicPlatformQrLoginPhase.failed => const Color(0xFFC62828),
      MusicPlatformQrLoginPhase.waitingConfirm => const Color(0xFFB26A00),
      MusicPlatformQrLoginPhase.idle ||
      MusicPlatformQrLoginPhase.preparing ||
      MusicPlatformQrLoginPhase.waitingScan => const Color(0xFF3559E0),
    };

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(dense ? 12 : 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            state.statusLabel,
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(state.detail, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ProviderStatusChip extends StatelessWidget {
  const _ProviderStatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE6EAF3)),
      ),
      child: Text(label, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
