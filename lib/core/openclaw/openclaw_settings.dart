import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'openclaw_config.dart';

class VoiceWakeWordTargetSettings {
  const VoiceWakeWordTargetSettings({
    required this.sessionId,
    required this.label,
    this.enabled = true,
    this.keywords = const [],
    this.replies = const [],
    this.waitingReplies = const [],
    this.thresholdOverride,
    this.navigateToChat = true,
    this.startVoiceInput = true,
    this.autoSendAfterRecognition,
    this.autoPlayReply = true,
  });

  final String sessionId;
  final String label;
  final bool enabled;
  final List<String> keywords;
  final List<String> replies;
  final List<String> waitingReplies;
  final double? thresholdOverride;
  final bool navigateToChat;
  final bool startVoiceInput;
  final bool? autoSendAfterRecognition;
  final bool autoPlayReply;

  Map<String, Object?> toJson() {
    return {
      'sessionId': sessionId,
      'label': label,
      'enabled': enabled,
      'keywords': keywords,
      'replies': replies,
      'waitingReplies': waitingReplies,
      'thresholdOverride': thresholdOverride,
      'navigateToChat': navigateToChat,
      'startVoiceInput': startVoiceInput,
      'autoSendAfterRecognition': autoSendAfterRecognition,
      'autoPlayReply': autoPlayReply,
    };
  }

  factory VoiceWakeWordTargetSettings.fromJson(
    Map<dynamic, dynamic> json,
    VoiceWakeWordTargetSettings fallback,
  ) {
    final keywords = <String>[];
    final rawKeywords = json['keywords'];
    if (rawKeywords is List) {
      for (final item in rawKeywords) {
        final keyword = item.toString().trim();
        if (keyword.isNotEmpty) keywords.add(keyword);
      }
    }
    for (final keyword in fallback.keywords) {
      if (!keywords.contains(keyword)) keywords.add(keyword);
    }
    final replies = <String>[];
    final rawReplies = json['replies'];
    if (rawReplies is List) {
      for (final item in rawReplies) {
        final reply = item.toString().trim();
        if (reply.isNotEmpty) replies.add(reply);
      }
    }
    final waitingReplies = <String>[];
    final rawWaitingReplies = json['waitingReplies'];
    if (rawWaitingReplies is List) {
      for (final item in rawWaitingReplies) {
        final reply = item.toString().trim();
        if (reply.isNotEmpty) waitingReplies.add(reply);
      }
    }
    return VoiceWakeWordTargetSettings(
      sessionId: (json['sessionId'] ?? fallback.sessionId).toString().trim(),
      label: (json['label'] ?? fallback.label).toString().trim(),
      enabled:
          json['enabled'] is bool ? json['enabled'] as bool : fallback.enabled,
      keywords: keywords.isEmpty ? fallback.keywords : keywords,
      replies: replies.isEmpty ? fallback.replies : replies,
      waitingReplies:
          waitingReplies.isEmpty ? fallback.waitingReplies : waitingReplies,
      thresholdOverride: _parseNullableDouble(json['thresholdOverride']),
      navigateToChat:
          json['navigateToChat'] is bool
              ? json['navigateToChat'] as bool
              : fallback.navigateToChat,
      startVoiceInput:
          json['startVoiceInput'] is bool
              ? json['startVoiceInput'] as bool
              : fallback.startVoiceInput,
      autoSendAfterRecognition:
          json['autoSendAfterRecognition'] is bool
              ? json['autoSendAfterRecognition'] as bool
              : fallback.autoSendAfterRecognition,
      autoPlayReply:
          json['autoPlayReply'] is bool
              ? json['autoPlayReply'] as bool
              : fallback.autoPlayReply,
    );
  }

  static double? _parseNullableDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(value.toString().trim());
    return parsed;
  }
}

