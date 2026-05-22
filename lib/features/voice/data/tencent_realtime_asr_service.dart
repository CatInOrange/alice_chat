import 'dart:async';

import 'package:asr_plugin/asr_plugin.dart';

import '../domain/voice_settings.dart';

class TencentRealtimeAsrEvent {
  const TencentRealtimeAsrEvent({
    required this.index,
    required this.text,
    required this.isStable,
    required this.isFinal,
  });

  final int index;
  final String text;
  final bool isStable;
  final bool isFinal;
}

class TencentRealtimeAsrException implements Exception {
  const TencentRealtimeAsrException({
    required this.code,
    required this.message,
    this.response,
  });

  final int code;
  final String message;
  final String? response;

  @override
  String toString() {
    final buffer = StringBuffer('腾讯 ASR 错误 $code');
    final normalizedMessage = message.trim();
    if (normalizedMessage.isNotEmpty) {
      buffer.write('：$normalizedMessage');
    }
    final normalizedResponse = response?.trim();
    if (normalizedResponse != null && normalizedResponse.isNotEmpty) {
      buffer.write('（$normalizedResponse）');
    }
    return buffer.toString();
  }
}

class TencentRealtimeAsrSession {
  TencentRealtimeAsrSession._({
    required ASRController controller,
    required StreamController<TencentRealtimeAsrEvent> eventsController,
    required StreamSubscription<ASRData> recognitionSubscription,
  }) : _controller = controller,
       _eventsController = eventsController,
       _recognitionSubscription = recognitionSubscription;

  final ASRController _controller;
  final StreamController<TencentRealtimeAsrEvent> _eventsController;
  final StreamSubscription<ASRData> _recognitionSubscription;
  bool _closed = false;
  bool _ended = false;

  Stream<TencentRealtimeAsrEvent> get events => _eventsController.stream;

  Future<void> finish() async {
    if (_closed || _ended) return;
    _ended = true;
    await _controller.stop();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _recognitionSubscription.cancel();
    await _controller.stop();
    await _controller.release();
    await _eventsController.close();
  }
}

class TencentRealtimeAsrService {
  Future<TencentRealtimeAsrSession> start({
    required VoiceSettings settings,
  }) async {
    final appId = settings.tencentAppId.trim();
    final secretId = settings.tencentSecretId.trim();
    final secretKey = settings.tencentSecretKey.trim();
    if (appId.isEmpty || secretId.isEmpty || secretKey.isEmpty) {
      throw Exception('请先在设置的“语音”中配置腾讯云 AppID、SecretID 和 SecretKey');
    }
    final numericAppId = int.tryParse(appId);
    if (numericAppId == null || numericAppId <= 0) {
      throw Exception('腾讯云 AppID 必须是数字');
    }

    final config =
        ASRControllerConfig()
          ..appID = numericAppId
          ..secretID = secretId
          ..secretKey = secretKey
          ..token =
              settings.tencentToken.trim().isEmpty
                  ? null
                  : settings.tencentToken.trim()
          ..engine_model_type =
              settings.tencentEngineModelType.trim().isEmpty
                  ? '16k_zh'
                  : settings.tencentEngineModelType.trim()
          ..convert_num_mode = 1
          ..filter_dirty = 0
          ..filter_modal = 0
          ..filter_punc = 0
          ..needvad = 1
          ..vad_silence_time = 3000
          ..is_compress = true
          ..silence_detect = true
          ..silence_detect_duration = 3000;
    final controller = await config.build();
    final eventsController = StreamController<TencentRealtimeAsrEvent>();
    final recognitionSubscription = controller.recognize().listen(
      (data) => _handleAsrData(data, eventsController),
      onError: (Object error, StackTrace stackTrace) {
        if (!eventsController.isClosed) {
          eventsController.addError(_normalizeAsrError(error), stackTrace);
        }
      },
      onDone: () {
        if (!eventsController.isClosed) {
          eventsController.close();
        }
      },
      cancelOnError: false,
    );
    return TencentRealtimeAsrSession._(
      controller: controller,
      eventsController: eventsController,
      recognitionSubscription: recognitionSubscription,
    );
  }

  Object _normalizeAsrError(Object error) {
    if (error is ASRError) {
      return TencentRealtimeAsrException(
        code: error.code,
        message: error.message,
        response: error.resp,
      );
    }
    return error;
  }

  void _handleAsrData(
    ASRData data,
    StreamController<TencentRealtimeAsrEvent> eventsController,
  ) {
    if (eventsController.isClosed) return;
    switch (data.type) {
      case ASRDataType.SLICE:
      case ASRDataType.SEGMENT:
        final text = data.res ?? '';
        if (text.isEmpty) return;
        eventsController.add(
          TencentRealtimeAsrEvent(
            index: data.id ?? 0,
            text: text,
            isStable: data.type == ASRDataType.SEGMENT,
            isFinal: false,
          ),
        );
        break;
      case ASRDataType.SUCCESS:
        final text = data.result ?? '';
        if (text.isNotEmpty) {
          eventsController.add(
            TencentRealtimeAsrEvent(
              index: 0,
              text: text,
              isStable: true,
              isFinal: false,
            ),
          );
        }
        eventsController.close();
        break;
      case ASRDataType.NOTIFY:
        break;
    }
  }
}
