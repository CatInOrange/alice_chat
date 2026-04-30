import 'package:flutter/foundation.dart';

import '../../../core/openclaw/music_provider_models.dart';
import '../../../core/openclaw/openclaw_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';

enum MusicPlatformAuthStateKind {
  missing,
  imported,
  suspicious,
}

class MusicPlatformLocalState {
  const MusicPlatformLocalState({
    required this.provider,
    required this.authState,
    required this.statusLabel,
    required this.summary,
    required this.detail,
    required this.detectedKeys,
    this.rawCookie,
  });

  final MusicProviderInfo provider;
  final MusicPlatformAuthStateKind authState;
  final String statusLabel;
  final String summary;
  final String detail;
  final List<String> detectedKeys;
  final String? rawCookie;

  bool get hasCookie => (rawCookie ?? '').trim().isNotEmpty;
  bool get likelyReady => authState == MusicPlatformAuthStateKind.imported;
}

class MusicPlatformStore extends ChangeNotifier {
  MusicPlatformStore({OpenClawClient? client})
    : _client =
          client ??
          OpenClawHttpClient(
            const OpenClawConfig(
              baseUrl: '',
              modelId: 'alicechat-default',
              providerId: 'alicechat-channel',
              agent: 'main',
              sessionName: 'alicechat',
              bridgeUrl:
                  'ws://127.0.0.1:18791?token=yuanzhe-7611681-668128-zheyuan-012345',
            ),
          );

  OpenClawClient _client;
  bool _isLoading = false;
  bool _isReady = false;
  String? _error;
  List<MusicProviderInfo> _providers = const [];
  Map<String, MusicPlatformLocalState> _localStates = const {};

  bool get isLoading => _isLoading;
  bool get isReady => _isReady;
  String? get error => _error;
  List<MusicProviderInfo> get providers => _providers;
  List<MusicPlatformLocalState> get platformStates =>
      _providers
          .map(
            (provider) =>
                _localStates[provider.providerId] ??
                _buildLocalState(provider: provider, rawCookie: null),
          )
          .toList(growable: false);

  MusicPlatformLocalState? stateFor(String providerId) => _localStates[providerId];

  Future<void> reloadConfig() async {
    final config = await OpenClawSettingsStore.load();
    _client = OpenClawHttpClient(config);
    _isReady = false;
    _error = null;
    notifyListeners();
  }

