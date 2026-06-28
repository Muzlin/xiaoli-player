import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// 收付款二维码：macOS 原生生成(CoreImage)与扫一扫(AVFoundation)。
/// 安卓暂不支持(相机库需 pub.dev，被墙)——回退到 收款ID/链接 + 选联系人转账。
class NativeQr {
  static const _ch = MethodChannel('xiaoli/qr');
  static bool get supported => Platform.isMacOS;

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

  /// 弹相机窗扫码，返回识别到的字符串(取消/失败返回 null)。
  static Future<String?> scan() async {
    if (!supported) return null;
    try {
      final r = await _ch.invokeMethod('scan');
      return (r is String && r.isNotEmpty) ? r : null;
    } catch (_) {
      return null;
    }
  }
}
