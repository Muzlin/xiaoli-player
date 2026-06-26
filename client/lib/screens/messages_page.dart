import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/platform_service.dart';

/// 把文本里的网址变成可点链接(在 app 内/外部浏览器打开)。
final _urlRe = RegExp(r'(https?://[^\s]+)');
Widget _linkifyText(String text, Color color) {
  if (!_urlRe.hasMatch(text)) {
    return Text(text, style: TextStyle(color: color));
  }
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _urlRe.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    final url = m.group(0)!;
    spans.add(TextSpan(
      text: url,
      style: const TextStyle(
          decoration: TextDecoration.underline, fontWeight: FontWeight.w600),
      recognizer: TapGestureRecognizer()
        ..onTap = () {
          final uri = Uri.tryParse(url);
          if (uri != null) {
            launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
    ));
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return Text.rich(TextSpan(style: TextStyle(color: color), children: spans));
}

/// 会话置顶 / 消息免打扰（纯本地 prefs）。key=对方uid或群gid。
class _ChatPrefs {
  static Set<String> pinned = {};
  static Set<String> muted = {};
  static bool _loaded = false;

  static Future<void> ensure() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    pinned = (p.getStringList('chat_pinned') ?? []).toSet();
    muted = (p.getStringList('chat_muted') ?? []).toSet();
    _loaded = true;
  }

  static Future<void> togglePin(String k) async {
    final p = await SharedPreferences.getInstance();
    pinned.contains(k) ? pinned.remove(k) : pinned.add(k);
    await p.setStringList('chat_pinned', pinned.toList());
  }

  static Future<void> toggleMute(String k) async {
    final p = await SharedPreferences.getInstance();
    muted.contains(k) ? muted.remove(k) : muted.add(k);
    await p.setStringList('chat_muted', muted.toList());
  }

  /// 置顶的排前面（保持各自原顺序）。
  static List<Map<String, dynamic>> sort(
      List<Map<String, dynamic>> list, String Function(Map<String, dynamic>) key) {
    final pin = list.where((c) => pinned.contains(key(c))).toList();
    final rest = list.where((c) => !pinned.contains(key(c))).toList();
    return [...pin, ...rest];
  }
}

/// 消息中心：私信 + 群聊。onPlayVideo 用于点开"推荐视频"卡片直接播。
class MessagesPage extends StatefulWidget {
  final void Function(String id, String title) onPlayVideo;
  const MessagesPage({super.key, required this.onPlayVideo});
  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('消息'),
          actions: [
            IconButton(
              icon: const Icon(Icons.camera_outlined),
              tooltip: '朋友圈',
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) =>
                          MomentsPage(onPlayVideo: widget.onPlayVideo))),
            ),
            IconButton(
              icon: const Icon(Icons.smart_toy_outlined),
              tooltip: '机器人',
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const BotPage())),
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (v) async {
                if (v == 'test') {
                  final nowTest = await PlatformService.onTestAccount();
                  await PlatformService.switchTestAccount();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(nowTest
                            ? '已切回主账号'
                            : '已切到测试账号（再点一次切回）')));
                    Navigator.of(context).pop();
                  }
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'test', child: Text('切换测试账号')),
              ],
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: '私信', icon: Icon(Icons.chat_bubble_outline)),
            Tab(text: '群聊', icon: Icon(Icons.groups_outlined)),
          ]),
        ),
        body: TabBarView(children: [
          _DmTab(onPlayVideo: widget.onPlayVideo),
          _GroupTab(onPlayVideo: widget.onPlayVideo),
        ]),
      ),
    );
  }
}

// ============ 私信 ============
class _DmTab extends StatefulWidget {
  final void Function(String id, String title) onPlayVideo;
  const _DmTab({required this.onPlayVideo});
  @override
  State<_DmTab> createState() => _DmTabState();
}

