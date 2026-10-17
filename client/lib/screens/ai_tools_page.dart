import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// AI 工具箱：25 个常用小工具，每个是一个按钮。
class AiToolsPage extends StatefulWidget {
  const AiToolsPage({super.key});
  @override
  State<AiToolsPage> createState() => _AiToolsPageState();
}

class _T {
  final String name;
  final IconData icon;
  final bool input;
  final String hint;
  final String Function(String s) run;
  const _T(this.name, this.icon, this.input, this.hint, this.run);
}

class _AiToolsPageState extends State<AiToolsPage> {
  void _open(_T t) async {
    String s = '';
    if (t.input) {
      final c = TextEditingController();
      final r = await showDialog<String>(
        context: context,
        builder: (x) => AlertDialog(
          title: Text(t.name),
          content: TextField(
            controller: c,
            autofocus: true,
            maxLines: 6,
            decoration: InputDecoration(hintText: t.hint),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(x), child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(x, c.text), child: const Text('确定')),
          ],
        ),
      );
      if (r == null) return;
      s = r;
    }
    final out = t.run(s);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t.name, style: const TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: SelectableText(out,
              style: const TextStyle(fontSize: 14, height: 1.5)),
        ),
        actions: [
          TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: out));
                Navigator.pop(context);
              },
              child: const Text('复制')),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  double? _calc(String e) {
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
    return exprFn();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tools = <_T>[
      _T('字数统计', Icons.text_fields, true, '粘贴文本', (s) {
        final chars = s.replaceAll(RegExp(r'\s'), '').length;
        final words =
            s.trim().isEmpty ? 0 : s.trim().split(RegExp(r'\s+')).length;
        return '字符(不含空格)：$chars\n词数：$words\n总长度：${s.length}\n行数：${s.isEmpty ? 0 : s.split('\n').length}';
      }),
      _T('计算器', Icons.calculate_outlined, true, '如 12*(3+4)', (s) {
        final v = _calc(s);
        return v == null ? '算不了' : '= $v';
      }),
      _T('随机密码', Icons.password, false, '', (_) {
        const cs = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#\$%&*';
        final r = Random.secure();
        return List.generate(16, (_) => cs[r.nextInt(cs.length)]).join();
      }),
      _T('UUID', Icons.tag, false, '', (_) {
        final r = Random.secure();
        final h = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
        return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
      }),
      _T('时间戳', Icons.access_time, false, '',
          (_) => '${DateTime.now().millisecondsSinceEpoch ~/ 1000}'),
      _T('今天日期', Icons.event, false, '', (_) {
        final d = DateTime.now();
        const wk = ['一', '二', '三', '四', '五', '六', '日'];
        return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} 星期${wk[d.weekday - 1]}';
      }),
      _T('JSON 格式化', Icons.data_object, true, '粘贴 JSON', (s) {
        try {
          return const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
        } catch (_) {
          return '不是合法 JSON';
        }
      }),
      _T('JSON 压缩', Icons.compress, true, '粘贴 JSON', (s) {
        try {
          return jsonEncode(jsonDecode(s));
        } catch (_) {
          return '不是合法 JSON';
        }
      }),
      _T('Base64 编码', Icons.code, true, '文本', (s) => base64Encode(utf8.encode(s))),
      _T('Base64 解码', Icons.code_off, true, 'Base64', (s) {
        try {
          return utf8.decode(base64Decode(s.trim()));
        } catch (_) {
          return '解码失败';
        }
      }),
      _T('URL 编码', Icons.link, true, '文本', (s) => Uri.encodeComponent(s)),
      _T('URL 解码', Icons.link_off, true, '编码', (s) {
        try {
          return Uri.decodeComponent(s);
        } catch (_) {
          return '解码失败';
        }
      }),
      _T('转大写', Icons.arrow_upward, true, '文本', (s) => s.toUpperCase()),
      _T('转小写', Icons.arrow_downward, true, '文本', (s) => s.toLowerCase()),
      _T('反转文字', Icons.swap_horiz, true, '文本',
          (s) => String.fromCharCodes(s.runes.toList().reversed)),
      _T('去空格', Icons.space_bar, true, '文本',
          (s) => s.replaceAll(RegExp(r'\s+'), '')),
      _T('行去重', Icons.filter_alt_outlined, true, '多行文本', (s) {
        final seen = <String>{};
        return s.split('\n').where((l) => seen.add(l.trim())).join('\n');
      }),
      _T('行排序', Icons.sort, true, '多行文本', (s) {
        final l = s.split('\n')..sort();
        return l.join('\n');
      }),
      _T('行打乱', Icons.shuffle, true, '多行文本', (s) {
        final l = s.split('\n')..shuffle();
        return l.join('\n');
      }),
      _T('千分位', Icons.numbers, true, '数字', (s) {
        final v = double.tryParse(s.trim());
        if (v == null) return '请输入数字';
        final p = v.toStringAsFixed(2).split('.');
        final b = StringBuffer();
        for (var i = 0; i < p[0].length; i++) {
          if (i > 0 && (p[0].length - i) % 3 == 0) b.write(',');
          b.write(p[0][i]);
        }
        return '${b.toString()}.${p[1]}';
      }),
      _T('罗马数字', Icons.translate, true, '1-3999', (s) {
        final v = int.tryParse(s.trim());
        if (v == null || v <= 0 || v > 3999) return '请输入 1-3999';
        const map = [
          [1000, 'M'], [900, 'CM'], [500, 'D'], [400, 'CD'], [100, 'C'],
          [90, 'XC'], [50, 'L'], [40, 'XL'], [10, 'X'], [9, 'IX'],
          [5, 'V'], [4, 'IV'], [1, 'I']
        ];
        var x = v;
        final b = StringBuffer();
        for (final e in map) {
          final n = e[0] as int;
          while (x >= n) {
            b.write(e[1]);
            x -= n;
          }
        }
        return '$b';
      }),
      _T('质数判断', Icons.verified_outlined, true, '整数', (s) {
        final n = int.tryParse(s.trim());
        if (n == null || n < 2) return '不是质数';
        for (var i = 2; i * i <= n; i++) {
          if (n % i == 0) return '$n 不是质数（能被 $i 整除）';
        }
        return '$n 是质数';
      }),
      _T('阶乘', Icons.functions, true, '0-20', (s) {
        final n = int.tryParse(s.trim());
        if (n == null || n < 0 || n > 20) return '请输入 0-20';
        var f = 1;
        for (var i = 2; i <= n; i++) {
          f *= i;
        }
        return '$n! = $f';
      }),
      _T('手机号打码', Icons.visibility_off_outlined, true, '含手机号的文本', (s) =>
          s.replaceAllMapped(RegExp(r'1[3-9]\d{9}'),
              (m) => '${m.group(0)!.substring(0, 3)}****${m.group(0)!.substring(7)}')),
      _T('提取链接', Icons.link, true, '文本', (s) {
        final m = RegExp(r'https?://[^\s]+').allMatches(s).map((x) => x.group(0)).toList();
        return m.isEmpty ? '没找到链接' : m.join('\n');
      }),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('AI 工具箱')),
      backgroundColor: dark ? const Color(0xFF14141A) : const Color(0xFFF7F8FC),
      body: GridView.builder(
        padding: const EdgeInsets.all(14),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 160,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.15,
        ),
        itemCount: tools.length,
        itemBuilder: (_, i) {
          final t = tools[i];
          return Material(
            color: dark ? const Color(0xFF1E1E26) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _open(t),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: dark ? const Color(0xFF333A45) : const Color(0xFFEDEFF5)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(t.icon,
                        size: 28,
                        color: const Color(0xFF2B7BFF)),
                    const SizedBox(height: 8),
                    Text(t.name,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
