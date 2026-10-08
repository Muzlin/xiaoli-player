import 'package:flutter/material.dart';
import '../services/account_service.dart';

/// 创作 AI 助手：调用服务端 AI 接口(默认本机 Ollama)，按账号计费 token，
/// 每月额度(默认 10 万)用完即不可用。
class AiPage extends StatefulWidget {
  const AiPage({super.key});
  @override
  State<AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<AiPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, String>> _msgs = []; // {role, content}
  bool _busy = false;
  int _used = 0, _limit = 100000;
  String _model = '';
  bool _enabled = true;
  String? _err;

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
      _limit = (d['limit'] as num?)?.toInt() ?? 100000;
      _model = '${d['model'] ?? ''}';
      _enabled = d['enabled'] != false;
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    if (_used >= _limit) return;
    setState(() {
      _msgs.add({'role': 'user', 'content': text});
      _busy = true;
      _err = null;
      _input.clear();
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
    } else {
      setState(() => _err = '${d['error'] ?? 'AI 请求失败'}');
    }
    _jump();
  }

  void _jump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final remaining = (_limit - _used).clamp(0, _limit);
    return Scaffold(
      appBar: AppBar(
        title: const Text('创作 AI 助手'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text('剩余 $remaining / $_limit',
                  style: TextStyle(
                      fontSize: 12,
                      color: remaining > 0 ? cs.primary : Colors.red)),
            ),
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
              child: const Text('创作 AI 助手已被管理员关闭'),
            ),
          if (remaining <= 0)
            Container(
              width: double.infinity,
              color: Colors.red.shade50,
              padding: const EdgeInsets.all(10),
              child: const Text('本月 AI 额度已用完，下月 1 号重置'),
            ),
          Expanded(
            child: _msgs.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.auto_awesome, size: 56, color: cs.primary),
                          const SizedBox(height: 12),
                          Text(_model.isEmpty ? '创作 AI 助手' : '模型：$_model',
                              style: const TextStyle(color: Colors.black54)),
                          const SizedBox(height: 6),
                          const Text('可以帮你写标题、简介、脚本、文案…',
                              style:
                                  TextStyle(fontSize: 12, color: Colors.black38)),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _msgs.length,
                    itemBuilder: (_, i) {
                      final m = _msgs[i];
                      final me = m['role'] == 'user';
                      return Align(
                        alignment:
                            me ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.78),
                          decoration: BoxDecoration(
                            color: me ? cs.primary : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: me
                                ? null
                                : Border.all(color: Colors.black12),
                          ),
                          child: SelectableText(
                            m['content'] ?? '',
                            style: TextStyle(
                                color: me ? Colors.white : Colors.black87,
                                fontSize: 14,
                                height: 1.5),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_err != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_err!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      enabled: _enabled && remaining > 0 && !_busy,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: remaining > 0 ? '输入问题，例如：帮我想 5 个视频标题' : '额度已用完',
                        isDense: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 44,
                    child: FilledButton(
                      onPressed:
                          (_busy || !_enabled || remaining <= 0) ? null : _send,
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Text('发送'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
