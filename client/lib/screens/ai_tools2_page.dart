import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// AI 工具大全：100 个按钮（数据驱动）。
class AiTools2Page extends StatefulWidget {
  const AiTools2Page({super.key});
  @override
  State<AiTools2Page> createState() => _AiTools2PageState();
}

class _Tool {
  final String label;
  final String kind;
  final String arg;
  const _Tool(this.label, this.kind, [this.arg = '']);
}

const List<_Tool> _tools = [
  // 统计 15
  _Tool('总字符', 'c_all'), _Tool('字符(不含空格)', 'c_nospace'),
  _Tool('中文字数', 'c_cn'), _Tool('英文字母', 'c_en'),
  _Tool('数字个数', 'c_digit'), _Tool('标点个数', 'c_punct'),
  _Tool('空格数', 'c_space'), _Tool('行数', 'c_lines'),
  _Tool('非空行', 'c_nonempty'), _Tool('段落数', 'c_para'),
  _Tool('词数', 'c_words'), _Tool('唯一字符', 'c_unique'),
  _Tool('大写字母', 'c_upper'), _Tool('小写字母', 'c_lower'),
  _Tool('词频Top', 'c_wordfreq'),
  // 变换 24
  _Tool('转大写', 'upper'), _Tool('转小写', 'lower'),
  _Tool('首字母大写', 'cap_first'), _Tool('每词首字母大写', 'cap_words'),
  _Tool('反转文字', 'reverse'), _Tool('反转词序', 'reverse_words'),
  _Tool('反转行序', 'reverse_lines'), _Tool('去所有空格', 'strip_space'),
  _Tool('合并空格', 'collapse_space'), _Tool('去空行', 'remove_blank'),
  _Tool('行去重', 'dedup_lines'), _Tool('词去重', 'dedup_words'),
  _Tool('行排序', 'sort_lines'), _Tool('按长度排序', 'sort_len'),
  _Tool('行打乱', 'shuffle_lines'), _Tool('去标点', 'strip_punct'),
  _Tool('去数字', 'strip_digits'), _Tool('只留数字', 'keep_digits'),
  _Tool('只留中文', 'keep_cn'), _Tool('只留英文', 'keep_en'),
  _Tool('加行号', 'add_lineno'), _Tool('每行加引号', 'quote_each'),
  _Tool('项目符号', 'bullet'), _Tool('编号列表', 'numbered'),
  // 编码 8
  _Tool('Base64编码', 'b64e'), _Tool('Base64解码', 'b64d'),
  _Tool('URL编码', 'urle'), _Tool('URL解码', 'urld'),
  _Tool('JSON格式化', 'json_fmt'), _Tool('JSON压缩', 'json_min'),
  _Tool('HTML转义', 'html_escape'), _Tool('HTML反转义', 'html_unescape'),
  // 提取 10
  _Tool('提取链接', 'x_url'), _Tool('提取邮箱', 'x_email'),
  _Tool('提取手机号', 'x_phone'), _Tool('提取数字', 'x_number'),
  _Tool('提取IP', 'x_ip'), _Tool('提取日期', 'x_date'),
  _Tool('提取话题#', 'x_hashtag'), _Tool('提取@提及', 'x_at'),
  _Tool('提取中文', 'x_cn'), _Tool('合并为一行', 'join_lines'),
  // 生成 10
  _Tool('UUID', 'uuid'), _Tool('短UUID', 'uuid_short'),
  _Tool('随机密码', 'password'), _Tool('随机字符串', 'rand_str'),
  _Tool('随机十六进制', 'rand_hex'), _Tool('随机数', 'rand_num'),
  _Tool('随机颜色', 'rand_color'), _Tool('随机表情', 'rand_emoji'),
  _Tool('随机选择', 'rand_pick'), _Tool('重复文本', 'repeat'),
  // 数字 16
  _Tool('计算器', 'calc'), _Tool('百分比', 'percent'),
  _Tool('平均值', 'avg'), _Tool('求和', 'sum'),
  _Tool('最大最小', 'minmax'), _Tool('四舍五入', 'round'),
  _Tool('千分位', 'thousands'), _Tool('转二进制', 'bin'),
  _Tool('转八进制', 'oct'), _Tool('转十六进制', 'hex'),
  _Tool('罗马数字', 'roman'), _Tool('阶乘', 'factorial'),
  _Tool('质数判断', 'prime'), _Tool('斐波那契', 'fib'),
  _Tool('最大公约/最小公倍', 'gcd'), _Tool('平方根', 'sqrt'),
  // 日期 11
  _Tool('时间戳', 'ts'), _Tool('今天日期', 'today'),
  _Tool('明天日期', 'tomorrow'), _Tool('昨天日期', 'yesterday'),
  _Tool('一周后', 'week_later'), _Tool('一周前', 'week_ago'),
  _Tool('星期几', 'weekday'), _Tool('本月天数', 'month_days'),
  _Tool('闰年判断', 'leap'), _Tool('距今天数', 'diff'),
  _Tool('年龄', 'age'),
  // 文本 12
  _Tool('截断20字', 'truncate'), _Tool('数字补零4位', 'pad_zero'),
  _Tool('左填充', 'pad_left'), _Tool('右填充', 'pad_right'),
  _Tool('居中', 'center'), _Tool('替换', 'replace'),
  _Tool('按逗号分行', 'split_comma'), _Tool('按分隔符分行', 'split_by'),
  _Tool('手机号打码', 'mask_phone'), _Tool('身份证打码', 'mask_id'),
  _Tool('邮箱打码', 'mask_email'), _Tool('一键脱敏', 'mask_all'),
];

