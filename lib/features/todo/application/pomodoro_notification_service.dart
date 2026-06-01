import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/debug/native_debug_bridge.dart';
import '../domain/todo_models.dart';

class PomodoroNotificationService {
  PomodoroNotificationService._();

  static final PomodoroNotificationService instance =
      PomodoroNotificationService._();
  static const MethodChannel _channel = MethodChannel(
    'alicechat/pomodoro_timer',
  );

  bool get _supportsNativeTimers =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> prepareReliableReminders() async {
    if (!_supportsNativeTimers) return;
    try {
      final status = await _channel.invokeMapMethod<String, bool>(
        'getReminderStatus',
      );
      final exactAlarmAllowed = status?['exactAlarmAllowed'] ?? true;
      final ignoringBatteryOptimizations =
          status?['ignoringBatteryOptimizations'] ?? true;
      await NativeDebugBridge.instance.log(
        'pomodoro',
        'reminder status exactAlarmAllowed=$exactAlarmAllowed ignoringBatteryOptimizations=$ignoringBatteryOptimizations',
      );
      if (!exactAlarmAllowed) {
        await _channel.invokeMethod<void>('requestExactAlarmPermission');
        await NativeDebugBridge.instance.log(
          'pomodoro',
          'requested exact alarm permission',
        );
        return;
      }
      if (!ignoringBatteryOptimizations) {
        await _channel.invokeMethod<void>(
          'requestBatteryOptimizationExemption',
        );
        await NativeDebugBridge.instance.log(
          'pomodoro',
          'requested battery optimization exemption',
        );
      }
    } catch (error) {
      await NativeDebugBridge.instance.log(
        'pomodoro',
        'prepare reminders failed error=$error',
        level: 'WARN',
      );
    }
  }

  Future<void> schedule({
    required TodoPomodoro pomodoro,
    required String taskTitle,
  }) async {
    if (!_supportsNativeTimers) return;
    try {
      await _channel.invokeMethod<void>('schedulePomodoro', {
        'id': pomodoro.id,
        'taskId': pomodoro.taskId,
        'taskTitle': taskTitle,
        'phase': pomodoro.phase.name,
        'triggerAt': pomodoro.endsAt.millisecondsSinceEpoch,
      });
      await NativeDebugBridge.instance.log(
        'pomodoro',
        'schedule native id=${pomodoro.id} phase=${pomodoro.phase.name} triggerAt=${pomodoro.endsAt.toIso8601String()}',
      );
    } catch (error) {
      await NativeDebugBridge.instance.log(
        'pomodoro',
        'schedule native failed id=${pomodoro.id} error=$error',
        level: 'WARN',
      );
    }
  }

  Future<void> cancel(String id) async {
    if (!_supportsNativeTimers) return;
    try {
      await _channel.invokeMethod<void>('cancelPomodoro', {'id': id});
      await NativeDebugBridge.instance.log('pomodoro', 'cancel native id=$id');
    } catch (error) {
      await NativeDebugBridge.instance.log(
        'pomodoro',
        'cancel native failed id=$id error=$error',
        level: 'WARN',
      );
    }
  }
}
