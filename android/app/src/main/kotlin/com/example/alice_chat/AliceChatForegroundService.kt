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
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit
import java.util.ArrayDeque
import kotlin.concurrent.thread

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
    private var appForeground: Boolean = true
    @Volatile
    private var lastBackgroundedAtMs: Long = 0L
    @Volatile
    private var lastSeq: Long? = null
    private var workerThread: Thread? = null

    override fun onCreate() {
        super.onCreate()
        DebugLogBuffer.append("fg-service", "onCreate")
        createChannels()
        loadDeliveredDedupeKeys()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        activeSessionId = intent?.getStringExtra(EXTRA_ACTIVE_SESSION_ID)?.trim().orEmpty()
        DebugLogBuffer.append("fg-service", "onStartCommand activeSessionId=$activeSessionId appForeground=$appForeground running=$running startId=$startId action=${intent?.action.orEmpty()}")
        startForeground(SERVICE_NOTIFICATION_ID, buildServiceNotification())
        if (!running) {
            running = true
            instance = this
            startEventLoop()
        } else {
            instance = this
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        DebugLogBuffer.append("fg-service", "onDestroy")
        running = false
        workerThread?.interrupt()
        workerThread = null
        instance = null
        super.onDestroy()
    }

    private fun startEventLoop() {
        DebugLogBuffer.append("fg-service", "startEventLoop")
        workerThread = thread(start = true, name = "alicechat-sse") {
            while (running) {
                try {
                    connectAndConsumeSse()
                } catch (_: InterruptedException) {
                    DebugLogBuffer.append("fg-service", "event loop interrupted")
                    break
                } catch (error: Exception) {
                    DebugLogBuffer.append("fg-service", "event loop error=${error.message}")
                    Thread.sleep(RECONNECT_DELAY_MS)
                }
            }
        }
    }

    private fun connectAndConsumeSse() {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val baseUrlEntry = readFlutterStringPref(prefs, "openclaw.baseUrl")
        val passwordEntry = readFlutterStringPref(prefs, "openclaw.appPassword")
        val rawBaseUrl = baseUrlEntry.second
        DebugLogBuffer.append(
            "fg-service",
            "connectAndConsumeSse baseUrlKey=${baseUrlEntry.first} baseUrl=$rawBaseUrl lastSeq=${lastSeq ?: "null"} active=$activeSessionId appForeground=$appForeground"
        )
        if (rawBaseUrl.isEmpty()) {
            DebugLogBuffer.append(
                "fg-service",
                "missing baseUrl, retry later keys=${prefs.all.keys.filter { it.contains("baseUrl") || it.contains("appPassword") }}"
            )
            Thread.sleep(RECONNECT_DELAY_MS)
            return
        }
        val password = passwordEntry.second
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
            DebugLogBuffer.append("fg-service", "sse response code=${response.code}")
            if (!response.isSuccessful) {
                DebugLogBuffer.append("fg-service", "decision=retry_http code=${response.code} lastSeq=${lastSeq ?: "null"}")
                Thread.sleep(RECONNECT_DELAY_MS)
                return
            }
            DebugLogBuffer.append("fg-service", "decision=stream_connected lastSeq=${lastSeq ?: "null"}")
            consumeSseResponse(response)
            DebugLogBuffer.append("fg-service", "decision=stream_ended lastSeq=${lastSeq ?: "null"}")
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

        DebugLogBuffer.append("fg-service", "raw event eventName=${eventName.orEmpty()} payload=$payloadText")
        val json = JSONObject(payloadText)
        if (json.has("seq")) {
            lastSeq = json.optLong("seq")
        }
        val effectiveEvent = eventName ?: json.optString("type")
        val payload = json.optJSONObject("payload") ?: json
        val deliveryPhase = payload.optString("deliveryPhase").ifBlank { json.optString("deliveryPhase") }
        DebugLogBuffer.append("fg-service", "effectiveEvent=$effectiveEvent deliveryPhase=${deliveryPhase.ifBlank { "unknown" }}")
        when (effectiveEvent) {
            "notification.candidate" -> handleNotificationCandidate(payload, deliveryPhase)
            "assistant.message.completed", "message.created" -> {
                DebugLogBuffer.append("fg-service", "decision=ignore_legacy_event event=$effectiveEvent")
                return
            }
            else -> return
        }
    }

    private fun handleNotificationCandidate(payload: JSONObject, deliveryPhase: String) {
        val sessionId = payload.optString("sessionId").trim()
        val messageId = payload.optString("messageId").trim()
        val dedupeKey = payload.optString("dedupeKey").trim()
        val title = payload.optString("title").ifBlank {
            payload.optString("senderName").ifBlank { resolveTitleForSession(sessionId) }
        }
        val preview = payload.optString("bodyPreview").trim().ifBlank { "[新消息]" }
        val senderName = payload.optString("senderName").trim()
        val stableDedupeKey = dedupeKey.ifBlank {
            if (sessionId.isNotBlank() && messageId.isNotBlank()) "$sessionId:$messageId" else ""
        }
        DebugLogBuffer.append(
            "fg-service",
            "candidate_received session=$sessionId messageId=$messageId dedupeKey=$dedupeKey stableDedupeKey=$stableDedupeKey deliveryPhase=${deliveryPhase.ifBlank { "unknown" }} active=$activeSessionId appForeground=$appForeground sender=$senderName title=$title previewLen=${preview.length}"
        )
        if (sessionId.isEmpty()) {
            DebugLogBuffer.append("fg-service", "decision=drop_invalid_candidate reason=empty_session messageId=$messageId")
            return
        }
        if (deliveryPhase == "replay") {
            DebugLogBuffer.append("fg-service", "decision=suppress_replay session=$sessionId messageId=$messageId dedupeKey=$dedupeKey")
            return
        }
        if (stableDedupeKey.isNotEmpty() && hasSeenDedupeKey(stableDedupeKey)) {
            DebugLogBuffer.append("fg-service", "decision=suppress_duplicate session=$sessionId messageId=$messageId dedupeKey=$stableDedupeKey active=$activeSessionId appForeground=$appForeground")
            return
        }
        maybeNotify(
            sessionId = sessionId,
            title = title,
            messageId = messageId,
            preview = preview,
            hasAttachments = preview == "[图片]",
            source = "candidate",
            dedupeKey = stableDedupeKey,
        )
    }

    private fun maybeNotify(
        sessionId: String,
        title: String,
        messageId: String,
        preview: String,
        hasAttachments: Boolean,
        source: String,
        dedupeKey: String,
    ) {
        val recentlyBackgrounded =
            !appForeground &&
                lastBackgroundedAtMs > 0L &&
                System.currentTimeMillis() - lastBackgroundedAtMs <= 5_000L
        if (appForeground && sessionId.isNotEmpty() && sessionId == activeSessionId && !recentlyBackgrounded) {
            DebugLogBuffer.append("fg-service", "decision=suppress_active_session source=$source session=$sessionId active=$activeSessionId appForeground=$appForeground recentlyBackgrounded=$recentlyBackgrounded")
            return
        }
        if (recentlyBackgrounded) {
            DebugLogBuffer.append("fg-service", "decision=allow_recent_background source=$source session=$sessionId active=$activeSessionId appForeground=$appForeground backgroundedAt=$lastBackgroundedAtMs")
        }
        DebugLogBuffer.append("fg-service", "decision=notify_attempt source=$source session=$sessionId title=$title messageId=$messageId textLen=${preview.length} active=$activeSessionId appForeground=$appForeground hasAttachments=$hasAttachments dedupeKey=$dedupeKey recentlyBackgrounded=$recentlyBackgrounded backgroundedAt=$lastBackgroundedAtMs")
        if (dedupeKey.isNotEmpty()) {
            rememberDedupeKey(dedupeKey)
        }
        showMessageNotification(sessionId, title, messageId, preview)
    }

    private fun showMessageNotification(
        eventSessionId: String,
        title: String,
        messageId: String,
        preview: String
    ) {
        val payload = JSONObject().apply {
            put("sessionId", eventSessionId)
            put("messageId", messageId)
        }.toString()
        val intent = Intent(this, MainActivity::class.java).apply {
            action = MainActivity.ACTION_OPEN_CHAT_NOTIFICATION
            putExtra(EXTRA_SESSION_ID, eventSessionId)
            putExtra(EXTRA_MESSAGE_ID, messageId)
            putExtra(MainActivity.EXTRA_NOTIFICATION_OPEN_PAYLOAD, payload)
            data = android.net.Uri.parse("alicechat://notification-open/${eventSessionId}/${messageId.ifEmpty { "latest" }}")
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            (eventSessionId + ":" + messageId + ":open").hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, MESSAGE_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(preview)
            .setStyle(NotificationCompat.BigTextStyle().bigText(preview))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setLargeIcon(loadAvatarBitmap(eventSessionId))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notificationId = (eventSessionId + ":" + messageId).hashCode()
        val notificationsEnabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            manager.areNotificationsEnabled()
        } else {
            true
        }
        val channelImportance = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.getNotificationChannel(MESSAGE_CHANNEL_ID)?.importance ?: -1
        } else {
            -1
        }
        val activeNotifications = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) manager.activeNotifications.size else -1
        DebugLogBuffer.append("fg-service", "decision=post notificationId=$notificationId eventSession=$eventSessionId channel=$MESSAGE_CHANNEL_ID enabled=$notificationsEnabled channelImportance=$channelImportance activeCount=$activeNotifications title=$title preview=${preview.take(80)}")
        try {
            manager.notify(notificationId, notification)
            val activeNotificationsAfter = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) manager.activeNotifications.size else -1
            DebugLogBuffer.append("fg-service", "decision=posted notificationId=$notificationId eventSession=$eventSessionId activeCountAfter=$activeNotificationsAfter preview=${preview.take(80)}")
        } catch (error: Exception) {
            DebugLogBuffer.append("fg-service", "decision=post_failed notificationId=$notificationId eventSession=$eventSessionId error=${error.message}")
        }
    }

    private fun loadDeliveredDedupeKeys() {
        val prefs = getSharedPreferences(DEDUPE_PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(DEDUPE_KEYS_PREF_KEY, null).orEmpty().trim()
        deliveredDedupeKeys.clear()
        if (raw.isNotEmpty()) {
            try {
                val arr = JSONArray(raw)
                for (i in 0 until arr.length()) {
                    val key = arr.optString(i).trim()
                    if (key.isNotEmpty()) {
                        deliveredDedupeKeys.addLast(key)
                    }
                }
            } catch (error: Exception) {
                DebugLogBuffer.append("fg-service", "dedupe_load_failed error=${error.message}")
            }
        }
        trimDeliveredDedupeKeys()
        DebugLogBuffer.append("fg-service", "dedupe_loaded size=${deliveredDedupeKeys.size}")
    }

    private fun hasSeenDedupeKey(key: String): Boolean {
        return synchronized(deliveredDedupeKeys) {
            deliveredDedupeKeys.contains(key)
        }
    }

    private fun rememberDedupeKey(key: String) {
        synchronized(deliveredDedupeKeys) {
            deliveredDedupeKeys.remove(key)
            deliveredDedupeKeys.addLast(key)
            trimDeliveredDedupeKeys()
            persistDeliveredDedupeKeysLocked()
        }
        DebugLogBuffer.append("fg-service", "dedupe_remembered key=$key size=${deliveredDedupeKeys.size}")
    }

    private fun trimDeliveredDedupeKeys() {
        while (deliveredDedupeKeys.size > MAX_DEDUPE_KEYS) {
            deliveredDedupeKeys.removeFirst()
        }
    }

    private fun persistDeliveredDedupeKeysLocked() {
        val arr = JSONArray()
        deliveredDedupeKeys.forEach { arr.put(it) }
        val prefs = getSharedPreferences(DEDUPE_PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(DEDUPE_KEYS_PREF_KEY, arr.toString()).apply()
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
        val cached = sessionMetadata[sessionId]?.get("title")?.trim().orEmpty()
        if (cached.isNotEmpty()) {
            return cached
        }
        return when (sessionId) {
            "alice:main", "alice" -> "alice"
            "yulinglong:main", "yulinglong" -> "玲珑"
            "lisuxin:main", "lisuxin" -> "素心"
            "guqingge:main", "guqingge" -> "清歌"
            else -> "AliceChat"
        }
    }

    private fun loadAvatarBitmap(sessionId: String): Bitmap? {
        val metadataAvatar = sessionMetadata[sessionId]?.get("avatarAssetPath")?.trim().orEmpty()
        val metadataBitmap = loadAvatarBitmapFromMetadata(metadataAvatar)
        if (metadataBitmap != null) {
            return metadataBitmap
        }
        val resId = when (sessionId) {
            "alice:main", "alice" -> R.drawable.alice_avatar
            "yulinglong:main", "yulinglong" -> R.drawable.linglong_avatar
            "lisuxin:main", "lisuxin" -> R.drawable.lisuxin_avatar
            else -> 0
        }
        if (resId != 0) {
            return BitmapFactory.decodeResource(resources, resId)
        }
        return when (sessionId) {
            "guqingge:main", "guqingge" ->
                loadAvatarBitmapFromMetadata("assets/avatars/qingge.jpg")
            else -> null
        }
    }

    private fun loadAvatarBitmapFromMetadata(avatarAssetPath: String): Bitmap? {
        if (avatarAssetPath.isBlank()) return null
        val resId = when (avatarAssetPath.substringAfterLast('/')) {
            "alice.jpg", "alice_avatar.jpg" -> R.drawable.alice_avatar
            "linglong.jpg", "linglong_avatar.jpg" -> R.drawable.linglong_avatar
            "lisuxin.jpg", "lisuxin_avatar.jpg" -> R.drawable.lisuxin_avatar
            else -> 0
        }
        if (resId != 0) {
            return BitmapFactory.decodeResource(resources, resId)
        }
        return try {
            assets.open(avatarAssetPath).use { input ->
                BitmapFactory.decodeStream(input)
            }
        } catch (_: IOException) {
            null
        }
    }

    private fun readFlutterStringPref(
        prefs: android.content.SharedPreferences,
        key: String,
    ): Pair<String, String> {
        val candidates = listOf("flutter.$key", key)
        for (candidate in candidates) {
            val value = prefs.getString(candidate, null)?.trim().orEmpty()
            if (value.isNotEmpty()) {
                return candidate to value
            }
        }
        return candidates.first() to ""
    }

    companion object {
        const val SERVICE_CHANNEL_ID = "alicechat_background_service"
        const val MESSAGE_CHANNEL_ID = "alicechat_messages"
        const val SERVICE_NOTIFICATION_ID = 10010
        const val EXTRA_ACTIVE_SESSION_ID = "activeSessionId"
        const val EXTRA_SESSION_ID = "sessionId"
        const val EXTRA_MESSAGE_ID = "messageId"
        private const val RECONNECT_DELAY_MS = 3000L
        private const val DEDUPE_PREFS_NAME = "alicechat_notification_dedupe"
        private const val DEDUPE_KEYS_PREF_KEY = "delivered_keys"
        private const val MAX_DEDUPE_KEYS = 256

        @Volatile
        private var instance: AliceChatForegroundService? = null
        private val sessionMetadata = mutableMapOf<String, MutableMap<String, String>>()
        private val deliveredDedupeKeys = ArrayDeque<String>()

        fun updateActiveSession(sessionId: String) {
            instance?.activeSessionId = sessionId.trim()
            DebugLogBuffer.append("fg-service", "activeSessionUpdated session=${sessionId.trim()} viaMethodChannel=${instance != null} appForeground=${instance?.appForeground}")
        }

        fun updateAppForeground(isForeground: Boolean) {
            instance?.appForeground = isForeground
            if (!isForeground) {
                instance?.lastBackgroundedAtMs = System.currentTimeMillis()
            }
            DebugLogBuffer.append("fg-service", "appForegroundUpdated foreground=$isForeground viaMethodChannel=${instance != null} active=${instance?.activeSessionId.orEmpty()} backgroundedAt=${instance?.lastBackgroundedAtMs ?: 0L}")
        }

        fun updateSessionMetadata(sessionId: String, title: String, avatarAssetPath: String) {
            val normalized = sessionId.trim()
            if (normalized.isEmpty()) return
            sessionMetadata[normalized] = mutableMapOf(
                "title" to title.trim(),
                "avatarAssetPath" to avatarAssetPath.trim(),
            )
            DebugLogBuffer.append("fg-service", "sessionMetadataUpdated session=$normalized title=${title.trim()} avatar=${avatarAssetPath.trim()}")
        }
    }
}
