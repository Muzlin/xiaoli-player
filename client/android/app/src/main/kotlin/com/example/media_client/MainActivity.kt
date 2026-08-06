package com.example.media_client

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.AudioManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import androidx.camera.core.*
import androidx.camera.camera2.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var volumeChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null
    private var screenChannel: MethodChannel? = null
    private var installerChannel: MethodChannel? = null
    private var openChannel: MethodChannel? = null
    private var notifChannel: MethodChannel? = null
    private var qrChannel: MethodChannel? = null
    private var pendingQrScanResult: MethodChannel.Result? = null
    // 直播采集(摄像头)：与 screenChannel(xiaoli/screen_lock，锁屏广播用) 是完全不同的东西，
    // 这里对应 xiaoli/screenrec 通道，Dart 侧 ScreenRecorder 复用。
    private var screenrecChannel: MethodChannel? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var cameraExecutor: ExecutorService? = null
    private var lastCameraFrameTs: Long = 0L
    // 直播采集(屏幕/MediaProjection)：实际的 MediaProjection/VirtualDisplay 生命周期
    // 由独立的 ScreenCaptureService 持有(Activity 没有 startForeground() API)，
    // 这里只保留发起投屏请求 + 等待系统弹窗结果需要的引用。
    private var mediaProjectionManager: MediaProjectionManager? = null
    private var pendingScreenStartResult: MethodChannel.Result? = null
    private var notifId: Int = 1000 // 递增通知 id，多条消息不互相覆盖
    private var sharedUrl: String? = null
    private var pendingOpenPath: String? = null // 启动时「打开方式」传入的待播文件

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
        mediaProjectionManager =
            getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
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
        // 「打开方式」：把外部用本 app 打开的音视频文件交给 Dart 播放。
        openChannel = MethodChannel(messenger, "xiaoli/openfile")
        openChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getPending") {
                result.success(pendingOpenPath?.let { listOf(it) } ?: emptyList<String>())
                pendingOpenPath = null
            } else {
                result.notImplemented()
            }
        }
        // 系统通知：收到新消息时弹安卓通知栏。
        notifChannel = MethodChannel(messenger, "xiaoli/notify")
        notifChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestAuth" -> { result.success(true) } // 权限在 Dart 侧用 permission_handler 之外的 SDK33 申请，这里仅占位
                "show" -> {
                    val title = call.argument<String>("title") ?: "新消息"
                    val body = call.argument<String>("body") ?: ""
                    showNotification(title, body)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        // 收付款二维码：生成 / 从图片识别 / 摄像头扫一扫。生成/识别可能是大图，放后台
        // TaskQueue 跑，避免大图片解码卡住 UI 线程导致 ANR；"scan" 要开 Activity，
        // 单独切回主线程。
        qrChannel = MethodChannel(
            messenger, "xiaoli/qr",
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue())
        qrChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "generate" -> {
                    val data = call.argument<String>("data")
                    if (data.isNullOrEmpty()) {
                        result.error("bad_args", "缺少 data", null)
                    } else {
                        try {
                            result.success(generateQrPng(data))
                        } catch (e: Throwable) {
                            result.error("generate_failed", e.message, null)
                        }
                    }
                }
                "scanImage" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("bad_args", "缺少 bytes", null)
                    } else {
                        try {
                            result.success(decodeQrFromBytes(bytes))
                        } catch (e: Throwable) {
                            result.error("scan_failed", e.message, null)
                        }
                    }
                }
                "scan" -> {
                    runOnUiThread {
                        if (pendingQrScanResult != null) {
                            // 已有一次扫码在进行中：拒绝新请求，不覆盖旧的 pending
                            // Result（否则旧的那次调用永远等不到返回，Dart 端会卡死）。
                            result.error("busy", "已有扫码窗口在进行中", null)
                        } else {
                            pendingQrScanResult = result
                            startActivityForResult(
                                Intent(this, QrScanActivity::class.java), QR_SCAN_REQUEST_CODE)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        // 直播采集：安卓摄像头(startCamera/stopCamera)。屏幕录制那次任务会在同一个
        // handler 的 when 里追加 startDesktop/stopDesktop/openScreenSettings 分支，
        // 不要新建第二个指向同名 channel 的 MethodChannel(会互相覆盖 handler)。
        screenrecChannel = MethodChannel(messenger, "xiaoli/screenrec")
        screenrecChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startCamera" -> {
                    val front = call.argument<Boolean>("front") ?: true
                    if (checkSelfPermission(android.Manifest.permission.CAMERA)
                        != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(android.Manifest.permission.CAMERA), 1002)
                        result.success(false)
                    } else {
                        startCameraCapture(front)
                        result.success(true)
                    }
                }
                "stopCamera" -> { stopCameraCapture(); result.success(null) }
                "startDesktop" -> {
                    pendingScreenStartResult = result
                    val intent = mediaProjectionManager?.createScreenCaptureIntent()
                    if (intent != null) {
                        startActivityForResult(intent, SCREEN_CAPTURE_REQUEST_CODE)
                    } else {
                        result.success(false)
                    }
                }
                "stopDesktop" -> { stopScreenCapture(); result.success(null) }
                "openScreenSettings" -> {
                    // Android 没有对应的一次性设置项，重新发起一次投屏权限请求。
                    val intent = mediaProjectionManager?.createScreenCaptureIntent()
                    if (intent != null) startActivityForResult(intent, SCREEN_CAPTURE_REQUEST_CODE)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        registerReceiver(screenReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        })
    }

    private fun generateQrPng(data: String, size: Int = 480): ByteArray {
        val writer = com.google.zxing.qrcode.QRCodeWriter()
        // MARGIN 用 ZXing 默认(4 模块)，符合 ISO/IEC 18004 静区最小要求，太窄扫描器可能锁不定位。
        val matrix = writer.encode(data, com.google.zxing.BarcodeFormat.QR_CODE, size, size)
        val bmp = android.graphics.Bitmap.createBitmap(
            size, size, android.graphics.Bitmap.Config.ARGB_8888)
        val pixels = IntArray(size * size)
        for (y in 0 until size) {
            for (x in 0 until size) {
                pixels[y * size + x] =
                    if (matrix.get(x, y)) android.graphics.Color.BLACK
                    else android.graphics.Color.WHITE
            }
        }
        bmp.setPixels(pixels, 0, size, 0, 0, size, size)
        val stream = java.io.ByteArrayOutputStream()
        bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream)
        return stream.toByteArray()
    }

    private fun decodeQrFromBytes(bytes: ByteArray): String? {
        return try {
            val bmp = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                ?: return null
            val w = bmp.width
            val h = bmp.height
            val pixels = IntArray(w * h)
            bmp.getPixels(pixels, 0, w, 0, 0, w, h)
            val source = com.google.zxing.RGBLuminanceSource(w, h, pixels)
            val bitmap = com.google.zxing.BinaryBitmap(
                com.google.zxing.common.HybridBinarizer(source))
            // 只认二维码：不加这个 hint 的话 ZXing 会顺带尝试条形码等格式，选中的照片如果
            // 恰好还带其它条码图案，可能把不相关的条码内容当成收付款码识别结果返回。
            val hints = mapOf(
                com.google.zxing.DecodeHintType.POSSIBLE_FORMATS to
                    listOf(com.google.zxing.BarcodeFormat.QR_CODE))
            com.google.zxing.MultiFormatReader().decode(bitmap, hints).text
        } catch (e: Throwable) {
            null
        }
    }

    // 直播：安卓摄像头无预览后台采集(CameraX)，节流后把 JPEG 帧回调给 Dart。
    private fun startCameraCapture(front: Boolean) {
        cameraExecutor?.shutdown()
        val executor = Executors.newSingleThreadExecutor()
        cameraExecutor = executor
        val providerFuture = ProcessCameraProvider.getInstance(this)
        providerFuture.addListener({
            try {
                val provider = providerFuture.get()
                cameraProvider = provider
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analysis.setAnalyzer(executor) { proxy -> onCameraFrame(proxy) }
                val selector = if (front) CameraSelector.DEFAULT_FRONT_CAMERA
                               else CameraSelector.DEFAULT_BACK_CAMERA
                provider.unbindAll()
                provider.bindToLifecycle(this as LifecycleOwner, selector, analysis)
            } catch (e: Exception) {
                runOnUiThread {
                    android.widget.Toast.makeText(this, "打开摄像头失败：${e.message}", android.widget.Toast.LENGTH_SHORT).show()
                }
            }
        }, androidx.core.content.ContextCompat.getMainExecutor(this))
    }

    private fun stopCameraCapture() {
        cameraProvider?.unbindAll()
        cameraProvider = null
        cameraExecutor?.shutdown()
        cameraExecutor = null
    }

    // 直播：安卓屏幕采集(MediaProjection)。系统投屏授权结果在 onActivityResult 里处理，
    // 真正的 MediaProjection/VirtualDisplay 生命周期交给 ScreenCaptureService(前台服务)。
    private fun startScreenCaptureService(resultCode: Int, data: Intent) {
        ScreenCaptureService.frameListener = { jpg ->
            runOnUiThread { screenrecChannel?.invokeMethod("frame", jpg) }
        }
        val intent = Intent(this, ScreenCaptureService::class.java).apply {
            putExtra(ScreenCaptureService.EXTRA_RESULT_CODE, resultCode)
            putExtra(ScreenCaptureService.EXTRA_DATA, data)
        }
        androidx.core.content.ContextCompat.startForegroundService(this, intent)
    }

    private fun stopScreenCapture() {
        ScreenCaptureService.frameListener = null
        stopService(Intent(this, ScreenCaptureService::class.java))
    }

    private fun onCameraFrame(imageProxy: ImageProxy) {
        try {
            val now = System.currentTimeMillis()
            // 节流：约每700ms发一帧，和桌面版cadence对齐，避免刷爆 /live-frame 和流量/电量。
            if (now - lastCameraFrameTs < 700) return
            lastCameraFrameTs = now
            val jpg = yuv420ToJpeg(imageProxy)
            if (jpg != null) {
                runOnUiThread { screenrecChannel?.invokeMethod("frame", jpg) }
            }
        } catch (_: Exception) {
        } finally {
            imageProxy.close()
        }
    }

    /**
     * ImageProxy(YUV_420_888) -> NV21(按 pixelStride 精确交错 U/V) -> JPEG。
     * CameraX 多数机型 U/V plane 的 pixelStride 是 2(半交错)，这里逐像素按 stride 取样
     * 交错成标准 NV21(V 在前 U 在后)，比"整buffer顺序拷贝"的近似写法更严谨。
     */
    private fun yuv420ToJpeg(image: ImageProxy): ByteArray? {
        return try {
            val width = image.width
            val height = image.height
            val yPlane = image.planes[0]
            val uPlane = image.planes[1]
            val vPlane = image.planes[2]
            val yBuffer = yPlane.buffer
            val uBuffer = uPlane.buffer
            val vBuffer = vPlane.buffer
            val nv21 = ByteArray(width * height + 2 * (width / 2) * (height / 2))

            // Y 平面：按 rowStride 逐行拷贝，去掉行尾 padding。
            var pos = 0
            val yRowStride = yPlane.rowStride
            val yPixelStride = yPlane.pixelStride
            if (yPixelStride == 1 && yRowStride == width) {
                yBuffer.get(nv21, 0, width * height)
                pos = width * height
            } else {
                val row = ByteArray(yRowStride)
                for (r in 0 until height) {
                    val avail = yBuffer.remaining().coerceAtMost(yRowStride)
                    yBuffer.get(row, 0, avail)
                    for (c in 0 until width) {
                        nv21[pos++] = row[c * yPixelStride]
                    }
                }
            }

            // UV 平面：NV21 要求 VU 交错，按各自 rowStride/pixelStride 精确取样。
            val uvRowStride = uPlane.rowStride
            val uPixelStride = uPlane.pixelStride
            val vRowStride = vPlane.rowStride
            val vPixelStride = vPlane.pixelStride
            val chromaW = width / 2
            val chromaH = height / 2
            val uRow = ByteArray(uvRowStride)
            val vRow = ByteArray(vRowStride)
            for (r in 0 until chromaH) {
                val uAvail = uBuffer.remaining().coerceAtMost(uvRowStride)
                uBuffer.get(uRow, 0, uAvail)
                val vAvail = vBuffer.remaining().coerceAtMost(vRowStride)
                vBuffer.get(vRow, 0, vAvail)
                for (c in 0 until chromaW) {
                    nv21[pos++] = vRow[c * vPixelStride]
                    nv21[pos++] = uRow[c * uPixelStride]
                }
            }

            val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
            val out = ByteArrayOutputStream()
            yuvImage.compressToJpeg(Rect(0, 0, width, height), 70, out)
            out.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShareIntent(intent)
        // 启动即「打开方式」：先缓存，Dart 起来后 getPending 拉取播放。
        pendingOpenPath = viewIntentPath(intent)
        // Android 13+ 需运行时申请通知权限，否则消息通知静默不显示。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                != android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(
                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
            }
        }
    }

    private val notifChannelId = "xiaoli_msgs"

    // 收到新消息弹安卓通知栏。点通知回到 app。
    private fun showNotification(title: String, body: String) {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            mgr.getNotificationChannel(notifChannelId) == null
        ) {
            val ch = NotificationChannel(
                notifChannelId, "聊天消息", NotificationManager.IMPORTANCE_HIGH)
            ch.description = "新私信 / 群消息提醒"
            mgr.createNotificationChannel(ch)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this, 0, launch ?: Intent(),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(this, notifChannelId)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        mgr.notify(notifId++, n)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
        // app 已在运行时「打开方式」：直接推给 Dart 播放。
        viewIntentPath(intent)?.let { openChannel?.invokeMethod("open", it) }
    }

    // 从 ACTION_VIEW intent 取出音视频文件地址（content:// 或 file:// 由 media_kit 直接播）。
    private fun viewIntentPath(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        return uri.toString()
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // requestCode 1001 = POST_NOTIFICATIONS(见 onCreate)，无需额外处理，这里只新增
        // 1002 = CAMERA(直播用)分支，不动 1001 原有行为。
        if (requestCode == 1002) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (granted) {
                screenrecChannel?.invokeMethod("cameraPermissionGranted", null)
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == QR_SCAN_REQUEST_CODE) {
            val text = if (resultCode == RESULT_OK) data?.getStringExtra("data") else null
            pendingQrScanResult?.success(text)
            pendingQrScanResult = null
        }
        if (requestCode == SCREEN_CAPTURE_REQUEST_CODE) {
            if (resultCode == RESULT_OK && data != null) {
                startScreenCaptureService(resultCode, data)
                pendingScreenStartResult?.success(true)
            } else {
                pendingScreenStartResult?.success(false)
            }
            pendingScreenStartResult = null
        }
    }

    companion object {
        private const val QR_SCAN_REQUEST_CODE = 4201
        private const val SCREEN_CAPTURE_REQUEST_CODE = 1003
    }
}
