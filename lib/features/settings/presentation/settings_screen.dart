import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/debug/native_debug_bridge.dart';
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
            const DebugLogsPanel(),
          ],
        ),
      ),
    );
  }
}