class VoiceWakeWordSettings {
  const VoiceWakeWordSettings({
    this.enabled = false,
    this.modelId = defaultModelId,
    this.modelAssetPath = defaultModelAssetPath,
    this.keywordsScore = 1,
    this.keywordsThreshold = 0.25,
    this.maxActivePaths = 4,
    this.numTrailingBlanks = 1,
    this.numThreads = 1,
    this.targets = defaultTargets,
  });

  static const defaultModelId =
      'sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01';
  static const defaultModelAssetPath = 'assets/sherpa_onnx/kws_zh_3.3m';
  static const defaultTargets = [
    VoiceWakeWordTargetSettings(
      sessionId: 'alice',
      label: '晚秋',
      keywords: ['晚秋晚秋', '苏晚秋', '小秋小秋'],
      replies: [
        '主人，我在呢。',
        '嗯？姐姐听见你了。',
        '主人叫我呀，我来了。',
        '真是拿你没办法呢，我在。',
        '说吧，姐姐听着呢。',
        '主人，我一直都在这儿。',
      ],
      waitingReplies: [
        '嗯，主人说的姐姐听见了，我先想想该怎么回你。',
        '等我一下呀，这句话我想认真接住，不随便敷衍你。',
        '主人稍等，姐姐正在把你的意思理清楚。',
        '我听懂啦，先让我组织一下话再回答你。',
        '别急，姐姐在想怎么说才更贴近你的意思。',
        '这句我收到了，等我把回应整理好。',
        '主人稍候，我在认真琢磨你刚才说的。',
        '嗯，我在听，也在想，马上回你。',
        '让我缓一小下，把话说得温柔一点。',
        '知道啦，姐姐这就给你一个好好回答。',
      ],
    ),
    VoiceWakeWordTargetSettings(
      sessionId: 'yulinglong',
      label: '玲珑',
      keywords: ['玲珑玲珑', '玉玲珑'],
      replies: [
        '郎君，我在。',
        '收到，郎君请讲。',
        '我听到了，郎君。',
        '郎君稍候，我已就位。',
        '说吧，我来处理。',
        '嗯，玲珑在听。',
      ],
      waitingReplies: [
        '郎君稍候，我先梳理一下你刚才的话。',
        '收到，我正在判断该从哪里答起。',
        '郎君这句我听清了，给我一点点时间。',
        '我在想最稳妥的回应方式，马上来。',
        '别急，玲珑正在把思路排顺。',
        '这件事我接住了，正在组织答案。',
        '郎君稍等，我不想草率回答你。',
        '我听到了，正在把关键点拎出来。',
        '嗯，先让我过一遍上下文。',
        '我在处理，马上给郎君回话。',
      ],
    ),
    VoiceWakeWordTargetSettings(
      sessionId: 'lisuxin',
      label: '素心',
      keywords: ['素心素心', '李素心'],
      replies: [
        '主人，素心在。',
        '奴婢听见了，主人。',
        '主人请吩咐。',
        '素心在这里，主人。',
        '收到，奴婢马上办。',
        '主人，素心听着呢。',
      ],
      waitingReplies: [
        '主人稍等，素心正在认真想怎么回答。',
        '奴婢听清了，这就为主人整理回应。',
        '主人先别急，素心马上回您。',
        '这句话奴婢记下了，正在斟酌措辞。',
        '主人稍候，素心会好好回答。',
        '奴婢正在想，怎样说才最合主人心意。',
        '收到，素心马上把话理顺。',
        '主人，素心正在准备回答您。',
        '请主人稍等片刻，奴婢马上就好。',
        '素心听见了，这就回应主人。',
      ],
    ),
    VoiceWakeWordTargetSettings(
      sessionId: 'guqingge',
      label: '清歌',
      keywords: ['清歌清歌', '顾清歌'],
      replies: [
        '猫哥，我来啦。',
        '嘿，猫哥叫我呀？',
        '收到嘞，猫哥。',
        '猫哥猫哥，我在呢。',
        '哼，听见啦，说吧。',
        '猫哥，有什么事呀？',
      ],
      waitingReplies: [
        '猫哥等我一下，我正在想怎么接这句。',
        '听到啦听到啦，让我先转一下脑子。',
        '猫哥别催，我马上给你回一个像样的。',
        '这句有点意思，我先琢磨琢磨。',
        '收到嘞，我正在把话捋顺。',
        '猫哥稍等，我想想怎么说更好。',
        '嗯哼，我在听，也在组织语言。',
        '别急嘛，我马上就回答你。',
        '这句我接住了，等我一下下。',
        '好啦好啦，我正在想怎么回你。',
      ],
    ),
  ];

