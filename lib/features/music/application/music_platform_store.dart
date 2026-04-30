import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

enum MusicPlatformQrLoginPhase {
  idle,
  preparing,
  waitingScan,
  waitingConfirm,
  authorized,
  expired,
  failed,
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
    this.remoteProfileName,
    this.remoteAccountId,
    this.remoteValidated = false,
  });

  final MusicProviderInfo provider;
  final MusicPlatformAuthStateKind authState;
  final String statusLabel;
  final String summary;
  final String detail;
  final List<String> detectedKeys;
  final String? rawCookie;
  final String? remoteProfileName;
  final String? remoteAccountId;
  final bool remoteValidated;

  bool get hasCookie => (rawCookie ?? '').trim().isNotEmpty;
  bool get likelyReady => authState == MusicPlatformAuthStateKind.imported;
}

class MusicPlatformQrLoginState {
  const MusicPlatformQrLoginState({
    required this.providerId,
    required this.phase,
    required this.statusLabel,
    required this.detail,
    this.qrData,
    this.unikey,
  });

  final String providerId;
  final MusicPlatformQrLoginPhase phase;
  final String statusLabel;
  final String detail;
  final String? qrData;
  final String? unikey;

  bool get canRenderQr => (qrData ?? '').trim().isNotEmpty;
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
  Map<String, MusicPlatformQrLoginState> _qrStates = const {};
  final Map<String, Timer> _qrPollTimers = <String, Timer>{};
  final Map<String, _NeteaseQrSession> _qrSessions =
      <String, _NeteaseQrSession>{};

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

  MusicPlatformQrLoginState? qrStateFor(String providerId) =>
      _qrStates[providerId];

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
      final baseUrl = _client is OpenClawHttpClient
          ? (_client as OpenClawHttpClient).config.baseUrl.trim()
          : '';
      if (baseUrl.isEmpty) {
        throw Exception('请先在设置页填写后端地址');
      }
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
        localStates[provider.providerId] = await _loadProviderLocalState(provider);
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

  Future<void> startQrLogin(String providerId) async {
    if (providerId != 'netease') {
      _setQrState(
        MusicPlatformQrLoginState(
          providerId: providerId,
          phase: MusicPlatformQrLoginPhase.failed,
          statusLabel: '暂不支持',
          detail: '当前只有网易云音乐接入了二维码登录骨架。',
        ),
      );
      return;
    }

    await closeQrLogin(providerId, clearState: true);
    _setQrState(
      MusicPlatformQrLoginState(
        providerId: providerId,
        phase: MusicPlatformQrLoginPhase.preparing,
        statusLabel: '准备中',
        detail: '正在向网易云申请二维码登录 key…',
      ),
    );

    try {
      final session = await _createNeteaseQrSession();
      _qrSessions[providerId] = session;
      final qrData = 'https://music.163.com/login?codekey=${Uri.encodeComponent(session.unikey)}';
      _setQrState(
        MusicPlatformQrLoginState(
          providerId: providerId,
          phase: MusicPlatformQrLoginPhase.waitingScan,
          statusLabel: '待扫码',
          detail: '请用网易云音乐 App 扫码；扫码后还需要在手机上确认登录。',
          qrData: qrData,
          unikey: session.unikey,
        ),
      );
      _startQrPolling(providerId);
    } catch (error) {
      _setQrState(
        MusicPlatformQrLoginState(
          providerId: providerId,
          phase: MusicPlatformQrLoginPhase.failed,
          statusLabel: '启动失败',
          detail: '二维码登录初始化失败：$error',
        ),
      );
    }
  }

  Future<void> refreshQrLogin(String providerId) => startQrLogin(providerId);

  Future<void> closeQrLogin(
    String providerId, {
    bool clearState = false,
  }) async {
    _qrPollTimers.remove(providerId)?.cancel();
    _qrSessions.remove(providerId);
    if (clearState) {
      final nextStates = Map<String, MusicPlatformQrLoginState>.from(_qrStates);
      nextStates.remove(providerId);
      _qrStates = nextStates;
      notifyListeners();
    }
  }

  Future<void> _refreshProviderLocalState(String providerId) async {
    final provider = _providers.where((item) => item.providerId == providerId).firstOrNull;
    if (provider == null) return;
    _localStates = {
      ..._localStates,
      providerId: await _loadProviderLocalState(provider),
    };
    notifyListeners();
  }

