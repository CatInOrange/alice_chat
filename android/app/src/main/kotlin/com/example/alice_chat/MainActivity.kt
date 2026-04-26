package com.example.alice_chat

import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : FlutterActivity() {
    private var pendingNotificationSessionId: String? = null

    companion object {
        const val ACTION_OPEN_CHAT_NOTIFICATION = "com.example.alice_chat.OPEN_CHAT_NOTIFICATION"
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
                "consumePendingNotificationOpen" -> {
                    appendLog("main", "consumePendingNotificationOpen session=${pendingNotificationSessionId.orEmpty()}")
                    result.success(pendingNotificationSessionId)
                    pendingNotificationSessionId = null
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
    }

    private fun captureIntent(intent: Intent?) {
        val action = intent?.action.orEmpty()
        val sessionId = intent?.getStringExtra(AliceChatForegroundService.EXTRA_SESSION_ID)?.trim().orEmpty()
        val messageId = intent?.getStringExtra(AliceChatForegroundService.EXTRA_MESSAGE_ID)?.trim().orEmpty()
        appendLog("main", "captureIntent action=$action session=$sessionId messageId=$messageId")
        if (action != ACTION_OPEN_CHAT_NOTIFICATION) {
            appendLog("main", "captureIntent ignored_non_notification action=$action")
            return
        }
        if (sessionId.isNotEmpty()) {
            pendingNotificationSessionId = sessionId
            appendLog("main", "captureIntent accepted_notification session=$sessionId")
        } else {
            appendLog("main", "captureIntent ignored_empty_notification_session messageId=$messageId")
        }
    }

    private fun appendLog(tag: String, message: String) {
        DebugLogBuffer.append(tag, message)
    }
}

object DebugLogBuffer {
    private const val MAX_SIZE = 300
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
