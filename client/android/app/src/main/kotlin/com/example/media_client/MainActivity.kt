package com.example.media_client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.Bundle
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var volumeChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null
    private var screenChannel: MethodChannel? = null
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