class _DmTabState extends State<_DmTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _convs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _ChatPrefs.ensure();
    final c = await PlatformService.dmList();
    if (mounted) setState(() {
      _convs = _ChatPrefs.sort(c, (x) => '${x['peer']}');
      _loading = false;
    });
  }

  Future<void> _convMenu(String key) async {
    final pinned = _ChatPrefs.pinned.contains(key);
    final muted = _ChatPrefs.muted.contains(key);
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(pinned ? '取消置顶' : '置顶会话'),
              onTap: () => Navigator.pop(context, 'pin')),
          ListTile(
              leading: Icon(
                  muted ? Icons.notifications_off : Icons.notifications_off_outlined),
              title: Text(muted ? '取消免打扰' : '消息免打扰'),
              onTap: () => Navigator.pop(context, 'mute')),
        ]),
      ),
    );
    if (v == 'pin') await _ChatPrefs.togglePin(key);
    if (v == 'mute') await _ChatPrefs.toggleMute(key);
    _load();
  }

  Future<void> _newChat() async {
    final picked = await _pickUser(context);
    if (picked == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _ChatPage(
        peer: picked['uid'] as String,
        peerNick: picked['nick'] as String,
        onPlayVideo: widget.onPlayVideo,
      ),
    ));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: _newChat,
        tooltip: '发起私信',
        child: const Icon(Icons.edit),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _convs.isEmpty
              ? const Center(
                  child: Text('还没有私信，点右下角找人聊~',
                      style: TextStyle(color: Colors.black38)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _convs.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final c = _convs[i];
                      final key = '${c['peer']}';
                      final pinned = _ChatPrefs.pinned.contains(key);
                      final muted = _ChatPrefs.muted.contains(key);
                      return ListTile(
                        tileColor:
                            pinned ? const Color(0x0A000000) : null,
                        leading: const CircleAvatar(
                            child: Icon(Icons.person)),
                        title: Row(children: [
                          Flexible(child: Text('${c['peer_nick'] ?? ''}')),
                          if (muted)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Icon(Icons.notifications_off,
                                  size: 14, color: Colors.black38),
                            ),
                        ]),
                        subtitle: Text('${c['last'] ?? ''}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: pinned
                            ? const Icon(Icons.push_pin,
                                size: 14, color: Colors.black38)
                            : null,
                        onLongPress: () => _convMenu(key),
                        onTap: () async {
                          await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                  builder: (_) => _ChatPage(
                                        peer: c['peer'] as String,
                                        peerNick: '${c['peer_nick'] ?? ''}',
                                        onPlayVideo: widget.onPlayVideo,
                                      )));
                          _load();
                        },
                      );
                    },
                  ),
                ),
    );
  }
}

// ============ 群聊列表 ============
class _GroupTab extends StatefulWidget {
  final void Function(String id, String title) onPlayVideo;
  const _GroupTab({required this.onPlayVideo});
  @override
  State<_GroupTab> createState() => _GroupTabState();
}

class _GroupTabState extends State<_GroupTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _groups = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _ChatPrefs.ensure();
    final g = await PlatformService.groupList();
    if (mounted) setState(() {
      _groups = _ChatPrefs.sort(g, (x) => '${x['gid']}');
      _loading = false;
    });
  }

  Future<void> _groupMenu(String key) async {
    final pinned = _ChatPrefs.pinned.contains(key);
    final muted = _ChatPrefs.muted.contains(key);
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(pinned ? '取消置顶' : '置顶群聊'),
              onTap: () => Navigator.pop(context, 'pin')),
          ListTile(
              leading: Icon(muted
                  ? Icons.notifications_off
                  : Icons.notifications_off_outlined),
              title: Text(muted ? '取消免打扰' : '消息免打扰'),
              onTap: () => Navigator.pop(context, 'mute')),
        ]),
      ),
    );
    if (v == 'pin') await _ChatPrefs.togglePin(key);
    if (v == 'mute') await _ChatPrefs.toggleMute(key);
    _load();
  }

  Future<void> _createGroup() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('建群'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(hintText: '群名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('创建')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty) return;
    final d = await PlatformService.groupCreate(name);
    if (d != null && d['ok'] == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: _createGroup,
        tooltip: '建群',
        child: const Icon(Icons.group_add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _groups.isEmpty
              ? const Center(
                  child: Text('还没有群，点右下角建一个~',
                      style: TextStyle(color: Colors.black38)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _groups.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final g = _groups[i];
                      final role = '${g['role']}';
                      final key = '${g['gid']}';
                      final pinned = _ChatPrefs.pinned.contains(key);
                      final muted = _ChatPrefs.muted.contains(key);
                      return ListTile(
                        tileColor:
                            pinned ? const Color(0x0A000000) : null,
                        leading: const CircleAvatar(
                            child: Icon(Icons.groups)),
                        title: Row(children: [
                          Flexible(child: Text('${g['name'] ?? ''}')),
                          if (muted)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Icon(Icons.notifications_off,
                                  size: 14, color: Colors.black38),
                            ),
                        ]),
                        subtitle: Text(
                            '${g['count']} 人${role == 'owner' ? ' · 群主' : role == 'admin' ? ' · 管理' : ''}${g['no_leave'] == true ? ' · 禁退' : ''}'),
                        trailing: pinned
                            ? const Icon(Icons.push_pin,
                                size: 14, color: Colors.black38)
                            : null,
                        onLongPress: () => _groupMenu(key),
                        onTap: () async {
                          await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                  builder: (_) => _GroupChatPage(
                                        gid: g['gid'] as String,
                                        onPlayVideo: widget.onPlayVideo,
                                      )));
                          _load();
                        },
                      );
                    },
                  ),
                ),
    );
  }
}

// ============ 私信聊天 ============
class _ChatPage extends StatefulWidget {
  final String peer;
  final String peerNick;
  final void Function(String id, String title) onPlayVideo;
  const _ChatPage(
      {required this.peer, required this.peerNick, required this.onPlayVideo});
  @override
  State<_ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<_ChatPage> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _msgs = [];
  String? _myUid;

  @override
  void initState() {
    super.initState();
    PlatformService.walletUid()
        .then((u) => mounted ? setState(() => _myUid = u) : null);
    _load();
  }

