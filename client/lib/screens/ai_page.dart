import 'dart:convert';
import 'dart:io';
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
      widget.onAction?.call(action, params);
    }
    _jump();
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
