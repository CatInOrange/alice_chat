import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../../core/openclaw/openclaw_settings.dart';

class SherpaWakeWordHit {
  const SherpaWakeWordHit({
    required this.keyword,
    required this.sessionId,
    required this.label,
    required this.at,
    this.navigateToChat = true,
    this.startVoiceInput = true,
    this.autoSendAfterRecognition,
    this.autoPlayReply = true,
  });

  final String keyword;
  final String sessionId;
  final String label;
  final DateTime at;
  final bool navigateToChat;
  final bool startVoiceInput;
  final bool? autoSendAfterRecognition;
  final bool autoPlayReply;
}

class SherpaWakeWordModelStatus {
  const SherpaWakeWordModelStatus({
    required this.directory,
    required this.ready,
    required this.missingFiles,
  });

  final String directory;
  final bool ready;
  final List<String> missingFiles;
}

class SherpaWakeWordTestSession {
  SherpaWakeWordTestSession({
    required this.hits,
    required Future<void> Function() stop,
  }) : _stop = stop;

  final Stream<SherpaWakeWordHit> hits;
  final Future<void> Function() _stop;

  Future<void> stop() => _stop();
}

class SherpaWakeWordService {
  static const modelDownloadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/'
      'sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2';

  static bool _bindingsReady = false;

  final AudioRecorder _recorder = AudioRecorder();

  Future<SherpaWakeWordModelStatus> modelStatus(
    VoiceWakeWordSettings settings,
  ) async {
    await installBundledDefaultModel(settings);
    final dir = await _resolveModelDirectory(settings);
    final missing = <String>[
      for (final file in _expectedModelFiles)
        if (!File(p.join(dir.path, file)).existsSync()) file,
    ];
    return SherpaWakeWordModelStatus(
      directory: dir.path,
      ready: missing.isEmpty,
      missingFiles: missing,
    );
  }

  Future<SherpaWakeWordModelStatus> installBundledDefaultModel(
    VoiceWakeWordSettings settings, {
    bool overwrite = false,
  }) async {
    final configured = settings.modelAssetPath.trim();
    if (configured.isNotEmpty &&
        configured != VoiceWakeWordSettings.defaultModelAssetPath) {
      return _rawModelStatus(settings);
    }

    final dir = await _resolveModelDirectory(settings);
    await dir.create(recursive: true);
    for (final file in _expectedModelFiles) {
      final output = File(p.join(dir.path, file));
      if (!overwrite && output.existsSync()) continue;
      final bytes = await rootBundle.load(
        '${VoiceWakeWordSettings.defaultModelAssetPath}/$file',
      );
      await output.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    }
    return _rawModelStatus(settings);
  }

  Future<SherpaWakeWordModelStatus> _rawModelStatus(
    VoiceWakeWordSettings settings,
  ) async {
    final dir = await _resolveModelDirectory(settings);
    final missing = <String>[
      for (final file in _expectedModelFiles)
        if (!File(p.join(dir.path, file)).existsSync()) file,
    ];
    return SherpaWakeWordModelStatus(
      directory: dir.path,
      ready: missing.isEmpty,
      missingFiles: missing,
    );
  }

