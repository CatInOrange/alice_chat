import 'dart:io';

import '../openclaw/openclaw_http_client.dart';
import '../openclaw/openclaw_settings.dart';
import 'debug_log_store.dart';
import 'native_debug_bridge.dart';

class DebugLogUploader {
  DebugLogUploader._();

  static final DebugLogUploader instance = DebugLogUploader._();

  Future<Map<String, dynamic>> upload() async {
    await DebugLogStore.instance.ensureLoaded();
    await NativeDebugBridge.instance.log('debug-upload', 'upload start');
    final nativeLines = await NativeDebugBridge.instance.fetchNativeLogs();
    final config = await OpenClawSettingsStore.load();
    final client = OpenClawHttpClient(config);
    final payload = {
      'source': 'alicechat-app',
      'uploadedAt': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystem,
      'flutterLogs': DebugLogStore.instance.entries
          .map((e) => {
                'ts': e.timestamp.toIso8601String(),
                'level': e.level,
                'tag': e.tag,
                'message': e.message,
              })
          .toList(),
      'nativeLogs': nativeLines,
      'summary': {
        'flutterCount': DebugLogStore.instance.entries.length,
        'nativeCount': nativeLines.length,
      },
    };
    final result = await client.sendClientDebugLog(payload);
    await NativeDebugBridge.instance.log(
      'debug-upload',
      'upload success uploadId=${result['uploadId'] ?? ''}',
    );
    return result;
  }
}