class _AiTools2PageState extends State<AiTools2Page> {
  final _search = TextEditingController();
  String _q = '';

  double? _calc(String e) {
    final t = <String>[];
    for (final m in RegExp(r'\d+\.?\d*|[+\-*/()]').allMatches(e.replaceAll(' ', ''))) {
      t.add(m.group(0)!);
    }
    if (t.isEmpty) return null;
    var i = 0;
    late double Function() expr;
    double f() {
      if (i >= t.length) return 0;
      final x = t[i];
      if (x == '(') {
        i++;
        final v = expr();
        if (i < t.length && t[i] == ')') i++;
        return v;
      }
      if (x == '-') {
        i++;
        return -f();
      }
      i++;
      return double.tryParse(x) ?? 0;
    }

    double term() {
      var v = f();
      while (i < t.length && (t[i] == '*' || t[i] == '/')) {
        final op = t[i++];
        final r = f();
        v = op == '*' ? v * r : v / r;
      }
      return v;
    }

    double ef() {
      var v = term();
      while (i < t.length && (t[i] == '+' || t[i] == '-')) {
        final op = t[i++];
        final r = term();
        v = op == '+' ? v + r : v - r;
      }
      return v;
    }

    expr = ef;
    return ef();
  }

  String _run(_Tool t, String s) {
    final now = DateTime.now();
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final nums = RegExp(r'-?\d+\.?\d*')
        .allMatches(s)
        .map((m) => double.parse(m.group(0)!))
        .toList();
    switch (t.kind) {
      case 'c_all': return '${s.length}';
      case 'c_nospace': return '${s.replaceAll(RegExp(r'\s'), '').length}';
      case 'c_cn': return '${RegExp(r'[\u4e00-\u9fff]').allMatches(s).length}';
      case 'c_en': return '${RegExp(r'[A-Za-z]').allMatches(s).length}';
      case 'c_digit': return '${RegExp(r'\d').allMatches(s).length}';
      case 'c_punct': return '${RegExp(r'[\p{P}\p{S}]', unicode: true).allMatches(s).length}';
      case 'c_space': return '${RegExp(r'\s').allMatches(s).length}';
      case 'c_lines': return '${s.isEmpty ? 0 : s.split('\n').length}';
      case 'c_nonempty': return '${s.split('\n').where((l) => l.trim().isNotEmpty).length}';
      case 'c_para': return '${s.split(RegExp(r'\n\s*\n')).where((x) => x.trim().isNotEmpty).length}';
      case 'c_words': return '${s.trim().isEmpty ? 0 : s.trim().split(RegExp(r'\s+')).length}';
      case 'c_unique': return '${s.split('').toSet().length}';
      case 'c_upper': return '${RegExp(r'[A-Z]').allMatches(s).length}';
      case 'c_lower': return '${RegExp(r'[a-z]').allMatches(s).length}';
      case 'c_wordfreq':
        final m = <String, int>{};
        for (final w in s.split(RegExp(r'\s+')).where((x) => x.isNotEmpty)) {
          m[w] = (m[w] ?? 0) + 1;
        }
        final e = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        return e.take(20).map((x) => '${x.key} ×${x.value}').join('　');
      case 'upper': return s.toUpperCase();
      case 'lower': return s.toLowerCase();
      case 'cap_first': return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
      case 'cap_words':
        return s.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
      case 'reverse': return String.fromCharCodes(s.runes.toList().reversed);
      case 'reverse_words': return s.split(' ').reversed.join(' ');
      case 'reverse_lines': return s.split('\n').reversed.join('\n');
      case 'strip_space': return s.replaceAll(RegExp(r'\s+'), '');
      case 'collapse_space': return s.replaceAll(RegExp(r'[ \t]+'), ' ');
      case 'remove_blank': return s.split('\n').where((l) => l.trim().isNotEmpty).join('\n');
      case 'dedup_lines':
        final seen = <String>{};
        return s.split('\n').where((l) => seen.add(l.trim())).join('\n');
      case 'dedup_words':
        final seen = <String>{};
        return s.split(RegExp(r'\s+')).where((w) => seen.add(w)).join(' ');
      case 'sort_lines': final l = s.split('\n')..sort(); return l.join('\n');
      case 'sort_len': final l = s.split('\n')..sort((a, b) => a.length.compareTo(b.length)); return l.join('\n');
      case 'shuffle_lines': final l = s.split('\n')..shuffle(); return l.join('\n');
      case 'strip_punct': return s.replaceAll(RegExp(r'[\p{P}\p{S}]', unicode: true), ' ');
      case 'strip_digits': return s.replaceAll(RegExp(r'\d'), '');
      case 'keep_digits': return s.replaceAll(RegExp(r'[^\d]'), '');
      case 'keep_cn': return s.replaceAll(RegExp(r'[^\u4e00-\u9fff]'), '');
      case 'keep_en': return s.replaceAll(RegExp(r'[^A-Za-z\s]'), '');
      case 'add_lineno':
        var i = 0;
        return s.split('\n').map((l) => '${(++i).toString().padLeft(2, '0')} | $l').join('\n');
      case 'quote_each': return s.split('\n').map((l) => '「$l」').join('\n');
      case 'bullet': return s.split('\n').where((l) => l.trim().isNotEmpty).map((l) => '- $l').join('\n');
      case 'numbered':
        var i = 0;
        return s.split('\n').where((l) => l.trim().isNotEmpty).map((l) => '${++i}. $l').join('\n');
      case 'b64e': return base64Encode(utf8.encode(s));
      case 'b64d':
        try { return utf8.decode(base64Decode(s.trim())); } catch (_) { return '解码失败'; }
      case 'urle': return Uri.encodeComponent(s);
      case 'urld':
        try { return Uri.decodeComponent(s); } catch (_) { return '解码失败'; }
      case 'json_fmt':
        try { return const JsonEncoder.withIndent('  ').convert(jsonDecode(s)); } catch (_) { return '不是合法 JSON'; }
      case 'json_min':
        try { return jsonEncode(jsonDecode(s)); } catch (_) { return '不是合法 JSON'; }
      case 'html_escape':
        return s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
      case 'html_unescape':
        return s.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&amp;', '&');
      case 'x_url': final m = RegExp(r'https?://[^\s]+').allMatches(s).map((x) => x.group(0)).toList(); return m.isEmpty ? '没找到' : m.join('\n');
      case 'x_email': final m = RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+').allMatches(s).map((x) => x.group(0)).toList(); return m.isEmpty ? '没找到' : m.join('\n');
      case 'x_phone': final m = RegExp(r'1[3-9]\d{9}').allMatches(s).map((x) => x.group(0)).toList(); return m.isEmpty ? '没找到' : m.join('\n');
      case 'x_number': return nums.map((x) => x.toString().replaceAll(RegExp(r'\.0$'), '')).join(' ');
      case 'x_ip': final m = RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b').allMatches(s).map((x) => x.group(0)).toList(); return m.isEmpty ? '没找到' : m.join('\n');
      case 'x_date': final m = RegExp(r'\d{4}[-/年]\d{1,2}[-/月]\d{1,2}').allMatches(s).map((x) => x.group(0)).toList(); return m.isEmpty ? '没找到' : m.join('\n');
      case 'x_hashtag': final m = RegExp(r'#\S+').allMatches(s).map((x) => x.group(0)).toList(); return m.isEmpty ? '没找到' : m.join(' ');
      case 'x_at': final m = RegExp(r'@\S+').allMatches(s).map((x) => x.group(0)).toList(); return m.isEmpty ? '没找到' : m.join(' ');
      case 'x_cn': return s.replaceAll(RegExp(r'[^\u4e00-\u9fff]'), '');
      case 'join_lines': return s.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join(' ');
      case 'uuid':
        final r = Random.secure();
        final h = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
        return '${h.substring(0,8)}-${h.substring(8,12)}-${h.substring(12,16)}-${h.substring(16,20)}-${h.substring(20)}';
      case 'uuid_short':
        final r = Random.secure();
        return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
      case 'password':
        const cs = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#\$%&*';
        final r = Random.secure();
        return List.generate(16, (_) => cs[r.nextInt(cs.length)]).join();
      case 'rand_str':
        const cs = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        final r = Random.secure();
        return List.generate(12, (_) => cs[r.nextInt(cs.length)]).join();
      case 'rand_hex':
        final r = Random.secure();
        return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
      case 'rand_num': return '${1 + Random().nextInt(100)}';
      case 'rand_color':
        final r = Random();
        return '#${r.nextInt(0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';
      case 'rand_emoji':
        const e = ['😀','😂','🥰','😎','🤔','👍','🎬','🔥','🎵','🍜','🌈','⭐','💡','🚀','🍺','🐱'];
        return e[Random().nextInt(e.length)];
      case 'rand_pick':
        final opts = s.split(RegExp(r'[,，、\s]+')).where((x) => x.isNotEmpty).toList();
        return opts.isEmpty ? '请输入选项(逗号分隔)' : opts[Random().nextInt(opts.length)];
      case 'repeat':
        final n = (int.tryParse(t.arg) ?? 3).clamp(1, 100);
        return List.filled(n, s).join('\n');
      case 'calc':
        final v = _calc(s);
        return v == null ? '算不了' : '= $v';
      case 'percent':
        return nums.length >= 2 ? '${(nums[0] / nums[1] * 100).toStringAsFixed(2)}%' : '需要两个数字';
      case 'avg':
        return nums.isEmpty ? '没找到数字' : '${(nums.reduce((a, b) => a + b) / nums.length).toStringAsFixed(2)}';
      case 'sum':
        return nums.isEmpty ? '没找到数字' : '${nums.fold<double>(0, (a, b) => a + b).toStringAsFixed(2)}';
      case 'minmax':
        return nums.isEmpty ? '没找到数字' : '最小 ${nums.reduce(min)}　最大 ${nums.reduce(max)}';
      case 'round':
        final v = double.tryParse(s.trim());
        return v == null ? '请输入数字' : v.toStringAsFixed(2);
      case 'thousands':
        final v = double.tryParse(s.trim());
        if (v == null) return '请输入数字';
        final p = v.toStringAsFixed(2).split('.');
        final b = StringBuffer();
        for (var i = 0; i < p[0].length; i++) {
          if (i > 0 && (p[0].length - i) % 3 == 0) b.write(',');
          b.write(p[0][i]);
        }
        return '${b.toString()}.${p[1]}';
      case 'bin':
        final v = int.tryParse(s.trim());
        return v == null ? '请输入整数' : v.toRadixString(2);
      case 'oct':
        final v = int.tryParse(s.trim());
        return v == null ? '请输入整数' : v.toRadixString(8);
      case 'hex':
        final v = int.tryParse(s.trim());
        return v == null ? '请输入整数' : '0x${v.toRadixString(16).toUpperCase()}';
      case 'roman':
        final v = int.tryParse(s.trim());
        if (v == null || v <= 0 || v > 3999) return '请输入 1-3999';
        const map = [[1000,'M'],[900,'CM'],[500,'D'],[400,'CD'],[100,'C'],[90,'XC'],[50,'L'],[40,'XL'],[10,'X'],[9,'IX'],[5,'V'],[4,'IV'],[1,'I']];
        var x = v;
        final b = StringBuffer();
        for (final e in map) {
          final n = e[0] as int;
          while (x >= n) { b.write(e[1]); x -= n; }
        }
        return '$b';
      case 'factorial':
        final n = int.tryParse(s.trim());
        if (n == null || n < 0 || n > 20) return '请输入 0-20';
        var f = 1;
        for (var i = 2; i <= n; i++) { f *= i; }
        return '$n! = $f';
      case 'prime':
        final n = int.tryParse(s.trim());
        if (n == null || n < 2) return '不是质数';
        for (var i = 2; i * i <= n; i++) { if (n % i == 0) return '$n 不是质数'; }
        return '$n 是质数';
      case 'fib':
        final n = (int.tryParse(s.trim()) ?? 10).clamp(1, 90);
        var a = 0, b = 1;
        final o = <int>[];
        for (var i = 0; i < n; i++) { o.add(a); final t2 = a + b; a = b; b = t2; }
        return o.join(' ');
      case 'gcd':
        if (nums.length < 2) return '需要两个正整数';
        var x = nums[0].toInt(), y = nums[1].toInt();
        if (x <= 0 || y <= 0) return '需要两个正整数';
        final a0 = x, b0 = y;
        while (y != 0) { final t2 = x % y; x = y; y = t2; }
        return '最大公约 $x　最小公倍 ${a0 * b0 ~/ x}';
      case 'sqrt':
        final v = double.tryParse(s.trim());
        return v == null || v < 0 ? '请输入非负数' : '${sqrt(v)}';
      case 'ts': return '${now.millisecondsSinceEpoch ~/ 1000}';
      case 'today': return fmt(now);
      case 'tomorrow': return fmt(now.add(const Duration(days: 1)));
      case 'yesterday': return fmt(now.subtract(const Duration(days: 1)));
      case 'week_later': return fmt(now.add(const Duration(days: 7)));
      case 'week_ago': return fmt(now.subtract(const Duration(days: 7)));
      case 'weekday':
        const wk = ['一','二','三','四','五','六','日'];
        return '星期${wk[now.weekday - 1]}';
      case 'month_days': return '${DateTime(now.year, now.month + 1, 0).day} 天';
      case 'leap':
        final y = int.tryParse(s.trim()) ?? now.year;
        return '${(y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? '是' : '不是'}闰年';
      case 'diff':
        try { final d = DateTime.parse(s.trim()); return '${d.difference(now).inDays} 天'; } catch (_) { return '日期如 2026-12-31'; }
      case 'age':
        try {
          final b = DateTime.parse(s.trim());
          var a = now.year - b.year;
          if (now.month < b.month || (now.month == b.month && now.day < b.day)) a--;
          return '$a 岁';
        } catch (_) { return '生日如 2008-06-01'; }
      case 'truncate': return s.length <= 20 ? s : '${s.substring(0, 20)}…';
      case 'pad_zero': return s.padLeft(4, '0');
      case 'pad_left': return s.padLeft(20, ' ');
      case 'pad_right': return s.padRight(20, ' ');
      case 'center':
        if (s.length >= 30) return s;
        return ' ' * ((30 - s.length) ~/ 2) + s;
      case 'replace': return s.isEmpty ? '请输入内容' : s.replaceAll(t.arg.isEmpty ? ' ' : t.arg, '_');
      case 'split_comma': return s.split(RegExp(r'[,，]')).map((x) => x.trim()).where((x) => x.isNotEmpty).join('\n');
      case 'split_by': return s.split(t.arg.isEmpty ? ',' : t.arg).map((x) => x.trim()).where((x) => x.isNotEmpty).join('\n');
      case 'mask_phone': return s.replaceAllMapped(RegExp(r'1[3-9]\d{9}'), (m) => '${m.group(0)!.substring(0, 3)}****${m.group(0)!.substring(7)}');
      case 'mask_id': return s.replaceAllMapped(RegExp(r'\d{17}[\dXx]'), (m) => '${m.group(0)!.substring(0, 6)}********${m.group(0)!.substring(14)}');
      case 'mask_email': return s.replaceAllMapped(RegExp(r'([\w.+-]{1,2})[\w.+-]*@'), (m) => '${m.group(1)}***@');
      case 'mask_all':
        var o = s;
        o = o.replaceAllMapped(RegExp(r'1[3-9]\d{9}'), (m) => '${m.group(0)!.substring(0, 3)}****${m.group(0)!.substring(7)}');
        o = o.replaceAllMapped(RegExp(r'\d{17}[\dXx]'), (m) => '${m.group(0)!.substring(0, 6)}********${m.group(0)!.substring(14)}');
        o = o.replaceAllMapped(RegExp(r'([\w.+-]{1,2})[\w.+-]*@'), (m) => '${m.group(1)}***@');
        return o;
      default: return '未实现';
    }
  }

