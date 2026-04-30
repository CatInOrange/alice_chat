import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/debug/native_debug_bridge.dart';
import '../../../core/openclaw/music_provider_models.dart';
import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';
import '../../chat/application/chat_session_store.dart';
import '../../music/application/music_platform_store.dart';
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
      final chatStore = context.read<ChatSessionStore>();
      final musicPlatformStore = context.read<MusicPlatformStore>();
      await chatStore.reloadConfig();
      await musicPlatformStore.reloadConfig();
      await musicPlatformStore.ensureReady();
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
      final deadline = DateTime.now().add(Duration(seconds: isBackend ? 90 : 120));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        try {
          final client = OpenClawHttpClient(store.currentConfig);
          final taskResult = await client.getAdminTask(taskId);
          latestTask =
              (taskResult['task'] as Map?)?.cast<String, dynamic>() ?? latestTask;
        } catch (_) {
          if (!isBackend) rethrow;
          continue;
        }
        final state = (latestTask['state'] ?? '').toString();
        final message = (latestTask['message'] ?? '').toString();
        if (mounted) {
          setState(() {
            _adminActionMessage =
                message.isNotEmpty ? '$actionLabel：$message' : '$actionLabel 执行中…';
          });
        }
        if (state == 'succeeded') {
          if (isBackend) {
            await store.reloadConfig();
            await musicPlatformStore.reloadConfig();
            await musicPlatformStore.ensureReady();
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

  Future<void> _showCookieImportSheet(MusicProviderInfo provider) async {
    final controller = TextEditingController();
    final existingCookie =
        await OpenClawSettingsStore.loadMusicProviderCookie(provider.providerId) ?? '';
    controller.text = existingCookie;
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
                '导入 ${provider.displayName} Cookie',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                '当前先只做本地保存骨架，不会上传到 AliceChat 后端。后续前端会直接用它做真实登录态与播放源解析。',
              ),
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
                        await OpenClawSettingsStore.saveMusicProviderCookie(
                          providerId: provider.providerId,
                          cookie: controller.text,
                        );
                        if (!sheetContext.mounted) return;
                        Navigator.of(sheetContext).pop();
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              controller.text.trim().isEmpty
                                  ? '${provider.displayName} Cookie 已清空'
                                  : '${provider.displayName} Cookie 已保存到本地',
                            ),
                          ),
                        );
                        setState(() {});
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

  @override
  Widget build(BuildContext context) {
    final musicPlatforms = context.watch<MusicPlatformStore>();

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
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.library_music_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            '音乐平台',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: musicPlatforms.isLoading
                              ? null
                              : () => context.read<MusicPlatformStore>().ensureReady(),
                          icon: const Icon(Icons.refresh),
                          tooltip: '刷新平台状态',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '平台登录属于全局能力，统一放在设置页管理。当前先接入平台能力读取与 Cookie 导入骨架。',
                    ),
                    const SizedBox(height: 16),
                    if (musicPlatforms.isLoading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: LinearProgressIndicator(),
                      )
                    else if ((musicPlatforms.error ?? '').trim().isNotEmpty)
                      _PlatformErrorBanner(message: musicPlatforms.error!)
                    else if (musicPlatforms.providers.isEmpty)
                      const Text('暂未发现可用音乐平台')
                    else
                      ...musicPlatforms.providers.map(
                        (provider) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _MusicProviderCard(
                            provider: provider,
                            onImportCookie: () => _showCookieImportSheet(provider),
                          ),
                        ),
                      ),
                  ],
                ),
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

class _MusicProviderCard extends StatefulWidget {
  const _MusicProviderCard({
    required this.provider,
    required this.onImportCookie,
  });

  final MusicProviderInfo provider;
  final Future<void> Function() onImportCookie;

  @override
  State<_MusicProviderCard> createState() => _MusicProviderCardState();
}

class _MusicProviderCardState extends State<_MusicProviderCard> {
  String? _cookie;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCookie();
  }

  Future<void> _loadCookie() async {
    final cookie = await OpenClawSettingsStore.loadMusicProviderCookie(
      widget.provider.providerId,
    );
    if (!mounted) return;
    setState(() {
      _cookie = cookie;
      _loading = false;
    });
  }

  @override
  void didUpdateWidget(covariant _MusicProviderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider.providerId != widget.provider.providerId) {
      _loading = true;
      _loadCookie();
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider;
    final hasCookie = (_cookie ?? '').trim().isNotEmpty;

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
                backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
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
                      _loading
                          ? '正在读取本地登录状态…'
                          : hasCookie
                          ? '本地已保存 Cookie（后续可直接用于客户端登录态）'
                          : '尚未配置本地登录信息',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              _ProviderStatusChip(
                label: hasCookie ? '已配置' : '未配置',
                color: hasCookie ? const Color(0xFF2E7D32) : const Color(0xFFB26A00),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _CapabilityChip(label: 'auth:${provider.authMode}'),
              if (provider.supportsSearch) const _CapabilityChip(label: 'search'),
              if (provider.supportsResolve) const _CapabilityChip(label: 'resolve'),
              if (provider.supportsLyrics) const _CapabilityChip(label: 'lyrics'),
              ...provider.supportedAuthMethods.map(
                (item) => _CapabilityChip(label: item),
              ),
            ],
          ),
          if (provider.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(provider.notes, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await widget.onImportCookie();
                    await _loadCookie();
                  },
                  icon: const Icon(Icons.cookie_outlined),
                  label: Text(hasCookie ? '更新 Cookie' : '导入 Cookie'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: provider.supportedAuthMethods.contains('qrCode')
                      ? () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('二维码登录下一轮前端能力接入时再落地。'),
                            ),
                          );
                        }
                      : null,
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('二维码登录'),
                ),
              ),
            ],
          ),
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
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
        ),
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