  Future<void> _load() async {
    final d = await PlatformService.dmMsgs(widget.peer);
    if (d != null && mounted) {
      setState(() => _msgs = ((d['msgs'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList());
    }
  }

  Future<void> _send() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    _ctrl.clear();
    final ok = await PlatformService.dmSend(widget.peer, text: t);
    if (ok) _load();
  }

  Future<void> _recommend() async {
    final v = await _pickVideo(context);
    if (v == null) return;
    final ok = await PlatformService.dmSend(widget.peer,
        vid: v['id'] as String, title: v['title'] as String);
    if (ok) _load();
  }

  // 在私聊里发红包（=转账 + 一条🧧消息，对方余额到账）。
  Future<void> _redpacket() async {
    var amount = 8;
    final msgCtrl = TextEditingController(text: '恭喜发财，大吉大利');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFFC0392B),
          title: const Text('🧧 发红包', style: TextStyle(color: Color(0xFFFFE2A8))),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 8, children: [
              for (final a in [6, 8, 18, 66, 88])
                ChoiceChip(
                  label: Text('$a'),
                  selected: amount == a,
                  selectedColor: const Color(0xFFFFD24A),
                  onSelected: (_) => setD(() => amount = a),
                ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: msgCtrl,
              maxLength: 40,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: '写句祝福…',
                hintStyle: TextStyle(color: Colors.white54),
                counterStyle: TextStyle(color: Colors.white54),
              ),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child:
                    const Text('取消', style: TextStyle(color: Colors.white70))),
            FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFFD24A),
                    foregroundColor: const Color(0xFF7A1F18)),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('塞钱进红包')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final d = await PlatformService.transfer(widget.peer, amount);
    if (!mounted) return;
    if (d == null) {
      _snack(context, '发红包失败，请检查网络');
    } else if (d['ok'] == true) {
      _snack(context, '🧧 红包已发出！-$amount 币');
      await PlatformService.dmSend(widget.peer,
          text: '[🧧红包] ${msgCtrl.text.trim()}（$amount 币已到账）');
      _load();
    } else {
      _snack(context, '${d['error'] ?? '发红包失败'}');
    }
  }

  Future<void> _sendCard() async {
    final picked = await _pickUser(context);
    if (picked == null) return;
    final ok =
        await PlatformService.dmSend(widget.peer, card: picked['uid'] as String);
    if (ok) _load();
  }

  void _openCard(String uid, String nick) {
    if (uid.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _ChatPage(
          peer: uid, peerNick: nick, onPlayVideo: widget.onPlayVideo),
    ));
  }

  Future<void> _transfer() async {
    final amt = await _askAmount(context, '转账给 ${widget.peerNick}');
    if (amt == null || amt <= 0) return;
    final d = await PlatformService.transfer(widget.peer, amt);
    if (!mounted) return;
    if (d == null) {
      _snack(context, '转账失败，请检查网络');
    } else if (d['ok'] == true) {
      _snack(context, '已转 $amt 兑换币（余额 ${d['balance']}）');
      await PlatformService.dmSend(widget.peer,
          text: '[转账] 给你转了 $amt 兑换币 💰');
      _load();
    } else {
      _snack(context, '${d['error'] ?? '转账失败'}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
          title: Text(widget.peerNick),
          backgroundColor: const Color(0xFFEDEDED),
          foregroundColor: Colors.black87,
          elevation: 0),
      body: Column(children: [
        Expanded(
            child: _MsgList(
                msgs: _msgs,
                myUid: _myUid,
                onPlayVideo: widget.onPlayVideo,
                onCard: _openCard)),
        _ChatInput(
            controller: _ctrl,
            onSend: _send,
            onRecommend: _recommend,
            onTransfer: _transfer,
            onRedpacket: _redpacket,
            onCard: _sendCard),
      ]),
    );
  }
}

void _snack(BuildContext context, String m) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
}

/// 输入金额对话框。返回正整数或 null。
Future<int?> _askAmount(BuildContext context, String title) async {
  final ctrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
            labelText: '兑换币金额', prefixIcon: Icon(Icons.paid)),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定')),
      ],
    ),
  );
  if (ok != true) return null;
  return int.tryParse(ctrl.text.trim());
}

