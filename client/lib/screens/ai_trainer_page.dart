import 'package:flutter/material.dart';
import '../services/account_service.dart';

/// AI 训练师：通过「问答样本 / 规则 / 知识库」训练 AI 的回答风格与知识。
class AiTrainerPage extends StatefulWidget {
  const AiTrainerPage({super.key});
  @override
  State<AiTrainerPage> createState() => _AiTrainerPageState();
}

class _AiTrainerPageState extends State<AiTrainerPage> {
  String _kind = 'train';
  List _items = [];
  bool _busy = false;

  static const _tabs = <List<String>>[
    ['train', '问答样本', '问题=>回答'],
    ['rule', '规则', '必须遵守的规则，如：回答不超过50字'],
    ['kb', '知识库', '要记住的知识，如：本店营业时间9-21点'],
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _label => _tabs.firstWhere((t) => t[0] == _kind)[1];
  String get _hint => _tabs.firstWhere((t) => t[0] == _kind)[2];

  Future<void> _load() async {
    final d = await AccountService.aiUserData(_kind, 'list');
    if (!mounted) return;
    setState(() => _items = (d['items'] as List?) ?? []);
  }

  Future<void> _add() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (x) => AlertDialog(
        title: Text('添加$_label'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(hintText: _hint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(x), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(x, c.text.trim()),
              child: const Text('添加')),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    setState(() => _busy = true);
    final d = await AccountService.aiUserData(_kind, 'add', text: text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (d['ok'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${d['error'] ?? '添加失败'}')));
      return;
    }
    _load();
  }

  Future<void> _del(String id) async {
    await AccountService.aiUserData(_kind, 'del', id: id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 训练师')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: _tabs
                  .map((t) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(t[1]),
                          selected: _kind == t[0],
                          onSelected: (_) {
                            setState(() => _kind = t[0]);
                            _load();
                          },
                        ),
                      ))
                  .toList(),
            ),
          ),
          Expanded(
            child: _items.isEmpty
                ? const Center(
                    child: Text('还没有训练数据\n点右下角 + 添加',
                        textAlign: TextAlign.center))
                : ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final it = _items[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                            _kind == 'train'
                                ? Icons.question_answer_outlined
                                : _kind == 'rule'
                                    ? Icons.rule
                                    : Icons.menu_book_outlined),
                        title: Text('${it['text']}'),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _del('${it['id']}'),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '提示：问答样本写成「问题=>回答」，AI 会照这个风格回答；规则优先级最高，知识库用于补充事实。',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color),
            ),
          ),
        ],
      ),
      floatingActionButton: _busy
          ? null
          : FloatingActionButton(
              onPressed: _add, child: const Icon(Icons.add)),
    );
  }
}
