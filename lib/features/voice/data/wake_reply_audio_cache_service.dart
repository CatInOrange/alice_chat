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
    final replies = _normalizedReplies(target.replies);
    if (replies.isEmpty || !settings.canUseOutput) return null;
    final text = replies[_random.nextInt(replies.length)];
    return _cachedOrGenerate(
      text: text,
      settings: settings,
      sessionId: target.sessionId,
      cacheName: 'wake_replies',
    );
  }

  Future<String?> randomWaitingCachedOrGenerate({
    required VoiceSettings settings,
    required String sessionId,
  }) async {
    final target = _targetForSession(settings, sessionId);
    if (target == null || !settings.canUseOutput) return null;
    final replies = _normalizedReplies(target.waitingReplies);
    if (replies.isEmpty) return null;
    final text = replies[_random.nextInt(replies.length)];
    return _cachedOrGenerate(
      text: text,
      settings: settings,
      sessionId: target.sessionId,
      cacheName: 'waiting_replies',
    );
  }

  Future<int> generateAll(VoiceSettings settings) async {
    if (!settings.canUseOutput) {
      throw Exception('请先启用语音输出并配置 MiniMax API Key');
    }
    var count = 0;
    for (final target in settings.wakeWord.targets) {
      for (final text in _normalizedReplies(target.replies)) {
        await _cachedOrGenerate(
          text: text,
          settings: settings,
          sessionId: target.sessionId,
          cacheName: 'wake_replies',
        );
        count += 1;
      }
    }
    return count;
  }

  Future<int> generateAllWaiting(VoiceSettings settings) async {
    if (!settings.canUseOutput) {
      throw Exception('请先启用语音输出并配置 MiniMax API Key');
    }
    var count = 0;
    for (final target in settings.wakeWord.targets) {
      for (final text in _normalizedReplies(target.waitingReplies)) {
        await _cachedOrGenerate(
          text: text,
          settings: settings,
          sessionId: target.sessionId,
          cacheName: 'waiting_replies',
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
    required String cacheName,
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
    final dir = await _cacheDirectory(cacheName);
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

  Future<Directory> _cacheDirectory(String cacheName) async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'alicechat_$cacheName'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  List<String> _normalizedReplies(List<String> replies) {
    final seen = <String>{};
    return [
      for (final reply in replies)
        if (reply.trim().isNotEmpty && seen.add(reply.trim())) reply.trim(),
    ];
  }

  VoiceWakeWordTargetSettings? _targetForSession(
    VoiceSettings settings,
    String sessionId,
  ) {
    for (final target in settings.wakeWord.targets) {
      if (target.sessionId == sessionId) return target;
    }
    return null;
  }
}
