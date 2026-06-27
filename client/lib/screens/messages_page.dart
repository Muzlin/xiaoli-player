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
    PlatformService.activeChatKey = 'dm:${widget.peer}'; // 正在看，别给这会话弹通知
    PlatformService.walletUid()
        .then((u) => mounted ? setState(() => _myUid = u) : null);
    _load();
  }

  @override
  void dispose() {
    if (PlatformService.activeChatKey == 'dm:${widget.peer}') {
      PlatformService.activeChatKey = null;
    }
    super.dispose();
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
    final d = await PlatformService.chatPacket(
        scope: 'dm',
        target: widget.peer,
        ptype: 'redpacket',
        amount: amount,
        msg: msgCtrl.text.trim());
    if (!mounted) return;
    if (d != null && d['ok'] == true) {
      _snack(context, '🧧 红包已发出，等对方领取');
      _load();
    } else {
      _snack(context, '${d?['error'] ?? '发红包失败'}');
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
    final d = await PlatformService.chatPacket(
        scope: 'dm', target: widget.peer, ptype: 'transfer', amount: amt);
    if (!mounted) return;
    if (d != null && d['ok'] == true) {
      _snack(context, '已发出转账，等对方收款');
      _load();
    } else {
      _snack(context, '${d?['error'] ?? '转账失败'}');
    }
  }

  Future<Map<String, dynamic>?> _grabPacket(String pid) async {
    final d = await PlatformService.packetGrab(pid);
    if (mounted) _load();
    return d;
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
                onCard: _openCard,
                onGrabPacket: _grabPacket,
                onReact: (mid, emoji) async {
                  await PlatformService.msgReact(
                      scope: 'dm', target: widget.peer, mid: mid, emoji: emoji);
                  _load();
                },
                onPat: (m) async {
                  await PlatformService.patUser(
                      scope: 'dm', target: widget.peer);
                  _load();
                })),
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
    PlatformService.activeChatKey = 'grp:${widget.gid}'; // 正在看，别给这群弹通知
    PlatformService.walletUid()
        .then((u) => mounted ? setState(() => _myUid = u) : null);
    _load();
  }

  @override
  void dispose() {
    if (PlatformService.activeChatKey == 'grp:${widget.gid}') {
      PlatformService.activeChatKey = null;
    }
    super.dispose();
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

  // 群里发拼手气红包（成员抢）。
  Future<void> _redpacket() async {
    final totalCtrl = TextEditingController(text: '20');
    final partsCtrl = TextEditingController(text: '5');
    final msgCtrl = TextEditingController(text: '恭喜发财');
    // 群成员（排除自己）用于「专属红包」指定收礼人
    final nickMap = Map<String, dynamic>.from(
        (_info['member_nicks'] as Map?) ?? const {});
    final members = ((_info['members'] as List?) ?? [])
        .map((e) => '$e')
        .where((u) => u.isNotEmpty && u != _myUid)
        .toList();
    String? toUid; // null=拼手气群红包；非空=专属给某人
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          final exclusive = toUid != null;
          return AlertDialog(
            backgroundColor: const Color(0xFFC0392B),
            title: Text(exclusive ? '🧧 专属红包' : '🧧 群红包（拼手气）',
                style: const TextStyle(color: Color(0xFFFFE2A8))),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: totalCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                      labelText: '总额',
                      labelStyle: TextStyle(color: Colors.white70))),
              if (!exclusive)
                TextField(
                    controller: partsCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                        labelText: '个数（多于群人数则可继续抢）',
                        labelStyle: TextStyle(color: Colors.white70))),
              TextField(
                  controller: msgCtrl,
                  maxLength: 40,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                      labelText: '祝福语',
                      labelStyle: TextStyle(color: Colors.white70),
                      counterStyle: TextStyle(color: Colors.white54))),
              const SizedBox(height: 6),
              if (members.isNotEmpty)
                Align(
                    alignment: Alignment.centerLeft,
                    child: DropdownButton<String?>(
                        value: toUid,
                        isExpanded: true,
                        dropdownColor: const Color(0xFF8E2A20),
                        iconEnabledColor: Colors.white70,
                        style: const TextStyle(color: Colors.white),
                        hint: const Text('发给所有人（拼手气）',
                            style: TextStyle(color: Colors.white70)),
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('发给所有人（拼手气）',
                                  style: TextStyle(color: Colors.white))),
                          for (final u in members)
                            DropdownMenuItem<String?>(
                                value: u,
                                child: Text('专属给 ${nickMap[u] ?? u}',
                                    style:
                                        const TextStyle(color: Colors.white))),
                        ],
                        onChanged: (v) => setDlg(() => toUid = v))),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消',
                      style: TextStyle(color: Colors.white70))),
              FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFFD24A),
                      foregroundColor: const Color(0xFF7A1F18)),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(exclusive ? '发专属红包' : '塞钱发群里')),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    final total = int.tryParse(totalCtrl.text.trim()) ?? 0;
    final parts =
        toUid != null ? 1 : (int.tryParse(partsCtrl.text.trim()) ?? 0);
    final d = await PlatformService.chatPacket(
        scope: 'group',
        target: widget.gid,
        ptype: 'redpacket',
        amount: total,
        parts: parts,
        msg: msgCtrl.text.trim(),
        to: toUid ?? '');
    if (!mounted) return;
    if (d != null && d['ok'] == true) {
      _snack(context, toUid != null ? '🧧 专属红包已发' : '🧧 群红包已发，等大家抢');
      _load();
    } else {
      _snack(context, '${d?['error'] ?? '发红包失败'}');
    }
  }

  Future<Map<String, dynamic>?> _grabPacket(String pid) async {
    final d = await PlatformService.packetGrab(pid);
    if (mounted) _load();
    return d;
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
                onCard: _openCard,
                onGrabPacket: _grabPacket,
                onReact: (mid, emoji) async {
                  await PlatformService.msgReact(
                      scope: 'group',
                      target: widget.gid,
                      mid: mid,
                      emoji: emoji);
                  _load();
                },
                onPat: (m) async {
                  await PlatformService.patUser(
                      scope: 'group',
                      target: widget.gid,
                      to: '${m['from'] ?? ''}');
                  _load();
                })),
        _ChatInput(
            controller: _ctrl,
            onSend: _send,
            onRecommend: _recommend,
            onRedpacket: _redpacket,
            onCard: _sendCard,
            myUid: _myUid,
            atMembers: Map<String, String>.from(
                (_info['member_nicks'] as Map?) ?? const {})),
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
  final Future<Map<String, dynamic>?> Function(String pid)? onGrabPacket;
  final void Function(String mid, String emoji)? onReact; // 表情回应
  final void Function(Map<String, dynamic> msg)? onPat; // 拍一拍(双击对方消息)
  const _MsgList(
      {required this.msgs,
      required this.myUid,
      required this.onPlayVideo,
      this.onCard,
      this.onGrabPacket,
      this.onReact,
      this.onPat,
      this.group = false});

  // 长按消息弹表情选择条 → 切换回应。
  void _showReactPicker(BuildContext context, Map<String, dynamic> m) {
    final mid = '${m['mid'] ?? ''}';
    if (mid.isEmpty || onReact == null) return;
    const emojis = ['👍', '❤️', '😂', '😮', '😢', '🎉'];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(28)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            for (final e in emojis)
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                  Navigator.pop(ctx);
                  onReact!(mid, e);
                },
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(e, style: const TextStyle(fontSize: 26)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // 气泡下方的回应 chip 行（emoji + 人数，自己点过则高亮）。
  Widget? _reactionChips(Map<String, dynamic> m) {
    final r = m['reactions'];
    if (r is! Map || r.isEmpty) return null;
    final mid = '${m['mid'] ?? ''}';
    final chips = <Widget>[];
    r.forEach((emoji, who) {
      final list = (who is List) ? who : const [];
      if (list.isEmpty) return;
      final mineIn = myUid != null && list.contains(myUid);
      chips.add(GestureDetector(
        onTap: () => onReact?.call(mid, '$emoji'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: mineIn ? const Color(0xFFD7F0D0) : Colors.white,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
                color: mineIn ? const Color(0xFF07C160) : Colors.black12),
          ),
          child: Text('$emoji ${list.length}',
              style: const TextStyle(fontSize: 12, color: Colors.black87)),
        ),
      ));
    });
    if (chips.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(spacing: 4, runSpacing: 4, children: chips),
    );
  }

  // 微信式红包/转账领取界面：红色封面 + 開/收款按钮 → 揭示金额。
  Future<void> _openPacket(BuildContext context, Map<String, dynamic> m) async {
    final isRed = m['ptype'] == 'redpacket';
    final blessing = '${m['msg'] ?? ''}'.trim().isEmpty
        ? (isRed ? '恭喜发财，大吉大利' : '给你转账')
        : '${m['msg']}';
    final fromNick = '${m['from_nick'] ?? ''}'.trim();
    final pid = '${m['pid'] ?? ''}';
    final claimed = m['_claimed'] == true;
    final done = m['_done'] == true;
    final canMore = m['_canmore'] == true;
    final myAmount = (m['_myamount'] as num?)?.toInt() ?? 0;
    String phase; // cover | opening | revealed | gone
    int amount = myAmount;
    String? errMsg;
    if (claimed && !canMore) {
      phase = 'revealed';
    } else if (done) {
      phase = 'gone';
    } else {
      phase = 'cover';
    }
    const red = Color(0xFFC73A2F);
    const red2 = Color(0xFFB02619);
    const gold = Color(0xFFF6D58A);
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Widget body;
        if (phase == 'opening') {
          body = const SizedBox(
              height: 84,
              child: Center(child: CircularProgressIndicator(color: gold)));
        } else if (phase == 'revealed') {
          body = Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$amount',
                style: const TextStyle(
                    color: gold, fontSize: 46, fontWeight: FontWeight.bold)),
            const Text('兑换币', style: TextStyle(color: gold, fontSize: 14)),
            const SizedBox(height: 8),
            Text(isRed ? '已存入你的零钱' : '已收款',
                style: const TextStyle(color: Colors.white60, fontSize: 12)),
          ]);
        } else if (phase == 'gone') {
          body = Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
                errMsg ??
                    (claimed
                        ? '已领取 $myAmount 兑换币'
                        : (isRed ? '手慢了，红包已被领完' : '已被领取')),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15)),
          );
        } else {
          body = GestureDetector(
            onTap: () async {
              setS(() => phase = 'opening');
              final r = await onGrabPacket?.call(pid);
              if (!ctx.mounted) return; // 领取途中关了弹窗
              if (r != null && r['ok'] == true) {
                setS(() {
                  amount = (r['amount'] as num?)?.toInt() ?? 0;
                  phase = 'revealed';
                });
              } else {
                setS(() {
                  errMsg = '${r?['error'] ?? '领取失败'}';
                  phase = 'gone';
                });
              }
            },
            child: Container(
              width: 78,
              height: 78,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                  color: gold,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: Color(0x55000000), blurRadius: 8)
                  ]),
              child: Text(isRed ? '開' : '收',
                  style: const TextStyle(
                      color: red2,
                      fontSize: 30,
                      fontWeight: FontWeight.bold)),
            ),
          );
        }
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 48, vertical: 70),
          child: Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [red, red2]),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 26),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Align(
                  alignment: Alignment.topRight,
                  child: GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: const Icon(Icons.close,
                          color: Colors.white54, size: 22))),
              const CircleAvatar(
                  radius: 22,
                  backgroundColor: gold,
                  child: Icon(Icons.person, color: red2)),
              const SizedBox(height: 8),
              Text(
                  fromNick.isEmpty
                      ? (isRed ? '红包' : '转账')
                      : '$fromNick 的${isRed ? '红包' : '转账'}',
                  style: const TextStyle(color: gold, fontSize: 13)),
              const SizedBox(height: 14),
              Text(blessing,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 24),
              body,
              const SizedBox(height: 6),
            ]),
          ),
        );
      }),
    );
  }

  Widget _packetBubble(BuildContext context, Map<String, dynamic> m, bool mine) {
    final isRed = m['ptype'] == 'redpacket';
    final msg = '${m['msg'] ?? ''}';
    final claimed = m['_claimed'] == true;
    final done = m['_done'] == true;
    final canMore = m['_canmore'] == true; // 个数>人数时同一人可继续抢
    final myAmount = (m['_myamount'] as num?)?.toInt() ?? 0;
    final toNick = '${m['to_nick'] ?? ''}'; // 专属红包指定人
    final exclusive = '${m['to'] ?? ''}'.isNotEmpty;

    String status;
    if (claimed && !canMore) {
      status = isRed ? '已领 $myAmount 币' : '已收款 $myAmount 币';
    } else if (mine && !canMore) {
      status = done
          ? (isRed ? '已被领完' : '已被领取')
          : (isRed ? '红包待领取' : '等待对方收款');
    } else if (done) {
      status = isRed ? '手慢了，已抢光' : '已被领取';
    } else {
      status = claimed ? '已领 $myAmount 币 · 还能再抢' : (isRed ? '点击领取红包' : '点击收款');
    }

    final faded = (claimed && !canMore) || done;

    // Merged authoritative WeChat-style palette.
    final bodyColor = faded ? const Color(0xFFFBDCA8) : const Color(0xFFFA9D3B);
    final footerColor = faded ? const Color(0xFFF0CB8C) : const Color(0xFFE2872C);
    final titleColor = faded ? const Color(0xFF9A7B4B) : const Color(0xFFFFFCF5);
    final statusColor = faded ? const Color(0xFFB39A6E) : const Color(0xFFFBE7C8);
    final footerLabelColor =
        faded ? const Color(0xFFBBA579) : const Color(0xFFFFF3DC);
    final exclusiveColor =
        faded ? const Color(0xFFB39A6E) : const Color(0xFFFFD24A);
    final emblemBg = faded ? const Color(0xFFE6D2A6) : const Color(0xFFF8D88C);
    const emblemGlyph = Color(0xFFC8431E);

    final brand = isRed ? '趣播红包' : '趣播转账';

    return InkWell(
      onTap: () => _openPacket(context, m), // 点开微信式领取界面
      child: Container(
        width: 240,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              offset: Offset(0, 1),
              blurRadius: 3,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top amber body.
            Container(
              color: bodyColor,
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Opacity(
                    opacity: faded ? 0.55 : 1.0,
                    child: Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: emblemBg,
                        shape: BoxShape.circle,
                      ),
                      child: isRed
                          ? const Text(
                              '￥',
                              style: TextStyle(
                                color: emblemGlyph,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          : const Icon(
                              Icons.swap_horiz,
                              color: emblemGlyph,
                              size: 22,
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          msg.isEmpty ? (isRed ? '恭喜发财，大吉大利' : '给你转账') : msg,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (exclusive) ...[
                          const SizedBox(height: 3),
                          Text(
                            '专属红包 · 仅 $toNick 可领',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: exclusiveColor,
                              fontSize: 10,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Bottom darker footer strip with brand label.
            Container(
              height: 30,
              color: footerColor,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: Text(
                brand,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: footerLabelColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
        // 拍一拍：居中灰色系统提示行。
        if (m['kind'] == 'pat') {
          final fn = '${m['from_nick'] ?? ''}';
          final tn = '${m['to_nick'] ?? ''}';
          final meFrom = m['from'] == myUid;
          final meTo = m['to'] == myUid;
          final who = meFrom ? '你' : fn;
          final whom = meTo ? '你' : tn;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Center(
              child: Text('$who 拍了拍 $whom',
                  style: const TextStyle(fontSize: 12, color: Colors.black45)),
            ),
          );
        }
        final mine = m['from'] == myUid;
        final isVideo = m['kind'] == 'video';
        final isCard = m['kind'] == 'card';
        final isPacket = m['kind'] == 'packet';
        final bubble = isPacket
            ? _packetBubble(context, m, mine)
            : isCard
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
        final reactChips = _reactionChips(m);
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
            GestureDetector(
              onLongPress: () => _showReactPicker(context, m),
              // 双击对方文字气泡=拍一拍发送者；卡片/红包/视频自带点击，不抢手势。
              onDoubleTap: (!mine &&
                      onPat != null &&
                      !isPacket &&
                      !isCard &&
                      !isVideo)
                  ? () => onPat!(m)
                  : null,
              child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.64),
                  child: bubble),
            ),
            if (reactChips != null) reactChips,
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
  final Map<String, String>? atMembers; // 群聊 @ 成员表(uid→昵称)
  final String? myUid;
  const _ChatInput(
      {required this.controller,
      required this.onSend,
      required this.onRecommend,
      this.onTransfer,
      this.onRedpacket,
      this.onCard,
      this.atMembers,
      this.myUid});

  // 群聊输入 @ 时弹成员表；选中把「@昵称 」插进输入框。
  void _showAtPicker(BuildContext context) {
    final members = atMembers;
    if (members == null || members.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
              padding: EdgeInsets.all(14),
              child: Text('选择要 @ 的人',
                  style: TextStyle(fontWeight: FontWeight.w600))),
          for (final e in members.entries)
            if (e.key != myUid)
              ListTile(
                dense: true,
                leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: e.key.startsWith('bot')
                        ? const Color(0xFFE3A93B)
                        : const Color(0xFF07C160),
                    child: Icon(
                        e.key.startsWith('bot')
                            ? Icons.smart_toy
                            : Icons.person,
                        color: Colors.white,
                        size: 18)),
                title: Text(e.value),
                onTap: () {
                  Navigator.pop(ctx);
                  _insertAt(e.value);
                },
              ),
        ]),
      ),
    );
  }

  void _insertAt(String nick) {
    var t = controller.text;
    if (!t.endsWith('@')) {
      if (t.isNotEmpty && !t.endsWith(' ')) t += ' '; // 按钮触发时补空格分隔
      t += '@';
    }
    controller.text = '$t$nick ';
    controller.selection = TextSelection.fromPosition(
        TextPosition(offset: controller.text.length));
  }

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
            if (atMembers != null && atMembers!.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.alternate_email, color: Colors.black54),
                tooltip: '@成员',
                onPressed: () => _showAtPicker(context),
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
                onChanged: atMembers == null
                    ? null
                    : (v) {
                        // 仅在「行首或空格后刚输入 @」时弹，避免编辑/删除到 @ 结尾时反复弹
                        if (v.endsWith('@') &&
                            (v.length == 1 ||
                                ' \n\t'.contains(v[v.length - 2]))) {
                          _showAtPicker(context);
                        }
                      },
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

  // 10 个事件触发规则：[key, 中文名, 默认回复]
  static const List<List<String>> _evtRules = [
    ['app_open', '打开软件', '欢迎回来！今天也要开心鸭~'],
    ['sign', '每日签到', '签到成功，坚持就是胜利！'],
    ['comeback', '久别回归', '好久不见，可想你了~'],
    ['low_balance', '余额告急', '兑换币不多啦，记得签到/看视频赚币~'],
    ['watch', '观影达标', '观影达人！又解锁一个里程碑👏'],
    ['moment', '发了朋友圈', '动态发布成功，已帮你点亮✨'],
    ['got_packet', '收到红包/转账', '到账啦，恭喜发财🧧'],
    ['follow', '关注了人', '关注成功，又多了个好友~'],
    ['achievement', '解锁成就', '叮！解锁新成就，太强了🏆'],
    ['night', '深夜关怀', '夜深了，注意休息哦🌙'],
  ];

  Future<void> _create() async {
    final nameCtrl = TextEditingController();
    final wordCtrl = TextEditingController();
    final textCtrl = TextEditingController(text: '你好呀，我是机器人~');
    final everyCtrl = TextEditingController(text: '0');
    final evtCtrls = {
      for (final e in _evtRules) e[0]: TextEditingController(text: e[2])
    };
    final evtOn = <String>{};
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
              const Divider(),
              const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('🔔 事件触发（选填，满足规则机器人就私信你）',
                      style: TextStyle(fontWeight: FontWeight.w600))),
              for (final e in _evtRules) ...[
                Row(children: [
                  Checkbox(
                    visualDensity: VisualDensity.compact,
                    value: evtOn.contains(e[0]),
                    onChanged: (v) => setD(() =>
                        v == true ? evtOn.add(e[0]) : evtOn.remove(e[0])),
                  ),
                  Expanded(child: Text(e[1])),
                ]),
                if (evtOn.contains(e[0]))
                  Padding(
                    padding: const EdgeInsets.only(left: 12, bottom: 6),
                    child: TextField(
                        controller: evtCtrls[e[0]],
                        maxLength: 100,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                            isDense: true,
                            counterText: '',
                            labelText: '机器人发的内容')),
                  ),
              ],
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
    // 先把值读出来，再统一释放控制器(含 10 个事件控制器)，避免泄漏。
    final name = nameCtrl.text.trim();
    final word = wordCtrl.text.trim();
    final replyText = textCtrl.text.trim();
    final every = int.tryParse(everyCtrl.text.trim()) ?? 0;
    final events = <String, String>{};
    for (final e in _evtRules) {
      if (evtOn.contains(e[0])) {
        final t = evtCtrls[e[0]]!.text.trim();
        if (t.isNotEmpty) events[e[0]] = t;
      }
    }
    for (final c in [nameCtrl, wordCtrl, textCtrl, everyCtrl, ...evtCtrls.values]) {
      c.dispose();
    }
    if (ok != true || name.isEmpty) return;
    final d = await PlatformService.botCreate(
      name: name,
      word: word,
      kind: kind,
      text: replyText,
      vid: vid?['id'] as String? ?? '',
      title: vid?['title'] as String? ?? '',
      item: kind == 'coupon' ? 'coupon_10' : '',
      scheduleMin: (every > 0 && target != null) ? every : 0,
      target: target ?? '',
      events: events,
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