  Future<void> _open(_Tool t) async {
    String s = '';
    final needsInput = !const {
      'uuid','uuid_short','password','rand_str','rand_hex','rand_num',
      'rand_color','rand_emoji','ts','today','tomorrow','yesterday',
      'week_later','week_ago','weekday','month_days'
    }.contains(t.kind);
    if (needsInput) {
      final c = TextEditingController();
      final hint = switch (t.kind) {
        'calc' => '如 12*(3+4)',
        'roman' || 'factorial' || 'prime' || 'fib' || 'bin' || 'oct' || 'hex' => '整数',
        'age' => '生日 2008-06-01',
        'diff' => '日期 2026-12-31',
        'leap' => '年份 2028',
        'rand_pick' => '火锅,烧烤,日料',
        'replace' => '要替换的内容',
        'split_by' => '按这个分隔符分行',
        _ => '粘贴文本',
      };
      final r = await showDialog<String>(
        context: context,
        builder: (x) => AlertDialog(
          title: Text(t.label),
          content: TextField(
            controller: c,
            autofocus: true,
            maxLines: 6,
            decoration: InputDecoration(hintText: hint),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(x), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(x, c.text), child: const Text('确定')),
          ],
        ),
      );
      if (r == null) return;
      s = r;
    }
    final out = _run(t, s);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t.label, style: const TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
            child: SelectableText(out,
                style: const TextStyle(fontSize: 14, height: 1.5))),
        actions: [
          TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: out));
                Navigator.pop(context);
              },
              child: const Text('复制')),
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final list = _q.isEmpty
        ? _tools
        : _tools.where((t) => t.label.contains(_q)).toList();
    return Scaffold(
      appBar: AppBar(title: Text('工具大全（${_tools.length}）')),
      backgroundColor: dark ? const Color(0xFF14141A) : const Color(0xFFF7F8FC),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _q = v.trim()),
            decoration: InputDecoration(
              hintText: '搜索工具…',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.6,
            ),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final t = list[i];
              return Material(
                color: dark ? const Color(0xFF1E1E26) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _open(t),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: dark
                              ? const Color(0xFF333A45)
                              : const Color(0xFFEDEFF5)),
                    ),
                    child: Text(t.label,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
