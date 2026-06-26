import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
    final c = await PlatformService.dmList();
    if (mounted) setState(() {
      _convs = c;
      _loading = false;
    });
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
                      return ListTile(
                        leading: const CircleAvatar(
                            child: Icon(Icons.person)),
                        title: Text('${c['peer_nick'] ?? ''}'),
                        subtitle: Text('${c['last'] ?? ''}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
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
    final g = await PlatformService.groupList();
    if (mounted) setState(() {
      _groups = g;
      _loading = false;
    });
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
                      return ListTile(
                        leading: const CircleAvatar(
                            child: Icon(Icons.groups)),
                        title: Text('${g['name'] ?? ''}'),
                        subtitle: Text(
                            '${g['count']} 人${role == 'owner' ? ' · 群主' : role == 'admin' ? ' · 管理' : ''}${g['no_leave'] == true ? ' · 禁退' : ''}'),
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
                msgs: _msgs, myUid: _myUid, onPlayVideo: widget.onPlayVideo)),
        _ChatInput(
            controller: _ctrl,
            onSend: _send,
            onRecommend: _recommend,
            onTransfer: _transfer),
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
                onPlayVideo: widget.onPlayVideo)),
        _ChatInput(
            controller: _ctrl,
            onSend: _send,
            onRecommend: _recommend,
            onTransfer: _transfer),
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
  const _MsgList(
      {required this.msgs,
      required this.myUid,
      required this.onPlayVideo,
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
        final bubble = isVideo
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
  const _ChatInput(
      {required this.controller,
      required this.onSend,
      required this.onRecommend,
      this.onTransfer});
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
