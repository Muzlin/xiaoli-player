import 'dart:io';
import 'package:flutter/services.dart';

/// 系统通知（macOS 通知中心 / Android 通知栏）。原生实现见
/// macos/Runner/MainFlutterWindow.swift 与 android .../MainActivity.kt 的 `xiaoli/notify`。
class NativeNotify {
  static const _ch = MethodChannel('xiaoli/notify');
  static bool get _supported => Platform.isMacOS || Platform.isAndroid;

  /// 启动时申请一次通知权限（macOS 弹授权框；Android 13+ 在原生 onCreate 申请）。
  static Future<void> requestAuth() async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod('requestAuth');
    } catch (_) {}
  }

  /// 弹一条系统通知。
  static Future<void> show(String title, String body) async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod('show', {'title': title, 'body': body});
    } catch (_) {}
  }
}
