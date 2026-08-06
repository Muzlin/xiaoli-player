import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// 收付款二维码：
/// - macOS：原生生成(CoreImage)与扫一扫(AVFoundation)，选图由原生 NSOpenPanel 完成。
/// - Android：原生生成/识别用 ZXing（纯 Java、发布在 Maven Central，不依赖 Google Play
///   Services，不用踩 pub.dev 相机插件的坑）；选图在 Dart 侧用 file_picker 选，
///   把字节丢给原生解码；摄像头扫码是原生 CameraX 全屏取景页。
class NativeQr {
  static const _ch = MethodChannel('xiaoli/qr');
  static bool get supported => Platform.isMacOS || Platform.isAndroid;

  /// 生成二维码 PNG 字节(失败返回 null)。
  static Future<Uint8List?> generate(String data) async {
    if (!supported) return null;
    try {
      final r = await _ch.invokeMethod('generate', {'data': data});
      if (r is Uint8List) return r;
      if (r is List<int>) return Uint8List.fromList(r);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 弹相机窗扫码，返回识别到的字符串(取消/失败返回 null)。带超时兜底：极端情况下
  /// (比如系统在扫码页开着时把 MainActivity 回收重建)原生那边可能永远等不到结果，
  /// 不加超时这里就会一直卡着转圈。
  static Future<String?> scan() async {
    if (!supported) return null;
    try {
      final r = await _ch
          .invokeMethod('scan')
          .timeout(const Duration(minutes: 3), onTimeout: () => null);
      return (r is String && r.isNotEmpty) ? r : null;
    } catch (_) {
      return null;
    }
  }

  /// 从图片识别二维码：无需相机，最稳定。macOS 由原生弹窗自己选图；
  /// Android 在 Dart 侧用 file_picker 选图，把字节交给原生解码。
  static Future<String?> scanImage() async {
    if (!supported) return null;
    try {
      if (Platform.isAndroid) {
        final r = await FilePicker.platform.pickFiles(type: FileType.image);
        final bytes = r?.files.single.bytes;
        final path = r?.files.single.path;
        final data = bytes ?? (path != null ? await File(path).readAsBytes() : null);
        if (data == null) return null;
        final res = await _ch.invokeMethod('scanImage', {'bytes': data});
        return (res is String && res.isNotEmpty) ? res : null;
      }
      final r = await _ch.invokeMethod('scanImage');
      return (r is String && r.isNotEmpty) ? r : null;
    } catch (_) {
      return null;
    }
  }

  /// 选一组图片(PPT幻灯片)，返回文件路径。目前只有 macOS 原生端实现了这个方法，
  /// 别用通用的 [supported](已含 Android)判断，否则 Android 上会一直静默返回空列表。
  static Future<List<String>> pickImages() async {
    if (!Platform.isMacOS) return [];
    try {
      final r = await _ch.invokeMethod('pickImages');
      if (r is List) return r.whereType<String>().toList();
    } catch (_) {}
    return [];
  }
}
