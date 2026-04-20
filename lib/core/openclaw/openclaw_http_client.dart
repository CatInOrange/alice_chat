import 'dart:convert';

import 'package:http/http.dart' as http;

import 'openclaw_client.dart';
import 'openclaw_config.dart';

class OpenClawHttpClient implements OpenClawClient {
  OpenClawHttpClient(this.config, {http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  final OpenClawConfig config;
  final http.Client _httpClient;

  Uri _uri(String path) {
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    return Uri.parse('$base$path');
  }

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    final token = config.apiToken;
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  @override
  Future<String> ensureSession({required String preferredName}) async {
    final sessionsResponse = await _httpClient.get(
      _uri('/api/sessions'),
      headers: _headers,
    );
    if (sessionsResponse.statusCode >= 400) {
      throw Exception('加载会话失败: ${sessionsResponse.body}');
    }

    final sessionsJson = jsonDecode(sessionsResponse.body) as Map<String, dynamic>;
    final sessions = (sessionsJson['sessions'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();

    for (final session in sessions) {
      if ((session['name'] ?? '').toString() == preferredName) {
        return (session['id'] ?? '').toString();
      }
    }

    final createResponse = await _httpClient.post(
      _uri('/api/sessions'),
      headers: _headers,
      body: jsonEncode({'name': preferredName}),
    );
    if (createResponse.statusCode >= 400) {
      throw Exception('创建会话失败: ${createResponse.body}');
    }

    final createJson = jsonDecode(createResponse.body) as Map<String, dynamic>;
    final session = createJson['session'] as Map<String, dynamic>? ?? const {};
    return (session['id'] ?? '').toString();
  }

  @override
  Future<List<Map<String, dynamic>>> loadMessages(String sessionId) async {
    final response = await _httpClient.get(
      _uri('/api/sessions/$sessionId/messages'),
      headers: _headers,
    );
    if (response.statusCode >= 400) {
      throw Exception('加载消息失败: ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return (json['messages'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
  }

  @override
  Future<String> sendMessage({required String sessionId, required String text}) async {
    final response = await _httpClient.post(
      _uri('/api/chat'),
      headers: _headers,
      body: jsonEncode({
        'sessionId': sessionId,
        'modelId': config.modelId,
        'providerId': config.providerId,
        'text': text,
        'historyText': text,
        'agent': config.agent,
        'session': config.sessionName,
        if (config.bridgeUrl != null && config.bridgeUrl!.isNotEmpty)
          'bridgeUrl': config.bridgeUrl,
        'messageSource': 'chat',
        'ttsEnabled': false,
      }),
    );

    if (response.statusCode >= 400) {
      throw Exception('发送消息失败: ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final reply = (json['payload']?['reply'] ?? json['reply'] ?? '').toString();
    return reply;
  }
}
