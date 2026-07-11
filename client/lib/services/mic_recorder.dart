import 'dart:io';
import 'package:flutter/services.dart';

/// 麦克风分段录音（仅 macOS 原生 `xiaoli/mic`）：录固定秒数 WAV 供 whisper 转字幕。
class MicRecorder {
  static const _ch = MethodChannel('xiaoli/mic');
  static bool get supported => Platform.isMacOS;

  /// 录 [seconds] 秒麦克风，返回 WAV 文件路径；失败/无权限返回 null。
  static Future<String?> recordChunk({double seconds = 5.0}) async {
    if (!supported) return null;
    try {
      final p = await _ch
          .invokeMethod<String>('recordChunk', {'seconds': seconds});
      return p;
    } catch (_) {
      return null;
    }
  }

  static Future<void> stop() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }
}
