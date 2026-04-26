import 'package:shared_preferences/shared_preferences.dart';

import 'openclaw_config.dart';

class OpenClawSettingsStore {
  OpenClawSettingsStore._();

  static const _baseUrlKey = 'openclaw.baseUrl';
  static const _appPasswordKey = 'openclaw.appPassword';
  static const _backgroundServiceEnabledKey = 'alicechat.backgroundServiceEnabled';

  static const OpenClawConfig _defaultConfig = OpenClawConfig(
    baseUrl: '',
    modelId: 'bian',
    providerId: 'alicechat-channel',
    agent: 'main',
    sessionName: 'alicechat',
    bridgeUrl: 'ws://127.0.0.1:18791?token=yuanzhe-7611681-668128-zheyuan-012345',
  );

  static Future<OpenClawConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString(_baseUrlKey)?.trim();
    final appPassword = prefs.getString(_appPasswordKey);
    return _defaultConfig.copyWith(
      baseUrl: (baseUrl == null || baseUrl.isEmpty) ? null : baseUrl,
      appPassword: (appPassword == null || appPassword.isEmpty) ? null : appPassword,
    );
  }

  static Future<void> save({
    required String baseUrl,
    required String appPassword,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, baseUrl.trim());
    await prefs.setString(_appPasswordKey, appPassword);
  }

  static Future<bool> loadBackgroundServiceEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_backgroundServiceEnabledKey) ?? true;
  }

  static Future<void> saveBackgroundServiceEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_backgroundServiceEnabledKey, enabled);
  }
}
