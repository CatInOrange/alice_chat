import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/openclaw/openclaw_config.dart';
import '../domain/push_device.dart';

class PushApi {
  PushApi(this.config, {http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final OpenClawConfig config;
  final http.Client _httpClient;

  Uri _uri(String path) {
    final base =
        config.baseUrl.endsWith('/')
            ? config.baseUrl.substring(0, config.baseUrl.length - 1)
            : config.baseUrl;
    return Uri.parse('$base$path');
  }

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final password = config.appPassword?.trim();
    if (password != null && password.isNotEmpty) {
      headers['X-AliceChat-Password'] = password;
    }
    return headers;
  }

  bool get isConfigured => config.baseUrl.trim().isNotEmpty;

  Future<void> registerDevice(PushDeviceRegistration registration) async {
    if (!isConfigured) return;
    final response = await _httpClient.post(
      _uri('/api/push/register'),
      headers: _headers,
      body: jsonEncode(registration.toJson()),
    );
    if (response.statusCode >= 400) {
      throw Exception('注册推送设备失败: ${response.body}');
    }
  }

  Future<void> unregisterDevice({
    required String deviceId,
    String pushToken = '',
  }) async {
    if (!isConfigured) return;
    final response = await _httpClient.post(
      _uri('/api/push/unregister'),
      headers: _headers,
      body: jsonEncode({'deviceId': deviceId, 'pushToken': pushToken}),
    );
    if (response.statusCode >= 400) {
      throw Exception('注销推送设备失败: ${response.body}');
    }
  }

  Future<void> updatePresence(PushPresenceUpdate update) async {
    if (!isConfigured) return;
    final response = await _httpClient.post(
      _uri('/api/push/presence'),
      headers: _headers,
      body: jsonEncode(update.toJson()),
    );
    if (response.statusCode >= 400) {
      throw Exception('更新在线状态失败: ${response.body}');
    }
  }
}
