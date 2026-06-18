package com.example.media_client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var volumeChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null
    private var screenChannel: MethodChannel? = null
    private var installerChannel: MethodChannel? = null
    private var sharedUrl: String? = null

    // F46: 记录音量键按下时刻，区分长按(换曲)/短按(调音量)。
    private var volDownAt: Long = 0

    // F48: 屏幕开关广播。
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> screenChannel?.invokeMethod("screenLocked", null)
                Intent.ACTION_SCREEN_ON -> screenChannel?.invokeMethod("screenUnlocked", null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        volumeChannel = MethodChannel(messenger, "xiaoli/volume")
        screenChannel = MethodChannel(messenger, "xiaoli/screen_lock")
        shareChannel = MethodChannel(messenger, "xiaoli/share")
        shareChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getSharedUrl") {
                result.success(sharedUrl)
                sharedUrl = null
            } else {
                result.notImplemented()
            }
        }
        // 自动更新：调起系统安装器装新版 apk。
        installerChannel = MethodChannel(messenger, "xiaoli/installer")
        installerChannel?.setMethodCallHandler { call, result ->
            if (call.method == "install") {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("no_path", "缺少 apk 路径", null)
                } else {
                    try {
                        installApk(path)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }
            } else {
                result.notImplemented()
            }
        }
        registerReceiver(screenReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        })
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    // 自动更新：用 FileProvider 把 apk 交给系统安装器（Android 7+ 必须用 content:// URI）。
    private fun installApk(path: String) {
        val file = File(path)
        val uri = FileProvider.getUriForFile(
            this, "$packageName.fileprovider", file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        // Android 8+ 需「安装未知应用」权限，系统会自动引导用户去授权。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
            )
        }
        startActivity(intent)
    }

    // F47: 从系统分享接收 URL。
    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
            val m = Regex("https?://[^\\s]+").find(text)
            sharedUrl = m?.value
            sharedUrl?.let { shareChannel?.invokeMethod("onSharedUrl", it) }
        }
    }

    // F46: 长按音量键换曲，短按调音量。
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
            keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
        ) {
            if (event?.repeatCount == 0) volDownAt = System.currentTimeMillis()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
            keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
        ) {
            val held = System.currentTimeMillis() - volDownAt
            if (held >= 500) {
                volumeChannel?.invokeMethod(
                    if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "next" else "prev", null
                )
            } else {
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    if (keyCode == KeyEvent.KEYCODE_VOLUME_UP)
                        AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER,
                    AudioManager.FLAG_SHOW_UI
                )
            }
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(screenReceiver)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}