// ============ 群聊天 ============
class _GroupChatPage extends StatefulWidget {
  final String gid;
  final void Function(String id, String title) onPlayVideo;
  const _GroupChatPage({required this.gid, required this.onPlayVideo});
  @override
  State<_GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<_GroupChatPage> {
  final _ctrl = TextEditingController();
  Map<String, dynamic> _info = {};
  List<Map<String, dynamic>> _msgs = [];
  String? _myUid;

  @override
  void initState() {
    super.initState();
    PlatformService.walletUid()
        .then((u) => mounted ? setState(() => _myUid = u) : null);
    _load();
  }

  Future<void> _load() async {
    final d = await PlatformService.groupMsgs(widget.gid);
    if (d != null && d['ok'] == true && mounted) {
      setState(() {
        _info = d;
        _msgs = ((d['msgs'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      });
    } else if (d != null && d['ok'] != true && mounted) {
      // 被踢/解散
      Navigator.of(context).pop();
    }
  }

  Future<void> _send() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    _ctrl.clear();
    if (await PlatformService.groupSend(widget.gid, text: t)) _load();
  }

  Future<void> _recommend() async {
    final v = await _pickVideo(context);
    if (v == null) return;
    if (await PlatformService.groupSend(widget.gid,
        vid: v['id'] as String, title: v['title'] as String)) _load();
  }

  Future<void> _sendCard() async {
    final picked = await _pickUser(context);
    if (picked == null) return;
    final ok =
        await PlatformService.groupSend(widget.gid, card: picked['uid'] as String);
    if (ok) _load();
  }

  void _openCard(String uid, String nick) {
    if (uid.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _ChatPage(
          peer: uid, peerNick: nick, onPlayVideo: widget.onPlayVideo),
    ));
  }

  // 群聊转账：选一位群成员转账。
  Future<void> _transfer() async {
    final picked = await _pickUser(context);
    if (picked == null || !mounted) return;
    final to = picked['uid'] as String;
    final nick = '${picked['nick'] ?? ''}';
    final amt = await _askAmount(context, '转账给 $nick');
    if (amt == null || amt <= 0) return;
    final d = await PlatformService.transfer(to, amt);
    if (!mounted) return;
    if (d == null) {
      _snack(context, '转账失败，请检查网络');
    } else if (d['ok'] == true) {
      _snack(context, '已转 $amt 兑换币给 $nick');
      await PlatformService.groupSend(widget.gid,
          text: '[转账] 给 $nick 转了 $amt 兑换币 💰');
      _load();
    } else {
      _snack(context, '${d['error'] ?? '转账失败'}');
    }
  }

  String get _myRole {
    if (_info['owner'] == _myUid) return 'owner';
    if (((_info['admins'] as List?) ?? []).contains(_myUid)) return 'admin';
    return 'member';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        title: Text('${_info['name'] ?? '群聊'}'),
        backgroundColor: const Color(0xFFEDEDED),
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.manage_accounts),
            tooltip: '群管理',
            onPressed: () => _openManage(),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
            child: _MsgList(
                msgs: _msgs,
                myUid: _myUid,
                group: true,
                onPlayVideo: widget.onPlayVideo,
                onCard: _openCard)),
        _ChatInput(
            controller: _ctrl,
            onSend: _send,
            onRecommend: _recommend,
            onTransfer: _transfer,
            onCard: _sendCard),
      ]),
    );
  }

  void _openManage() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _GroupManageSheet(
        gid: widget.gid,
        info: _info,
        myUid: _myUid,
        myRole: _myRole,
        onChanged: () {
          Navigator.pop(context);
          _load();
        },
        onLeftOrDisbanded: () {
          Navigator.pop(context); // sheet
          Navigator.pop(context); // chat
        },
      ),
    );
  }
}

// ============ 群管理面板 ============
class _GroupManageSheet extends StatefulWidget {
  final String gid;
  final Map<String, dynamic> info;
  final String? myUid;
  final String myRole;
  final VoidCallback onChanged;
  final VoidCallback onLeftOrDisbanded;
  const _GroupManageSheet(
      {required this.gid,
      required this.info,
      required this.myUid,
      required this.myRole,
      required this.onChanged,
      required this.onLeftOrDisbanded});
  @override
  State<_GroupManageSheet> createState() => _GroupManageSheetState();
}

class _GroupManageSheetState extends State<_GroupManageSheet> {
  bool _busy = false;

  Future<void> _op(String op, {String target = '', bool on = true}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final d = await PlatformService.groupOp(widget.gid, op,
        target: target, on: on);
    setState(() => _busy = false);
    if (!mounted) return;
    if (d == null) {
      _toast('操作失败，请检查网络');
      return;
    }
    if (d['ok'] == true) {
      if (op == 'disband' || op == 'leave') {
        widget.onLeftOrDisbanded();
      } else {
        widget.onChanged();
      }
    } else {
      _toast('${d['error'] ?? '操作失败'}');
    }
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _rename() async {
    final ctrl =
        TextEditingController(text: '${widget.info['name'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改群名'),
        content: TextField(
            controller: ctrl, autofocus: true, maxLength: 30),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty) return;
    setState(() => _busy = true);
    final d = await PlatformService.groupOp(widget.gid, 'rename', name: name);
    if (!mounted) return;
    setState(() => _busy = false);
    if (d != null && d['ok'] == true) {
      widget.onChanged();
    } else {
      _toast('${d?['error'] ?? '改名失败'}');
    }
  }

