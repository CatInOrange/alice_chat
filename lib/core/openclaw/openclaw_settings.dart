import 'package:shared_preferences/shared_preferences.dart';

import 'openclaw_config.dart';

class OpenClawSettingsStore {
  OpenClawSettingsStore._();

  static const _baseUrlKey = 'openclaw.baseUrl';
  static const _appPasswordKey = 'openclaw.appPassword';
  static const _modelIdKey = 'openclaw.modelId';
  static const _providerIdKey = 'openclaw.providerId';
  static const _backgroundServiceEnabledKey =
      'alicechat.backgroundServiceEnabled';
  static const _musicProviderCookiePrefix = 'music.provider.cookie.';

  static const OpenClawConfig _defaultConfig = OpenClawConfig(
    baseUrl: '',
    modelId: 'alicechat-default',
    providerId: 'alicechat-channel',
    agent: 'main',
    sessionName: 'alicechat',
    bridgeUrl:
        'ws://127.0.0.1:18791?token=yuanzhe-7611681-668128-zheyuan-012345',
  );

  static Future<OpenClawConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString(_baseUrlKey)?.trim();
    final appPassword = prefs.getString(_appPasswordKey);
    final modelId = prefs.getString(_modelIdKey)?.trim();
    final providerId = prefs.getString(_providerIdKey)?.trim();
    final normalizedProviderId =
        (providerId == null || providerId.isEmpty)
            ? null
            : providerId == 'alicechat-channel'
            ? providerId
            : 'alicechat-channel';
    return _defaultConfig.copyWith(
      baseUrl: (baseUrl == null || baseUrl.isEmpty) ? null : baseUrl,
      appPassword:
          (appPassword == null || appPassword.isEmpty) ? null : appPassword,
      modelId: (modelId == null || modelId.isEmpty) ? null : modelId,
      providerId: normalizedProviderId,
    );
  }

  static Future<void> save({
    required String baseUrl,
    required String appPassword,
    String? modelId,
    String? providerId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, baseUrl.trim());
    await prefs.setString(_appPasswordKey, appPassword);
    if (modelId != null) {
      await prefs.setString(_modelIdKey, modelId.trim());
    }
    if (providerId != null) {
      await prefs.setString(_providerIdKey, providerId.trim());
    }
  }

  static Future<void> saveModelSelection({
    required String modelId,
    required String providerId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelIdKey, modelId.trim());
    await prefs.setString(
      _providerIdKey,
      providerId.trim().isEmpty ? 'alicechat-channel' : providerId.trim(),
    );
  }

  static Future<bool> loadBackgroundServiceEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_backgroundServiceEnabledKey) ?? true;
  }

  static Future<void> saveBackgroundServiceEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_backgroundServiceEnabledKey, enabled);
  }

  static Future<String?> loadMusicProviderCookie(String providerId) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('$_musicProviderCookiePrefix$providerId')?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  static Future<void> saveMusicProviderCookie({
    required String providerId,
    required String cookie,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = cookie.trim();
    if (normalized.isEmpty) {
      await prefs.remove('$_musicProviderCookiePrefix$providerId');
      return;
    }
    await prefs.setString('$_musicProviderCookiePrefix$providerId', normalized);
  }
}