  Future<SherpaWakeWordTestSession> startTest(
    VoiceWakeWordSettings settings,
  ) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw Exception('前台唤醒测试目前只在 Android/iOS 上启用');
    }
    if (!await _recorder.hasPermission()) {
      throw Exception('没有麦克风权限');
    }

    final status = await modelStatus(settings);
    if (!status.ready) {
      throw Exception(
        '缺少 sherpa-onnx KWS 模型文件：${status.missingFiles.join(', ')}\n'
        '请把模型解压到：${status.directory}',
      );
    }

    _initBindings();

    final spotter = _createSpotter(settings, status.directory);
    final stream = spotter.createStream();
    final hits = StreamController<SherpaWakeWordHit>.broadcast();
    final audioStream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        audioInterruption: AudioInterruptionMode.none,
      ),
    );

    var stopped = false;
    StreamSubscription<Uint8List>? audioSubscription;
    audioSubscription = audioStream.listen(
      (chunk) {
        if (stopped) return;
        stream.acceptWaveform(
          samples: _pcm16ToFloat32(chunk),
          sampleRate: 16000,
        );
        while (spotter.isReady(stream)) {
          spotter.decode(stream);
        }
        final keyword = spotter.getResult(stream).keyword.trim();
        if (keyword.isEmpty) return;
        final target = _targetForKeyword(settings, keyword);
        if (target == null) return;
        hits.add(
          SherpaWakeWordHit(
            keyword: keyword,
            sessionId: target.sessionId,
            label: target.label,
            at: DateTime.now(),
            navigateToChat: target.navigateToChat,
            startVoiceInput: target.startVoiceInput,
            autoSendAfterRecognition: target.autoSendAfterRecognition,
            autoPlayReply: target.autoPlayReply,
          ),
        );
        spotter.reset(stream);
      },
      onError: hits.addError,
      onDone: hits.close,
    );

    return SherpaWakeWordTestSession(
      hits: hits.stream,
      stop: () async {
        if (stopped) return;
        stopped = true;
        await audioSubscription?.cancel();
        await _recorder.stop();
        stream.free();
        spotter.free();
        await hits.close();
      },
    );
  }

  Future<void> dispose() => _recorder.dispose();

  Future<Directory> _resolveModelDirectory(
    VoiceWakeWordSettings settings,
  ) async {
    final configured = settings.modelAssetPath.trim();
    if (configured.isNotEmpty && p.isAbsolute(configured)) {
      return Directory(configured);
    }
    final root = await getApplicationSupportDirectory();
    return Directory(
      p.join(
        root.path,
        configured.isEmpty
            ? VoiceWakeWordSettings.defaultModelAssetPath
            : configured,
      ),
    );
  }

  sherpa.KeywordSpotter _createSpotter(
    VoiceWakeWordSettings settings,
    String modelDir,
  ) {
    final keywords = _buildKeywords(settings);
    if (keywords.isEmpty) {
      throw Exception('没有可用的唤醒词，请至少启用一个角色并填写唤醒词');
    }
    return sherpa.KeywordSpotter(
      sherpa.KeywordSpotterConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: _firstExisting(modelDir, const [
              'encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
              'encoder-epoch-12-avg-2-chunk-16-left-64.onnx',
            ]),
            decoder: _firstExisting(modelDir, const [
              'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
              'decoder-epoch-12-avg-2-chunk-16-left-64.onnx',
            ]),
            joiner: _firstExisting(modelDir, const [
              'joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
              'joiner-epoch-12-avg-2-chunk-16-left-64.onnx',
            ]),
          ),
          tokens: p.join(modelDir, 'tokens.txt'),
          numThreads: settings.numThreads,
          provider: 'cpu',
          debug: false,
        ),
        maxActivePaths: settings.maxActivePaths,
        numTrailingBlanks: settings.numTrailingBlanks,
        keywordsScore: settings.keywordsScore,
        keywordsThreshold: settings.keywordsThreshold,
        keywordsBuf: keywords,
        keywordsBufSize: utf8.encode(keywords).length,
      ),
    );
  }

  String _firstExisting(String modelDir, List<String> candidates) {
    for (final candidate in candidates) {
      final path = p.join(modelDir, candidate);
      if (File(path).existsSync()) return path;
    }
    return p.join(modelDir, candidates.first);
  }

  static void _initBindings() {
    if (_bindingsReady) return;
    sherpa.initBindings();
    _bindingsReady = true;
  }

  String _buildKeywords(VoiceWakeWordSettings settings) {
    final lines = <String>[];
    for (final target in settings.targets.where((target) => target.enabled)) {
      for (final keyword in target.keywords) {
        final line = _keywordToTokenLine(settings, target, keyword);
        if (line.isNotEmpty) lines.add(line);
      }
    }
    return lines.join('\n');
  }

  VoiceWakeWordTargetSettings? _targetForKeyword(
    VoiceWakeWordSettings settings,
    String keyword,
  ) {
    for (final target in settings.targets.where((target) => target.enabled)) {
      if (target.keywords.any(
        (item) => _originalKeywordForMatch(item.trim()) == keyword,
      )) {
        return target;
      }
    }
    return null;
  }

  String _keywordToTokenLine(
    VoiceWakeWordSettings settings,
    VoiceWakeWordTargetSettings target,
    String keyword,
  ) {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.contains('@')) return trimmed;
    final tokens = _knownChineseKeywordTokens[trimmed];
    if (tokens == null) return '';
    final threshold = target.thresholdOverride ?? settings.keywordsThreshold;
    return '$tokens '
        ':${_formatConfigNumber(settings.keywordsScore)} '
        '#${_formatConfigNumber(threshold)} '
        '@$trimmed';
  }

  String _originalKeywordForMatch(String keyword) {
    final at = keyword.lastIndexOf('@');
    if (at >= 0 && at + 1 < keyword.length) {
      return keyword.substring(at + 1).trim();
    }
    return keyword;
  }

  String _formatConfigNumber(num value) {
    final text = value.toStringAsFixed(3);
    return text.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  Float32List _pcm16ToFloat32(Uint8List bytes) {
    final samples = Float32List(bytes.length ~/ 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i += 1) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return samples;
  }
}

const _expectedModelFiles = [
  'encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
  'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
  'joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
  'tokens.txt',
];

const _knownChineseKeywordTokens = {
  '晚秋晚秋': 'w ǎn q iū w ǎn q iū',
  '苏晚秋': 's ū w ǎn q iū',
  '小秋小秋': 'x iǎo q iū x iǎo q iū',
  '玲珑玲珑': 'l íng l óng l íng l óng',
  '玉玲珑': 'y ù l íng l óng',
  '素心素心': 's ù x īn s ù x īn',
  '李素心': 'l ǐ s ù x īn',
  '清歌清歌': 'q īng g ē q īng g ē',
  '顾清歌': 'g ù q īng g ē',
};
