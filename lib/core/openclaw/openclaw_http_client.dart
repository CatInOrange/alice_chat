import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'openclaw_client.dart';
import 'openclaw_config.dart';

class OpenClawHttpClient implements OpenClawClient {
  OpenClawHttpClient(this.config, {http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final OpenClawConfig config;
  final http.Client _httpClient;

  Uri _uri(String path, {Map<String, String>? queryParameters}) {
    final base =
        config.baseUrl.endsWith('/')
            ? config.baseUrl.substring(0, config.baseUrl.length - 1)
            : config.baseUrl;
    return Uri.parse('$base$path').replace(queryParameters: queryParameters);
  }

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
    };
    final password = config.appPassword?.trim();
    if (password != null && password.isNotEmpty) {
      headers['X-AliceChat-Password'] = password;
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
      throw _buildRequestException('加载会话失败', sessionsResponse);
    }

    final sessionsJson =
        jsonDecode(sessionsResponse.body) as Map<String, dynamic>;
    final sessions =
        (sessionsJson['sessions'] as List<dynamic>? ?? const [])
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
      throw _buildRequestException('创建会话失败', createResponse);
    }

    final createJson = jsonDecode(createResponse.body) as Map<String, dynamic>;
    final session = createJson['session'] as Map<String, dynamic>? ?? const {};
    return (session['id'] ?? '').toString();
  }

  @override
  Future<MessagePageResult> loadMessages(
    String sessionId, {
    int? limit,
    String? beforeMessageId,
    String? afterMessageId,
  }) async {
    final queryParameters = <String, String>{
      if (limit != null) 'limit': limit.toString(),
      if (beforeMessageId != null && beforeMessageId.isNotEmpty)
        'before': beforeMessageId,
      if (afterMessageId != null && afterMessageId.isNotEmpty)
        'after': afterMessageId,
    };
    final response = await _httpClient.get(
      _uri('/api/sessions/$sessionId/messages', queryParameters: queryParameters),
      headers: _headers,
    );
    if (response.statusCode >= 400) {
      throw _buildRequestException('加载消息失败', response);
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return MessagePageResult(
      messages: (json['messages'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>(),
      paging: (json['paging'] as Map<String, dynamic>? ?? const {}),
    );
  }

  @override
  Future<String> sendMessage({
    required String sessionId,
    required String text,
    String? contactId,
    String? userId,
    String? clientMessageId,
  }) async {
    final response = await _httpClient.post(
      _uri('/api/messages'),
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
        if (contactId != null && contactId.isNotEmpty) 'contactId': contactId,
        if (userId != null && userId.isNotEmpty) 'userId': userId,
        if (clientMessageId != null && clientMessageId.isNotEmpty)
          'clientMessageId': clientMessageId,
      }),
    );

    if (response.statusCode >= 400) {
      throw _buildRequestException('发送消息失败', response);
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (json['ok'] != true) {
      throw Exception('发送消息失败: ${response.body}');
    }
    return (json['messageId'] ?? '').toString();
  }

  @override
  Future<void> sendClientDebugLog(Map<String, dynamic> payload) async {
    try {
      await _httpClient.post(
        _uri('/api/debug/client-log'),
        headers: _headers,
        body: jsonEncode(payload),
      );
    } catch (_) {
      // Best effort only.
    }
  }

  @override
  Stream<Map<String, dynamic>> subscribeEvents({
    String? sessionId,
    int? since,
  }) async* {
    final request = http.Request(
      'GET',
      _uri(
        '/api/events',
        queryParameters: {
          if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
          if (since != null) 'since': since.toString(),
        },
      ),
    );
    request.headers.addAll(_headers);
    final response = await _httpClient.send(request);
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      throw Exception(
        response.statusCode == 401
            ? '认证失败，请检查设置中的访问密码'
            : '订阅事件失败: ${body.isNotEmpty ? body : (response.reasonPhrase ?? response.statusCode.toString())}',
      );
    }

    final lineStream = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    String? eventName;
    final dataLines = <String>[];

    await for (final rawLine in lineStream) {
      final line = rawLine.trimRight();
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          final data = dataLines.join('\n').trim();
          if (data.isNotEmpty) {
            final payload = jsonDecode(data);
            if (payload is Map<String, dynamic>) {
              final effectivePayload =
                  payload['payload'] is Map<String, dynamic>
                      ? Map<String, dynamic>.from(payload['payload'] as Map)
                      : Map<String, dynamic>.from(payload);
              yield {
                'event': eventName ?? 'message',
                if (payload['seq'] != null) 'seq': payload['seq'],
                if (payload['ts'] != null) 'ts': payload['ts'],
                if (payload['type'] != null) 'transportEvent': payload['type'],
                ...effectivePayload,
              };
            }
          }
        }
        eventName = null;
        dataLines.clear();
        continue;
      }
      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
        continue;
      }
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trim());
      }
    }
  }

  Exception _buildRequestException(String prefix, http.Response response) {
    if (response.statusCode == 401) {
      return Exception('认证失败，请检查设置中的访问密码');
    }
    final body = response.body.trim();
    return Exception('$prefix: ${body.isNotEmpty ? body : response.statusCode}');
  }
}
