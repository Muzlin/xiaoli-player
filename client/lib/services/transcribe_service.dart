import 'dart:io';

/// 本地 AI 语音转字幕：ffmpeg 抽音频 → whisper-cli 转写 → SRT。
/// 需 macOS 已装 whisper-cpp(brew) + ffmpeg，并下好模型。仅非沙箱构建可用。
class TranscribeService {
  static String? _find(List<String> candidates) {
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  static final String? whisper =
      _find(['/opt/homebrew/bin/whisper-cli', '/usr/local/bin/whisper-cli']);
  static final String? ffmpeg =
      _find(['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg']);
  static final String model =
      '${Platform.environment['HOME'] ?? ''}/小李播放器/whisper/ggml-small.bin';

  /// 工具链是否齐备（按钮据此显示）。
  static bool get available =>
      whisper != null && ffmpeg != null && File(model).existsSync();

  /// 从音频源生成中文 SRT；失败/无语音返回 null。
  /// [source] 流地址或本地路径；[headers] B站防盗链头(Referer/UA)。
  static Future<String?> transcribe(
    String source, {
    Map<String, String>? headers,
  }) async {
    if (!available) return null;
    final tmp = Directory.systemTemp.createTempSync('xl_asr_');
    final wav = '${tmp.path}/audio.wav';
    final outPrefix = '${tmp.path}/out';
    try {
      // 1) ffmpeg 抽音频 → 16kHz 单声道 wav（whisper 要求）。B站需带 Referer。
      final ffArgs = <String>[];
      if (headers != null && headers.isNotEmpty) {
        final hs =
            headers.entries.map((e) => '${e.key}: ${e.value}').join('\r\n');
        ffArgs.addAll(['-headers', '$hs\r\n']);
      }
      ffArgs.addAll(
          ['-i', source, '-vn', '-ar', '16000', '-ac', '1', '-y', wav]);
      final ff = await Process.run(ffmpeg!, ffArgs);
      if (ff.exitCode != 0 || !File(wav).existsSync()) return null;
      // 2) whisper-cli 转写为 SRT（中文）。
      final wr = await Process.run(whisper!, [
        '-m', model,
        '-l', 'zh',
        '-f', wav,
        '-osrt',
        '-of', outPrefix,
        '-np',
      ]);
      final srtFile = File('$outPrefix.srt');
      if (wr.exitCode != 0 || !srtFile.existsSync()) return null;
      final srt = srtFile.readAsStringSync();
      return srt.trim().isEmpty ? null : srt;
    } catch (_) {
      return null;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