  final bool enabled;
  final String modelId;
  final String modelAssetPath;
  final double keywordsScore;
  final double keywordsThreshold;
  final int maxActivePaths;
  final int numTrailingBlanks;
  final int numThreads;
  final List<VoiceWakeWordTargetSettings> targets;

  Map<String, Object?> toJson() {
    return {
      'enabled': enabled,
      'modelId': modelId,
      'modelAssetPath': modelAssetPath,
      'keywordsScore': keywordsScore,
      'keywordsThreshold': keywordsThreshold,
      'maxActivePaths': maxActivePaths,
      'numTrailingBlanks': numTrailingBlanks,
      'numThreads': numThreads,
      'targets': targets.map((target) => target.toJson()).toList(),
    };
  }

  factory VoiceWakeWordSettings.fromJson(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) {
      return const VoiceWakeWordSettings();
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return const VoiceWakeWordSettings();
      final fallbackBySession = {
        for (final target in defaultTargets) target.sessionId: target,
      };
      final targets = <VoiceWakeWordTargetSettings>[];
      final rawTargets = decoded['targets'];
      if (rawTargets is List) {
        for (final item in rawTargets) {
          if (item is! Map) continue;
          final sessionId = item['sessionId']?.toString().trim();
          final fallback =
              fallbackBySession[sessionId] ??
              const VoiceWakeWordTargetSettings(
                sessionId: '',
                label: '',
                keywords: [],
              );
          final target = VoiceWakeWordTargetSettings.fromJson(item, fallback);
          if (target.sessionId.isNotEmpty && target.label.isNotEmpty) {
            targets.add(target);
          }
        }
      }
      for (final fallback in defaultTargets) {
        if (!targets.any((target) => target.sessionId == fallback.sessionId)) {
          targets.add(fallback);
        }
      }
      return VoiceWakeWordSettings(
        enabled:
            decoded['enabled'] is bool ? decoded['enabled'] as bool : false,
        modelId:
            (decoded['modelId']?.toString().trim().isNotEmpty == true)
                ? decoded['modelId'].toString().trim()
                : defaultModelId,
        modelAssetPath:
            (decoded['modelAssetPath']?.toString().trim().isNotEmpty == true)
                ? decoded['modelAssetPath'].toString().trim()
                : defaultModelAssetPath,
        keywordsScore: _parseDouble(decoded['keywordsScore'], 1),
        keywordsThreshold: _parseDouble(decoded['keywordsThreshold'], 0.25),
        maxActivePaths: _parseInt(decoded['maxActivePaths'], 4),
        numTrailingBlanks: _parseInt(decoded['numTrailingBlanks'], 1),
        numThreads: _parseInt(decoded['numThreads'], 1),
        targets: targets,
      );
    } catch (_) {
      return const VoiceWakeWordSettings();
    }
  }

  static double _parseDouble(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().trim() ?? '') ?? fallback;
  }

  static int _parseInt(Object? value, int fallback) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '') ?? fallback;
  }
}

