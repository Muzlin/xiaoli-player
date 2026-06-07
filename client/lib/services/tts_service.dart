import 'dart:io';

/// 系统 TTS 配音：调用 macOS `say` 朗读文本（中文音色）。仅非沙箱构建可用。
class TtsService {
  static String? _voice;
  static bool _resolved = false;
  static Process? _proc;

  /// 找一个中文音色名（首个 zh_CN），结果缓存。
  static Future<String?> _zhVoice() async {
    if (_resolved) return _voice;
    _resolved = true;
    try {
      final r = await Process.run('/usr/bin/say', ['-v', '?']);
      for (final l in (r.stdout as String).split('\n')) {
        if (l.contains('zh_CN')) {
          _voice = l.split(RegExp(r'\s{2,}')).first.trim();
          break;
        }
      }
    } catch (_) {}
    return _voice;
  }

  /// 朗读一句（会先停掉上一句，避免重叠）。
  static Future<void> speak(String text) async {
    await stop();
    final t = text.trim();
    if (t.isEmpty) return;
    final v = await _zhVoice();
    final args = <String>[if (v != null) ...['-v', v], '-r', '190', t];
    try {
      _proc = await Process.start('/usr/bin/say', args);
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      _proc?.kill();
    } catch (_) {}
    _proc = null;
  }
}
