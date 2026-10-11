import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
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
const _bg = Color(0xFFF7F8FC);
const _userBubble = Color(0xFFDDE9FF);

class _AiPageState extends State<AiPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, String>> _msgs = []; // {role, content}
  bool _busy = false;
  bool _uploading = false;
  String? _attachName;
  String? _attachText;
  int _used = 0, _limit = 10000;
  bool _enabled = true;
  String? _err;

  static const _suggestions = <List<String>>[
    ['🎬', '起 5 个吸引人的视频标题'],
    ['📝', '写一段 60 秒口播脚本'],
    ['🔥', '这条视频怎么上热门？'],
    ['🖼️', '帮我写个封面文案'],
  ];

  @override
  void initState() {
    super.initState();
    _loadUsage();
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
      final acts = d['actions'];
      if (acts is List && widget.onAction != null) {
        for (final a in acts) {
          if (a is Map && a['action'] != null) {
            final params = (a['params'] is Map)
                ? Map<String, dynamic>.from(a['params'] as Map)
                : <String, dynamic>{};
            widget.onAction!('${a['action']}', params);
          }
        }
      }
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
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _avatar(26),
            const SizedBox(width: 8),
            const Text('创作AI助手',
                style: TextStyle(
                    color: Color(0xFF1A1A1A),
                    fontWeight: FontWeight.w600,
                    fontSize: 17)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'AI 生成视频并发布',
            onPressed: _busy ? null : _makeVideo,
            icon: const Icon(Icons.movie_creation_outlined,
                color: Color(0xFF4A5568)),
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
        Center(child: _avatar(64)),
        const SizedBox(height: 16),
        const Center(
          child: Text('Hi，我是小李 AI 助手',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A1A1A))),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            '视频标题 · 简介 · 脚本 · 文案，样样都行',
            style: const TextStyle(fontSize: 13, color: Color(0xFF8A93A6)),
          ),
        ),
        const SizedBox(height: 26),
        ..._suggestions.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _busy ? null : () => _sendText(s[1]),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFEDEFF5)),
                    ),
                    child: Row(
                      children: [
                        Text(s[0], style: const TextStyle(fontSize: 18)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(s[1],
                              style: const TextStyle(
                                  fontSize: 14.5, color: Color(0xFF2A2F3A))),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 18, color: Color(0xFFB8C0CC)),
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
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFEDEFF5)),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _brand1)),
                    SizedBox(width: 8),
                    Text('正在思考…',
                        style: TextStyle(
                            fontSize: 13, color: Color(0xFF8A93A6))),
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
              decoration: const BoxDecoration(
                color: _userBubble,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: SelectableText(m['content'] ?? '',
                  style: const TextStyle(
                      color: Color(0xFF17233D), fontSize: 14.5, height: 1.5)),
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
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                    border: Border.all(color: const Color(0xFFEDEFF5)),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x0A000000),
                          blurRadius: 8,
                          offset: Offset(0, 2)),
                    ],
                  ),
                  child: SelectableText(m['content'] ?? '',
                      style: const TextStyle(
                          color: Color(0xFF1A1F2B),
                          fontSize: 14.5,
                          height: 1.55)),
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
                  color: ok ? const Color(0xFF8A93A6) : Colors.red)),
        ],
      ),
    );
  }

  Widget _inputBar(int remaining) {
    final canSend = _enabled && remaining > 0 && !_busy;
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_attachName != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF3FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.attach_file, size: 16, color: _brand1),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_attachName!,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, color: Color(0xFF2A2F3A))),
                    ),
                    GestureDetector(
                      onTap: () => setState(() {
                        _attachName = null;
                        _attachText = null;
                      }),
                      child: const Icon(Icons.close,
                          size: 16, color: Color(0xFF8A93A6)),
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
                      : const Icon(Icons.add_photo_alternate_outlined,
                          color: Color(0xFF8A93A6)),
                ),
                Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F3F7),
                  borderRadius: BorderRadius.circular(22),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  enabled: _enabled && remaining > 0,
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(fontSize: 15, color: Color(0xFF1A1F2B)),
                  decoration: InputDecoration(
                    hintText: remaining > 0
                        ? '发消息，例如：帮我想 5 个视频标题'
                        : '今日额度已用完',
                    hintStyle: const TextStyle(
                        color: Color(0xFFA6AEBD), fontSize: 14),
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
                  color: canSend ? null : const Color(0xFFDCE0E8),
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