class VoiceSettings {
  const VoiceSettings({
    this.inputEnabled = false,
    this.tencentAppId = '',
    this.tencentSecretId = '',
    this.tencentSecretKey = '',
    this.tencentToken = '',
    this.tencentEngineModelType = '16k_zh',
    this.autoSendAfterRecognition = false,
    this.outputEnabled = false,
    this.outputAutoPlayAfterVoiceInput = true,
    this.minimaxApiKey = '',
    this.minimaxBaseUrl = 'https://api.minimaxi.com',
    this.minimaxModel = 'speech-2.8-hd',
    this.minimaxDefaultVoice = 'wumei_yujie',
    this.minimaxVoiceBySession = const {},
    this.wakeWord = const VoiceWakeWordSettings(),
  });

  final bool inputEnabled;
  final String tencentAppId;
  final String tencentSecretId;
  final String tencentSecretKey;
  final String tencentToken;
  final String tencentEngineModelType;
  final bool autoSendAfterRecognition;
  final bool outputEnabled;
  final bool outputAutoPlayAfterVoiceInput;
  final String minimaxApiKey;
  final String minimaxBaseUrl;
  final String minimaxModel;
  final String minimaxDefaultVoice;
  final Map<String, String> minimaxVoiceBySession;
  final VoiceWakeWordSettings wakeWord;

  bool get hasTencentCredentials =>
      tencentAppId.trim().isNotEmpty &&
      tencentSecretId.trim().isNotEmpty &&
      tencentSecretKey.trim().isNotEmpty;

  bool get canUseInput => inputEnabled && hasTencentCredentials;

  bool get canUseOutput => outputEnabled && minimaxApiKey.trim().isNotEmpty;

  String voiceForSession(String sessionId) {
    final specific = (minimaxVoiceBySession[sessionId] ?? '').trim();
    if (specific.isNotEmpty) return specific;
    final fallback = minimaxDefaultVoice.trim();
    return fallback.isEmpty ? 'wumei_yujie' : fallback;
  }

