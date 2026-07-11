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

  // Windows 常见安装位置 + PATH 内的 ffmpeg（Process.run 会按 PATH 查找裸命令）。
  static String? _findWin(String exe, List<String> dirs) {
    for (final d in dirs) {
      final p = '$d\\$exe.exe';
      if (File(p).existsSync()) return p;
    }
    // 回退：交给 PATH 解析（用户把 ffmpeg 加进环境变量即可）。
    try {
      final r = Process.runSync('where', [exe]);
      if (r.exitCode == 0) {
        final line = (r.stdout as String).trim().split('\n').first.trim();
        if (line.isNotEmpty && File(line).existsSync()) return line;
      }
    } catch (_) {}
    return null;
  }

  static final String? whisper = Platform.isWindows
      ? _findWin('whisper-cli', [
          r'C:\Program Files\whisper',
          r'C:\whisper',
        ])
      : _find(['/opt/homebrew/bin/whisper-cli', '/usr/local/bin/whisper-cli']);
  static final String? ffmpeg = Platform.isWindows
      ? _findWin('ffmpeg', [
          r'C:\ffmpeg\bin',
          r'C:\Program Files\ffmpeg\bin',
        ])
      : _find(['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg']);
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

  /// 直播字幕：把一小段 WAV 转成纯文本(无时间戳)。失败/无语音返回 null。
  static Future<String?> transcribeChunkToText(String wavIn) async {
    if (!available) return null;
    final tmp = Directory.systemTemp.createTempSync('xl_cap_');
    final wav = '${tmp.path}/a.wav';
    final outPrefix = '${tmp.path}/out';
    try {
      final ff = await Process.run(
          ffmpeg!, ['-i', wavIn, '-vn', '-ar', '16000', '-ac', '1', '-y', wav]);
      if (ff.exitCode != 0 || !File(wav).existsSync()) return null;
      final wr = await Process.run(whisper!, [
        '-m', model,
        '-l', 'zh',
        '-f', wav,
        '-otxt',
        '-nt', // 不要时间戳
        '-of', outPrefix,
        '-np',
      ]);
      final txtFile = File('$outPrefix.txt');
      if (wr.exitCode != 0 || !txtFile.existsSync()) return null;
      final txt =
          txtFile.readAsStringSync().replaceAll('\n', ' ').replaceAll('  ', ' ').trim();
      // whisper 对静音/噪声常吐 "(音乐)"「谢谢观看」等占位，过滤掉最常见的。
      if (txt.isEmpty || txt == '谢谢大家' || txt.startsWith('(') || txt.startsWith('[')) {
        return null;
      }
      return txt;
    } catch (_) {
      return null;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 直播双语字幕：一段 WAV → 中文 + 英文(whisper --translate 转英)。返回"中文\nEnglish"。
  static Future<String?> transcribeChunkBilingual(String wavIn) async {
    if (!available) return null;
    final tmp = Directory.systemTemp.createTempSync('xl_bi_');
    final wav = '${tmp.path}/a.wav';
    try {
      final ff = await Process.run(
          ffmpeg!, ['-i', wavIn, '-vn', '-ar', '16000', '-ac', '1', '-y', wav]);
      if (ff.exitCode != 0 || !File(wav).existsSync()) return null;
      Future<String?> run(List<String> extra, String suffix) async {
        final of = '${tmp.path}/o_$suffix';
        final r = await Process.run(whisper!,
            ['-m', model, '-f', wav, '-otxt', '-nt', '-of', of, '-np', ...extra]);
        final f = File('$of.txt');
        if (r.exitCode != 0 || !f.existsSync()) return null;
        final t = f.readAsStringSync().replaceAll('\n', ' ').trim();
        if (t.isEmpty || t.startsWith('(') || t.startsWith('[')) return null;
        return t;
      }

      final zh = await run(['-l', 'zh'], 'zh');
      if (zh == null) return null; // 无语音就别出英文占位
      final en = await run(['-l', 'zh', '-tr'], 'en'); // -tr=翻译成英文
      return en != null ? '$zh\n$en' : zh;
    } catch (_) {
      return null;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
