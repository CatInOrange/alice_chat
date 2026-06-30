package com.example.alice_chat

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : FlutterActivity() {
    private var pendingNotificationOpenPayload: String? = null

    companion object {
        const val ACTION_OPEN_CHAT_NOTIFICATION = "com.example.alice_chat.OPEN_CHAT_NOTIFICATION"
        const val ACTION_OPEN_POMODORO_NOTIFICATION = "com.example.alice_chat.OPEN_POMODORO_NOTIFICATION"
        const val EXTRA_NOTIFICATION_OPEN_PAYLOAD = "notificationOpenPayload"
        const val EXTRA_POMODORO_OPEN_PAYLOAD = "pomodoroOpenPayload"
        private const val MAX_PENDING_MUSIC_ACTIONS = 32
        private val mainHandler = Handler(Looper.getMainLooper())
        private var backgroundMusicChannel: MethodChannel? = null
        private val pendingMusicActionPayloads = ArrayDeque<String>()

        @Synchronized
        fun publishBackgroundMusicAction(payload: String) {
            val normalized = payload.trim()
            if (normalized.isEmpty()) return
            val channel = backgroundMusicChannel
            if (channel != null) {
                mainHandler.post {
                    channel.invokeMethod("onMusicAction", normalized)
                }
                appendStaticLog("main", "publishBackgroundMusicAction delivered payload=$normalized")
                return
            }
            pendingMusicActionPayloads.addLast(normalized)
            while (pendingMusicActionPayloads.size > MAX_PENDING_MUSIC_ACTIONS) {
                pendingMusicActionPayloads.removeFirst()
            }
            appendStaticLog("main", "publishBackgroundMusicAction queued size=${pendingMusicActionPayloads.size} payload=$normalized")
        }

        @Synchronized
        private fun consumePendingMusicActions(): List<String> {
            val items = pendingMusicActionPayloads.toList()
            pendingMusicActionPayloads.clear()
            appendStaticLog("main", "consumePendingMusicActions size=${items.size}")
            return items
        }

        private fun appendStaticLog(tag: String, message: String) {
            DebugLogBuffer.append(tag, message)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureIntent(intent)
    }

    override fun onDestroy() {
        backgroundMusicChannel = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "alicechat/background_connection"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundService" -> {
                    val sessionId = call.argument<String>("sessionId").orEmpty()
                    appendLog("main", "startForegroundService session=$sessionId")
                    val serviceIntent = Intent(this, AliceChatForegroundService::class.java).apply {
                        putExtra(AliceChatForegroundService.EXTRA_ACTIVE_SESSION_ID, sessionId)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(serviceIntent)
                    } else {
                        startService(serviceIntent)
                    }
                    val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                    prefs.edit().putBoolean("flutter.alicechat.backgroundServiceEnabled", true).apply()
                    result.success(null)
                }
                "stopForegroundService" -> {
                    appendLog("main", "stopForegroundService")
                    val intent = Intent(this, AliceChatForegroundService::class.java)
                    stopService(intent)
                    val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                    prefs.edit().putBoolean("flutter.alicechat.backgroundServiceEnabled", false).apply()
                    result.success(null)
                }
                "updateActiveSession" -> {
                    val sessionId = call.argument<String>("sessionId").orEmpty()
                    appendLog("main", "updateActiveSession session=$sessionId")
                    AliceChatForegroundService.updateActiveSession(sessionId)
                    result.success(null)
                }
                "updateSessionMetadata" -> {
                    val sessionId = call.argument<String>("sessionId").orEmpty()
                    val title = call.argument<String>("title").orEmpty()
                    val avatarAssetPath = call.argument<String>("avatarAssetPath").orEmpty()
                    appendLog("main", "updateSessionMetadata session=$sessionId title=$title avatar=$avatarAssetPath")
                    AliceChatForegroundService.updateSessionMetadata(sessionId, title, avatarAssetPath)
                    result.success(null)
                }
                "updateAppForeground" -> {
                    val isForeground = call.argument<Boolean>("isForeground") ?: true
                    appendLog("main", "updateAppForeground foreground=$isForeground")
                    AliceChatForegroundService.updateAppForeground(isForeground)
                    result.success(null)
                }
                "consumePendingNotificationOpen" -> {
                    appendLog("main", "consumePendingNotificationOpen payload=${pendingNotificationOpenPayload.orEmpty()}")
                    result.success(pendingNotificationOpenPayload)
                    pendingNotificationOpenPayload = null
                }
                else -> result.notImplemented()
            }
        }
        backgroundMusicChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "alicechat/background_music_events"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePendingMusicActions" -> {
                        result.success(consumePendingMusicActions())
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "alicechat/pomodoro_timer"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getReminderStatus" -> {
                    result.success(pomodoroReminderStatus())
                }
                "requestExactAlarmPermission" -> {
                    openExactAlarmSettings()
                    result.success(null)
                }
                "requestBatteryOptimizationExemption" -> {
                    openBatteryOptimizationSettings()
                    result.success(null)
                }
                "schedulePomodoro" -> {
                    val id = call.argument<String>("id").orEmpty()
                    val taskId = call.argument<String>("taskId").orEmpty()
                    val taskTitle = call.argument<String>("taskTitle").orEmpty()
                    val phase = call.argument<String>("phase").orEmpty()
                    val triggerAt = call.argument<Number>("triggerAt")?.toLong() ?: 0L
                    schedulePomodoroAlarm(id, taskId, taskTitle, phase, triggerAt)
                    result.success(null)
                }
                "cancelPomodoro" -> {
                    val id = call.argument<String>("id").orEmpty()
                    cancelPomodoroAlarm(id)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "alicechat/debug_logs"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getLogs" -> result.success(DebugLogBuffer.snapshot())
                "clearLogs" -> {
                    DebugLogBuffer.clear()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "alicechat/app_control"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "moveTaskToBack" -> {
                    appendLog("main", "moveTaskToBack requested")
                    result.success(moveTaskToBack(true))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun captureIntent(intent: Intent?) {
        val action = intent?.action.orEmpty()
        if (action == ACTION_OPEN_POMODORO_NOTIFICATION) {
            appendLog("main", "captureIntent accepted_pomodoro payload=${intent?.getStringExtra(EXTRA_POMODORO_OPEN_PAYLOAD).orEmpty()}")
            val pomodoroId = intent?.getStringExtra(PomodoroAlarmReceiver.EXTRA_POMODORO_ID).orEmpty()
            PomodoroAlarmReceiver.stopVibrationReminder(this, pomodoroId)
            return
        }
        val sessionId = intent?.getStringExtra(AliceChatForegroundService.EXTRA_SESSION_ID)?.trim().orEmpty()
        val messageId = intent?.getStringExtra(AliceChatForegroundService.EXTRA_MESSAGE_ID)?.trim().orEmpty()
        val payload = intent?.getStringExtra(EXTRA_NOTIFICATION_OPEN_PAYLOAD).orEmpty()
        appendLog("main", "captureIntent action=$action session=$sessionId messageId=$messageId payload=$payload")
        if (action != ACTION_OPEN_CHAT_NOTIFICATION) {
            appendLog("main", "captureIntent ignored_non_notification action=$action")
            return
        }
        if (payload.isNotEmpty()) {
            pendingNotificationOpenPayload = payload
            appendLog("main", "captureIntent accepted_notification payload=$payload")
        } else if (sessionId.isNotEmpty()) {
            pendingNotificationOpenPayload = "{\"sessionId\":\"$sessionId\",\"messageId\":\"$messageId\"}"
            appendLog("main", "captureIntent accepted_notification fallbackPayload=$pendingNotificationOpenPayload")
        } else {
            appendLog("main", "captureIntent ignored_empty_notification_session messageId=$messageId")
        }
    }

    private fun appendLog(tag: String, message: String) {
        DebugLogBuffer.append(tag, message)
    }

    private fun pomodoroReminderStatus(): Map<String, Boolean> {
        val exactAlarmAllowed = canScheduleExactPomodoroAlarm()
        val ignoringBatteryOptimizations = isIgnoringBatteryOptimizations()
        appendLog(
            "pomodoro",
            "reminder status exactAlarmAllowed=$exactAlarmAllowed ignoringBatteryOptimizations=$ignoringBatteryOptimizations"
        )
        return mapOf(
            "exactAlarmAllowed" to exactAlarmAllowed,
            "ignoringBatteryOptimizations" to ignoringBatteryOptimizations,
        )
    }

    private fun canScheduleExactPomodoroAlarm(): Boolean {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms()
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun openExactAlarmSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || canScheduleExactPomodoroAlarm()) return
        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
            data = Uri.parse("package:$packageName")
        }
        startSettingsIntent(intent, "exact_alarm")
    }

    private fun openBatteryOptimizationSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || isIgnoringBatteryOptimizations()) return
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
        }
        startSettingsIntent(intent, "battery_optimization")
    }

    private fun startSettingsIntent(intent: Intent, source: String) {
        try {
            startActivity(intent)
            appendLog("pomodoro", "open settings source=$source")
        } catch (error: Exception) {
            appendLog("pomodoro", "open settings failed source=$source error=${error.message}")
        }
    }

    private fun schedulePomodoroAlarm(
        id: String,
        taskId: String,
        taskTitle: String,
        phase: String,
        triggerAt: Long,
    ) {
        if (id.isBlank() || triggerAt <= 0L) {
            appendLog("pomodoro", "schedule skipped invalid id=$id triggerAt=$triggerAt")
            return
        }
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pendingIntent = pomodoroPendingIntent(id, taskId, taskTitle, phase)
        val canExact = canScheduleExactPomodoroAlarm()
        if (canExact && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
        } else if (canExact) {
            alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
        } else {
            alarmManager.set(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
        }
        appendLog("pomodoro", "schedule id=$id task=$taskId phase=$phase triggerAt=$triggerAt exact=$canExact")
    }

    private fun cancelPomodoroAlarm(id: String) {
        if (id.isBlank()) return
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(pomodoroPendingIntent(id, "", "", ""))
        appendLog("pomodoro", "cancel id=$id")
    }

    private fun pomodoroPendingIntent(
        id: String,
        taskId: String,
        taskTitle: String,
        phase: String,
    ): PendingIntent {
        val intent = Intent(this, PomodoroAlarmReceiver::class.java).apply {
            action = PomodoroAlarmReceiver.ACTION_POMODORO_ALARM
            putExtra(PomodoroAlarmReceiver.EXTRA_POMODORO_ID, id)
            putExtra(PomodoroAlarmReceiver.EXTRA_TASK_ID, taskId)
            putExtra(PomodoroAlarmReceiver.EXTRA_TASK_TITLE, taskTitle)
            putExtra(PomodoroAlarmReceiver.EXTRA_PHASE, phase)
            data = android.net.Uri.parse("alicechat://pomodoro-alarm/$id")
        }
        return PendingIntent.getBroadcast(
            this,
            id.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

object DebugLogBuffer {
    private const val MAX_SIZE = 1200
    private val lines = ArrayDeque<String>()
    private val formatter = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.getDefault())

    @Synchronized
    fun append(tag: String, message: String) {
        val line = "[${formatter.format(Date())}] [INFO] [$tag] $message"
        lines.addLast(line)
        while (lines.size > MAX_SIZE) {
            lines.removeFirst()
        }
    }

    @Synchronized
    fun snapshot(): List<String> = lines.toList()

    @Synchronized
    fun clear() {
        lines.clear()
    }
}
