import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/voice_settings.dart';

class MiniMaxTtsResult {
  const MiniMaxTtsResult({required this.filePath, required this.mimeType});

  final String filePath;
  final String mimeType;
}

class MiniMaxTtsService {
  MiniMaxTtsService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<MiniMaxTtsResult> synthesizeToFile({
    required String text,
    required VoiceSettings settings,
    required String sessionId,
  }) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty) {
      throw Exception('没有可朗读的文字');
    }
    final apiKey = settings.minimaxApiKey.trim();
    if (apiKey.isEmpty) {
      throw Exception('请先在设置的“语音”中配置 MiniMax API Key');
    }

    final baseUrl =
        settings.minimaxBaseUrl.trim().isEmpty
            ? 'https://api.minimaxi.com'
            : settings.minimaxBaseUrl.trim();
    final uri = Uri.parse(
      '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/t2a_v2',
    );
    final voiceId = settings.voiceForSession(sessionId);
    final response = await _client.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model':
            settings.minimaxModel.trim().isEmpty
                ? 'speech-2.8-hd'
                : settings.minimaxModel.trim(),
        'text': normalizedText,
        'stream': false,
        'output_format': 'hex',
        'voice_setting': {
          'voice_id': voiceId,
          'speed': 0.9,
          'vol': 1.0,
          'pitch': 0,
        },
        'audio_setting': {
          'sample_rate': 32000,
          'bitrate': 128000,
          'format': 'mp3',
          'channel': 1,
        },
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'MiniMax TTS HTTP ${response.statusCode}: ${response.body}',
      );
    }

    final contentType =
        (response.headers['content-type'] ?? '').split(';').first.toLowerCase();
    Uint8List audioBytes;
    String mimeType;
    if (contentType.startsWith('audio/')) {
      audioBytes = response.bodyBytes;
      mimeType = contentType;
    } else {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) {
        throw Exception('MiniMax TTS 返回格式无效');
      }
      final data = decoded['data'];
      final audioHex =
          data is Map ? (data['audio'] ?? '').toString().trim() : '';
      if (audioHex.isEmpty) {
        final message =
            (decoded['base_resp'] is Map
                    ? decoded['base_resp']['status_msg']
                    : decoded['message'])
                ?.toString();
        throw Exception(
          message?.isNotEmpty == true ? message! : 'MiniMax TTS 没有返回音频',
        );
      }
      audioBytes = _decodeHex(audioHex);
      final extraInfo = decoded['extra_info'];
      final audioFormat =
          extraInfo is Map
              ? (extraInfo['audio_format'] ?? 'mp3').toString()
              : 'mp3';
      mimeType = audioFormat.isEmpty ? 'audio/mpeg' : 'audio/$audioFormat';
    }

    final tempDir = await getTemporaryDirectory();
    final outputDir = Directory(p.join(tempDir.path, 'alicechat_tts'));
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }
    final extension = _extensionForMimeType(mimeType);
    final file = File(
      p.join(
        outputDir.path,
        'tts_${DateTime.now().millisecondsSinceEpoch}.$extension',
      ),
    );
    await file.writeAsBytes(audioBytes, flush: true);
    return MiniMaxTtsResult(filePath: file.path, mimeType: mimeType);
  }

  Uint8List _decodeHex(String hex) {
    final normalized = hex.replaceAll(RegExp(r'\s+'), '');
    if (normalized.length.isOdd) {
      throw Exception('MiniMax TTS 音频 hex 长度无效');
    }
    final bytes = Uint8List(normalized.length ~/ 2);
    for (var i = 0; i < normalized.length; i += 2) {
      bytes[i ~/ 2] = int.parse(normalized.substring(i, i + 2), radix: 16);
    }
    return bytes;
  }

  String _extensionForMimeType(String mimeType) {
    final normalized = mimeType.toLowerCase();
    if (normalized.contains('wav')) return 'wav';
    if (normalized.contains('mpeg') || normalized.contains('mp3')) return 'mp3';
    if (normalized.contains('aac')) return 'aac';
    if (normalized.contains('m4a') || normalized.contains('mp4')) return 'm4a';
    return 'audio';
  }
}