  Future<void> _invite() async {
    if (_busy) return;
    final picked = await _pickUser(context);
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    final ok =
        await PlatformService.groupInvite(widget.gid, picked['uid'] as String);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      widget.onChanged();
    } else {
      _toast('邀请失败（群可能已满或对方被封禁）');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final owner = '${widget.info['owner']}';
    final admins = ((widget.info['admins'] as List?) ?? []).cast<dynamic>();
    final members =
        ((widget.info['members'] as List?) ?? []).cast<dynamic>();
    final isOwner = widget.myRole == 'owner';
    final isAdmin = widget.myRole == 'owner' || widget.myRole == 'admin';
    final noLeave = widget.info['no_leave'] == true;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, sc) => ListView(
        controller: sc,
        children: [
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text('群管理',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          if (isAdmin)
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('修改群名'),
              subtitle: Text('${widget.info['name'] ?? ''}'),
              onTap: _busy ? null : _rename,
            ),
          if (isOwner)
            SwitchListTile(
              title: const Text('禁止成员退群'),
              subtitle: const Text('开启后普通成员无法主动退群'),
              value: noLeave,
              onChanged: _busy ? null : (v) => _op('noleave', on: v),
            ),
          ListTile(
            leading: const Icon(Icons.person_add),
            title: const Text('邀请成员'),
            onTap: _invite,
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Text('成员（${members.length}）',
                style: const TextStyle(color: Colors.black54)),
          ),
          for (final m in members)
            _MemberRow(
              uid: '$m',
              isOwnerRow: '$m' == owner,
              isAdminRow: admins.contains(m),
              meIsOwner: isOwner,
              meIsAdmin: isAdmin,
              isSelf: '$m' == widget.myUid,
              busy: _busy,
              accent: cs.primary,
              onSetAdmin: (on) => _op('admin', target: '$m', on: on),
              onKick: () => _op('kick', target: '$m'),
            ),
          const Divider(),
          if (isOwner)
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text('解散群',
                  style: TextStyle(color: Colors.red)),
              onTap: _busy
                  ? null
                  : () async {
                      final ok = await _confirm(context, '解散群', '解散后群聊和消息都会删除，不可恢复。');
                      if (ok) _op('disband');
                    },
            )
          else
            ListTile(
              leading: const Icon(Icons.exit_to_app),
              title: Text(noLeave ? '退群（群主已禁止）' : '退出群聊'),
              enabled: !noLeave && !_busy,
              onTap: () => _op('leave'),
            ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  final String uid;
  final bool isOwnerRow, isAdminRow, meIsOwner, meIsAdmin, isSelf, busy;
  final Color accent;
  final void Function(bool on) onSetAdmin;
  final VoidCallback onKick;
  const _MemberRow(
      {required this.uid,
      required this.isOwnerRow,
      required this.isAdminRow,
      required this.meIsOwner,
      required this.meIsAdmin,
      required this.isSelf,
      required this.busy,
      required this.accent,
      required this.onSetAdmin,
      required this.onKick});

  @override
  Widget build(BuildContext context) {
    final tag = isOwnerRow
        ? '群主'
        : isAdminRow
            ? '管理'
            : '';
    // 群主可设/撤管理、踢任何非群主；管理可踢普通成员。
    final canKick = !isOwnerRow &&
        !isSelf &&
        (meIsOwner || (meIsAdmin && !isAdminRow));
    return ListTile(
      dense: true,
      leading: CircleAvatar(
          radius: 16,
          backgroundColor: isOwnerRow ? accent : Colors.black12,
          child: Icon(Icons.person,
              size: 18,
              color: isOwnerRow ? Colors.white : Colors.black45)),
      title: Text('…${uid.length > 6 ? uid.substring(uid.length - 6) : uid}'),
      subtitle: tag.isEmpty ? null : Text(tag),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (meIsOwner && !isOwnerRow)
          TextButton(
            onPressed: busy ? null : () => onSetAdmin(!isAdminRow),
            child: Text(isAdminRow ? '撤管理' : '设管理'),
          ),
        if (canKick)
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
            tooltip: '踢出',
            onPressed: busy ? null : onKick,
          ),
      ]),
    );
  }
}

// ============ 共用：消息列表 / 输入栏 / 选人 / 选视频 ============
class _MsgList extends StatelessWidget {
  final List<Map<String, dynamic>> msgs;
  final String? myUid;
  final bool group;
  final void Function(String id, String title) onPlayVideo;
  final void Function(String uid, String nick)? onCard;
  const _MsgList(
      {required this.msgs,
      required this.myUid,
      required this.onPlayVideo,
      this.onCard,
      this.group = false});

