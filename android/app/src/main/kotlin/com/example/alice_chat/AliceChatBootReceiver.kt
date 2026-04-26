package com.example.alice_chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class AliceChatBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean("flutter.alicechat.backgroundServiceEnabled", false)
        if (!enabled) return
        val serviceIntent = Intent(context, AliceChatForegroundService::class.java)
        context.startForegroundService(serviceIntent)
    }
}
