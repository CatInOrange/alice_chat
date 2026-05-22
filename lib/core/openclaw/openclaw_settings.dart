import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'openclaw_config.dart';

class VoiceSettings {
  const VoiceSettings({
    this.inputEnabled = false,
    this.tencentAppId = '',
    this.tencentSecretId = '',
    this.tencentSecretKey = '',
    this.tencentToken = '',
    this.tencentEngineModelType = '16k_zh',
    this.autoSendAfterRecognition = false,
  });

  final bool inputEnabled;
  final String tencentAppId;
  final String tencentSecretId;
  final String tencentSecretKey;
  final String tencentToken;
  final String tencentEngineModelType;
  final bool autoSendAfterRecognition;

  bool get hasTencentCredentials =>
      tencentSecretId.trim().isNotEmpty && tencentSecretKey.trim().isNotEmpty;

  bool get canUseInput => inputEnabled && hasTencentCredentials;

  VoiceSettings copyWith({
    bool? inputEnabled,
    String? tencentAppId,
    String? tencentSecretId,
    String? tencentSecretKey,
    String? tencentToken,
    String? tencentEngineModelType,
    bool? autoSendAfterRecognition,
  }) {
    return VoiceSettings(
      inputEnabled: inputEnabled ?? this.inputEnabled,
      tencentAppId: tencentAppId ?? this.tencentAppId,
      tencentSecretId: tencentSecretId ?? this.tencentSecretId,
      tencentSecretKey: tencentSecretKey ?? this.tencentSecretKey,
      tencentToken: tencentToken ?? this.tencentToken,
      tencentEngineModelType:
          tencentEngineModelType ?? this.tencentEngineModelType,
      autoSendAfterRecognition:
          autoSendAfterRecognition ?? this.autoSendAfterRecognition,
    );
  }
}

class OpenClawSettingsStore {
  OpenClawSettingsStore._();

  static const _baseUrlKey = 'openclaw.baseUrl';
  static const _appPasswordKey = 'openclaw.appPassword';
  static const _modelIdKey = 'openclaw.modelId';
  static const _providerIdKey = 'openclaw.providerId';
  static const _backgroundServiceEnabledKey =
      'alicechat.backgroundServiceEnabled';
  static const _voiceInputEnabledKey = 'alicechat.voice.inputEnabled';
  static const _voiceTencentAppIdKey = 'alicechat.voice.tencent.appId';
  static const _voiceTencentSecretIdKey = 'alicechat.voice.tencent.secretId';
  static const _voiceTencentSecretKeyKey = 'alicechat.voice.tencent.secretKey';
  static const _voiceTencentTokenKey = 'alicechat.voice.tencent.token';
  static const _voiceTencentEngineModelTypeKey =
      'alicechat.voice.tencent.engineModelType';
  static const _voiceAutoSendAfterRecognitionKey =
      'alicechat.voice.autoSendAfterRecognition';
  static const _musicProviderCookiePrefix = 'music.provider.cookie.';
  static const _tavernQuickRepliesKey = 'alicechat.tavern.quickReplies';

  static const List<Map<String, String>> _defaultTavernQuickReplies = [
    {
      'mode': 'continue',
      'label': '继续',
      'instruction':
          '请紧接当前剧情自然续写，优先承接最近的互动、情绪、动作与场景，不要生硬跳转；若无明显新事件，就顺着当前节奏继续推进。',
    },
    {
      'mode': 'twist',
      'label': '转折',
      'instruction':
          '请在保持当前剧情连续性的前提下，引入一个自然的新变化、事件、线索、来人或冲突，让剧情出现新的转折，但不要硬切或脱离当前语境。',
    },
    {
      'mode': 'describe',
      'label': '描写',
      'instruction':
          '请延续当前场景，放慢节奏，重点加强动作、神态、环境、触感、声音与氛围等细节描写，先细致展开当前内容，不急着推动重大新事件。',
    },
  ];

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