  Future<void> ensureReady({bool forceRefresh = false}) async {
    if (_isLoading) return;
    if (_isReady && !forceRefresh) return;

    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      await reloadConfig();
      final response = await _client.getMusicProviders();
      final providers = ((response['providers'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map(
            (item) => MusicProviderInfo.fromMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            ),
          )
          .toList(growable: false);
      final localStates = <String, MusicPlatformLocalState>{};
      for (final provider in providers) {
        final cookie = await OpenClawSettingsStore.loadMusicProviderCookie(
          provider.providerId,
        );
        localStates[provider.providerId] = _buildLocalState(
          provider: provider,
          rawCookie: cookie,
        );
      }
      _providers = providers;
      _localStates = localStates;
      _isReady = true;
    } catch (error) {
      _error = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> saveProviderCookie({
    required String providerId,
    required String cookie,
  }) async {
    await OpenClawSettingsStore.saveMusicProviderCookie(
      providerId: providerId,
      cookie: cookie,
    );
    await _refreshProviderLocalState(providerId);
  }

  Future<void> clearProviderCookie(String providerId) async {
    await OpenClawSettingsStore.saveMusicProviderCookie(
      providerId: providerId,
      cookie: '',
    );
    await _refreshProviderLocalState(providerId);
  }

  Future<void> _refreshProviderLocalState(String providerId) async {
    final provider = _providers.where((item) => item.providerId == providerId).firstOrNull;
    if (provider == null) return;
    final cookie = await OpenClawSettingsStore.loadMusicProviderCookie(providerId);
    _localStates = {
      ..._localStates,
      providerId: _buildLocalState(provider: provider, rawCookie: cookie),
    };
    notifyListeners();
  }

  MusicPlatformLocalState _buildLocalState({
    required MusicProviderInfo provider,
    required String? rawCookie,
  }) {
    final normalizedCookie = rawCookie?.trim();
    if (normalizedCookie == null || normalizedCookie.isEmpty) {
      return MusicPlatformLocalState(
        provider: provider,
        rawCookie: null,
        authState: MusicPlatformAuthStateKind.missing,
        statusLabel: '未配置',
        summary: '还没有导入本地登录信息',
        detail: '建议先导入 Cookie；下一轮客户端侧会直接基于它做真实登录校验和播放源解析。',
        detectedKeys: const [],
      );
    }

    final cookieMap = _parseCookieMap(normalizedCookie);
    final detectedKeys = cookieMap.keys.toList(growable: false);

    if (provider.providerId == 'netease') {
      return _buildNeteaseLocalState(
        provider: provider,
        rawCookie: normalizedCookie,
        cookieMap: cookieMap,
        detectedKeys: detectedKeys,
      );
    }

    return MusicPlatformLocalState(
      provider: provider,
      rawCookie: normalizedCookie,
      authState: detectedKeys.isEmpty
          ? MusicPlatformAuthStateKind.suspicious
          : MusicPlatformAuthStateKind.imported,
      statusLabel: detectedKeys.isEmpty ? '格式可疑' : '已导入',
      summary: detectedKeys.isEmpty ? 'Cookie 结构不完整' : '已导入本地登录信息',
      detail: detectedKeys.isEmpty
          ? '未识别到有效 Cookie 键值，后续接真实平台时大概率无法直接使用。'
          : '已检测到 ${detectedKeys.length} 个 Cookie 键，后续可继续接平台专属校验逻辑。',
      detectedKeys: detectedKeys,
    );
  }

  MusicPlatformLocalState _buildNeteaseLocalState({
    required MusicProviderInfo provider,
    required String rawCookie,
    required Map<String, String> cookieMap,
    required List<String> detectedKeys,
  }) {
    final hasMusicU = cookieMap.containsKey('MUSIC_U');
    final hasMusicA = cookieMap.containsKey('MUSIC_A');
    final hasMusicAT = cookieMap.containsKey('MUSIC_A_T');
    final hasCsrf = cookieMap.containsKey('__csrf');
    final hasDeviceFingerprint =
        cookieMap.containsKey('NMTID') || cookieMap.containsKey('_ntes_nuid');
    final hasAnyAuthToken = hasMusicU || hasMusicA || hasMusicAT;

    if (hasAnyAuthToken) {
      final hints = <String>[
        if (hasMusicU) 'MUSIC_U',
        if (hasMusicA) 'MUSIC_A',
        if (hasMusicAT) 'MUSIC_A_T',
        if (hasCsrf) '__csrf',
        if (hasDeviceFingerprint) '设备指纹键',
      ];
      return MusicPlatformLocalState(
        provider: provider,
        rawCookie: rawCookie,
        authState: MusicPlatformAuthStateKind.imported,
        statusLabel: '已导入',
        summary: '检测到网易云登录 Cookie',
        detail:
            '已识别 ${hints.join(' / ')}。这已经足够作为下一轮 App 端真实登录校验与直连解析的输入骨架。',
        detectedKeys: detectedKeys,
      );
    }

    if (detectedKeys.isEmpty) {
      return MusicPlatformLocalState(
        provider: provider,
        rawCookie: rawCookie,
        authState: MusicPlatformAuthStateKind.suspicious,
        statusLabel: '格式可疑',
        summary: '没有识别到有效的 Cookie 键值',
        detail: '当前内容更像是残缺文本，后续大概率无法用于网易云登录。',
        detectedKeys: const [],
      );
    }

    return MusicPlatformLocalState(
      provider: provider,
      rawCookie: rawCookie,
      authState: MusicPlatformAuthStateKind.suspicious,
      statusLabel: '待校验',
      summary: '已保存 Cookie，但未检测到核心登录键',
      detail:
          '当前只识别到 ${detectedKeys.take(4).join(' / ')}，缺少 MUSIC_U 或 MUSIC_A 一类核心键，可能只是游客态或不完整导出。',
      detectedKeys: detectedKeys,
    );
  }

  Map<String, String> _parseCookieMap(String rawCookie) {
    final result = <String, String>{};
    for (final segment in rawCookie.split(';')) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) continue;
      final index = trimmed.indexOf('=');
      if (index <= 0) continue;
      final key = trimmed.substring(0, index).trim();
      final value = trimmed.substring(index + 1).trim();
      if (key.isEmpty || value.isEmpty) continue;
      result[key] = value;
    }
    return result;
  }
}
