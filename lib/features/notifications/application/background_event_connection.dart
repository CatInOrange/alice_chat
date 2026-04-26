import '../../../core/debug/native_debug_bridge.dart';

class BackgroundEventConnection {
  BackgroundEventConnection._();

  static final BackgroundEventConnection instance =
      BackgroundEventConnection._();

  bool _running = false;

  bool get isRunning => _running;

  Future<void> start() async {
    _running = false;
    await NativeDebugBridge.instance.log(
      'bg-events',
      'start skipped disabled_single_native_source',
    );
  }

  Future<void> stop() async {
    _running = false;
    await NativeDebugBridge.instance.log(
      'bg-events',
      'stop noop disabled_single_native_source',
    );
  }

  void rememberSession({required String sessionId, required String title}) {}
}