  @override
  Widget build(BuildContext context) {
    if (msgs.isEmpty) {
      return const Center(
          child: Text('还没有消息，发一条吧~',
              style: TextStyle(color: Colors.black38)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: msgs.length,
      itemBuilder: (_, i) {
        final m = msgs[i];
        final mine = m['from'] == myUid;
        final isVideo = m['kind'] == 'video';
        final isCard = m['kind'] == 'card';
        final bubble = isCard
            ? InkWell(
                onTap: () => onCard?.call(
                    '${m['card']}', '${m['card_nick'] ?? ''}'),
                child: Container(
                  width: 210,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [
                    const CircleAvatar(
                        radius: 20,
                        backgroundColor: Color(0xFF07C160),
                        child: Icon(Icons.contact_page,
                            color: Colors.white, size: 22)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('${m['card_nick'] ?? ''}',
                              style: const TextStyle(
                                  color: Colors.black87,
                                  fontWeight: FontWeight.w600)),
                          const Text('个人名片',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.black45)),
                        ])),
                  ]),
                ),
              )
            : isVideo
            ? InkWell(
                onTap: () => onPlayVideo(
                    '${m['vid']}', '${m['title'] ?? '推荐视频'}'),
                child: Container(
                  width: 210,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: mine ? const Color(0xFF95EC69) : Colors.white,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(children: [
                    const Icon(Icons.play_circle_fill,
                        color: Color(0xFF07C160), size: 30),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('推荐视频',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.black45)),
                            Text('${m['title'] ?? ''}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.black87)),
                          ]),
                    ),
                  ]),
                ),
              )
            : Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  // 微信风：自己=嫩绿，对方=白
                  color: mine ? const Color(0xFF95EC69) : Colors.white,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: _linkifyText('${m['text'] ?? ''}', Colors.black87),
              );
        // 微信风：对方头像在左、自己头像在右，气泡贴着头像。
        final avatar = CircleAvatar(
          radius: 18,
          backgroundColor: mine ? const Color(0xFF07C160) : Colors.black26,
          child: Icon(mine ? Icons.person : Icons.person_outline,
              size: 20, color: Colors.white),
        );
        final bubbleCol = Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (group && !mine)
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 2),
                child: Text('${m['from_nick'] ?? ''}',
                    style:
                        const TextStyle(fontSize: 11, color: Colors.black45)),
              ),
            ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.64),
                child: bubble),
          ],
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment:
                mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: mine
                ? [Flexible(child: bubbleCol), const SizedBox(width: 8), avatar]
                : [avatar, const SizedBox(width: 8), Flexible(child: bubbleCol)],
          ),
        );
      },
    );
  }
}

class _ChatInput extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onRecommend;
  final VoidCallback? onTransfer; // 私聊才有转账
  final VoidCallback? onRedpacket; // 私聊才有发红包
  final VoidCallback? onCard; // 发个人名片
  const _ChatInput(
      {required this.controller,
      required this.onSend,
      required this.onRecommend,
      this.onTransfer,
      this.onRedpacket,
      this.onCard});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF7F7F7), // 微信输入栏底色
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.video_library_outlined,
                  color: Colors.black54),
              tooltip: '推荐视频',
              onPressed: onRecommend,
            ),
            if (onTransfer != null)
              IconButton(
                icon: const Icon(Icons.paid_outlined, color: Colors.black54),
                tooltip: '转账兑换币',
                onPressed: onTransfer,
              ),
            if (onRedpacket != null)
              IconButton(
                icon: const Text('🧧', style: TextStyle(fontSize: 20)),
                tooltip: '发红包',
                onPressed: onRedpacket,
              ),
            if (onCard != null)
              IconButton(
                icon: const Icon(Icons.contact_page_outlined,
                    color: Colors.black54),
                tooltip: '发名片',
                onPressed: onCard,
              ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: '说点什么…',
                  filled: true,
                  fillColor: Colors.white,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 6),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF07C160),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  minimumSize: const Size(0, 40)),
              onPressed: onSend,
              child: const Text('发送'),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 选人（通讯录）。返回 {uid,nick} 或 null。
Future<Map<String, dynamic>?> _pickUser(BuildContext context) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _UserPicker(),
  );
}

class _UserPicker extends StatefulWidget {
  const _UserPicker();
  @override
  State<_UserPicker> createState() => _UserPickerState();
}