  VoiceSettings copyWith({
    bool? inputEnabled,
    String? tencentAppId,
    String? tencentSecretId,
    String? tencentSecretKey,
    String? tencentToken,
    String? tencentEngineModelType,
    bool? autoSendAfterRecognition,
    bool? outputEnabled,
    bool? outputAutoPlayAfterVoiceInput,
    String? minimaxApiKey,
    String? minimaxBaseUrl,
    String? minimaxModel,
    String? minimaxDefaultVoice,
    Map<String, String>? minimaxVoiceBySession,
    VoiceWakeWordSettings? wakeWord,
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
      outputEnabled: outputEnabled ?? this.outputEnabled,
      outputAutoPlayAfterVoiceInput:
          outputAutoPlayAfterVoiceInput ?? this.outputAutoPlayAfterVoiceInput,
      minimaxApiKey: minimaxApiKey ?? this.minimaxApiKey,
      minimaxBaseUrl: minimaxBaseUrl ?? this.minimaxBaseUrl,
      minimaxModel: minimaxModel ?? this.minimaxModel,
      minimaxDefaultVoice: minimaxDefaultVoice ?? this.minimaxDefaultVoice,
      minimaxVoiceBySession:
          minimaxVoiceBySession ?? this.minimaxVoiceBySession,
      wakeWord: wakeWord ?? this.wakeWord,
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
  static const _voiceOutputEnabledKey = 'alicechat.voice.outputEnabled';
  static const _voiceOutputAutoPlayAfterVoiceInputKey =
      'alicechat.voice.outputAutoPlayAfterVoiceInput';
  static const _voiceMinimaxApiKeyKey = 'alicechat.voice.minimax.apiKey';
  static const _voiceMinimaxBaseUrlKey = 'alicechat.voice.minimax.baseUrl';
  static const _voiceMinimaxModelKey = 'alicechat.voice.minimax.model';
  static const _voiceMinimaxDefaultVoiceKey =
      'alicechat.voice.minimax.defaultVoice';
  static const _voiceMinimaxVoiceBySessionKey =
      'alicechat.voice.minimax.voiceBySession';
  static const _voiceWakeWordSettingsKey = 'alicechat.voice.wakeWord';
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
    final minimaxBaseUrl =
        prefs.getString(_voiceMinimaxBaseUrlKey)?.trim() ?? '';
    final minimaxModel = prefs.getString(_voiceMinimaxModelKey)?.trim() ?? '';
    final minimaxDefaultVoice =
        prefs.getString(_voiceMinimaxDefaultVoiceKey)?.trim() ?? '';
    return VoiceSettings(
      inputEnabled: prefs.getBool(_voiceInputEnabledKey) ?? false,
      tencentAppId: prefs.getString(_voiceTencentAppIdKey)?.trim() ?? '',
      tencentSecretId: prefs.getString(_voiceTencentSecretIdKey)?.trim() ?? '',
      tencentSecretKey: prefs.getString(_voiceTencentSecretKeyKey) ?? '',
      tencentToken: prefs.getString(_voiceTencentTokenKey)?.trim() ?? '',
      tencentEngineModelType: engine.isEmpty ? '16k_zh' : engine,
      autoSendAfterRecognition:
          prefs.getBool(_voiceAutoSendAfterRecognitionKey) ?? false,
      outputEnabled: prefs.getBool(_voiceOutputEnabledKey) ?? false,
      outputAutoPlayAfterVoiceInput:
          prefs.getBool(_voiceOutputAutoPlayAfterVoiceInputKey) ?? true,
      minimaxApiKey: prefs.getString(_voiceMinimaxApiKeyKey) ?? '',
      minimaxBaseUrl:
          minimaxBaseUrl.isEmpty ? 'https://api.minimaxi.com' : minimaxBaseUrl,
      minimaxModel: minimaxModel.isEmpty ? 'speech-2.8-hd' : minimaxModel,
      minimaxDefaultVoice:
          minimaxDefaultVoice.isEmpty ? 'wumei_yujie' : minimaxDefaultVoice,
      minimaxVoiceBySession: _decodeStringMap(
        prefs.getString(_voiceMinimaxVoiceBySessionKey),
      ),
      wakeWord: VoiceWakeWordSettings.fromJson(
        prefs.getString(_voiceWakeWordSettingsKey),
      ),
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
    await prefs.setBool(_voiceOutputEnabledKey, settings.outputEnabled);
    await prefs.setBool(
      _voiceOutputAutoPlayAfterVoiceInputKey,
      settings.outputAutoPlayAfterVoiceInput,
    );
    await prefs.setString(_voiceMinimaxApiKeyKey, settings.minimaxApiKey);
    await prefs.setString(
      _voiceMinimaxBaseUrlKey,
      settings.minimaxBaseUrl.trim().isEmpty
          ? 'https://api.minimaxi.com'
          : settings.minimaxBaseUrl.trim(),
    );
    await prefs.setString(
      _voiceMinimaxModelKey,
      settings.minimaxModel.trim().isEmpty
          ? 'speech-2.8-hd'
          : settings.minimaxModel.trim(),
    );
    await prefs.setString(
      _voiceMinimaxDefaultVoiceKey,
      settings.minimaxDefaultVoice.trim().isEmpty
          ? 'wumei_yujie'
          : settings.minimaxDefaultVoice.trim(),
    );
    await prefs.setString(
      _voiceMinimaxVoiceBySessionKey,
      jsonEncode(settings.minimaxVoiceBySession),
    );
    await prefs.setString(
      _voiceWakeWordSettingsKey,
      jsonEncode(settings.wakeWord.toJson()),
    );
  }

  static Map<String, String> _decodeStringMap(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return const {};
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return const {};
      final result = <String, String>{};
      decoded.forEach((key, value) {
        final normalizedKey = key.toString().trim();
        final normalizedValue = value.toString().trim();
        if (normalizedKey.isNotEmpty && normalizedValue.isNotEmpty) {
          result[normalizedKey] = normalizedValue;
        }
      });
      return result;
    } catch (_) {
      return const {};
    }
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
