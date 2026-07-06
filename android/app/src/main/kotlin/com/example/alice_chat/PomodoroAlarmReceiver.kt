package com.example.alice_chat

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import org.json.JSONObject

class PomodoroAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pomodoroId = intent.getStringExtra(EXTRA_POMODORO_ID).orEmpty()
        if (intent.action == ACTION_STOP_POMODORO_VIBRATION) {
            DebugLogBuffer.append("pomodoro", "vibration stop received id=$pomodoroId")
            stopReminder(context, pomodoroId)
            return
        }
        val taskId = intent.getStringExtra(EXTRA_TASK_ID).orEmpty()
        val taskTitle = intent.getStringExtra(EXTRA_TASK_TITLE).orEmpty().ifBlank { "当前任务" }
        val phase = intent.getStringExtra(EXTRA_PHASE).orEmpty()
        DebugLogBuffer.append("pomodoro", "alarm received id=$pomodoroId task=$taskId phase=$phase title=$taskTitle")
        createChannel(context)
        vibrate(context, pomodoroId)
        showNotification(context, pomodoroId, taskId, taskTitle, phase)
    }

    private fun showNotification(
        context: Context,
        pomodoroId: String,
        taskId: String,
        taskTitle: String,
        phase: String,
    ) {
        val focusDone = phase == "focus"
        val title = if (focusDone) "番茄完成" else "休息结束"
        val body = if (focusDone) "“$taskTitle” 25 分钟到了，记录一下进展。" else "休息结束，要继续下一轮吗？"
        val payload = JSONObject().apply {
            put("kind", "pomodoro")
            put("pomodoroId", pomodoroId)
            put("taskId", taskId)
            put("phase", phase)
        }.toString()
        val openIntent = Intent(context, MainActivity::class.java).apply {
            action = MainActivity.ACTION_OPEN_POMODORO_NOTIFICATION
            putExtra(MainActivity.EXTRA_POMODORO_OPEN_PAYLOAD, payload)
            putExtra(EXTRA_POMODORO_ID, pomodoroId)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            data = android.net.Uri.parse("alicechat://pomodoro/$pomodoroId/$phase")
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            ("pomodoro:$pomodoroId:$phase").hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopPendingIntent = stopPendingIntent(context, pomodoroId)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pendingIntent)
            .setDeleteIntent(stopPendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVibrate(VIBRATION_PATTERN)
            .addAction(android.R.drawable.ic_lock_silent_mode, "停止震动", stopPendingIntent)
            .build()
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(("pomodoro:$pomodoroId").hashCode(), notification)
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "番茄时钟",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "番茄工作与休息结束提醒"
            enableVibration(true)
            vibrationPattern = VIBRATION_PATTERN
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun vibrate(context: Context, pomodoroId: String) {
        try {
            val vibrator = vibrator(context)
            vibrator.cancel()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    VibrationEffect.createWaveform(VIBRATION_PATTERN, VIBRATION_REPEAT_INDEX),
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(VIBRATION_PATTERN, VIBRATION_REPEAT_INDEX)
            }
            scheduleAutoStop(context, pomodoroId)
        } catch (error: Exception) {
            DebugLogBuffer.append("pomodoro", "vibrate failed error=${error.message}")
        }
    }

    private fun stopReminder(context: Context, pomodoroId: String) {
        stopVibrationReminder(context, pomodoroId)
    }

    private fun scheduleAutoStop(context: Context, pomodoroId: String) {
        if (pomodoroId.isBlank()) return
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val triggerAt = System.currentTimeMillis() + VIBRATION_AUTO_STOP_MS
        val pendingIntent = stopPendingIntent(context, pomodoroId)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
            } else {
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
            }
        } catch (error: Exception) {
            DebugLogBuffer.append("pomodoro", "vibration exact auto-stop failed id=$pomodoroId error=${error.message}")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
            } else {
                alarmManager.set(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
            }
        }
        DebugLogBuffer.append("pomodoro", "vibration auto-stop scheduled id=$pomodoroId triggerAt=$triggerAt")
    }

    private fun cancelAutoStop(context: Context, pomodoroId: String) {
        cancelAutoStopAlarm(context, pomodoroId)
    }

    private fun vibrator(context: Context): Vibrator =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            manager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

    companion object {
        const val ACTION_POMODORO_ALARM = "com.example.alice_chat.POMODORO_ALARM"
        const val ACTION_STOP_POMODORO_VIBRATION = "com.example.alice_chat.STOP_POMODORO_VIBRATION"
        const val EXTRA_POMODORO_ID = "pomodoroId"
        const val EXTRA_TASK_ID = "taskId"
        const val EXTRA_TASK_TITLE = "taskTitle"
        const val EXTRA_PHASE = "phase"
        const val CHANNEL_ID = "alicechat_pomodoro_timer"
        const val VIBRATION_REPEAT_INDEX = 1
        const val VIBRATION_AUTO_STOP_MS = 30_000L
        val VIBRATION_PATTERN = longArrayOf(0, 900, 220, 900, 220, 900, 650)

        fun cancelVibration(context: Context) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                    manager.defaultVibrator.cancel()
                } else {
                    @Suppress("DEPRECATION")
                    (context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator).cancel()
                }
            } catch (error: Exception) {
                DebugLogBuffer.append("pomodoro", "cancel vibration failed error=${error.message}")
            }
        }

        fun stopVibrationReminder(context: Context, pomodoroId: String) {
            cancelVibration(context)
            cancelAutoStopAlarm(context, pomodoroId)
        }

        private fun cancelAutoStopAlarm(context: Context, pomodoroId: String) {
            if (pomodoroId.isBlank()) return
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.cancel(stopPendingIntent(context, pomodoroId))
        }

        private fun stopPendingIntent(context: Context, pomodoroId: String): PendingIntent {
            val intent = Intent(context, PomodoroAlarmReceiver::class.java).apply {
                action = ACTION_STOP_POMODORO_VIBRATION
                putExtra(EXTRA_POMODORO_ID, pomodoroId)
                data = android.net.Uri.parse("alicechat://pomodoro-stop/$pomodoroId")
            }
            return PendingIntent.getBroadcast(
                context,
                ("pomodoro-stop:$pomodoroId").hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }
}
