import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/openclaw/openclaw_settings.dart';
import 'minimax_tts_service.dart';

class WakeReplyAudioCacheService {
  WakeReplyAudioCacheService({MiniMaxTtsService? ttsService})
    : _ttsService = ttsService ?? MiniMaxTtsService();

  final MiniMaxTtsService _ttsService;
  final Random _random = Random();

  Future<String?> randomCachedOrGenerate({
    required VoiceSettings settings,
    required VoiceWakeWordTargetSettings target,
  }) async {
    final replies = _normalizedReplies(target);
    if (replies.isEmpty || !settings.canUseOutput) return null;
    final text = replies[_random.nextInt(replies.length)];
    return _cachedOrGenerate(
      text: text,
      settings: settings,
      sessionId: target.sessionId,
    );
  }

  Future<int> generateAll(VoiceSettings settings) async {
    if (!settings.canUseOutput) {
      throw Exception('请先启用语音输出并配置 MiniMax API Key');
    }
    var count = 0;
    for (final target in settings.wakeWord.targets) {
      for (final text in _normalizedReplies(target)) {
        await _cachedOrGenerate(
          text: text,
          settings: settings,
          sessionId: target.sessionId,
        );
        count += 1;
      }
    }
    return count;
  }

  Future<String> _cachedOrGenerate({
    required String text,
    required VoiceSettings settings,
    required String sessionId,
  }) async {
    final voiceId = settings.voiceForSession(sessionId);
    final model =
        settings.minimaxModel.trim().isEmpty
            ? 'speech-2.8-hd'
            : settings.minimaxModel.trim();
    final key =
        sha1
            .convert(utf8.encode('$sessionId\n$voiceId\n$model\n$text'))
            .toString();
    final dir = await _cacheDirectory();
    final cached = File(p.join(dir.path, '$key.mp3'));
    if (await cached.exists() && await cached.length() > 0) {
      return cached.path;
    }
    final result = await _ttsService.synthesizeToFile(
      text: text,
      settings: settings,
      sessionId: sessionId,
    );
    final generated = File(result.filePath);
    await generated.copy(cached.path);
    return cached.path;
  }

  Future<Directory> _cacheDirectory() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'alicechat_wake_replies'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  List<String> _normalizedReplies(VoiceWakeWordTargetSettings target) {
    final seen = <String>{};
    return [
      for (final reply in target.replies)
        if (reply.trim().isNotEmpty && seen.add(reply.trim())) reply.trim(),
    ];
  }
}
