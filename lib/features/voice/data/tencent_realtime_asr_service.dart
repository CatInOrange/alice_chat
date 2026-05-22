import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

class TencentRealtimeAsrSession {
  TencentRealtimeAsrSession._({
    required WebSocketChannel channel,
    required StreamController<TencentRealtimeAsrEvent> eventsController,
    required StreamSubscription<dynamic> socketSubscription,
  }) : _channel = channel,
       _eventsController = eventsController,
       _socketSubscription = socketSubscription;

  final WebSocketChannel _channel;
  final StreamController<TencentRealtimeAsrEvent> _eventsController;
  final StreamSubscription<dynamic> _socketSubscription;
  bool _closed = false;
  bool _ended = false;

  Stream<TencentRealtimeAsrEvent> get events => _eventsController.stream;

  void sendAudio(Uint8List bytes) {
    if (_closed || _ended || bytes.isEmpty) return;
    _channel.sink.add(bytes);
  }

  Future<void> finish() async {
    if (_closed || _ended) return;
    _ended = true;
    _channel.sink.add(jsonEncode({'type': 'end'}));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _socketSubscription.cancel();
    await _channel.sink.close();
    await _eventsController.close();
  }
}

class TencentRealtimeAsrService {
  TencentRealtimeAsrService({Uuid? uuid, Random? random})
    : _uuid = uuid ?? const Uuid(),
      _random = random ?? Random.secure();

  static const _host = 'asr.cloud.tencent.com';
  static const _pathPrefix = '/asr/v2';

  final Uuid _uuid;
  final Random _random;

  Future<TencentRealtimeAsrSession> start({
    required VoiceSettings settings,
  }) async {
    final appId = settings.tencentAppId.trim();
    final secretId = settings.tencentSecretId.trim();
    final secretKey = settings.tencentSecretKey.trim();
    if (appId.isEmpty || secretId.isEmpty || secretKey.isEmpty) {
      throw Exception('请先在设置的“语音”中配置腾讯云 AppID、SecretID 和 SecretKey');
    }

    final uri = _buildUri(
      appId: appId,
      secretId: secretId,
      secretKey: secretKey,
      engineModelType:
          settings.tencentEngineModelType.trim().isEmpty
              ? '16k_zh'
              : settings.tencentEngineModelType.trim(),
    );
    final channel = WebSocketChannel.connect(uri);
    final eventsController = StreamController<TencentRealtimeAsrEvent>();
    late final TencentRealtimeAsrSession session;
    final socketSubscription = channel.stream.listen(
      (message) {
        _handleSocketMessage(message, eventsController);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!eventsController.isClosed) {
          eventsController.addError(error, stackTrace);
        }
      },
      onDone: () {
        if (!eventsController.isClosed) {
          eventsController.close();
        }
      },
      cancelOnError: false,
    );
    session = TencentRealtimeAsrSession._(
      channel: channel,
      eventsController: eventsController,
      socketSubscription: socketSubscription,
    );
    return session;
  }

  Uri _buildUri({
    required String appId,
    required String secretId,
    required String secretKey,
    required String engineModelType,
  }) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final params = <String, String>{
      'convert_num_mode': '1',
      'engine_model_type': engineModelType,
      'expired': (now + 24 * 60 * 60).toString(),
      'filter_dirty': '0',
      'filter_modal': '0',
      'filter_punc': '0',
      'needvad': '1',
      'nonce': (_random.nextInt(899999999) + 100000000).toString(),
      'secretid': secretId,
      'timestamp': now.toString(),
      'voice_format': '1',
      'voice_id': _uuid.v4(),
    };
    final sortedKeys = params.keys.toList()..sort();
    final canonicalQuery = sortedKeys
        .map((key) => '$key=${params[key]}')
        .join('&');
    final signText = '$_host$_pathPrefix/$appId?$canonicalQuery';
    final signature = base64Encode(
      Hmac(sha1, utf8.encode(secretKey)).convert(utf8.encode(signText)).bytes,
    );
    return Uri(
      scheme: 'wss',
      host: _host,
      path: '$_pathPrefix/$appId',
      queryParameters: {...params, 'signature': signature},
    );
  }

  void _handleSocketMessage(
    dynamic message,
    StreamController<TencentRealtimeAsrEvent> eventsController,
  ) {
    if (message is! String || eventsController.isClosed) return;
    final decoded = jsonDecode(message) as Map<String, dynamic>;
    final code = decoded['code'] as int? ?? 0;
    if (code != 0) {
      final errorMessage = (decoded['message'] ?? '腾讯云实时 ASR 失败').toString();
      eventsController.addError(Exception('$code: $errorMessage'));
      eventsController.close();
      return;
    }
    if (decoded['final'] == 1) {
      eventsController.add(
        const TencentRealtimeAsrEvent(
          index: -1,
          text: '',
          isStable: true,
          isFinal: true,
        ),
      );
      eventsController.close();
      return;
    }
    final result = (decoded['result'] as Map?)?.cast<String, dynamic>();
    if (result == null) return;
    final text = (result['voice_text_str'] ?? '').toString();
    if (text.isEmpty) return;
    final sliceType = result['slice_type'] as int? ?? 1;
    eventsController.add(
      TencentRealtimeAsrEvent(
        index: result['index'] as int? ?? 0,
        text: text,
        isStable: sliceType == 2,
        isFinal: false,
      ),
    );
  }
}
