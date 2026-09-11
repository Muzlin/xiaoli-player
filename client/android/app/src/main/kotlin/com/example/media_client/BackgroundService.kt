package com.example.media_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 常驻后台服务：带常驻通知，尽量不被系统回收，让 App 的 Dart 轮询(消息/验证码)
 * 在界面关闭后仍能继续，收到系统通知。
 *
 * 说明：不是推送服务。用户手动「强行停止」或系统省电策略仍可能杀掉它——
 * 这是安卓的限制，真正微信级的到达率需要厂商推送/极光等。
 */
class BackgroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIF_ID, buildNotification())
        return START_STICKY // 被回收后尽量自动重建
    }

    private fun buildNotification(): Notification {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            mgr.getNotificationChannel(CHANNEL) == null
        ) {
            val ch = NotificationChannel(
                CHANNEL, "后台运行", NotificationManager.IMPORTANCE_LOW)
            ch.description = "保持后台接收消息 / 验证码"
            mgr.createNotificationChannel(ch)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this, 0, launch ?: Intent(),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("小李播放器")
            .setContentText("后台运行中，可正常接收消息")
            .setOngoing(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    companion object {
        private const val CHANNEL = "xiaoli_bg"
        private const val NOTIF_ID = 990001

        fun start(ctx: Context) {
            val i = Intent(ctx, BackgroundService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(i)
                } else {
                    ctx.startService(i)
                }
            } catch (_: Exception) {
            }
        }

        fun stop(ctx: Context) {
            try {
                ctx.stopService(Intent(ctx, BackgroundService::class.java))
            } catch (_: Exception) {
            }
        }
    }
}