  Future<MusicPlatformLocalState> _loadProviderLocalState(
    MusicProviderInfo provider,
  ) async {
    final cookie = await OpenClawSettingsStore.loadMusicProviderCookie(
      provider.providerId,
    );
    final baseState = _buildLocalState(
      provider: provider,
      rawCookie: cookie,
    );
    if (provider.providerId != 'netease' || !baseState.hasCookie) {
      return baseState;
    }
    return _validateNeteaseAccount(baseState);
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
        detail: '你现在可以直接导入 Cookie，或者改用二维码登录。后续真实搜索和播放源解析都会基于本地登录态继续往下接。',
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
            '已识别 ${hints.join(' / ')}。下一步会再走一次真实接口校验，确认是否真的是可用登录态。',
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

  void _startQrPolling(String providerId) {
    _qrPollTimers.remove(providerId)?.cancel();
    _qrPollTimers[providerId] = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollQrLogin(providerId)),
    );
  }

  Future<void> _pollQrLogin(String providerId) async {
    final session = _qrSessions[providerId];
    final state = _qrStates[providerId];
    if (session == null || state == null) return;
    if (state.phase == MusicPlatformQrLoginPhase.authorized ||
        state.phase == MusicPlatformQrLoginPhase.expired ||
        state.phase == MusicPlatformQrLoginPhase.failed) {
      return;
    }

    try {
      final response = await _neteaseGet(
        '/api/login/qrcode/client/login',
        query: <String, String>{
          'key': session.unikey,
          'type': '1',
        },
        cookieJar: session.cookieJar,
      );
      session.cookieJar
        ..clear()
        ..addAll(response.cookieJar);
      final payload = _decodeJsonMap(response.body);
      final code = int.tryParse((payload['code'] ?? '').toString()) ?? -1;
      switch (code) {
        case 801:
          _setQrState(
            MusicPlatformQrLoginState(
              providerId: providerId,
              phase: MusicPlatformQrLoginPhase.waitingScan,
              statusLabel: '待扫码',
              detail: '二维码已生成，请用网易云音乐 App 扫码。',
              qrData: state.qrData,
              unikey: session.unikey,
            ),
          );
          break;
        case 802:
          _setQrState(
            MusicPlatformQrLoginState(
              providerId: providerId,
              phase: MusicPlatformQrLoginPhase.waitingConfirm,
              statusLabel: '待确认',
              detail: '已经扫码，请在手机上确认登录。',
              qrData: state.qrData,
              unikey: session.unikey,
            ),
          );
          break;
        case 803:
          final cookieHeader = _cookieJarToHeader(session.cookieJar);
          if (cookieHeader.trim().isEmpty) {
            throw Exception('扫码成功，但没有拿到可用 Cookie');
          }
          await OpenClawSettingsStore.saveMusicProviderCookie(
            providerId: providerId,
            cookie: cookieHeader,
          );
          await _refreshProviderLocalState(providerId);
          _setQrState(
            MusicPlatformQrLoginState(
              providerId: providerId,
              phase: MusicPlatformQrLoginPhase.authorized,
              statusLabel: '已登录',
              detail: '扫码登录成功，登录态已经保存到本地。下一步就可以继续接真实搜索与播放源解析。',
              qrData: state.qrData,
              unikey: session.unikey,
            ),
          );
          await closeQrLogin(providerId);
          break;
        case 800:
          _setQrState(
            MusicPlatformQrLoginState(
              providerId: providerId,
              phase: MusicPlatformQrLoginPhase.expired,
              statusLabel: '已过期',
              detail: '二维码已经过期，请重新生成。',
              qrData: state.qrData,
              unikey: session.unikey,
            ),
          );
          await closeQrLogin(providerId);
          break;
        default:
          final message = (payload['message'] ?? payload['msg'] ?? '未知状态').toString();
          _setQrState(
            MusicPlatformQrLoginState(
              providerId: providerId,
              phase: MusicPlatformQrLoginPhase.failed,
              statusLabel: '轮询失败',
              detail: '二维码状态检查失败：$message',
              qrData: state.qrData,
              unikey: session.unikey,
            ),
          );
          await closeQrLogin(providerId);
      }
    } catch (error) {
      _setQrState(
        MusicPlatformQrLoginState(
          providerId: providerId,
          phase: MusicPlatformQrLoginPhase.failed,
          statusLabel: '轮询失败',
          detail: '二维码状态检查失败：$error',
          qrData: state.qrData,
          unikey: session.unikey,
        ),
      );
      await closeQrLogin(providerId);
    }
  }

  Future<_NeteaseQrSession> _createNeteaseQrSession() async {
    final response = await _neteaseGet(
      '/api/login/qrcode/unikey',
      query: const <String, String>{'type': '1'},
    );
    final payload = _decodeJsonMap(response.body);
    final unikey = (payload['unikey'] ?? '').toString().trim();
    if (unikey.isEmpty) {
      throw Exception('没有拿到 unikey：${payload['message'] ?? payload['msg'] ?? response.body}');
    }
    return _NeteaseQrSession(unikey: unikey, cookieJar: response.cookieJar);
  }

  Future<_NeteaseHttpResponse> _neteaseGet(
    String path, {
    Map<String, String> query = const <String, String>{},
    Map<String, Cookie> cookieJar = const <String, Cookie>{},
    String? cookieHeader,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.https('music.163.com', path, query));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Linux; Android 14; AliceChat) AppleWebKit/537.36',
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, text/plain, */*',
      );
      request.headers.set(HttpHeaders.refererHeader, 'https://music.163.com/login');
      request.headers.set('origin', 'https://music.163.com');
      for (final cookie in cookieJar.values) {
        request.cookies.add(Cookie(cookie.name, cookie.value));
      }
      final normalizedCookieHeader = (cookieHeader ?? '').trim();
      if (normalizedCookieHeader.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, normalizedCookieHeader);
      }
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final nextJar = <String, Cookie>{...cookieJar};
      for (final cookie in response.cookies) {
        nextJar[cookie.name] = cookie;
      }
      return _NeteaseHttpResponse(
        statusCode: response.statusCode,
        body: body,
        cookieJar: nextJar,
      );
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic> _decodeJsonMap(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // ignore
    }
    return <String, dynamic>{'raw': body};
  }

  String _cookieJarToHeader(Map<String, Cookie> cookieJar) {
    return cookieJar.values
        .where((cookie) => cookie.value.trim().isNotEmpty)
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  Future<MusicPlatformLocalState> _validateNeteaseAccount(
    MusicPlatformLocalState baseState,
  ) async {
    final cookie = baseState.rawCookie?.trim();
    if (cookie == null || cookie.isEmpty) {
      return baseState;
    }
    try {
      final response = await _neteaseGet(
        '/api/w/nuser/account/get',
        cookieHeader: cookie,
      );
      final payload = _decodeJsonMap(response.body);
      final account = (payload['account'] as Map?)?.cast<String, dynamic>();
      final profile = (payload['profile'] as Map?)?.cast<String, dynamic>();
      if (account == null || profile == null) {
        return MusicPlatformLocalState(
          provider: baseState.provider,
          authState: MusicPlatformAuthStateKind.suspicious,
          statusLabel: '待校验',
          summary: 'Cookie 已保存，但未确认登录成功',
          detail: '真实登录态校验没有拿到账号信息，当前更像游客态、失效态，或者 Cookie 不完整。',
          detectedKeys: baseState.detectedKeys,
          rawCookie: baseState.rawCookie,
        );
      }
      final nickname = (profile['nickname'] ?? '').toString().trim();
      final accountId = (account['id'] ?? profile['userId'] ?? '').toString().trim();
      return MusicPlatformLocalState(
        provider: baseState.provider,
        authState: MusicPlatformAuthStateKind.imported,
        statusLabel: '已登录',
        summary: nickname.isEmpty ? '已通过网易云真实接口校验' : '已登录：$nickname',
        detail: accountId.isEmpty
            ? '已经通过网易云账号接口校验，当前 Cookie 可用。'
            : '已经通过网易云账号接口校验，账号 ID：$accountId。',
        detectedKeys: baseState.detectedKeys,
        rawCookie: baseState.rawCookie,
        remoteProfileName: nickname.isEmpty ? null : nickname,
        remoteAccountId: accountId.isEmpty ? null : accountId,
        remoteValidated: true,
      );
    } catch (error) {
      return MusicPlatformLocalState(
        provider: baseState.provider,
        authState: MusicPlatformAuthStateKind.suspicious,
        statusLabel: '校验失败',
        summary: '本地 Cookie 已保存，但真实登录态校验失败',
        detail: '网易云账号校验接口返回异常：$error',
        detectedKeys: baseState.detectedKeys,
        rawCookie: baseState.rawCookie,
      );
    }
  }

  void _setQrState(MusicPlatformQrLoginState state) {
    _qrStates = {
      ..._qrStates,
      state.providerId: state,
    };
    notifyListeners();
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

  @override
  void dispose() {
    for (final timer in _qrPollTimers.values) {
      timer.cancel();
    }
    _qrPollTimers.clear();
    _qrSessions.clear();
    super.dispose();
  }
}

class _NeteaseQrSession {
  _NeteaseQrSession({
    required this.unikey,
    required Map<String, Cookie> cookieJar,
  }) : cookieJar = <String, Cookie>{...cookieJar};

  final String unikey;
  final Map<String, Cookie> cookieJar;
}

class _NeteaseHttpResponse {
  const _NeteaseHttpResponse({
    required this.statusCode,
    required this.body,
    required this.cookieJar,
  });

  final int statusCode;
  final String body;
  final Map<String, Cookie> cookieJar;
}
