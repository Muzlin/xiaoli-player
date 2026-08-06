import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

/// 常见标准开源许可证类型，用于给「查看许可」页面里没有网络/在线翻译受限时
/// 提供内置的中文兜底翻译。
enum LicenseTemplate { mit, bsd2, bsd3, apache2, mpl2, isc, zlib }

const Map<LicenseTemplate, String> _assetPath = {
  LicenseTemplate.mit: 'assets/licenses_zh/mit.txt',
  LicenseTemplate.bsd2: 'assets/licenses_zh/bsd2.txt',
  LicenseTemplate.bsd3: 'assets/licenses_zh/bsd3.txt',
  LicenseTemplate.apache2: 'assets/licenses_zh/apache2.txt',
  LicenseTemplate.mpl2: 'assets/licenses_zh/mpl2.txt',
  LicenseTemplate.isc: 'assets/licenses_zh/isc.txt',
  LicenseTemplate.zlib: 'assets/licenses_zh/zlib.txt',
};

class LicenseTranslateResult {
  final String text;
  final bool fromBundled;
  final String? note; // 走内置兜底时给用户的提示文案
  LicenseTranslateResult(this.text, {this.fromBundled = false, this.note});
}

/// 许可证正文翻译成中文：优先走在线翻译（免 key 的 Google 接口），
/// 在线翻译失败/受限时，如果这份许可证是常见标准模板（MIT/BSD/Apache 等），
/// 退回内置的中文翻译；不是标准模板就报错，不瞎编内容。
class LicenseTranslateService {
  // 复用同一个 http.Client（连接复用），和这个项目里其它 service 的写法一致。
  static final http.Client _client = http.Client();
  static final Map<LicenseTemplate, String> _bundledCache = {};

  /// 识别是不是常见的标准许可证模板，用来做内置兜底翻译的匹配。
  /// 判断依据是各类许可证正文里几乎不变的措辞，不依赖版权年份/持有人这些会变的部分。
  static LicenseTemplate? identify(String text) {
    final t = text;
    final hasBsdBody =
        t.contains('Redistribution and use in source and binary forms');
    if (t.contains('Permission is hereby granted, free of charge') &&
        t.contains('THE SOFTWARE IS PROVIDED')) {
      return LicenseTemplate.mit;
    }
    if (t.contains('Apache License') && t.contains('Version 2.0')) {
      return LicenseTemplate.apache2;
    }
    // 必须同时匹配版本号，否则 MPL 1.1（条款和 2.0 不一样）会被误认成 MPL 2.0。
    if (t.contains('Mozilla Public License') && t.contains('Version 2.0')) {
      return LicenseTemplate.mpl2;
    }
    if (hasBsdBody && t.contains('Neither the name of')) {
      return LicenseTemplate.bsd3;
    }
    if (hasBsdBody) {
      return LicenseTemplate.bsd2;
    }
    if (t.contains(
        'Permission to use, copy, modify, and/or distribute this software')) {
      return LicenseTemplate.isc;
    }
    final low = t.toLowerCase();
    if (low.contains("this software is provided 'as-is'") ||
        low.contains('this software is provided "as-is"')) {
      return LicenseTemplate.zlib;
    }
    return null;
  }

  static Future<String> _bundled(LicenseTemplate tpl) async {
    final cached = _bundledCache[tpl];
    if (cached != null) return cached;
    final s = await rootBundle.loadString(_assetPath[tpl]!);
    _bundledCache[tpl] = s;
    return s;
  }

  /// 翻译一个包的许可证正文。[entryTexts] 是这个包绑定的每条 LicenseEntry 各自的
  /// 正文（一个包可能同时有 LICENSE、NOTICE 等多条，各自内容可能不是同一份许可证）。
  /// 在线翻译按合并后的整段一次性走；在线翻译失败时的内置兜底则逐条识别模板再
  /// 分别取内置译文拼接——只要有一条认不出模板，就整体放弃兜底并报错，不展示
  /// "看起来完整、实际漏了某条许可证内容"的翻译。
  static Future<LicenseTranslateResult> translate(
      List<String> entryTexts) async {
    final nonEmpty = entryTexts.where((t) => t.trim().isNotEmpty).toList();
    if (nonEmpty.isEmpty) {
      throw Exception('translate: nothing to translate');
    }
    final original = nonEmpty.join('\n\n');
    try {
      final zh = await _translateOnline(original);
      return LicenseTranslateResult(zh);
    } catch (_) {
      final templates = nonEmpty.map(identify).toList();
      if (templates.every((t) => t != null)) {
        final parts =
            await Future.wait(templates.map((t) => _bundled(t!)));
        return LicenseTranslateResult(
          parts.join('\n\n'),
          fromBundled: true,
          note: '在线翻译暂时受限，已为你显示内置翻译（仅供参考）',
        );
      }
      rethrow;
    }
  }

  /// 免 key 的 Google 非官方翻译接口。文本按段落切成小块分别请求再拼接（块之间
  /// 保留空行，避免段落被粘连），任意一块失败就整体判定在线翻译失败，交给上层
  /// 走兜底。故意顺序请求而不是并发：这是个无 key 的免费接口，并发多个请求更容易
  /// 触发限流，反而更容易需要走兜底。
  static Future<String> _translateOnline(String text) async {
    final chunks = _splitForTranslate(text);
    final pieces = <String>[];
    for (final chunk in chunks) {
      pieces.add(await _translateChunk(chunk));
    }
    final result = pieces.join('\n\n').trim();
    if (result.isEmpty) throw Exception('translate: empty result');
    return result;
  }

  static Future<String> _translateChunk(String chunk) async {
    if (chunk.trim().isEmpty) return chunk;
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': 'en',
      'tl': 'zh-CN',
      'dt': 't',
      'q': chunk,
    });
    final r = await _client.get(uri).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) {
      throw Exception('translate http ${r.statusCode}');
    }
    final data = jsonDecode(utf8.decode(r.bodyBytes));
    final sentences = data is List && data.isNotEmpty ? data[0] : null;
    if (sentences is! List) throw Exception('translate: bad response');
    final piece = StringBuffer();
    for (final s in sentences) {
      if (s is List && s.isNotEmpty && s[0] is String) piece.write(s[0]);
    }
    final result = piece.toString();
    // 接口偶尔会对某一块返回空的句子数组（不是报错，是"翻译了个寂寞"）：
    // 原文这块不是空的，译文却是空的，直接当失败处理，不要悄悄丢内容。
    if (result.trim().isEmpty) {
      throw Exception('translate: empty chunk result');
    }
    return result;
  }

  /// 按空行分段，再把段落攒到安全长度（~1500 字符）一批，尽量不切断句子；
  /// 单个段落本身超过安全长度（没有空行可切）时，硬切成若干块，避免单次请求
  /// 过长。
  static List<String> _splitForTranslate(String text) {
    const maxLen = 1500;
    final paragraphs = text.split('\n\n');
    final chunks = <String>[];
    var cur = StringBuffer();
    void flush() {
      if (cur.isNotEmpty) {
        chunks.add(cur.toString());
        cur = StringBuffer();
      }
    }

    for (var p in paragraphs) {
      while (p.length > maxLen) {
        flush();
        chunks.add(p.substring(0, maxLen));
        p = p.substring(maxLen);
      }
      if (cur.length + p.length + 2 > maxLen && cur.isNotEmpty) {
        flush();
      }
      if (cur.isNotEmpty) cur.write('\n\n');
      cur.write(p);
    }
    flush();
    return chunks.isEmpty ? [text] : chunks;
  }
}
