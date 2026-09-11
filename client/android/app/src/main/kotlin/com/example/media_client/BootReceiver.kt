package com.example.media_client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 开机 / 升级后自启：只有在设置里开过「后台运行」才拉起常驻服务。
 * 读取 Flutter shared_preferences(安卓上存于 FlutterSharedPreferences，键前缀 flutter.)。
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context?, intent: Intent?) {
        if (ctx == null) return
        val a = intent?.action ?: return
        if (a != Intent.ACTION_BOOT_COMPLETED &&
            a != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        val sp = ctx.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE)
        if (sp.getBoolean("flutter.background_run", false)) {
            BackgroundService.start(ctx)
        }
    }
}
