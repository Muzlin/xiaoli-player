import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/platform_service.dart';
import '../services/screen_recorder.dart';

/// 直播大厅：发起直播(系统屏幕录制) + 看正在直播的。
class LivePage extends StatefulWidget {
  final void Function(String id, String title) onPlayVideo;
  const LivePage({super.key, required this.onPlayVideo});
  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  List<Map<String, dynamic>> _lives = [];
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _load();
    _t = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final l = await PlatformService.liveList();
    if (mounted) setState(() => _lives = l);
  }

  Future<void> _start() async {
    final ctrl = TextEditingController(text: '我的直播');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('发起直播'),
        content: TextField(
            controller: ctrl,
            maxLength: 40,
            autofocus: true,
            decoration: const InputDecoration(labelText: '直播标题')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('开始直播')),
        ],
      ),
    );
    final title = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || title.isEmpty) return;
    final lid = await PlatformService.liveStart(title: title);
    if (!mounted) return;
    if (lid == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('发起失败')));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => LiveRoomPage(
            lid: lid,
            isHost: true,
            title: title,
            onPlayVideo: widget.onPlayVideo)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('直播')),
      floatingActionButton: ScreenRecorder.supported
          ? FloatingActionButton.extended(
              backgroundColor: const Color(0xFFE5424D),
              icon: const Icon(Icons.podcasts),
              label: const Text('发起直播'),
              onPressed: _start)
          : null,
      body: _lives.isEmpty
          ? RefreshIndicator(
              onRefresh: _load,
              child: ListView(children: const [
                SizedBox(height: 120),
                Center(
                    child: Text('当前没有人直播',
                        style: TextStyle(color: Colors.black38))),
              ]),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final l in _lives)
                    Card(
                      child: ListTile(
                        leading: const CircleAvatar(
                            backgroundColor: Color(0xFFE5424D),
                            child: Icon(Icons.live_tv, color: Colors.white)),
                        title: Text('${l['title']}'),
                        subtitle: Text(
                            '${l['host_nick']} · 👁 ${l['viewers']} 人在看'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => LiveRoomPage(
                                    lid: '${l['lid']}',
                                    isHost: false,
                                    title: '${l['title']}',
                                    onPlayVideo: widget.onPlayVideo))),
                      ),
                    ),
                ],
              ),
            ),
      backgroundColor: const Color(0xFFF2F2F2),
    );
  }
}

/// 直播间：主播推屏 / 观众看 + 弹幕评论 + 踢人 + 发视频。
class LiveRoomPage extends StatefulWidget {
  final String lid;
  final bool isHost;
  final String title;
  final void Function(String id, String title) onPlayVideo;
  const LiveRoomPage(
      {super.key,
      required this.lid,
      required this.isHost,
      required this.title,
      required this.onPlayVideo});
  @override
  State<LiveRoomPage> createState() => _LiveRoomPageState();
}