  static Future<VoiceSettings> loadVoiceSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final engine =
        prefs.getString(_voiceTencentEngineModelTypeKey)?.trim() ?? '';
    return VoiceSettings(
      inputEnabled: prefs.getBool(_voiceInputEnabledKey) ?? false,
      tencentAppId: prefs.getString(_voiceTencentAppIdKey)?.trim() ?? '',
      tencentSecretId: prefs.getString(_voiceTencentSecretIdKey)?.trim() ?? '',
      tencentSecretKey: prefs.getString(_voiceTencentSecretKeyKey) ?? '',
      tencentToken: prefs.getString(_voiceTencentTokenKey)?.trim() ?? '',
      tencentEngineModelType: engine.isEmpty ? '16k_zh' : engine,
      autoSendAfterRecognition:
          prefs.getBool(_voiceAutoSendAfterRecognitionKey) ?? false,
    );
  }

  static Future<void> saveVoiceSettings(VoiceSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_voiceInputEnabledKey, settings.inputEnabled);
    await prefs.setString(_voiceTencentAppIdKey, settings.tencentAppId.trim());
    await prefs.setString(
      _voiceTencentSecretIdKey,
      settings.tencentSecretId.trim(),
    );
    await prefs.setString(_voiceTencentSecretKeyKey, settings.tencentSecretKey);
    await prefs.setString(_voiceTencentTokenKey, settings.tencentToken.trim());
    await prefs.setString(
      _voiceTencentEngineModelTypeKey,
      settings.tencentEngineModelType.trim().isEmpty
          ? '16k_zh'
          : settings.tencentEngineModelType.trim(),
    );
    await prefs.setBool(
      _voiceAutoSendAfterRecognitionKey,
      settings.autoSendAfterRecognition,
    );
  }

  static Future<String?> loadMusicProviderCookie(String providerId) async {
    final prefs = await SharedPreferences.getInstance();
    final value =
        prefs.getString('$_musicProviderCookiePrefix$providerId')?.trim();
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

  static List<Map<String, String>> defaultTavernQuickReplies() {
    return _defaultTavernQuickReplies
        .map((item) => Map<String, String>.from(item))
        .toList(growable: false);
  }

  static Future<List<Map<String, String>>> loadTavernQuickReplies() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_tavernQuickRepliesKey)?.trim();
    if (raw == null || raw.isEmpty) {
      return defaultTavernQuickReplies();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return defaultTavernQuickReplies();
      }
      final normalized = <Map<String, String>>[];
      for (final item in decoded.whereType<Map>()) {
        final map = Map<String, dynamic>.from(item);
        final mode = (map['mode'] ?? '').toString().trim().toLowerCase();
        final label = (map['label'] ?? '').toString().trim();
        final instruction = (map['instruction'] ?? '').toString().trim();
        if (mode.isEmpty || label.isEmpty || instruction.isEmpty) continue;
        normalized.add({
          'mode': mode,
          'label': label,
          'instruction': instruction,
        });
      }
      if (normalized.isEmpty) {
        return defaultTavernQuickReplies();
      }
      return normalized;
    } catch (_) {
      return defaultTavernQuickReplies();
    }
  }

  static Future<void> saveTavernQuickReplies(
    List<Map<String, String>> items,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = items
        .map(
          (item) => {
            'mode': (item['mode'] ?? '').trim().toLowerCase(),
            'label': (item['label'] ?? '').trim(),
            'instruction': (item['instruction'] ?? '').trim(),
          },
        )
        .where(
          (item) =>
              item['mode']!.isNotEmpty &&
              item['label']!.isNotEmpty &&
              item['instruction']!.isNotEmpty,
        )
        .toList(growable: false);
    if (normalized.isEmpty) {
      await prefs.remove(_tavernQuickRepliesKey);
      return;
    }
    await prefs.setString(_tavernQuickRepliesKey, jsonEncode(normalized));
  }
}
