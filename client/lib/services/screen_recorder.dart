import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'platform_service.dart';

/// 系统级录屏(macOS 原生)：原生录短 H.264 片段→回调路径→上传服务器→管理台当视频播。
/// 仅 macOS；首次需用户在「系统设置>屏幕录制」授权(系统强制=知情同意)。
class ScreenRecorder {
  static const _ch = MethodChannel('xiaoli/screenrec');
  static bool _on = false;
  static bool get supported => Platform.isMacOS;
  static bool get running => _on;
  static void Function(Uint8List)? _onFrame;

  /// 桌面取帧(整个桌面，macOS 13+)：原生回调 JPEG 帧。
  static Future<bool> startDesktopFrames(void Function(Uint8List) onFrame) async {
    if (!supported) return false;
    _onFrame = onFrame;
    _ch.setMethodCallHandler(_onCall);
    try {
      return await _ch.invokeMethod<bool>('startDesktop') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopDesktopFrames() async {
    _onFrame = null;
    try {
      await _ch.invokeMethod('stopDesktop');
    } catch (_) {}
  }

  static Future<bool> start() async {
    if (!supported || _on) return _on;
    _ch.setMethodCallHandler(_onCall);
    try {
      final ok = await _ch.invokeMethod<bool>('start') ?? false;
      _on = ok;
      return ok;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stop() async {
    if (!supported) return;
    _on = false;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  static Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'frame') {
      final b = call.arguments;
      if (b is Uint8List) _onFrame?.call(b);
      return null;
    }
    if (call.method == 'clip' && _on) {
      final path = call.arguments as String?;
      if (path != null) await _uploadClip(path);
    }
  }

  static Future<void> _uploadClip(String path) async {
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final bytes = await f.readAsBytes();
      try {
        await f.delete();
      } catch (_) {}
      if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) return; // 防爆
      await PlatformService.uploadScreenrecClip(bytes);
    } catch (_) {}
  }
}
