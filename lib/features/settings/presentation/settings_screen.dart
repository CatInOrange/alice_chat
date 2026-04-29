import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/debug/native_debug_bridge.dart';
import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../../chat/application/chat_session_store.dart';
import '../../notifications/application/notification_service.dart';
import 'debug_logs_panel.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _backgroundServiceEnabled = true;
  bool _isSaving = false;
  bool _isRestartingBackend = false;
  bool _isRestartingGateway = false;
  String? _adminActionMessage;
  bool _didLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didLoad) return;
    _didLoad = true;
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final config = await OpenClawSettingsStore.load();
    if (!mounted) return;
    _urlController.text = config.baseUrl;
    _passwordController.text = config.appPassword ?? '';
    _backgroundServiceEnabled = await OpenClawSettingsStore.loadBackgroundServiceEnabled();
    setState(() {});
  }

  @override
  void dispose() {
    _urlController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    final baseUrl = _urlController.text.trim();
    final password = _passwordController.text;
    if (baseUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写后端地址')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      await OpenClawSettingsStore.save(
        baseUrl: baseUrl,
        appPassword: password,
      );
      await OpenClawSettingsStore.saveBackgroundServiceEnabled(
        _backgroundServiceEnabled,
      );
      if (!mounted) return;
      await context.read<ChatSessionStore>().reloadConfig();
      await NotificationService.instance.refreshConfig();
      await NativeDebugBridge.instance.log(
        'settings',
        'settings saved baseUrl=${baseUrl.isEmpty ? '(empty)' : baseUrl} backgroundService=$_backgroundServiceEnabled',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存，通知注册也会同步刷新')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
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
      message: isBackend
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

    final store = context.read<ChatSessionStore>();
    try {
      final submitResult = await submit();
      final task = (submitResult['task'] as Map?)?.cast<String, dynamic>() ?? const {};
      final taskId = (task['id'] ?? '').toString();
      if (taskId.isEmpty) {
        throw Exception('未拿到任务 ID');
      }

      Map<String, dynamic> latestTask = task;
      final deadline = DateTime.now().add(Duration(seconds: isBackend ? 90 : 120));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        try {
          final client = OpenClawHttpClient(store.currentConfig);
          final taskResult = await client.getAdminTask(taskId);
          latestTask = (taskResult['task'] as Map?)?.cast<String, dynamic>() ?? latestTask;
        } catch (_) {
          if (!isBackend) rethrow;
          continue;
        }
        final state = (latestTask['state'] ?? '').toString();
        final message = (latestTask['message'] ?? '').toString();
        if (mounted) {
          setState(() {
            _adminActionMessage = message.isNotEmpty ? '$actionLabel：$message' : '$actionLabel 执行中…';
          });
        }
        if (state == 'succeeded') {
          if (isBackend) {
            await store.reloadConfig();
            await NotificationService.instance.refreshConfig();
          }
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message.isNotEmpty ? message : '$actionLabel 完成')),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$actionLabel 失败：$exc')),
      );
    } finally {
      if (mounted) {
        setState(() {
          if (isBackend) {
            _isRestartingBackend = false;
          } else {
            _isRestartingGateway = false;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connection Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
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
            const SizedBox(height: 24),
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
                    _obscurePassword ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscurePassword = !_obscurePassword;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('后台常驻连接'),
              subtitle: const Text('退到后台后启用 Android 前台服务维持消息监听'),
              value: _backgroundServiceEnabled,
              onChanged: (value) {
                setState(() {
                  _backgroundServiceEnabled = value;
                });
              },
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _saveSettings,
                child: Text(_isSaving ? 'Saving...' : 'Save'),
              ),
            ),
            const SizedBox(height: 24),
            Card(
              color: Colors.orange.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '敏感操作',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    const Text('下面的操作会重启服务，可能造成短暂断连。请确认后再执行。'),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: (_isRestartingBackend || _isRestartingGateway)
                            ? null
                            : () => _runAdminAction(
                                  actionLabel: '重启 Backend',
                                  submit: () => OpenClawHttpClient(
                                    context.read<ChatSessionStore>().currentConfig,
                                  ).restartBackend(),
                                  isBackend: true,
                                ),
                        icon: _isRestartingBackend
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.restart_alt),
                        label: Text(_isRestartingBackend ? '后端重启中…' : '重启后端（Chat + Live2D）'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: (_isRestartingBackend || _isRestartingGateway)
                            ? null
                            : () => _runAdminAction(
                                  actionLabel: '重启 Gateway',
                                  submit: () => OpenClawHttpClient(
                                    context.read<ChatSessionStore>().currentConfig,
                                  ).restartGateway(),
                                  isBackend: false,
                                ),
                        icon: _isRestartingGateway
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.settings_ethernet),
                        label: Text(_isRestartingGateway ? 'Gateway 重启中…' : '重启 Gateway'),
                      ),
                    ),
                    if ((_adminActionMessage ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        _adminActionMessage!,
                        style: TextStyle(color: Colors.orange.shade900),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const DebugLogsPanel(),
          ],
        ),
      ),
    );
  }
}
