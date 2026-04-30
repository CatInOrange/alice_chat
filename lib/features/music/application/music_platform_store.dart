import 'package:flutter/foundation.dart';

import '../../../core/openclaw/music_provider_models.dart';
import '../../../core/openclaw/openclaw_client.dart';
import '../../../core/openclaw/openclaw_config.dart';
import '../../../core/openclaw/openclaw_http_client.dart';
import '../../../core/openclaw/openclaw_settings.dart';

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

  bool get isLoading => _isLoading;
  bool get isReady => _isReady;
  String? get error => _error;
  List<MusicProviderInfo> get providers => _providers;

  Future<void> reloadConfig() async {
    final config = await OpenClawSettingsStore.load();
    _client = OpenClawHttpClient(config);
    _isReady = false;
    _error = null;
    notifyListeners();
  }

  Future<void> ensureReady() async {
    if (_isReady || _isLoading) return;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      await reloadConfig();
      final response = await _client.getMusicProviders();
      _providers = ((response['providers'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map(
            (item) => MusicProviderInfo.fromMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            ),
          )
          .toList(growable: false);
      _isReady = true;
    } catch (error) {
      _error = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
