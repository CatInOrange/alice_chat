import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

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
      await musicPlatformStore.ensureReady(forceRefresh: true);
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
      final deadline = DateTime.now().add(
        Duration(seconds: isBackend ? 90 : 120),
      );
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
            await musicPlatformStore.ensureReady(forceRefresh: true);
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
                  onPressed: (qrState?.canRenderQr ?? false)
                      ? () => _saveQrImage(
                            platform.provider.displayName,
                            qrState!.qrData!,
                          )
                      : null,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('下载二维码'),
                ),
                FilledButton.icon(
                  onPressed: qrState?.phase == MusicPlatformQrLoginPhase.preparing
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有拿到 CLI 登录链接')),
      );
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CLI 登录链接无效：$url')),
      );
      return;
    }
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          launched ? '已打开网易云官方授权网页，请完成登录后回来点“检查 CLI 状态”' : '无法自动打开网页，请手动访问：$url',
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('二维码已保存到 ${file.path}')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存二维码失败：$error')),
      );
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
            onTap: () => _openDetailPage(
              title: '连接设置',
              icon: Icons.link_rounded,
              accentColor: const Color(0xFF4F46E5),
              builder: (context) => _buildConnectionSettingsContent(context),
            ),
          ),
          const SizedBox(height: 12),
          _SettingsEntryCard(
            icon: Icons.library_music_rounded,
            accentColor: const Color(0xFF0F766E),
            title: '音乐平台',
            subtitle: _musicSummary(musicPlatforms),
            badge: musicPlatforms.isLoading ? '刷新中' : null,
            onTap: () => _openDetailPage(
              title: '音乐平台',
              icon: Icons.library_music_rounded,
              accentColor: const Color(0xFF0F766E),
              builder: (context) => _buildMusicPlatformsContent(context),
            ),
          ),
          const SizedBox(height: 12),
          _SettingsEntryCard(
            icon: Icons.admin_panel_settings_rounded,
            accentColor: const Color(0xFFD97706),
            title: '服务管理',
            subtitle: _serviceSummary(),
            badge: (_adminActionMessage ?? '').trim().isNotEmpty ? '进行中' : null,
            onTap: () => _openDetailPage(
              title: '服务管理',
              icon: Icons.admin_panel_settings_rounded,
              accentColor: const Color(0xFFD97706),
              builder: (context) => _buildServiceManagementContent(context),
            ),
          ),
          const SizedBox(height: 12),
          _SettingsEntryCard(
            icon: Icons.bug_report_rounded,
            accentColor: const Color(0xFF7C3AED),
            title: '调试与日志',
            subtitle: '查看客户端调试日志，方便排查聊天链路和连接问题。',
            onTap: () => _openDetailPage(
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
    final cliReady = store.platformStates.where((item) {
      final cli = store.cliStateFor(item.provider.providerId);
      return cli?.loginValid == true;
    }).length;
    return '$total 个平台 · $active 个已接入 Cookie · $cliReady 个 CLI 可用';
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
        builder: (context) => _SettingsDetailScaffold(
          title: title,
          icon: icon,
          accentColor: accentColor,
          child: builder(context),
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
            },
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isSaving ? null : _saveSettings,
            icon: _isSaving
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
            onPressed: musicPlatforms.isLoading
                ? null
                : () => context
                    .read<MusicPlatformStore>()
                    .ensureReady(forceRefresh: true),
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
                      onQrLogin: platform.provider.supportedAuthMethods
                              .contains('qrCode')
                          ? () => _showQrLoginDialog(platform)
                          : null,
                      cliState: musicPlatforms.cliStateFor(
                        platform.provider.providerId,
                      ),
                      onCliLogin: platform.provider.supportedAuthMethods
                              .contains('cliLogin')
                          ? () => _startCliLogin(platform)
                          : null,
                      onRefreshCliLogin: platform.provider.supportedAuthMethods
                              .contains('cliLogin')
                          ? () => context
                              .read<MusicPlatformStore>()
                              .refreshCliLoginStatus(
                                platform.provider.providerId,
                              )
                          : null,
                      onClearCookie: platform.hasCookie
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
                  label: Text(
                    _isRestartingBackend ? '后端重启中…' : '重启后端（Chat + Live2D）',
                  ),
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
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
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
                                fontSize: 12,
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
    required this.child,
  });

  final String title;
  final IconData icon;
  final Color accentColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _SettingsHeroCard(
            title: title,
            subtitle: '这一页只保留和“$title”相关的内容，减少来回滚动和误触。',
            icon: icon,
            accentColor: accentColor,
          ),
          const SizedBox(height: 16),
          child,
        ],
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
              if (provider.supportsSearch) const _CapabilityChip(label: 'search'),
              if (provider.supportsResolve) const _CapabilityChip(label: 'resolve'),
              if (provider.supportsLyrics) const _CapabilityChip(label: 'lyrics'),
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
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onImportCookie,
                  icon: const Icon(Icons.cookie_outlined),
                  label: Text(platform.hasCookie ? '更新 Cookie' : '导入 Cookie'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onQrLogin,
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('二维码登录'),
                ),
              ),
            ],
          ),
          if (onCliLogin != null || onRefreshCliLogin != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onCliLogin,
                    icon: const Icon(Icons.open_in_browser_rounded),
                    label: const Text('CLI 官方登录'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextButton.icon(
                    onPressed: onRefreshCliLogin,
                    icon: const Icon(Icons.verified_user_outlined),
                    label: const Text('检查 CLI 状态'),
                  ),
                ),
              ],
            ),
          ],
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
    final color = state.loginValid
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
                Text(state.detail, style: Theme.of(context).textTheme.bodySmall),
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
      MusicPlatformQrLoginPhase.expired || MusicPlatformQrLoginPhase.failed =>
        const Color(0xFFC62828),
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
