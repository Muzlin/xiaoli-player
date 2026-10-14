import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:file_picker/file_picker.dart';
import '../services/account_service.dart';

/// 创作 AI 助手：调用服务端 AI 接口(默认本机 Ollama)，按账号计费 token，
/// 每日额度(默认 1 万)用完即不可用，次日 0 点重置。
/// 界面风格仿「腾讯元宝」：浅色、圆润气泡、底部胶囊输入条、欢迎页建议卡片。
class AiPage extends StatefulWidget {
  const AiPage({super.key, this.onAction});
  /// AI 返回的操作指令，交由宿主(App)执行：play/search/open/pause/next/prev。
  final void Function(String action, Map<String, dynamic> params)? onAction;
  @override
  State<AiPage> createState() => _AiPageState();
}

// 元宝风格配色
const _brand1 = Color(0xFF2B7BFF);
const _brand2 = Color(0xFF00C2C7);

class _AiPageState extends State<AiPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, String>> _msgs = []; // {role, content}
  bool _busy = false;
  bool _atBottom = true;
  bool _uploading = false;
  String? _attachName;
  String? _attachText;
  final FlutterTts _tts = FlutterTts();
  String _notice = '';
  List _tpls = [];
  List _faq = [];
  int _used = 0, _limit = 10000;
  bool _enabled = true;
  String? _err;

  static const _suggestions = <List<String>>[
    ['🎬', '起 5 个吸引人的视频标题'],
    ['📝', '写一段 60 秒口播脚本'],
    ['🔥', '这条视频怎么上热门？'],
    ['🖼️', '帮我写个封面文案'],
  ];

  // ===== 跟随系统/应用深浅色 =====
  bool get _dark => Theme.of(context).brightness == Brightness.dark;
  Color get _cBg => _dark ? const Color(0xFF14141A) : const Color(0xFFF7F8FC);
  Color get _cCard => _dark ? const Color(0xFF1E1E26) : Colors.white;
  Color get _cBorder =>
      _dark ? const Color(0xFF333A45) : const Color(0xFFEDEFF5);
  Color get _cText =>
      _dark ? const Color(0xFFE8EAF0) : const Color(0xFF1A1F2B);
  Color get _cIcon =>
      _dark ? const Color(0xFFB8C0CC) : const Color(0xFF4A5568);
  Color get _cSub =>
      _dark ? const Color(0xFF9AA3B2) : const Color(0xFF8A93A6);
  Color get _cHint =>
      _dark ? const Color(0xFF7A8494) : const Color(0xFFA6AEBD);
  Color get _cUserBubble =>
      _dark ? const Color(0xFF2B3F63) : const Color(0xFFDDE9FF);
  Color get _cUserText =>
      _dark ? const Color(0xFFE8EAF0) : const Color(0xFF17233D);
  Color get _cInputBg =>
      _dark ? const Color(0xFF26262E) : const Color(0xFFF2F3F7);
  Color get _cDisable =>
      _dark ? const Color(0xFF3A3A44) : const Color(0xFFDCE0E8);

  @override
  void initState() {
    super.initState();
    _loadUsage();
    _loadMeta();
    _tts.setLanguage('zh-CN');
    _tts.setSpeechRate(0.5);
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atEnd =
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 48;
      if (atEnd != _atBottom && mounted) setState(() => _atBottom = atEnd);
    });
  }

  Future<void> _loadMeta() async {
    final d = await AccountService.aiMeta();
    if (!mounted || d['ok'] != true) return;
    setState(() {
      _notice = '${d['notice'] ?? ''}';
      _tpls = (d['templates'] as List?) ?? [];
      _faq = (d['faq'] as List?) ?? [];
    });
  }

  void _speak(String t) async {
    try {
      await _tts.stop();
      await _tts.speak(t);
    } catch (_) {}
  }

  void _copy(String t) {
    Clipboard.setData(ClipboardData(text: t));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制')));
  }

  void _vote(String v, String t) {
    AccountService.aiFeedback(v, t);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(v == 'up' ? '感谢反馈 👍' : '已记录，我们会改进')));
  }

  Future<void> _runActions(Map<String, dynamic> d) async {
    final acts = d['actions'];
    if (acts is! List) return;
    for (final a in acts) {
      if (a is! Map || a['action'] == null) continue;
      final action = '${a['action']}';
      final params = (a['params'] is Map)
          ? Map<String, dynamic>.from(a['params'] as Map)
          : <String, dynamic>{};
      // 电脑终端类操作：把输出直接显示在对话里
      if (action == 'pc_shell' ||
          action == 'pc_apps' ||
          action == 'pc_screenshot') {
        final cmd = action == 'pc_shell'
            ? 'shell'
            : (action == 'pc_apps' ? 'apps' : 'screenshot');
        final r = await AccountService.pcCmd(cmd, '${params['cmd'] ?? ''}');
        if (!mounted) return;
        String out;
        if (r['out'] != null || r['err'] != null) {
          out = '${r['out'] ?? ''}' +
              ((r['err'] ?? '').toString().trim().isEmpty
                  ? ''
                  : '\n[err] ${r['err']}');
        } else if (r['apps'] is List) {
          out = (r['apps'] as List).join('、');
        } else if (r['ok'] == true) {
          out = '已执行';
        } else {
          out = '失败：${r['error'] ?? '未知'}';
        }
        if (out.trim().isEmpty) out = '(无输出)';
        setState(() => _msgs.add({'role': 'assistant', 'content': '🖥️ $out'}));
        continue;
      }
      // 本地工具(不调模型，直接算)
      if (action == 'new_chat') {
        setState(() => _msgs.clear());
        continue;
      }
      if (action == 'copy_last' || action == 'speak_last') {
        final m = _msgs.lastWhere((x) => x['role'] == 'assistant',
            orElse: () => <String, String>{});
        final txt = m['content'] ?? '';
        if (txt.isNotEmpty) {
          if (action == 'copy_last') {
            _copy(txt);
          } else {
            _speak(txt);
          }
        }
        continue;
      }
      final local = _localUtil(action, params);
      if (local != null) {
        setState(() => _msgs.add({'role': 'assistant', 'content': local}));
        continue;
      }
      widget.onAction?.call(action, params);
    }
    _jump();
  }

  double? _evalExpr(String e) {
    final tokens = <String>[];
    for (final m
        in RegExp(r'\d+\.?\d*|[+\-*/()]').allMatches(e.replaceAll(' ', ''))) {
      tokens.add(m.group(0)!);
    }
    if (tokens.isEmpty) return null;
    var i = 0;
    late double Function() expr;
    double factor() {
      if (i >= tokens.length) return 0;
      final t = tokens[i];
      if (t == '(') {
        i++;
        final v = expr();
        if (i < tokens.length && tokens[i] == ')') i++;
        return v;
      }
      if (t == '-') {
        i++;
        return -factor();
      }
      i++;
      return double.tryParse(t) ?? 0;
    }

    double term() {
      var v = factor();
      while (i < tokens.length && (tokens[i] == '*' || tokens[i] == '/')) {
        final op = tokens[i++];
        final r = factor();
        v = op == '*' ? v * r : v / r;
      }
      return v;
    }

    double exprFn() {
      var v = term();
      while (i < tokens.length && (tokens[i] == '+' || tokens[i] == '-')) {
        final op = tokens[i++];
        final r = term();
        v = op == '+' ? v + r : v - r;
      }
      return v;
    }

    expr = exprFn;
    final v = exprFn();
    return v.isFinite ? v : null;
  }

  String? _localUtil(String action, Map<String, dynamic> p) {
    final t = '${p['text'] ?? p['value'] ?? ''}';
    switch (action) {
      case 'count_words':
        final chars = t.replaceAll(RegExp(r'\s'), '').length;
        final words = t.trim().isEmpty
            ? 0
            : t.trim().split(RegExp(r'\s+')).length;
        return '字符数(不含空格)：$chars　词数：$words　总长度：${t.length}';
      case 'line_count':
        return '行数：${t.isEmpty ? 0 : t.split('\n').length}';
      case 'upper_text':
        return t.toUpperCase();
      case 'lower_text':
        return t.toLowerCase();
      case 'reverse_text':
        return String.fromCharCodes(t.runes.toList().reversed);
      case 'remove_spaces':
        return t.replaceAll(RegExp(r'\s+'), '');
      case 'trim_text':
        return t.trim();
      case 'repeat_text':
        final n = (int.tryParse('${p['n'] ?? '2'}') ?? 2).clamp(1, 100);
        return List.filled(n, t).join('\n');
      case 'dedup_lines':
        final seen = <String>{};
        final out = <String>[];
        for (final l in t.split('\n')) {
          if (seen.add(l.trim())) out.add(l);
        }
        return out.join('\n');
      case 'sort_lines':
        final ls = t.split('\n')..sort();
        return ls.join('\n');
      case 'shuffle_text':
        final ls = t.split('')..shuffle();
        return ls.join();
      case 'base64_encode':
        return base64Encode(utf8.encode(t));
      case 'base64_decode':
        try {
          return utf8.decode(base64Decode(t.trim()));
        } catch (_) {
          return '解码失败(不是合法 Base64)';
        }
      case 'url_encode':
        return Uri.encodeComponent(t);
      case 'url_decode':
        try {
          return Uri.decodeComponent(t);
        } catch (_) {
          return '解码失败';
        }
      case 'calc':
        final v = _evalExpr('${p['expr'] ?? t}');
        return v == null ? '算不了(${p['expr'] ?? t})' : '= $v';
      case 'percent':
        final a = double.tryParse('${p['a'] ?? 0}') ?? 0;
        final b = double.tryParse('${p['b'] ?? 1}') ?? 1;
        return '$a / $b = ${(a / b * 100).toStringAsFixed(2)}%';
      case 'bmi':
        final h = (double.tryParse('${p['h'] ?? 0}') ?? 0) / 100;
        final w = double.tryParse('${p['w'] ?? 0}') ?? 0;
        if (h <= 0) return '请提供身高(cm)和体重(kg)';
        return 'BMI = ${(w / (h * h)).toStringAsFixed(1)}';
      case 'tip_calc':
        final a = double.tryParse('${p['amount'] ?? 0}') ?? 0;
        final pc = double.tryParse('${p['pct'] ?? 10}') ?? 10;
        return '金额 $a × $pc% = ${(a * pc / 100).toStringAsFixed(2)}';
      case 'random_number':
        final a = int.tryParse('${p['min'] ?? 1}') ?? 1;
        final b = int.tryParse('${p['max'] ?? 100}') ?? 100;
        final lo = a < b ? a : b;
        final hi = a < b ? b : a;
        return '随机数：${lo + Random().nextInt(hi - lo + 1)}';
      case 'timestamp':
        return '当前时间戳：${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
      case 'date_today':
        final d = DateTime.now();
        const wk = ['一', '二', '三', '四', '五', '六', '日'];
        return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} 星期${wk[d.weekday - 1]}';
      case 'gen_uuid':
        final r = Random.secure();
        final h = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
        return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
      case 'random_color':
        final r = Random();
        final c = '#${(r.nextInt(0xffffff)).toRadixString(16).padLeft(6, '0').toUpperCase()}';
        return '随机颜色：$c';
      case 'pick_emoji':
        const es = ['😀', '😂', '🥰', '😎', '🤔', '👍', '🎬', '🔥', '🎵', '🍜', '🌈', '⭐', '💡', '🚀', '🍺', '🐱'];
        return '随机表情：${es[Random().nextInt(es.length)]}';
      case 'snake_case':
        return t.replaceAllMapped(RegExp(r'[A-Z\s]+'), (m) => '_${m.group(0)!.toLowerCase().trim()}')
            .replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'^_|_$'), '');
      case 'camel_case':
        final parts = t.split(RegExp(r'[\s_\-]+')).where((s) => s.isNotEmpty).toList();
        if (parts.isEmpty) return '';
        return parts.first.toLowerCase() +
            parts.skip(1).map((s) => s[0].toUpperCase() + s.substring(1).toLowerCase()).join();
      case 'title_case':
        return t.replaceAllMapped(RegExp(r'\b\w'), (m) => m.group(0)!.toUpperCase());
      case 'strip_html':
        return t.replaceAll(RegExp(r'<[^>]*>'), '');
      case 'markdown_strip':
        return t.replaceAll(RegExp(r'[*_`#>\[\]()]'), '');
      case 'extract_urls':
        final ms = RegExp(r'https?://[^\s]+').allMatches(t).map((m) => m.group(0)).toList();
        return ms.isEmpty ? '没找到链接' : ms.join('\n');
      case 'extract_numbers':
        final ms = RegExp(r'-?\d+\.?\d*').allMatches(t).map((m) => m.group(0)).toList();
        return ms.isEmpty ? '没找到数字' : ms.join(' ');
      case 'extract_emails':
        final ms = RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+').allMatches(t).map((m) => m.group(0)).toList();
        return ms.isEmpty ? '没找到邮箱' : ms.join('\n');
      case 'count_occurrences':
        final w = '${p['word'] ?? ''}';
        if (w.isEmpty) return '请提供要统计的词';
        return '「$w」出现了 ${w.allMatches(t).length} 次';
      case 'char_freq':
        final m = <String, int>{};
        for (final ch in t.split('')) {
          if (ch.trim().isEmpty) continue;
          m[ch] = (m[ch] ?? 0) + 1;
        }
        final es = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        return es.take(20).map((e) => '${e.key} ${e.value}').join('　');
      case 'json_format':
        try {
          return const JsonEncoder.withIndent('  ').convert(jsonDecode(t));
        } catch (_) {
          return '不是合法 JSON';
        }
      case 'json_minify':
        try {
          return jsonEncode(jsonDecode(t));
        } catch (_) {
          return '不是合法 JSON';
        }
      case 'truncate':
        final n = (int.tryParse('${p['n'] ?? '20'}') ?? 20).clamp(1, 5000);
        return t.length <= n ? t : '${t.substring(0, n)}…';
      case 'pad_number':
        final n = int.tryParse('${p['n'] ?? '4'}') ?? 4;
        return t.padLeft(n, '0');
      case 'binary_convert':
        final v = int.tryParse(t.trim());
        return v == null ? '请输入整数' : '二进制：${v.toRadixString(2)}';
      case 'hex_convert':
        final v = int.tryParse(t.trim());
        return v == null ? '请输入整数' : '十六进制：0x${v.toRadixString(16).toUpperCase()}';
      case 'ascii_convert':
        return t.runes.map((c) => c <= 127 ? '$c' : '?').join(' ');
      case 'roman_number':
        final v = int.tryParse(t.trim());
        if (v == null || v <= 0 || v > 3999) return '请输入 1-3999 的整数';
        const map = [
          [1000, 'M'], [900, 'CM'], [500, 'D'], [400, 'CD'], [100, 'C'],
          [90, 'XC'], [50, 'L'], [40, 'XL'], [10, 'X'], [9, 'IX'],
          [5, 'V'], [4, 'IV'], [1, 'I']
        ];
        var x = v;
        final sb = StringBuffer();
        for (final e in map) {
          final n = e[0] as int;
          while (x >= n) {
            sb.write(e[1]);
            x -= n;
          }
        }
        return '罗马数字：$sb';
      case 'days_until':
        try {
          final d = DateTime.parse(t.trim());
          final diff = d.difference(DateTime.now()).inDays;
          return diff >= 0 ? '还有 $diff 天' : '已过 ${-diff} 天';
        } catch (_) {
          return '日期格式如 2026-12-31';
        }
      case 'week_number':
        final d = DateTime.now();
        final wk = ((d.difference(DateTime(d.year, 1, 1)).inDays) / 7).floor() + 1;
        return '今年第 $wk 周';
      case 'password_strength':
        var sc = 0;
        if (t.length >= 8) sc++;
        if (t.length >= 12) sc++;
        if (RegExp(r'[a-z]').hasMatch(t)) sc++;
        if (RegExp(r'[A-Z]').hasMatch(t)) sc++;
        if (RegExp(r'\d').hasMatch(t)) sc++;
        if (RegExp(r'[^A-Za-z0-9]').hasMatch(t)) sc++;
        const lv = ['很弱', '弱', '一般', '较强', '强', '很强'];
        return '密码强度：${lv[sc.clamp(0, 5)]}（$sc/6）';
      case 'word_wrap':
        final n = (int.tryParse('${p['n'] ?? '20'}') ?? 20).clamp(1, 200);
        final sb = StringBuffer();
        for (var i = 0; i < t.length; i += n) {
          sb.writeln(t.substring(i, (i + n).clamp(0, t.length)));
        }
        return sb.toString().trimRight();
      case 'markdown_table':
        final rows = t.split('\n').where((l) => l.trim().isNotEmpty).toList();
        if (rows.isEmpty) return '无内容';
        final cells = rows.map((r) => r.split(RegExp(r'[,\t]'))).toList();
        final cols = cells.map((c) => c.length).reduce((a, b) => a > b ? a : b);
        final sb = StringBuffer();
        for (var i = 0; i < cells.length; i++) {
          final c = List<String>.from(cells[i]);
          while (c.length < cols) {
            c.add('');
          }
          sb.writeln('| ${c.join(' | ')} |');
          if (i == 0) {
            sb.writeln('|${List.filled(cols, '---').join('|')}|');
          }
        }
        return sb.toString().trimRight();
      case 'bullet_list':
        return t.split('\n').where((l) => l.trim().isNotEmpty).map((l) => '- $l').join('\n');
      case 'numbered_list':
        var i = 0;
        return t.split('\n').where((l) => l.trim().isNotEmpty).map((l) => '${++i}. $l').join('\n');
      case 'sort_by_length':
        final ls = t.split('\n')..sort((a, b) => a.length.compareTo(b.length));
        return ls.join('\n');
      case 'longest_line':
        final ls = t.split('\n');
        return ls.isEmpty ? '' : (ls..sort((a, b) => b.length.compareTo(a.length))).first;
      case 'shortest_line':
        final ls = t.split('\n');
        return ls.isEmpty ? '' : (ls..sort((a, b) => a.length.compareTo(b.length))).first;
      case 'avg_line_length':
        final ls = t.split('\n');
        return ls.isEmpty ? '0' : '平均行长：${(ls.fold<int>(0, (s, l) => s + l.length) / ls.length).toStringAsFixed(1)}';
      case 'word_freq':
        final ws = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        final m = <String, int>{};
        for (final w in ws) {
          m[w] = (m[w] ?? 0) + 1;
        }
        final es = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        return es.take(20).map((e) => '${e.key} ×${e.value}').join('　');
      case 'remove_dup_words':
        final seen = <String>{};
        return t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty && seen.add(w)).join(' ');
      case 'swap_case':
        return t.split('').map((c) => c == c.toUpperCase() ? c.toLowerCase() : c.toUpperCase()).join();
      case 'capitalize_sentences':
        return t.replaceAllMapped(RegExp(r'(^|[.!?。！？]\s*)([a-z])'),
            (m) => '${m.group(1)}${m.group(2)!.toUpperCase()}');
      case 'split_comma':
        return t.split(RegExp(r'[,，]')).map((s) => s.trim()).where((s) => s.isNotEmpty).join('\n');
      case 'join_lines':
        return t.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).join(' ');
      case 'remove_empty_lines':
        return t.split('\n').where((l) => l.trim().isNotEmpty).join('\n');
      case 'add_line_numbers':
        var i = 0;
        return t.split('\n').map((l) => '${(++i).toString().padLeft(2, '0')} | $l').join('\n');
      case 'reverse_lines':
        return t.split('\n').reversed.join('\n');
      case 'lines_to_csv':
        return t.split('\n').where((l) => l.trim().isNotEmpty).map((l) => '"${l.replaceAll('"', '""')}"').join(',');
      case 'quote_each':
        return t.split('\n').map((l) => '「$l」').join('\n');
      case 'escape_json':
        return jsonEncode(t);
      case 'unescape_json':
        try {
          final v = jsonDecode(t);
          return '$v';
        } catch (_) {
          return t.replaceAll('\\n', '\n').replaceAll('\\"', '"');
        }
      case 'count_paragraphs':
        return '段落数：${t.split(RegExp(r'\n\s*\n')).where((s) => s.trim().isNotEmpty).length}';
      case 'first_letters':
        return t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map((w) => w[0]).join();
      case 'acronym':
        return t.split(RegExp(r'[\s\-_]+')).where((w) => w.isNotEmpty).map((w) => w[0].toUpperCase()).join();
      case 'lorem_ipsum':
        return '这里是占位文本，用于排版预览。你可以把这段文字替换成自己的内容，'
            '保持段落长度大致相当，整体看起来会更整齐。';
      case 'md_heading':
        return '# $t';
      case 'md_quote':
        return t.split('\n').map((l) => '> $l').join('\n');
      case 'md_code':
        return '```\n$t\n```';
      case 'md_link':
        final parts = t.split(RegExp(r'\s+'));
        return parts.length >= 2 ? '[${parts.sublist(1).join(' ')}](${parts[0]})' : '[]($t)';
      case 'md_image':
        final parts = t.split(RegExp(r'\s+'));
        return parts.length >= 2 ? '![${parts.sublist(1).join(' ')}](${parts[0]})' : '![]($t)';
      case 'md_checkbox':
        return t.split('\n').where((l) => l.trim().isNotEmpty).map((l) => '- [ ] $l').join('\n');
      case 'md_toc':
        var i = 0;
        return t.split('\n').where((l) => l.trim().isNotEmpty).map((l) => '- [${++i}](#${l.trim()})').join('\n');
      case 'json_to_csv':
        try {
          final v = jsonDecode(t);
          final list = v is List ? v : [v];
          if (list.isEmpty) return '空';
          final keys = (list.first as Map).keys.toList();
          final sb = StringBuffer('${keys.join(',')}\n');
          for (final row in list) {
            sb.writeln(keys.map((k) => '"${(row as Map)[k] ?? ''}"').join(','));
          }
          return sb.toString().trimRight();
        } catch (_) {
          return '不是合法 JSON 数组';
        }
      case 'csv_to_json':
        final ls = t.split('\n').where((l) => l.trim().isNotEmpty).toList();
        if (ls.isEmpty) return '无内容';
        final keys = ls.first.split(',');
        final out = <Map<String, String>>[];
        for (final l in ls.skip(1)) {
          final vs = l.split(',');
          final m = <String, String>{};
          for (var i = 0; i < keys.length; i++) {
            m[keys[i].trim()] = i < vs.length ? vs[i].trim() : '';
          }
          out.add(m);
        }
        return const JsonEncoder.withIndent('  ').convert(out);
      case 'merge_unique':
        final seen = <String>{};
        return t.split('\n').where((l) => seen.add(l.trim())).join('\n');
      case 'common_lines':
        final a = (p['a'] ?? '').toString().split('\n').map((s) => s.trim()).toSet();
        final b = (p['b'] ?? '').toString().split('\n').map((s) => s.trim()).toSet();
        return a.intersection(b).where((s) => s.isNotEmpty).join('\n');
      case 'only_first':
        final a = (p['a'] ?? '').toString().split('\n').map((s) => s.trim()).toSet();
        final b = (p['b'] ?? '').toString().split('\n').map((s) => s.trim()).toSet();
        return a.difference(b).where((s) => s.isNotEmpty).join('\n');
      case 'split_columns':
        final sep = '${p['sep'] ?? ','}';
        final cs = t.split('\n').where((l) => l.isNotEmpty).map((l) => l.split(sep)).toList();
        final cols = cs.isEmpty ? 0 : cs.map((c) => c.length).reduce((a, b) => a > b ? a : b);
        if (cols < 2) return '没找到分隔符';
        return List.generate(cols, (i) => cs.map((c) => i < c.length ? c[i].trim() : '').join('\n')).join('\n---\n');
      case 'wrap_quotes':
        return '"${t.replaceAll('"', '\\"')}"';
      case 'strip_punct':
        return t.replaceAll(RegExp(r'[\p{P}\p{S}]', unicode: true), ' ');
      case 'strip_digits':
        return t.replaceAll(RegExp(r'\d'), '');
      case 'keep_digits':
        return t.replaceAll(RegExp(r'[^\d]'), '');
      case 'keep_chinese':
        return t.replaceAll(RegExp(r'[^\u4e00-\u9fff]'), '');
      case 'keep_english':
        return t.replaceAll(RegExp(r'[^A-Za-z\s]'), '');
      case 'sort_numeric':
        final ls = t.split('\n').where((l) => l.trim().isNotEmpty).toList();
        ls.sort((a, b) => (double.tryParse(a) ?? 0).compareTo(double.tryParse(b) ?? 0));
        return ls.join('\n');
      case 'shuffle_lines':
        final ls = t.split('\n')..shuffle();
        return ls.join('\n');
      case 'upper_first':
        return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
      case 'remove_blank_lines':
        return t.split(RegExp(r'\n\s*\n')).map((s) => s.trim()).where((s) => s.isNotEmpty).join('\n');
      case 'date_add':
        try {
          final d = DateTime.parse(t.trim()).add(Duration(days: int.tryParse('${p['n'] ?? '1'}') ?? 1));
          return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        } catch (_) {
          return '日期格式如 2026-01-01';
        }
      case 'date_format':
        try {
          final d = DateTime.parse(t.trim());
          const wk = ['一', '二', '三', '四', '五', '六', '日'];
          return '${d.year}年${d.month}月${d.day}日 星期${wk[d.weekday - 1]}';
        } catch (_) {
          return '日期格式如 2026-01-01';
        }
      case 'time_diff':
        try {
          final a = DateTime.parse('${p['a']}');
          final b = DateTime.parse('${p['b']}');
          final m = b.difference(a).inMinutes;
          return '相差 ${m ~/ 1440} 天 ${(m % 1440) ~/ 60} 小时 ${m % 60} 分';
        } catch (_) {
          return '需要 a、b 两个日期(YYYY-MM-DD)';
        }
      case 'age_calc':
        try {
          final b = DateTime.parse(t.trim());
          final d = DateTime.now();
          var age = d.year - b.year;
          if (d.month < b.month || (d.month == b.month && d.day < b.day)) age--;
          return '年龄：$age 岁';
        } catch (_) {
          return '生日格式如 2008-06-01';
        }
      case 'weekday_name':
        try {
          const wk = ['一', '二', '三', '四', '五', '六', '日'];
          return '星期${wk[DateTime.parse(t.trim()).weekday - 1]}';
        } catch (_) {
          return '日期格式如 2026-01-01';
        }
      case 'is_weekend':
        try {
          final w = DateTime.parse(t.trim()).weekday;
          return w >= 6 ? '是周末' : '是工作日';
        } catch (_) {
          return '日期格式如 2026-01-01';
        }
      case 'week_ago':
        final d = DateTime.now().subtract(const Duration(days: 7));
        return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      case 'month_days':
        final d = DateTime.now();
        final n = DateTime(d.year, d.month + 1, 0).day;
        return '本月共 $n 天';
      case 'leap_year':
        final y = int.tryParse(t.trim()) ?? DateTime.now().year;
        return '${(y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? '是' : '不是'}闰年';
      case 'num_to_chinese':
        const dg = '零一二三四五六七八九';
        final v = t.trim();
        final sb = StringBuffer();
        for (final c in v.split('')) {
          final d = int.tryParse(c);
          sb.write(d == null ? c : dg[d]);
        }
        return sb.toString();
      case 'thousands':
        final v = double.tryParse(t.trim());
        if (v == null) return '请输入数字';
        final s = v.toStringAsFixed(2).split('.');
        final buf = StringBuffer();
        final int3 = s[0];
        for (var i = 0; i < int3.length; i++) {
          if (i > 0 && (int3.length - i) % 3 == 0) buf.write(',');
          buf.write(int3[i]);
        }
        return '${buf.toString()}.${s[1]}';
      case 'round_num':
        final v = double.tryParse(t.trim());
        final n = int.tryParse('${p['n'] ?? '2'}') ?? 2;
        return v == null ? '请输入数字' : v.toStringAsFixed(n);
      case 'gcd_lcm':
        final a = int.tryParse('${p['a'] ?? 0}') ?? 0;
        final b = int.tryParse('${p['b'] ?? 0}') ?? 0;
        if (a <= 0 || b <= 0) return '需要两个正整数(a,b)';
        var x = a, y = b;
        while (y != 0) {
          final t = x % y;
          x = y;
          y = t;
        }
        return '最大公约数：$x　最小公倍数：${a * b ~/ x}';
      case 'factorial':
        final n0 = int.tryParse(t.trim());
        if (n0 == null || n0 < 0 || n0 > 20) return '请输入 0-20 的整数';
        var f = 1;
        for (var i = 2; i <= n0; i++) {
          f *= i;
        }
        return '$n0! = $f';
      case 'prime_check':
        final n0 = int.tryParse(t.trim());
        if (n0 == null || n0 < 2) return '不是质数';
        var prime = true;
        for (var i = 2; i * i <= n0; i++) {
          if (n0 % i == 0) {
            prime = false;
            break;
          }
        }
        return '$n0 ${prime ? '是' : '不是'}质数';
      case 'fibonacci':
        final n0 = (int.tryParse(t.trim()) ?? 10).clamp(1, 90);
        var a = 0, b = 1;
        final out = <int>[];
        for (var i = 0; i < n0; i++) {
          out.add(a);
          final t2 = a + b;
          a = b;
          b = t2;
        }
        return out.join(' ');
      case 'power':
        final a = double.tryParse('${p['a'] ?? 0}') ?? 0;
        final b = double.tryParse('${p['b'] ?? 2}') ?? 2;
        return '${p['a']} ^ ${p['b']} = ${pow(a, b).toStringAsFixed(6).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')}';
      case 'sqrt':
        final v = double.tryParse(t.trim());
        return v == null || v < 0 ? '请输入非负数' : '√$v = ${sqrt(v)}';
      case 'average':
        final ns = RegExp(r'-?\d+\.?\d*').allMatches(t).map((m) => double.parse(m.group(0)!)).toList();
        if (ns.isEmpty) return '没找到数字';
        return '平均值：${(ns.reduce((x, y) => x + y) / ns.length).toStringAsFixed(2)}';
      case 'sum_numbers':
        final ns = RegExp(r'-?\d+\.?\d*').allMatches(t).map((m) => double.parse(m.group(0)!)).toList();
        if (ns.isEmpty) return '没找到数字';
        return '合计：${ns.fold<double>(0, (x, y) => x + y).toStringAsFixed(2)}';
      case 'min_max':
        final ns = RegExp(r'-?\d+\.?\d*').allMatches(t).map((m) => double.parse(m.group(0)!)).toList();
        if (ns.isEmpty) return '没找到数字';
        return '最小：${ns.reduce((x, y) => x < y ? x : y)}　最大：${ns.reduce((x, y) => x > y ? x : y)}';
      default:
        return null;
    }
  }

  Future<void> _regenerate() async {
    if (_busy) return;
    final ui = _msgs.lastIndexWhere((m) => m['role'] == 'user');
    if (ui < 0) return;
    setState(() {
      if (_msgs.length > ui + 1) _msgs.removeRange(ui + 1, _msgs.length);
      _busy = true;
      _err = null;
    });
    _jump();
    final d = await AccountService.aiChat(_msgs);
    if (!mounted) return;
    setState(() => _busy = false);
    if (d['ok'] == true) {
      setState(() {
        _msgs.add({'role': 'assistant', 'content': '${d['reply'] ?? ''}'});
        _used = (d['used'] as num?)?.toInt() ?? _used;
        _limit = (d['limit'] as num?)?.toInt() ?? _limit;
      });
      _runActions(d);
    } else {
      setState(() => _err = '${d['error'] ?? 'AI 请求失败'}');
    }
    _jump();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadUsage() async {
    final d = await AccountService.aiUsage();
    if (!mounted || d == null) return;
    setState(() {
      _used = (d['used'] as num?)?.toInt() ?? 0;
      _limit = (d['limit'] as num?)?.toInt() ?? 10000;
      _enabled = d['enabled'] != false;
    });
  }

  void _sendText(String t) {
    _input.text = t;
    _send();
  }

  Future<void> _pickFile() async {
    try {
      final r = await FilePicker.platform.pickFiles(withData: false);
      if (r == null || r.files.isEmpty) return;
      final f = r.files.single;
      final path = f.path;
      if (path == null) return;
      setState(() => _uploading = true);
      final bytes = await File(path).readAsBytes();
      if (bytes.length > 20 * 1024 * 1024) {
        setState(() {
          _uploading = false;
          _err = '文件太大（最多 20MB）';
        });
        return;
      }
      final d = await AccountService.aiUpload(f.name, base64Encode(bytes));
      if (!mounted) return;
      setState(() {
        _uploading = false;
        if (d['ok'] == true) {
          _attachName = '${d['name'] ?? f.name}';
          _attachText = '${d['text'] ?? ''}';
          _err = null;
        } else {
          _err = '${d['error'] ?? '上传失败'}';
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _uploading = false;
          _err = '上传失败：$e';
        });
      }
    }
  }

  Future<void> _send() async {
    var text = _input.text.trim();
    if (_busy) return;
    if (text.isEmpty && _attachName == null) return;
    if (_used >= _limit) return;
    if (_attachName != null) {
      final ex = (_attachText ?? '').trim();
      text = '${text.isEmpty ? '看看这个文件' : text}\n📎 $_attachName'
          '${ex.isEmpty ? '' : '\n\n$ex'}';
    }
    setState(() {
      _msgs.add({'role': 'user', 'content': text});
      _busy = true;
      _err = null;
      _input.clear();
      _attachName = null;
      _attachText = null;
    });
    _jump();
    final d = await AccountService.aiChat(_msgs);
    if (!mounted) return;
    setState(() => _busy = false);
    if (d['ok'] == true) {
      setState(() {
        _msgs.add({'role': 'assistant', 'content': '${d['reply'] ?? ''}'});
        _used = (d['used'] as num?)?.toInt() ?? _used;
        _limit = (d['limit'] as num?)?.toInt() ?? _limit;
      });
      // 执行 AI 给出的 App 操作(play/search/open/pause/next/prev…)
      _runActions(d);
    } else {
      setState(() => _err = '${d['error'] ?? 'AI 请求失败'}');
    }
    _jump();
  }

  Future<void> _makeVideo() async {
    final c = TextEditingController();
    final topic = await showDialog<String>(
      context: context,
      builder: (x) => AlertDialog(
        title: const Text('AI 生成视频'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: '视频主题，如：健康饮食小知识'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(x), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(x, c.text.trim()),
              child: const Text('生成')),
        ],
      ),
    );
    if (topic == null || topic.isEmpty || !mounted) return;
    setState(() => _busy = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        title: Text('正在生成视频…'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(),
          SizedBox(height: 12),
          Text('AI 写脚本 + 配音 + 合成，约 1~2 分钟'),
        ]),
      ),
    );
    final d = await AccountService.aiVideo(topic);
    if (mounted) Navigator.of(context).pop();
    if (!mounted) return;
    setState(() => _busy = false);
    if (d['ok'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已生成并发布：${d['title']}（去「视频」里看）'),
        duration: const Duration(seconds: 5),
      ));
    } else {
      setState(() => _err = '${d['error'] ?? '生成失败'}');
    }
  }

  void _jump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Widget _msgBtn(IconData ic, String tip, VoidCallback onTap) {
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 30),
      iconSize: 16,
      icon: Icon(ic, color: _cSub),
    );
  }

  Future<void> _onMenu(String v) async {
    switch (v) {
      case 'tpl':
        _showTemplates();
        break;
      case 'pref':
        _showPrefs();
        break;
      case 'faq':
        _showFaq();
        break;
      case 'stats':
        _showStats();
        break;
      case 'hist':
        _showHistory();
        break;
      case 'exp':
        final d = await AccountService.aiExport();
        if (!mounted) return;
        if (d['ok'] == true) _copy('${d['text'] ?? ''}');
        break;
      case 'clr':
        await AccountService.aiHistory(clear: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已清除会话历史')));
        }
        break;
    }
  }

  void _showTemplates() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => ListView(
        shrinkWrap: true,
        children: [
          const Padding(
              padding: EdgeInsets.all(14),
              child: Text('快捷模板',
                  style: TextStyle(fontWeight: FontWeight.w700))),
          ..._tpls.map((t) => ListTile(
                leading: const Icon(Icons.auto_awesome,
                    size: 18, color: _brand1),
                title: Text('${t['t']}'),
                subtitle: Text('${t['v']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () {
                  Navigator.pop(context);
                  _sendText('${t['v']}');
                },
              )),
        ],
      ),
    );
  }

  Future<void> _showPrefs() async {
    final d = await AccountService.aiMeta();
    if (!mounted) return;
    final p = (d['prefs'] as Map?) ?? {};
    final mem = TextEditingController(text: '${p['memory'] ?? ''}');
    final tone = TextEditingController(text: '${p['tone'] ?? ''}');
    String lang = '${p['lang'] ?? 'zh'}';
    String length = '${p['length'] ?? ''}';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (x) => StatefulBuilder(
        builder: (x, setSt) => AlertDialog(
          title: const Text('我的偏好'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: tone,
                  decoration: const InputDecoration(
                      labelText: '语气（如：简洁/详细/幽默）')),
              const SizedBox(height: 8),
              TextField(
                  controller: mem,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: '记忆（如：我喜欢搞笑风格）')),
              const SizedBox(height: 10),
              Row(children: [
                const Text('语言：'),
                DropdownButton<String>(
                  value: lang,
                  items: const [
                    DropdownMenuItem(value: 'zh', child: Text('中文')),
                    DropdownMenuItem(value: 'en', child: Text('English')),
                  ],
                  onChanged: (v) => setSt(() => lang = v ?? 'zh'),
                ),
              ]),
              Row(children: [
                const Text('长度：'),
                DropdownButton<String>(
                  value: length.isEmpty ? '默认' : length,
                  items: const [
                    DropdownMenuItem(value: '默认', child: Text('默认')),
                    DropdownMenuItem(value: '短', child: Text('简短')),
                    DropdownMenuItem(value: '详细', child: Text('详细')),
                  ],
                  onChanged: (v) =>
                      setSt(() => length = (v == '默认') ? '' : (v ?? '')),
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(x), child: const Text('取消')),
            FilledButton(
                onPressed: () async {
                  await AccountService.aiPrefs(
                      memory: mem.text,
                      tone: tone.text,
                      lang: lang,
                      length: length);
                  if (x.mounted) Navigator.pop(x);
                },
                child: const Text('保存')),
          ],
        ),
      ),
    );
  }

  void _showFaq() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('常见问题'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _faq
                .map((f) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Q：${f['q']}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text('A：${f['a']}',
                              style: const TextStyle(
                                  fontSize: 13, color: Color(0xFF4A5568))),
                        ],
                      ),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  Future<void> _showStats() async {
    final d = await AccountService.aiStats();
    if (!mounted) return;
    if (d['ok'] != true) return;
    final ser = (d['series'] as List?) ?? [];
    final buf = StringBuffer('近 14 天用量：\n\n');
    for (final s in ser) {
      buf.writeln('${s['d']}   ${s['n']} token');
    }
    buf.writeln('\n累计：${d['total']} token');
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('用量统计'),
        content: SingleChildScrollView(child: Text('$buf')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _showHistory() async {
    final d = await AccountService.aiHistory();
    if (!mounted) return;
    if (d['ok'] != true) return;
    final arr = (d['history'] as List?) ?? [];
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('会话历史'),
        content: SizedBox(
          width: double.maxFinite,
          height: 380,
          child: arr.isEmpty
              ? const Center(child: Text('暂无历史'))
              : ListView.builder(
                  itemCount: arr.length,
                  itemBuilder: (_, i) {
                    final m = arr[i];
                    final me = m['role'] == 'user';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text('${me ? '我' : 'AI'}：${m['content']}',
                          style: TextStyle(
                              fontSize: 13,
                              color: me
                                  ? const Color(0xFF17233D)
                                  : const Color(0xFF4A5568))),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  Widget _avatar(double size) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
            colors: [_brand1, _brand2],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.auto_awesome, color: Colors.white, size: size * 0.55),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remaining = (_limit - _used).clamp(0, _limit);
    return Scaffold(
      backgroundColor: _cBg,
      floatingActionButton: (_msgs.isNotEmpty && !_atBottom)
          ? FloatingActionButton.small(
              backgroundColor: _cCard,
              foregroundColor: _brand1,
              onPressed: _jump,
              child: const Icon(Icons.keyboard_arrow_down),
            )
          : null,
      appBar: AppBar(
        backgroundColor: _cCard,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _avatar(26),
            const SizedBox(width: 8),
            Text('创作AI助手',
                style: TextStyle(
                    color: _cText,
                    fontWeight: FontWeight.w600,
                    fontSize: 17)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: Icon(Icons.more_horiz, color: _cIcon),
            onSelected: _onMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'tpl', child: Text('快捷模板')),
              PopupMenuItem(value: 'pref', child: Text('我的偏好（语气/记忆）')),
              PopupMenuItem(value: 'faq', child: Text('常见问题')),
              PopupMenuItem(value: 'stats', child: Text('用量统计')),
              PopupMenuItem(value: 'hist', child: Text('会话历史')),
              PopupMenuItem(value: 'exp', child: Text('导出对话')),
              PopupMenuItem(value: 'clr', child: Text('清除历史')),
            ],
          ),
          IconButton(
            tooltip: 'AI 生成视频并发布',
            onPressed: _busy ? null : _makeVideo,
            icon: Icon(Icons.movie_creation_outlined, color: _cIcon),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_enabled)
            Container(
              width: double.infinity,
              color: Colors.orange.shade50,
              padding: const EdgeInsets.all(10),
              child: const Text('创作 AI 助手已被管理员关闭',
                  style: TextStyle(color: Color(0xFF8A5A00))),
            ),
          if (_notice.isNotEmpty)
            Container(
              width: double.infinity,
              color: const Color(0xFFFFF7E6),
              padding: const EdgeInsets.all(10),
              child: Text(_notice,
                  style: const TextStyle(
                      color: Color(0xFF8A5A00), fontSize: 12.5)),
            ),
          if (remaining <= 0)
            Container(
              width: double.infinity,
              color: Colors.red.shade50,
              padding: const EdgeInsets.all(10),
              child: const Text('今日 AI 额度已用完，明天 0 点重置',
                  style: TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: _msgs.isEmpty ? _welcome() : _list(),
          ),
          if (_err != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(_err!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
          _quotaBar(remaining),
          _inputBar(remaining),
        ],
      ),
    );
  }

  Widget _welcome() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 36, 20, 20),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: _dark
                  ? [const Color(0xFF1B2740), const Color(0xFF14283A)]
                  : [const Color(0xFFEAF2FF), const Color(0xFFE6FBFA)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(children: [
            _avatar(64),
            const SizedBox(height: 14),
            Text('Hi，我是小李 AI 助手',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: _cText)),
            const SizedBox(height: 6),
            Text('视频标题 · 简介 · 脚本 · 文案，样样都行',
                style: TextStyle(fontSize: 13, color: _cSub)),
          ]),
        ),
        const SizedBox(height: 22),
        ..._suggestions.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: _cCard,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _busy ? null : () => _sendText(s[1]),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _cBorder),
                    ),
                    child: Row(
                      children: [
                        Text(s[0], style: const TextStyle(fontSize: 18)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(s[1],
                              style: TextStyle(
                                  fontSize: 14.5, color: _cText)),
                        ),
                        Icon(Icons.chevron_right, size: 18, color: _cIcon),
                      ],
                    ),
                  ),
                ),
              ),
            )),
      ],
    );
  }

  Widget _list() {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      itemCount: _msgs.length + (_busy ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= _msgs.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _avatar(30),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: _cCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _cBorder),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _brand1)),
                    const SizedBox(width: 8),
                    Text('正在思考…',
                        style: TextStyle(fontSize: 13, color: _cSub)),
                  ]),
                ),
              ],
            ),
          );
        }
        final m = _msgs[i];
        final me = m['role'] == 'user';
        if (me) {
          return Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 5),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.76),
              decoration: BoxDecoration(
                color: _cUserBubble,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: SelectableText(m['content'] ?? '',
                  style: TextStyle(
                      color: _cUserText, fontSize: 14.5, height: 1.5)),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _avatar(30),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        color: _cCard,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(4),
                          topRight: Radius.circular(16),
                          bottomLeft: Radius.circular(16),
                          bottomRight: Radius.circular(16),
                        ),
                        border: Border.all(color: _cBorder),
                        boxShadow: const [
                          BoxShadow(
                              color: Color(0x0A000000),
                              blurRadius: 8,
                              offset: Offset(0, 2)),
                        ],
                      ),
                      child: SelectableText(m['content'] ?? '',
                          style: TextStyle(
                              color: _cText,
                              fontSize: 14.5,
                              height: 1.55)),
                    ),
                    Row(
                      children: [
                        _msgBtn(Icons.volume_up_outlined, '朗读',
                            () => _speak(m['content'] ?? '')),
                        _msgBtn(Icons.copy_outlined, '复制',
                            () => _copy(m['content'] ?? '')),
                        _msgBtn(Icons.refresh, '重新生成', _regenerate),
                        _msgBtn(Icons.thumb_up_outlined, '赞',
                            () => _vote('up', m['content'] ?? '')),
                        _msgBtn(Icons.thumb_down_outlined, '踩',
                            () => _vote('down', m['content'] ?? '')),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _quotaBar(int remaining) {
    final ok = remaining > 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
      child: Row(
        children: [
          Icon(Icons.bolt, size: 13, color: ok ? _brand1 : Colors.red),
          const SizedBox(width: 4),
          Text('今日剩余 $remaining / $_limit token',
              style: TextStyle(
                  fontSize: 11.5,
                  color: ok ? _cSub : Colors.red)),
        ],
      ),
    );
  }

  Widget _inputBar(int remaining) {
    final canSend = _enabled && remaining > 0 && !_busy;
    return SafeArea(
      top: false,
      child: Container(
        color: _cCard,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_msgs.isNotEmpty && !_busy && _attachName == null)
              SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: _suggestions
                      .map((s) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              label: Text(s[1],
                                  style: const TextStyle(fontSize: 12)),
                              backgroundColor: _cInputBg,
                              side: BorderSide(color: _cBorder),
                              onPressed: () => _sendText(s[1]),
                            ),
                          ))
                      .toList(),
                ),
              ),
            if (_attachName != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color:
                      _dark ? const Color(0xFF232A3A) : const Color(0xFFEEF3FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.attach_file, size: 16, color: _brand1),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_attachName!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: _cText)),
                    ),
                    GestureDetector(
                      onTap: () => setState(() {
                        _attachName = null;
                        _attachText = null;
                      }),
                      child: Icon(Icons.close, size: 16, color: _cSub),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: '发送图片/文件（图片自动识别文字）',
                  onPressed: (_uploading || !_enabled) ? null : _pickFile,
                  icon: _uploading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(Icons.add_photo_alternate_outlined,
                          color: _cSub),
                ),
                Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: _cInputBg,
                  borderRadius: BorderRadius.circular(22),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  enabled: _enabled && remaining > 0,
                  onSubmitted: (_) => _send(),
                  style: TextStyle(fontSize: 15, color: _cText),
                  decoration: InputDecoration(
                    hintText: remaining > 0
                        ? '发消息，例如：帮我想 5 个视频标题'
                        : '今日额度已用完',
                    hintStyle: TextStyle(color: _cHint, fontSize: 14),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: canSend ? _send : null,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: canSend
                      ? const LinearGradient(
                          colors: [_brand1, _brand2],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight)
                      : null,
                  color: canSend ? null : _cDisable,
                ),
                child: _busy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.arrow_upward,
                        color: Colors.white, size: 22),
              ),
            ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
