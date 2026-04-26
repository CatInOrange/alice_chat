package com.example.alice_chat

import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingNotificationSessionId: String? = null

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
                    val intent = Intent(this, AliceChatForegroundService::class.java)
                    stopService(intent)
                    val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                    prefs.edit().putBoolean("flutter.alicechat.backgroundServiceEnabled", false).apply()
                    result.success(null)
                }
                "updateActiveSession" -> {
                    val sessionId = call.argument<String>("sessionId").orEmpty()
                    val serviceIntent = Intent(this, AliceChatForegroundService::class.java).apply {
                        putExtra(AliceChatForegroundService.EXTRA_ACTIVE_SESSION_ID, sessionId)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(serviceIntent)
                    } else {
                        startService(serviceIntent)
                    }
                    result.success(null)
                }
                "consumePendingNotificationOpen" -> {
                    result.success(pendingNotificationSessionId)
                    pendingNotificationSessionId = null
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun captureIntent(intent: Intent?) {
        val sessionId = intent?.getStringExtra(AliceChatForegroundService.EXTRA_SESSION_ID)
        if (!sessionId.isNullOrBlank()) {
            pendingNotificationSessionId = sessionId
        }
    }
}
