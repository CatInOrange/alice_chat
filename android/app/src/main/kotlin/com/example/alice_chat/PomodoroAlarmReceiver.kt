package com.example.alice_chat

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
        val taskId = intent.getStringExtra(EXTRA_TASK_ID).orEmpty()
        val taskTitle = intent.getStringExtra(EXTRA_TASK_TITLE).orEmpty().ifBlank { "当前任务" }
        val phase = intent.getStringExtra(EXTRA_PHASE).orEmpty()
        DebugLogBuffer.append("pomodoro", "alarm received id=$pomodoroId task=$taskId phase=$phase title=$taskTitle")
        createChannel(context)
        vibrate(context)
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
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            data = android.net.Uri.parse("alicechat://pomodoro/$pomodoroId/$phase")
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            ("pomodoro:$pomodoroId:$phase").hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVibrate(VIBRATION_PATTERN)
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

    private fun vibrate(context: Context) {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                manager.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    VibrationEffect.createWaveform(VIBRATION_PATTERN, -1),
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(VIBRATION_PATTERN, -1)
            }
        } catch (error: Exception) {
            DebugLogBuffer.append("pomodoro", "vibrate failed error=${error.message}")
        }
    }

    companion object {
        const val ACTION_POMODORO_ALARM = "com.example.alice_chat.POMODORO_ALARM"
        const val EXTRA_POMODORO_ID = "pomodoroId"
        const val EXTRA_TASK_ID = "taskId"
        const val EXTRA_TASK_TITLE = "taskTitle"
        const val EXTRA_PHASE = "phase"
        const val CHANNEL_ID = "alicechat_pomodoro_timer"
        val VIBRATION_PATTERN = longArrayOf(0, 450, 180, 450, 180, 700)
    }
}
