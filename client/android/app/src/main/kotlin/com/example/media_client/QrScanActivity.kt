package com.example.media_client

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.Toast
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.activity.ComponentActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 收付款「扫一扫」：全屏摄像头取景 + 实时识别二维码。
 * 识别到就把文本通过 RESULT_OK 带回去；用户取消/无权限就 RESULT_CANCELED。
 */
class QrScanActivity : ComponentActivity() {
    private lateinit var previewView: PreviewView
    private var cameraExecutor: ExecutorService? = null
    private val reader = MultiFormatReader().apply {
        setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE)))
    }
    @Volatile private var found = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        previewView = PreviewView(this)
        root.addView(previewView, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        val hint = TextView(this).apply {
            text = "将二维码对准框内"
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#66000000"))
            setPadding(24, 12, 24, 12)
            textSize = 14f
        }
        root.addView(hint, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL; topMargin = 96 })

        val cancelBtn = Button(this).apply {
            text = "取消"
            setOnClickListener { finishCanceled() }
        }
        root.addView(cancelBtn, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL; bottomMargin = 64 })

        setContentView(root)

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), 1)
        } else {
            startCamera()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            Toast.makeText(this, "需要相机权限才能扫码", Toast.LENGTH_SHORT).show()
            finishCanceled()
        }
    }

    private fun startCamera() {
        val executor = Executors.newSingleThreadExecutor()
        cameraExecutor = executor
        val providerFuture = ProcessCameraProvider.getInstance(this)
        providerFuture.addListener({
            val provider = providerFuture.get()
            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { it.setAnalyzer(executor) { proxy -> analyzeFrame(proxy) } }
            try {
                provider.unbindAll()
                provider.bindToLifecycle(
                    this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (e: Exception) {
                Toast.makeText(this, "打开摄像头失败：${e.message}", Toast.LENGTH_SHORT).show()
                finishCanceled()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun analyzeFrame(imageProxy: ImageProxy) {
        if (found) {
            imageProxy.close()
            return
        }
        try {
            val plane = imageProxy.planes[0]
            val buffer = plane.buffer
            buffer.rewind()
            val raw = ByteArray(buffer.remaining())
            buffer.get(raw)
            val rowStride = plane.rowStride
            val width = imageProxy.width
            val height = imageProxy.height
            val yData = if (rowStride == width) {
                raw
            } else {
                val packed = ByteArray(width * height)
                for (row in 0 until height) {
                    val srcPos = row * rowStride
                    if (srcPos + width > raw.size) break
                    System.arraycopy(raw, srcPos, packed, row * width, width)
                }
                packed
            }
            val source: LuminanceSource = YPlaneLuminanceSource(yData, width, height)
            val bitmap = BinaryBitmap(HybridBinarizer(source))
            val result = reader.decodeWithState(bitmap)
            found = true
            finishWithResult(result.text)
        } catch (_: NotFoundException) {
            // 这一帧没识别到二维码，继续扫下一帧。
        } catch (_: Exception) {
            // 偶发解码异常，忽略继续。
        } finally {
            reader.reset()
            imageProxy.close()
        }
    }

    private fun finishWithResult(text: String) {
        runOnUiThread {
            setResult(RESULT_OK, Intent().putExtra("data", text))
            finish()
        }
    }

    private fun finishCanceled() {
        setResult(RESULT_CANCELED)
        finish()
    }

    override fun onDestroy() {
        cameraExecutor?.shutdown()
        super.onDestroy()
    }

    /** 摄像头 YUV_420_888 的 Y 平面本身就是灰度图，直接当亮度源给 ZXing 用。 */
    private class YPlaneLuminanceSource(
        private val yData: ByteArray, width: Int, height: Int
    ) : LuminanceSource(width, height) {
        override fun getRow(y: Int, row: ByteArray?): ByteArray {
            val r = if (row != null && row.size >= width) row else ByteArray(width)
            System.arraycopy(yData, y * width, r, 0, width)
            return r
        }

        override fun getMatrix(): ByteArray = yData
    }
}