class _UserPickerState extends State<_UserPicker> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  Future<void> _load(String q) async {
    final u = await PlatformService.users(q: q);
    if (mounted) setState(() {
      _users = u;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (_, sc) => Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '搜索昵称…',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: _load,
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _users.isEmpty
                  ? const Center(
                      child: Text('没有找到用户（对方需先设昵称）',
                          style: TextStyle(color: Colors.black38)))
                  : ListView.builder(
                      controller: sc,
                      itemCount: _users.length,
                      itemBuilder: (_, i) {
                        final u = _users[i];
                        return ListTile(
                          leading:
                              const CircleAvatar(child: Icon(Icons.person)),
                          title: Text('${u['nick'] ?? ''}'),
                          onTap: () => Navigator.pop(context, u),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}

/// 选视频（推荐用）。返回 {id,title} 或 null。
Future<Map<String, dynamic>?> _pickVideo(BuildContext context) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _VideoPicker(),
  );
}

class _VideoPicker extends StatefulWidget {
  const _VideoPicker();
  @override
  State<_VideoPicker> createState() => _VideoPickerState();
}

class _VideoPickerState extends State<_VideoPicker> {
  List<PlatformVideo> _all = [];
  String _q = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    PlatformService().list().then((v) {
      if (mounted) setState(() {
        _all = v;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = _q.isEmpty
        ? _all
        : _all
            .where((v) => v.title.toLowerCase().contains(_q.toLowerCase()))
            .toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (_, sc) => Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '搜索要推荐的平台视频…',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: sc,
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final v = list[i];
                    return ListTile(
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(v.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${v.uploader} · ▶ ${v.views}'),
                      onTap: () =>
                          Navigator.pop(context, {'id': v.id, 'title': v.title}),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String body) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定')),
      ],
    ),
  );
  return r == true;
}

// ============ 朋友圈(动态) ============
class MomentsPage extends StatefulWidget {
  final void Function(String id, String title) onPlayVideo;
  const MomentsPage({super.key, required this.onPlayVideo});
  @override
  State<MomentsPage> createState() => _MomentsPageState();
}

class _MomentsPageState extends State<MomentsPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _list = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await PlatformService.moments();
    if (mounted) setState(() {
      _list = m;
      _loading = false;
    });
  }

  Future<void> _compose() async {
    final ctrl = TextEditingController();
    Map<String, dynamic>? vid;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('发动态'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 4,
                maxLength: 500,
                decoration: const InputDecoration(hintText: '这一刻的想法…')),
            if (vid != null)
              ListTile(
                  dense: true,
                  leading: const Icon(Icons.play_circle, color: Color(0xFFF26B21)),
                  title: Text('${vid!['title']}',
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
            TextButton.icon(
              icon: const Icon(Icons.video_library_outlined, size: 18),
              label: Text(vid == null ? '附带一个视频' : '换个视频'),
              onPressed: () async {
                final v = await _pickVideo(ctx);
                if (v != null) setD(() => vid = v);
              },
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('发布')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final text = ctrl.text.trim();
    if (text.isEmpty && vid == null) return;
    final sent = await PlatformService.momentPost(text,
        vid: vid?['id'] as String? ?? '', title: vid?['title'] as String? ?? '');
    if (sent) _load();
  }

  String _ago(int ts) {
    final d = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ts * 1000));
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes}分钟前';
    if (d.inDays < 1) return '${d.inHours}小时前';
    return '${d.inDays}天前';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('朋友圈')),
      floatingActionButton: FloatingActionButton(
        onPressed: _compose,
        tooltip: '发动态',
        child: const Icon(Icons.add_a_photo_outlined),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _list.isEmpty
              ? const Center(
                  child: Text('还没有动态，发第一条吧~',
                      style: TextStyle(color: Colors.black38)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _MomentTile(
                        m: _list[i],
                        ago: _ago,
                        onPlayVideo: widget.onPlayVideo,
                        onChanged: _load),
                  ),
                ),
    );
  }
}

class _MomentTile extends StatefulWidget {
  final Map<String, dynamic> m;
  final String Function(int) ago;
  final void Function(String id, String title) onPlayVideo;
  final VoidCallback onChanged;
  const _MomentTile(
      {required this.m,
      required this.ago,
      required this.onPlayVideo,
      required this.onChanged});
  @override
  State<_MomentTile> createState() => _MomentTileState();
}

class _MomentTileState extends State<_MomentTile> {
  late bool _liked = widget.m['liked'] == true;
  late int _likes = (widget.m['likes'] as num?)?.toInt() ?? 0;
  late List<dynamic> _comments = (widget.m['comments'] as List?) ?? [];

  Future<void> _like() async {
    final d = await PlatformService.momentLike('${widget.m['id']}');
    if (d != null && d['ok'] == true && mounted) {
      setState(() {
        _liked = d['liked'] == true;
        _likes = (d['likes'] as num).toInt();
      });
    }
  }

  Future<void> _comment() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('评论'),
        content: TextField(controller: ctrl, autofocus: true, maxLength: 200),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('发送')),
        ],
      ),
    );
    if (ok != true) return;
    final t = ctrl.text.trim();
    if (t.isEmpty) return;
    if (await PlatformService.momentComment('${widget.m['id']}', t)) {
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = widget.m;
    final vid = '${m['vid'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
              radius: 18,
              backgroundColor: cs.primary,
              child: const Icon(Icons.person, color: Colors.white, size: 20)),
          const SizedBox(width: 10),
          Text('${m['nick'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(widget.ago((m['ts'] as num?)?.toInt() ?? 0),
              style: const TextStyle(fontSize: 11, color: Colors.black38)),
        ]),
        if ('${m['text'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 46, top: 4),
            child: Text('${m['text']}'),
          ),
        if (vid.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 46, top: 6),
            child: InkWell(
              onTap: () => widget.onPlayVideo(vid, '${m['title'] ?? '视频'}'),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(6)),
                child: Row(children: [
                  Icon(Icons.play_circle_fill, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('${m['title'] ?? '视频'}',
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 40, top: 4),
          child: Row(children: [
            TextButton.icon(
              onPressed: _like,
              icon: Icon(_liked ? Icons.favorite : Icons.favorite_border,
                  size: 18, color: _liked ? Colors.red : Colors.black45),
              label: Text('$_likes',
                  style: const TextStyle(color: Colors.black54)),
            ),
            TextButton.icon(
              onPressed: _comment,
              icon: const Icon(Icons.mode_comment_outlined,
                  size: 18, color: Colors.black45),
              label: Text('${_comments.length}',
                  style: const TextStyle(color: Colors.black54)),
            ),
          ]),
        ),
        if (_comments.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(left: 46),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(6)),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in _comments)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: RichText(
                        text: TextSpan(
                            style: const TextStyle(
                                color: Colors.black87, fontSize: 13),
                            children: [
                              TextSpan(
                                  text: '${c['nick'] ?? ''}：',
                                  style: TextStyle(
                                      color: cs.primary,
                                      fontWeight: FontWeight.w600)),
                              TextSpan(text: '${c['text'] ?? ''}'),
                            ]),
                      ),
                    ),
                ]),
          ),
      ]),
    );
  }
}

