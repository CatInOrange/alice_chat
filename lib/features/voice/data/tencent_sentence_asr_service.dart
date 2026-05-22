import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../domain/voice_settings.dart';

class TencentSentenceAsrResult {
  const TencentSentenceAsrResult({
    required this.text,
    required this.requestId,
    required this.audioDurationMs,
  });

  final String text;
  final String requestId;
  final int audioDurationMs;
}

class TencentSentenceAsrService {
  TencentSentenceAsrService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  static const _host = 'asr.tencentcloudapi.com';
  static const _endpoint = 'https://asr.tencentcloudapi.com';
  static const _service = 'asr';
  static const _version = '2019-06-14';
  static const _action = 'SentenceRecognition';

  final http.Client _httpClient;

  Future<TencentSentenceAsrResult> recognizeFile({
    required File file,
    required VoiceSettings settings,
  }) async {
    final secretId = settings.tencentSecretId.trim();
    final secretKey = settings.tencentSecretKey.trim();
    if (secretId.isEmpty || secretKey.isEmpty) {
      throw Exception('请先在设置的“语音”中配置腾讯云 SecretID 和 SecretKey');
    }

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw Exception('录音为空');
    }
    if (bytes.length > 3 * 1024 * 1024) {
      throw Exception('录音超过 3MB，请缩短语音时长');
    }

    final payload = jsonEncode({
      'ProjectId': 0,
      'SubServiceType': 2,
      'EngSerViceType':
          settings.tencentEngineModelType.trim().isEmpty
              ? '16k_zh'
              : settings.tencentEngineModelType.trim(),
      'SourceType': 1,
      'VoiceFormat': 'wav',
      'Data': base64Encode(bytes),
      'DataLen': bytes.length,
      'ConvertNumMode': 1,
    });

    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final headers = _buildHeaders(
      payload: payload,
      secretId: secretId,
      secretKey: secretKey,
      token: settings.tencentToken.trim(),
      timestamp: timestamp,
    );

    final response = await _httpClient.post(
      Uri.parse(_endpoint),
      headers: headers,
      body: payload,
    );
    final decoded =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final body = (decoded['Response'] as Map?)?.cast<String, dynamic>() ?? {};
    final error = (body['Error'] as Map?)?.cast<String, dynamic>();
    if (response.statusCode >= 400 || error != null) {
      final code = (error?['Code'] ?? response.statusCode).toString();
      final message =
          (error?['Message'] ?? response.reasonPhrase ?? '腾讯云 ASR 请求失败')
              .toString();
      throw Exception('$code: $message');
    }

    return TencentSentenceAsrResult(
      text: (body['Result'] ?? '').toString().trim(),
      requestId: (body['RequestId'] ?? '').toString(),
      audioDurationMs:
          int.tryParse((body['AudioDuration'] ?? '').toString()) ?? 0,
    );
  }

  Map<String, String> _buildHeaders({
    required String payload,
    required String secretId,
    required String secretKey,
    required String token,
    required int timestamp,
  }) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      timestamp * 1000,
      isUtc: true,
    ).toIso8601String().substring(0, 10);
    const signedHeaders = 'content-type;host';
    const contentType = 'application/json; charset=utf-8';
    final hashedPayload = _sha256Hex(payload);
    final canonicalRequest = [
      'POST',
      '/',
      '',
      'content-type:$contentType',
      'host:$_host',
      '',
      signedHeaders,
      hashedPayload,
    ].join('\n');

    final credentialScope = '$date/$_service/tc3_request';
    final stringToSign = [
      'TC3-HMAC-SHA256',
      timestamp.toString(),
      credentialScope,
      _sha256Hex(canonicalRequest),
    ].join('\n');

    final secretDate = _hmacSha256(utf8.encode('TC3$secretKey'), date);
    final secretService = _hmacSha256(secretDate, _service);
    final secretSigning = _hmacSha256(secretService, 'tc3_request');
    final signature = _hex(_hmacSha256(secretSigning, stringToSign));
    final authorization =
        'TC3-HMAC-SHA256 Credential=$secretId/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature';

    return {
      'Content-Type': contentType,
      'Host': _host,
      'Authorization': authorization,
      'X-TC-Action': _action,
      'X-TC-Version': _version,
      'X-TC-Timestamp': timestamp.toString(),
      if (token.isNotEmpty) 'X-TC-Token': token,
    };
  }

  List<int> _hmacSha256(List<int> key, String value) {
    return Hmac(sha256, key).convert(utf8.encode(value)).bytes;
  }

  String _sha256Hex(String value) {
    return _hex(sha256.convert(utf8.encode(value)).bytes);
  }

  String _hex(List<int> bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
