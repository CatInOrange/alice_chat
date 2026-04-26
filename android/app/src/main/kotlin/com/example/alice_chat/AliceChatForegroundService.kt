package com.example.alice_chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.random.Random

class AliceChatForegroundService : Service() {
    private val client: OkHttpClient = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .connectTimeout(15, TimeUnit.SECONDS)
        .build()

    @Volatile
    private var running = false
    @Volatile
    private var activeSessionId: String = ""
    @Volatile
    private var lastSeq: Long? = null
    private var workerThread: Thread? = null

    override fun onCreate() {
        super.onCreate()
        createChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        activeSessionId = intent?.getStringExtra(EXTRA_ACTIVE_SESSION_ID)?.trim().orEmpty()
        startForeground(SERVICE_NOTIFICATION_ID, buildServiceNotification())
        if (!running) {
            running = true
            startEventLoop()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        running = false
        workerThread?.interrupt()
        workerThread = null
        super.onDestroy()
    }

    private fun startEventLoop() {
        workerThread = thread(start = true, name = "alicechat-sse") {
            while (running) {
                try {
                    connectAndConsumeSse()
                } catch (_: InterruptedException) {
                    break
                } catch (_: Exception) {
                    Thread.sleep(RECONNECT_DELAY_MS)
                }
            }
        }
    }

    private fun connectAndConsumeSse() {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val rawBaseUrl = prefs.getString("openclaw.baseUrl", "")?.trim().orEmpty()
        if (rawBaseUrl.isEmpty()) {
            Thread.sleep(RECONNECT_DELAY_MS)
            return
        }
        val password = prefs.getString("openclaw.appPassword", "")?.trim().orEmpty()
        val baseUrl = rawBaseUrl.removeSuffix("/")
        val urlBuilder = StringBuilder("$baseUrl/api/events")
        lastSeq?.let {
            urlBuilder.append("?since=").append(it)
        }

        val requestBuilder = Request.Builder()
            .url(urlBuilder.toString())
            .get()
            .addHeader("Accept", "text/event-stream")
        if (password.isNotEmpty()) {
            requestBuilder.addHeader("X-AliceChat-Password", password)
        }

        client.newCall(requestBuilder.build()).execute().use { response ->
            if (!response.isSuccessful) {
                Thread.sleep(RECONNECT_DELAY_MS)
                return
            }
            consumeSseResponse(response)
        }
    }

    private fun consumeSseResponse(response: Response) {
        val body = response.body ?: return
        BufferedReader(InputStreamReader(body.byteStream())).use { reader ->
            var eventName: String? = null
            val dataLines = mutableListOf<String>()
            while (running) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) {
                    handleSseEvent(eventName, dataLines)
                    eventName = null
                    dataLines.clear()
                    continue
                }
                if (line.startsWith("event:")) {
                    eventName = line.substringAfter(":").trim()
                    continue
                }
                if (line.startsWith("data:")) {
                    dataLines.add(line.substringAfter(":").trim())
                }
            }
        }
    }

    private fun handleSseEvent(eventName: String?, dataLines: List<String>) {
        if (dataLines.isEmpty()) return
        val payloadText = dataLines.joinToString("\n").trim()
        if (payloadText.isEmpty()) return

        val json = JSONObject(payloadText)
        if (json.has("seq")) {
            lastSeq = json.optLong("seq")
        }
        val effectiveEvent = eventName ?: json.optString("type")
        if (effectiveEvent != "assistant.message.completed" && effectiveEvent != "message.created") {
            return
        }
        val payload = json.optJSONObject("payload") ?: json
        val sessionId = payload.optString("sessionId").trim()
        if (sessionId.isEmpty()) return
        if (sessionId == activeSessionId) return
        val message = payload.optJSONObject("message") ?: return
        val role = message.optString("role").trim()
        if (role != "assistant") return
        val text = message.optString("text").trim()
        if (text.isEmpty()) return
        val title = payload.optString("senderName").ifBlank { resolveTitleForSession(sessionId) }
        val messageId = message.optString("id")
        showMessageNotification(sessionId, title, messageId)
    }

    private fun showMessageNotification(
        sessionId: String,
        title: String,
        messageId: String
    ) {
        val intent = Intent(this, MainActivity::class.java).apply {
            putExtra(EXTRA_SESSION_ID, sessionId)
            putExtra(EXTRA_MESSAGE_ID, messageId)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            sessionId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val teaser = pickTeaser(title)
        val notification = NotificationCompat.Builder(this, MESSAGE_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(teaser)
            .setStyle(NotificationCompat.BigTextStyle().bigText(teaser))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setLargeIcon(loadAvatarBitmap(sessionId))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify((sessionId + messageId + teaser).hashCode(), notification)
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val serviceChannel = NotificationChannel(
            SERVICE_CHANNEL_ID,
            "AliceChat 后台连接",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "保持 AliceChat 后台长连接"
            setShowBadge(false)
        }
        val messageChannel = NotificationChannel(
            MESSAGE_CHANNEL_ID,
            "AliceChat 消息通知",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "AliceChat 新消息提醒"
            setShowBadge(true)
        }
        manager.createNotificationChannel(serviceChannel)
        manager.createNotificationChannel(messageChannel)
    }

    private fun buildServiceNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, SERVICE_CHANNEL_ID)
            .setContentTitle("AliceChat 正在后台运行")
            .setContentText("保持消息连接中")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    private fun resolveTitleForSession(sessionId: String): String {
        return when (sessionId) {
            "alice:main", "alice" -> "alice"
            "yulinglong:main", "yulinglong" -> "玲珑"
            "lisuxin:main", "lisuxin" -> "素心"
            else -> "AliceChat"
        }
    }

    private fun pickTeaser(title: String): String {
        val pool = when (title) {
            "alice" -> listOf(
                "Alice 又来找你玩啦。",
                "Alice 带着新消息冒泡了。",
                "快看，Alice 正在等你回应。"
            )
            "玲珑" -> listOf(
                "玲珑又来敲你了。",
                "玲珑留了一句话，不看会后悔。",
                "玲珑那边有新动静。"
            )
            "素心" -> listOf(
                "素心抱着新消息跑来了。",
                "素心又勤勤恳恳地来汇报了。",
                "素心那边有更新，瞧一眼吧。"
            )
            else -> listOf(
                "有条新消息在等你翻牌。",
                "有人轻轻敲了敲你的聊天窗。",
                "新动静来了，快去看看。"
            )
        }
        return pool[Random.nextInt(pool.size)]
    }

    private fun loadAvatarBitmap(sessionId: String): Bitmap? {
        val resId = when (sessionId) {
            "alice:main", "alice" -> R.drawable.alice_avatar
            "yulinglong:main", "yulinglong" -> R.drawable.linglong_avatar
            "lisuxin:main", "lisuxin" -> R.drawable.lisuxin_avatar
            else -> return null
        }
        return BitmapFactory.decodeResource(resources, resId)
    }

    companion object {
        const val SERVICE_CHANNEL_ID = "alicechat_background_service"
        const val MESSAGE_CHANNEL_ID = "alicechat_messages"
        const val SERVICE_NOTIFICATION_ID = 10010
        const val EXTRA_ACTIVE_SESSION_ID = "activeSessionId"
        const val EXTRA_SESSION_ID = "sessionId"
        const val EXTRA_MESSAGE_ID = "messageId"
        private const val RECONNECT_DELAY_MS = 3000L
    }
}
