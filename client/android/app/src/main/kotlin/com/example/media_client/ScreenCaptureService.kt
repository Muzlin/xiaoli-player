package com.example.media_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import java.io.ByteArrayOutputStream

/**
 * 直播屏幕采集：单独 Service 承载 MediaProjection/VirtualDisplay 生命周期。
 * Android 14(API 34)起，创建 MediaProjection 前必须先有一个
 * foregroundServiceType="mediaProjection" 的前台服务处于运行状态，否则
 * createVirtualDisplay 会抛 SecurityException——这也是没有直接把这套逻辑
 * 写在 MainActivity 里的原因：Activity/Context 都没有 startForeground() API，
 * 那是 Service 专属方法，必须有一个真正的 Service 子类。
 *
 * 抓到的 JPEG 帧通过静态回调 [frameListener] 转发回 MainActivity 再喂给 Flutter；
 * 只持有函数引用，MainActivity 停止采集时会清空，避免 Service 间接长期持有 Activity。
 */
class ScreenCaptureService : Service() {
    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var lastFrameTs = 0L
    private val mainHandler = Handler(Looper.getMainLooper())

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            stopSelfCapture()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notif = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIF_ID, notif)
        }
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        val data = intent?.getParcelableExtra<Intent>(EXTRA_DATA)
        if (data == null || resultCode == 0) {
            stopSelf()
            return START_NOT_STICKY
        }
        // 关键顺序：startForeground() 必须先完成，这里才能安全拿 MediaProjection。
        val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = mgr.getMediaProjection(resultCode, data)
        if (projection == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        mediaProjection = projection
        projection.registerCallback(projectionCallback, mainHandler)
        startVirtualDisplay(projection)
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            mgr.getNotificationChannel(CHANNEL_ID) == null
        ) {
            mgr.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "直播录屏", NotificationManager.IMPORTANCE_LOW))
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("正在直播")
            .setContentText("小李播放器正在采集屏幕画面")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .build()
    }

    private fun startVirtualDisplay(projection: MediaProjection) {
        val metrics = resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi
        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        imageReader = reader
        reader.setOnImageAvailableListener({ r ->
            val image = r.acquireLatestImage()
            if (image != null) {
                try {
                    val now = System.currentTimeMillis()
                    // 节流：约每700ms一帧，和摄像头/桌面采集 cadence 对齐。
                    if (now - lastFrameTs >= 700) {
                        lastFrameTs = now
                        val jpg = rgbaImageToJpeg(image, width, height)
                        if (jpg != null) frameListener?.invoke(jpg)
                    }
                } finally {
                    image.close()
                }
            }
        }, mainHandler)
        virtualDisplay = projection.createVirtualDisplay(
            "xiaoli-live", width, height, density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface, null, null)
    }

    /** ImageReader 出来的 RGBA_8888(带 rowPadding) -> Bitmap -> JPEG。 */
    private fun rgbaImageToJpeg(image: android.media.Image, width: Int, height: Int): ByteArray? {
        return try {
            val plane = image.planes[0]
            val buffer = plane.buffer
            val pixelStride = plane.pixelStride
            val rowStride = plane.rowStride
            val rowPadding = rowStride - pixelStride * width
            val bitmap = android.graphics.Bitmap.createBitmap(
                width + rowPadding / pixelStride, height, android.graphics.Bitmap.Config.ARGB_8888)
            bitmap.copyPixelsFromBuffer(buffer)
            val cropped = if (rowPadding == 0) bitmap
                          else android.graphics.Bitmap.createBitmap(bitmap, 0, 0, width, height)
            val out = ByteArrayOutputStream()
            cropped.compress(android.graphics.Bitmap.CompressFormat.JPEG, 70, out)
            out.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    private fun stopSelfCapture() {
        virtualDisplay?.release(); virtualDisplay = null
        imageReader?.close(); imageReader = null
        mediaProjection?.unregisterCallback(projectionCallback)
        mediaProjection?.stop(); mediaProjection = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION") stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        stopSelfCapture()
        frameListener = null
        super.onDestroy()
    }

    companion object {
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"
        private const val CHANNEL_ID = "xiaoli_screencast"
        private const val NOTIF_ID = 9911

        /** 抓到 JPEG 帧时回调。MainActivity 启动采集前设置，停止采集/onDestroy 时清空。 */
        var frameListener: ((ByteArray) -> Unit)? = null
    }
}