class _LiveRoomPageState extends State<LiveRoomPage> {
  Uint8List? _frame;
  List<Map<String, dynamic>> _msgs = [];
  List<Map<String, dynamic>> _viewerList = [];
  int _viewers = 0;
  bool _frameInFlight = false;
  bool _ended = false;
  Timer? _stateT;
  Timer? _frameT;
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.isHost) {
      ScreenRecorder.startDesktopFrames(_onScreenFrame);
    }
    _stateT = Timer.periodic(const Duration(milliseconds: 1500), (_) => _poll());
    if (!widget.isHost) {
      _frameT =
          Timer.periodic(const Duration(milliseconds: 700), (_) => _pullFrame());
    }
    _poll();
  }

  @override
  void dispose() {
    _stateT?.cancel();
    _frameT?.cancel();
    if (widget.isHost) {
      ScreenRecorder.stopDesktopFrames();
      PlatformService.liveStop(widget.lid);
    }
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onScreenFrame(Uint8List jpg) async {
    if (_frameInFlight || _ended) return;
    _frameInFlight = true;
    try {
      await PlatformService.liveFrame(widget.lid, jpg);
    } finally {
      _frameInFlight = false;
    }
  }

  Future<void> _pullFrame() async {
    if (_ended) return;
    final b = await PlatformService.liveFrameBytes(widget.lid);
    if (b != null && mounted) setState(() => _frame = b);
  }

  Future<void> _poll() async {
    final s = await PlatformService.liveState(widget.lid);
    if (!mounted || s == null) return;
    if (s['kicked'] == true) {
      _bail('你已被移出直播间');
      return;
    }
    final active = s['active'] == true;
    setState(() {
      _msgs = ((s['msgs'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _viewers = (s['viewers'] as num?)?.toInt() ?? 0;
      _viewerList = ((s['viewer_list'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    });
    if (!active && !widget.isHost) _bail('直播已结束');
  }

  void _bail(String msg) {
    if (_ended) return;
    _ended = true;
    _stateT?.cancel();
    _frameT?.cancel();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _send() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    _ctrl.clear();
    await PlatformService.liveMsg(widget.lid, text: t);
    _poll();
  }

  Future<void> _shareVideo() async {
    final vids = await PlatformService.rank();
    if (!mounted) return;
    final picked = await showModalBottomSheet<PlatformVideo>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
              padding: EdgeInsets.all(14),
              child: Text('分享一个视频给观众',
                  style: TextStyle(fontWeight: FontWeight.w600))),
          for (final v in vids.take(30))
            ListTile(
                dense: true,
                leading: const Icon(Icons.play_circle_outline),
                title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(c, v)),
        ]),
      ),
    );
    if (picked == null) return;
    await PlatformService.liveMsg(widget.lid,
        kind: 'video', vid: picked.id, title: picked.title);
    _poll();
  }

  Future<void> _kick() async {
    if (_viewerList.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前没有观众')));
      return;
    }
    final v = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
              padding: EdgeInsets.all(14),
              child: Text('移出谁', style: TextStyle(fontWeight: FontWeight.w600))),
          for (final u in _viewerList)
            ListTile(
                dense: true,
                leading: const Icon(Icons.person_remove, color: Colors.red),
                title: Text('${u['nick']}'),
                onTap: () => Navigator.pop(c, u)),
        ]),
      ),
    );
    if (v == null) return;
    await PlatformService.liveKick(widget.lid, '${v['uid']}');
    _poll();
  }

  @override
  Widget build(BuildContext context) {
    final recent = _msgs.length > 6 ? _msgs.sublist(_msgs.length - 6) : _msgs;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          // ===== 画面 + 弹幕 =====
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: widget.isHost
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.podcasts,
                                color: Color(0xFFE5424D), size: 56),
                            const SizedBox(height: 10),
                            const Text('正在直播你的屏幕',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 16)),
                            const SizedBox(height: 4),
                            Text('观众通过画面看到你的桌面 · 打开视频/PPT 即可展示',
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 12)),
                          ],
                        )
                      : (_frame != null
                          ? Image.memory(_frame!, gaplessPlayback: true)
                          : const Text('等待主播画面…',
                              style: TextStyle(color: Colors.white54))),
                ),
              ),
              // 顶部信息条
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  color: Colors.black.withValues(alpha: 0.35),
                  child: Row(children: [
                    const Icon(Icons.live_tv, color: Color(0xFFE5424D), size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600))),
                    const Icon(Icons.remove_red_eye,
                        color: Colors.white70, size: 16),
                    const SizedBox(width: 3),
                    Text('$_viewers',
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () async {
                        if (widget.isHost) {
                          await PlatformService.liveStop(widget.lid);
                        }
                        if (mounted) Navigator.of(context).maybePop();
                      },
                      child: Text(widget.isHost ? '结束' : '退出',
                          style: const TextStyle(
                              color: Color(0xFFE5424D),
                              fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),
              ),
              // 弹幕(浮在画面上)
              Positioned(
                left: 10,
                right: 10,
                bottom: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final m in recent)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(10)),
                          child: m['kind'] == 'video'
                              ? GestureDetector(
                                  onTap: () => widget.onPlayVideo(
                                      '${m['vid']}', '${m['title'] ?? ''}'),
                                  child: Text(
                                      '🎬 ${m['nick']} 分享了视频：${m['title']}（点击看）',
                                      style: const TextStyle(
                                          color: Color(0xFFFFD24A),
                                          fontSize: 12)),
                                )
                              : Text('${m['nick']}：${m['text']}',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12)),
                        ),
                      ),
                  ],
                ),
              ),
            ]),
          ),
          // ===== 底部控制 + 发弹幕 =====
          Container(
            color: const Color(0xFF1A1A1A),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(children: [
              if (widget.isHost) ...[
                IconButton(
                    tooltip: '发视频',
                    icon: const Icon(Icons.video_library_outlined,
                        color: Colors.white70),
                    onPressed: _shareVideo),
                IconButton(
                    tooltip: '踢人',
                    icon: const Icon(Icons.person_remove_outlined,
                        color: Colors.white70),
                    onPressed: _kick),
              ],
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: '发条弹幕…',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: const Color(0xFF2A2A2A),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              IconButton(
                  icon: const Icon(Icons.send, color: Color(0xFFE5424D)),
                  onPressed: _send),
            ]),
          ),
        ]),
      ),
    );
  }
}