// ============ 机器人管理 ============
class BotPage extends StatefulWidget {
  const BotPage({super.key});
  @override
  State<BotPage> createState() => _BotPageState();
}

class _BotPageState extends State<BotPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _bots = [];
  List<Map<String, dynamic>> _groups = [];
  List<Map<String, dynamic>> _users = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = await PlatformService.botList();
    final g = await PlatformService.groupList();
    final u = await PlatformService.users();
    if (mounted) setState(() {
      _bots = b;
      _groups = g;
      _users = u.where((x) => !'${x['uid']}'.startsWith('bot')).toList();
      _loading = false;
    });
  }

  Future<void> _create() async {
    final nameCtrl = TextEditingController();
    final wordCtrl = TextEditingController();
    final textCtrl = TextEditingController(text: '你好呀，我是机器人~');
    final everyCtrl = TextEditingController(text: '0');
    String kind = 'text';
    String? target;
    Map<String, dynamic>? vid;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('创建机器人'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: nameCtrl,
                  maxLength: 20,
                  decoration: const InputDecoration(labelText: '机器人名字')),
              TextField(
                  controller: wordCtrl,
                  maxLength: 40,
                  decoration: const InputDecoration(
                      labelText: '触发词（留空=任何消息都回）')),
              const SizedBox(height: 8),
              Row(children: [
                const Text('回复：'),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: kind,
                  items: const [
                    DropdownMenuItem(value: 'text', child: Text('文字')),
                    DropdownMenuItem(value: 'video', child: Text('视频')),
                    DropdownMenuItem(value: 'coupon', child: Text('送优惠券')),
                  ],
                  onChanged: (v) => setD(() => kind = v ?? 'text'),
                ),
              ]),
              TextField(
                  controller: textCtrl,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: '回复文字')),
              if (kind == 'video')
                TextButton.icon(
                  icon: const Icon(Icons.video_library_outlined, size: 18),
                  label: Text(vid == null ? '选个视频' : '已选：${vid!['title']}'),
                  onPressed: () async {
                    final v = await _pickVideo(ctx);
                    if (v != null) setD(() => vid = v);
                  },
                ),
              const Divider(),
              const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('⏰ 定时发送（选填）',
                      style: TextStyle(fontWeight: FontWeight.w600))),
              TextField(
                  controller: everyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: '每几分钟发一次（0=不定时）')),
              if (_groups.isEmpty && _users.isEmpty)
                const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('（先建群或加联系人，定时机器人发给他们）',
                        style: TextStyle(fontSize: 12, color: Colors.black45)))
              else
                Row(children: [
                  const Text('发给：'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: target,
                      hint: const Text('选群或用户'),
                      items: [
                        for (final g in _groups)
                          DropdownMenuItem(
                              value: g['gid'] as String,
                              child: Text('👥 ${g['name']}',
                                  overflow: TextOverflow.ellipsis)),
                        for (final u in _users)
                          DropdownMenuItem(
                              value: u['uid'] as String,
                              child: Text('👤 ${u['nick']}',
                                  overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (v) => setD(() => target = v),
                    ),
                  ),
                ]),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('创建')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    final every = int.tryParse(everyCtrl.text.trim()) ?? 0;
    final d = await PlatformService.botCreate(
      name: name,
      word: wordCtrl.text.trim(),
      kind: kind,
      text: textCtrl.text.trim(),
      vid: vid?['id'] as String? ?? '',
      title: vid?['title'] as String? ?? '',
      item: kind == 'coupon' ? 'coupon_10' : '',
      scheduleMin: (every > 0 && target != null) ? every : 0,
      target: target ?? '',
    );
    if (d != null && d['ok'] == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的机器人')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.smart_toy_outlined),
        label: const Text('建机器人'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                    '机器人会出现在通讯录里。在「消息→找人」搜机器人名字即可和它聊天，命中触发词就自动回复。',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
              ),
              Expanded(
                child: _bots.isEmpty
                    ? const Center(
                        child: Text('还没有机器人，点下面建一个~',
                            style: TextStyle(color: Colors.black38)))
                    : ListView.separated(
                        itemCount: _bots.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final b = _bots[i];
                          final k = '${b['kind']}';
                          return ListTile(
                            leading: const CircleAvatar(
                                backgroundColor: Color(0xFF07C160),
                                child: Icon(Icons.smart_toy,
                                    color: Colors.white)),
                            title: Text('🤖${b['name']}'),
                            subtitle: Text(
                                '触发词：${(b['word'] as String).isEmpty ? '任何消息' : b['word']} → ${k == 'video' ? '回视频' : k == 'coupon' ? '送券' : '回文字'}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.red),
                              onPressed: () async {
                                if (await PlatformService.botDelete(
                                    '${b['id']}')) _load();
                              },
                            ),
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}
