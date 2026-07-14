import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import '../services/platform_service.dart';
import '../services/screen_recorder.dart';
import '../services/mic_recorder.dart';
import '../services/transcribe_service.dart';

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
    // 安卓有摄像头/屏幕两种采集源，先让主播选一个；其它平台(如 macOS)只有屏幕录制，
    // 维持原有行为不弹选择框。
    var hostSource = 'screen';
    if (Platform.isAndroid) {
      final chosen = await showModalBottomSheet<String>(
        context: context,
        builder: (c) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('摄像头直播'),
                onTap: () => Navigator.pop(c, 'camera')),
            ListTile(
                leading: const Icon(Icons.screen_share),
                title: const Text('屏幕直播'),
                onTap: () => Navigator.pop(c, 'screen')),
          ]),
        ),
      );
      if (chosen == null) return;
      if (!mounted) return;
      hostSource = chosen;
    }
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
            hostSource: hostSource,
            onPlayVideo: widget.onPlayVideo)));
  }

  Future<void> _schedule() async {
    final tc = TextEditingController(text: '我的直播');
    int mins = 60;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: const Text('预约直播'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: tc,
                decoration: const InputDecoration(labelText: '标题')),
            const SizedBox(height: 8),
            Row(children: [
              const Text('开播时间：'),
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: mins,
                  items: const [
                    DropdownMenuItem(value: 30, child: Text('30 分钟后')),
                    DropdownMenuItem(value: 60, child: Text('1 小时后')),
                    DropdownMenuItem(value: 180, child: Text('3 小时后')),
                    DropdownMenuItem(value: 1440, child: Text('明天此时')),
                  ],
                  onChanged: (v) => setD(() => mins = v ?? 60),
                ),
              ),
            ]),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('预约并通知粉丝')),
          ],
        ),
      ),
    );
    if (ok != true || tc.text.trim().isEmpty) return;
    final at = DateTime.now().add(Duration(minutes: mins));
    final r = await PlatformService.liveScheduleCreate(
        tc.text.trim(), at.millisecondsSinceEpoch ~/ 1000);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已预约，通知了 ${r?['notified'] ?? 0} 位粉丝')));
  }

  Future<void> _remote() async {
    final lc = TextEditingController();
    final pc = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('连接遥控'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: lc,
              decoration: const InputDecoration(labelText: '直播号(主播端显示)')),
          TextField(
              controller: pc,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '遥控口令')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('连接')),
        ],
      ),
    );
    if (ok != true || lc.text.trim().isEmpty || pc.text.trim().isEmpty) return;
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            _RemoteControlPage(lid: lc.text.trim(), pin: pc.text.trim())));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('直播'), actions: [
        IconButton(
            tooltip: '预约直播',
            icon: const Icon(Icons.event),
            onPressed: _schedule),
        IconButton(
            tooltip: '当遥控器',
            icon: const Icon(Icons.settings_remote),
            onPressed: _remote),
      ]),
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
  /// 主播源：'screen'(桌面/屏幕录制) | 'camera'(安卓摄像头)。默认 'screen'。
  final String hostSource;
  const LiveRoomPage(
      {super.key,
      required this.lid,
      required this.isHost,
      required this.title,
      required this.onPlayVideo,
      this.hostSource = 'screen'});
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
  String? _burst; // 礼物特效：屏幕中央弹个大 emoji
  Timer? _burstT;
  int _lastGiftTs = 0;
  bool _giftBaseline = false;
  bool _presenting = false; // 正在演示 PPT：屏幕录制帧让路给幻灯片帧
  Map<String, dynamic>? _deck; // 本场直播挂着的 PPT {id,count}(观众"看PPT")
  String? _caption; // 主播语音字幕(近实时)
  int _captionTs = 0; // 字幕时间戳(过期就不显示)
  bool _recording = false; // 主播是否在录播
  bool _captioning = false; // 主播是否在推语音字幕
  bool _bilingual = false; // 语音字幕是否双语(中英)
  Map<String, dynamic>? _pollData; // 当前投票 {q,options,counts}
  List<Map<String, dynamic>> _giftRank = const []; // 打赏榜
  List<Map<String, dynamic>> _hands = const []; // 举手/提问队列(主播可见)
  Map<String, dynamic>? _question; // 当前展示的观众提问
  bool _handRaised = false; // 本观众是否已举手

  @override
  void initState() {
    super.initState();
    if (widget.isHost) {
      final starter = widget.hostSource == 'camera'
          ? ScreenRecorder.startCameraFrames(_onScreenFrame)
          : ScreenRecorder.startDesktopFrames(_onScreenFrame);
      starter.then((ok) {
        if (!ok && mounted) _askScreenPermission();
      });
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
    _burstT?.cancel();
    _captioning = false;
    if (widget.isHost) {
      MicRecorder.stop();
      if (widget.hostSource == 'camera') {
        ScreenRecorder.stopCameraFrames();
      } else {
        ScreenRecorder.stopDesktopFrames();
      }
      PlatformService.liveStop(widget.lid);
    }
    _ctrl.dispose();
    super.dispose();
  }

  void _askScreenPermission() {
    final isAndroid = Platform.isAndroid;
    final isCamera = widget.hostSource == 'camera';
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(isCamera ? '需要「摄像头」权限' : '需要「屏幕录制」权限'),
        content: Text(isCamera
            ? '直播要用到摄像头。请在弹出的系统权限框里点「允许」，然后点「重新授权」重试。'
            : (isAndroid
                ? '直播要录制你的屏幕。点击「重新授权」，在弹出的系统对话框里选择「立即开始」即可。'
                : '直播要录制你的屏幕。请在 系统设置 › 隐私与安全性 › 屏幕录制 里勾选「小李播放器」，'
                    '然后完全退出并重新打开 App，再发起直播。')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('知道了')),
          FilledButton(
              onPressed: () {
                if (isCamera) {
                  ScreenRecorder.startCameraFrames(_onScreenFrame);
                } else if (isAndroid) {
                  ScreenRecorder.startDesktopFrames(_onScreenFrame);
                } else {
                  ScreenRecorder.openScreenSettings();
                }
                Navigator.pop(c);
              },
              child: Text(isCamera || isAndroid ? '重新授权' : '去设置')),
        ],
      ),
    );
  }

  Future<void> _onScreenFrame(Uint8List jpg) async {
    // 演示 PPT 时由演示页直接推清晰幻灯片，屏幕录制帧让路，避免互相覆盖。
    if (_frameInFlight || _ended || _presenting) return;
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
    final ppt = s['ppt'];
    final cap = s['caption'];
    setState(() {
      _msgs = ((s['msgs'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _viewers = (s['viewers'] as num?)?.toInt() ?? 0;
      _viewerList = ((s['viewer_list'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _deck = ppt is Map ? Map<String, dynamic>.from(ppt) : null;
      _recording = s['recording'] == true;
      if (cap is Map && cap['text'] != null) {
        _caption = '${cap['text']}';
        _captionTs = DateTime.now().millisecondsSinceEpoch;
      }
      final pl = s['poll'];
      _pollData = pl is Map ? Map<String, dynamic>.from(pl) : null;
      _giftRank = ((s['gift_rank'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _hands = ((s['hands'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final qq = s['question'];
      _question = qq is Map ? Map<String, dynamic>.from(qq) : null;
    });
    // 检测新礼物→放特效(首轮只建基线，不补放历史礼物)
    final gifts = _msgs.where((m) => m['kind'] == 'gift').toList();
    if (gifts.isNotEmpty) {
      final ts = (gifts.last['ts'] as num?)?.toInt() ?? 0;
      if (!_giftBaseline) {
        _lastGiftTs = ts;
        _giftBaseline = true;
      } else if (ts > _lastGiftTs) {
        _lastGiftTs = ts;
        _showBurst('${gifts.last['emoji'] ?? '🎁'}');
      }
    }
    if (!active && !widget.isHost) _bail('直播已结束');
  }

  void _showBurst(String emoji) {
    if (!mounted) return;
    setState(() => _burst = emoji);
    _burstT?.cancel();
    _burstT = Timer(const Duration(milliseconds: 1600),
        () => mounted ? setState(() => _burst = null) : null);
  }

  Future<void> _giftSheet() async {
    final gifts = await PlatformService.liveGifts();
    if (!mounted || gifts.isEmpty) return;
    final g = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final gift in gifts)
                GestureDetector(
                  onTap: () => Navigator.pop(c, gift),
                  child: Container(
                    width: 80,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(10)),
                    child: Column(children: [
                      Text('${gift['emoji']}',
                          style: const TextStyle(fontSize: 30)),
                      Text('${gift['name']}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                      Text('${gift['cost']}币',
                          style: const TextStyle(
                              color: Color(0xFFFFD24A), fontSize: 11)),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (g == null) return;
    final r = await PlatformService.liveGift(widget.lid, '${g['key']}');
    if (!mounted) return;
    if (r?['ok'] == true) {
      _showBurst('${g['emoji']}');
      _poll();
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${r?['error'] ?? '送礼失败'}')));
    }
  }

  Future<void> _openSlides() async {
    // 任意格式演示文件 → 服务端统一转 pptx + 拆页；演示时把当前页当直播帧推给公网观众。
    final res = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true, // 直接拿字节，跨平台一致
    );
    if (!mounted || res == null || res.files.isEmpty) return;
    final f = res.files.first;
    final bytes = f.bytes;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('读取文件失败')));
      return;
    }
    final ext = (f.extension ?? 'pptx').toLowerCase();
    // 转换进度弹窗（不可关闭）
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: Color(0xFF1A1A1A),
        content: Row(children: [
          SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Expanded(
              child: Text('正在转换演示文件…统一转 PPTX 并拆页',
                  style: TextStyle(color: Colors.white))),
        ]),
      ),
    );
    final r = await PlatformService.pptConvert(bytes, ext);
    if (!mounted) return;
    Navigator.of(context).pop(); // 关进度弹窗
    final slides = (r['slides'] as List?)?.cast<String>() ?? const [];
    if (slides.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${r['error'] ?? '转换失败，换个文件试试'}')));
      return;
    }
    // 把这套 PPT 挂到直播间，观众可"独立看PPT"翻页。
    final pid = '${r['id']}';
    final count = (r['count'] as int?) ?? slides.length;
    await PlatformService.liveSetPpt(widget.lid, pid, count);
    setState(() => _presenting = true);
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SlidePresenter(
            slideUrls: slides,
            lid: widget.lid,
            onInsertVideo: _shareVideo)));
    if (mounted) setState(() => _presenting = false);
  }

  /// 观众端：打开这场直播挂着的 PPT，只读翻页(不广播)。
  void _viewerOpenPpt() {
    final d = _deck;
    if (d == null) return;
    final id = d['id'] as String;
    final count = d['count'] as int;
    final urls = [
      for (var i = 1; i <= count; i++)
        '${PlatformService.current}/ppt/$id/slide-$i.png'
    ];
    if (urls.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SlidePresenter(slideUrls: urls, readOnly: true)));
  }

  Future<void> _toggleRecord() async {
    final want = !_recording;
    final ok = await PlatformService.liveRecord(widget.lid, want);
    if (!mounted) return;
    if (ok) {
      setState(() => _recording = want);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(want ? '开始录播·结束直播后自动生成回放视频进平台库' : '已停止录播')));
    }
  }

  Future<void> _toggleCaption() async {
    if (_captioning) {
      setState(() => _captioning = false);
      await MicRecorder.stop();
      return;
    }
    if (!MicRecorder.supported) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('语音字幕暂仅 macOS 支持')));
      return;
    }
    if (!TranscribeService.available) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('缺 whisper 模型/ffmpeg，无法转字幕')));
      return;
    }
    setState(() => _captioning = true);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('语音字幕已开启（首次会弹麦克风授权，约几秒延迟）')));
    _captionLoop();
  }

  /// 主播语音字幕循环：每段录音→whisper 转文本→推给观众+本地叠加。近实时(~几秒延迟)。
  Future<void> _captionLoop() async {
    while (mounted && _captioning && !_ended) {
      final wav = await MicRecorder.recordChunk(seconds: 5.0);
      if (!mounted || !_captioning) break;
      if (wav == null) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }
      final text = _bilingual
          ? await TranscribeService.transcribeChunkBilingual(wav)
          : await TranscribeService.transcribeChunkToText(wav);
      try {
        File(wav).deleteSync();
      } catch (_) {}
      if (!mounted || !_captioning) break;
      if (text != null && text.isNotEmpty) {
        setState(() {
          _caption = text;
          _captionTs = DateTime.now().millisecondsSinceEpoch;
        });
        await PlatformService.liveCaption(widget.lid, text);
      }
    }
  }

  // ===== 课堂投票(主播出题) =====
  Future<void> _createPoll() async {
    final qc = TextEditingController();
    final oc = TextEditingController(text: 'A\nB\nC');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('出投票题', style: TextStyle(color: Colors.white)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: qc,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                  hintText: '题目',
                  hintStyle: TextStyle(color: Colors.white38))),
          TextField(
              controller: oc,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                  hintText: '选项(每行一个)',
                  hintStyle: TextStyle(color: Colors.white38))),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('发布')),
        ],
      ),
    );
    if (ok != true) return;
    final opts = oc.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (qc.text.trim().isEmpty || opts.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('要有题目 + 至少2个选项')));
      }
      return;
    }
    await PlatformService.livePollCreate(widget.lid, qc.text.trim(), opts);
    _poll();
  }

  Future<void> _votePoll(int opt) async {
    await PlatformService.livePollVote(widget.lid, opt);
    _poll();
  }

  // ===== 举手/提问(观众) =====
  Future<void> _toggleHand() async {
    final want = !_handRaised;
    setState(() => _handRaised = want);
    await PlatformService.liveHand(widget.lid, want);
  }

  Future<void> _askQuestion() async {
    final tc = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('提问', style: TextStyle(color: Colors.white)),
        content: TextField(
            controller: tc,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
                hintText: '输入你的问题…',
                hintStyle: TextStyle(color: Colors.white38))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('提交')),
        ],
      ),
    );
    if (ok == true && tc.text.trim().isNotEmpty) {
      await PlatformService.liveQuestion(widget.lid, tc.text.trim());
      if (mounted) {
        setState(() => _handRaised = true);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已提交，等主播点名')));
      }
    }
  }

  // ===== 主播看举手队列并点名 =====
  Future<void> _showHands() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (c) => SafeArea(
        child: _hands.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('暂无举手/提问',
                    style: TextStyle(color: Colors.white54)))
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final h in _hands)
                    ListTile(
                      leading: const Icon(Icons.pan_tool_outlined,
                          color: Color(0xFFFFD24A)),
                      title: Text('${h['nick']}',
                          style: const TextStyle(color: Colors.white)),
                      subtitle: h['q'] != null
                          ? Text('${h['q']}',
                              style: const TextStyle(color: Colors.white70))
                          : null,
                      trailing: TextButton(
                        onPressed: () {
                          PlatformService.livePick(widget.lid, '${h['uid']}');
                          Navigator.pop(c);
                          _poll();
                        },
                        child: const Text('上麦/展示'),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  // ===== 主播查看/复制本场讲稿 =====
  Future<void> _showTranscript() async {
    final text = await PlatformService.liveTranscript(widget.lid);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('本场讲稿(语音字幕汇总)',
            style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: SelectableText(text.isEmpty ? '(还没有字幕，先开语音字幕)' : text,
                style: const TextStyle(color: Colors.white70)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('关闭')),
        ],
      ),
    );
  }

  // ===== 主播开遥控(显示 lid+pin 给手机端) =====
  Future<void> _setupRemote() async {
    final pin =
        (1000 + (DateTime.now().millisecondsSinceEpoch % 9000)).toString();
    final ok = await PlatformService.liveCtrlPin(widget.lid, pin);
    if (!mounted) return;
    if (ok) {
      showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('手机遥控已开启',
              style: TextStyle(color: Colors.white)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('在另一台设备的「直播大厅 › 遥控」里输入：',
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            SelectableText('直播号 ${widget.lid}',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
            SelectableText('口令 $pin',
                style: const TextStyle(
                    color: Color(0xFFFFD24A),
                    fontSize: 22,
                    fontWeight: FontWeight.bold)),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('知道了')),
          ],
        ),
      );
    }
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
                              : m['kind'] == 'gift'
                                  ? Text(
                                      '${m['nick']} 送出 ${m['emoji']}${m['name']}',
                                      style: const TextStyle(
                                          color: Color(0xFFFF7AB0),
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12))
                                  : Text('${m['nick']}：${m['text']}',
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 12)),
                        ),
                      ),
                  ],
                ),
              ),
              // 主播语音字幕(近实时)：画面底部居中，8s 不更新就隐
              if (_caption != null &&
                  _caption!.isNotEmpty &&
                  DateTime.now().millisecondsSinceEpoch - _captionTs < 8000)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 48,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(8)),
                      child: Text(_caption!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              height: 1.3)),
                    ),
                  ),
                ),
              // 打赏榜(右上角紧凑)
              if (_giftRank.isNotEmpty)
                Positioned(
                  right: 8,
                  top: 44,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(8)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('🏆 打赏榜',
                            style: TextStyle(
                                color: Color(0xFFFFD24A), fontSize: 11)),
                        for (var i = 0; i < _giftRank.length && i < 3; i++)
                          Text(
                              '${i + 1}. ${_giftRank[i]['nick']} ${_giftRank[i]['total']}🪙',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              // 观众提问上墙
              if (_question != null)
                Positioned(
                  left: 16,
                  right: 16,
                  top: 80,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: const Color(0xCC0A84FF),
                        borderRadius: BorderRadius.circular(10)),
                    child: Text('🙋 ${_question!['nick']}：${_question!['q']}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              // 课堂投票(中部，点选项投票)
              if (_pollData != null)
                Positioned(
                  left: 20,
                  right: 20,
                  top: 130,
                  child: _PollCard(
                    data: _pollData!,
                    onVote: widget.isHost ? null : _votePoll,
                    onClose: widget.isHost
                        ? () {
                            PlatformService.livePollClose(widget.lid);
                            _poll();
                          }
                        : null,
                  ),
                ),
              // 礼物特效：屏幕中央放大 emoji
              if (_burst != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: TweenAnimationBuilder<double>(
                        key: ValueKey(_lastGiftTs),
                        tween: Tween(begin: 0.4, end: 1.0),
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.elasticOut,
                        builder: (_, v, child) =>
                            Transform.scale(scale: v, child: child),
                        child: Text(_burst!,
                            style: const TextStyle(fontSize: 120)),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          // ===== 底部控制 + 发弹幕 =====
          Container(
            color: const Color(0xFF1A1A1A),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(children: [
              IconButton(
                  tooltip: '送礼物',
                  icon: const Text('🎁', style: TextStyle(fontSize: 20)),
                  onPressed: _giftSheet),
              if (widget.isHost) ...[
                IconButton(
                    tooltip: '演示图片/PPT',
                    icon: const Icon(Icons.slideshow_outlined,
                        color: Colors.white70),
                    onPressed: _openSlides),
                IconButton(
                    tooltip: '发视频',
                    icon: const Icon(Icons.video_library_outlined,
                        color: Colors.white70),
                    onPressed: _shareVideo),
                IconButton(
                    tooltip: _recording ? '录播中(点击停止)' : '开始录播',
                    icon: Icon(Icons.fiber_manual_record,
                        color: _recording
                            ? const Color(0xFFE5424D)
                            : Colors.white70),
                    onPressed: _toggleRecord),
                IconButton(
                    tooltip: _captioning ? '字幕中(点击停止)' : '语音字幕',
                    icon: Icon(Icons.closed_caption,
                        color: _captioning
                            ? const Color(0xFFFFD24A)
                            : Colors.white70),
                    onPressed: _toggleCaption),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  icon: const Icon(Icons.more_horiz, color: Colors.white70),
                  color: const Color(0xFF2A2A2A),
                  onSelected: (v) {
                    switch (v) {
                      case 'poll':
                        _createPoll();
                        break;
                      case 'hands':
                        _showHands();
                        break;
                      case 'script':
                        _showTranscript();
                        break;
                      case 'remote':
                        _setupRemote();
                        break;
                      case 'bilingual':
                        setState(() => _bilingual = !_bilingual);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(_bilingual ? '字幕改中英双语' : '字幕改中文')));
                        break;
                      case 'kick':
                        _kick();
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'poll',
                        child: Text('📊 出投票题',
                            style: TextStyle(color: Colors.white))),
                    PopupMenuItem(
                        value: 'hands',
                        child: Text('🙋 举手队列 (${_hands.length})',
                            style: const TextStyle(color: Colors.white))),
                    const PopupMenuItem(
                        value: 'script',
                        child: Text('📝 本场讲稿',
                            style: TextStyle(color: Colors.white))),
                    const PopupMenuItem(
                        value: 'remote',
                        child: Text('📱 手机遥控',
                            style: TextStyle(color: Colors.white))),
                    PopupMenuItem(
                        value: 'bilingual',
                        child: Text(_bilingual ? '🌐 双语字幕 ✓' : '🌐 双语字幕',
                            style: const TextStyle(color: Colors.white))),
                    const PopupMenuItem(
                        value: 'kick',
                        child: Text('🚫 踢人',
                            style: TextStyle(color: Colors.white))),
                  ],
                ),
              ],
              if (!widget.isHost) ...[
                if (_deck != null)
                  IconButton(
                      tooltip: '看PPT',
                      icon: const Icon(Icons.slideshow_outlined,
                          color: Color(0xFFFFD24A)),
                      onPressed: _viewerOpenPpt),
                IconButton(
                    tooltip: _handRaised ? '已举手(点击放下)' : '举手',
                    icon: Icon(Icons.pan_tool_outlined,
                        color: _handRaised
                            ? const Color(0xFFFFD24A)
                            : Colors.white70),
                    onPressed: _toggleHand),
                IconButton(
                    tooltip: '提问',
                    icon: const Icon(Icons.help_outline, color: Colors.white70),
                    onPressed: _askQuestion),
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

/// 手机遥控端：连上直播(lid+pin)，控制演示翻页 + 激光笔。
class _RemoteControlPage extends StatefulWidget {
  final String lid;
  final String pin;
  const _RemoteControlPage({required this.lid, required this.pin});
  @override
  State<_RemoteControlPage> createState() => _RemoteControlPageState();
}

class _RemoteControlPageState extends State<_RemoteControlPage> {
  bool _ok = true;
  int _lastLaser = 0;

  Future<void> _send(String action, {int? page, double? x, double? y}) async {
    final ok = await PlatformService.liveControl(widget.lid, widget.pin, action,
        page: page, x: x, y: y);
    if (mounted && !ok) setState(() => _ok = false);
  }

  void _laser(Offset local, Size size) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastLaser < 120) return; // 节流，别刷爆
    _lastLaser = now;
    _send('laser',
        x: (local.dx / size.width).clamp(0.0, 1.0),
        y: (local.dy / size.height).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
          backgroundColor: Colors.black,
          title: Text(_ok ? '遥控中 · ${widget.lid}' : '口令错/未开启')),
      body: Column(children: [
        Expanded(
          child: Row(children: [
            Expanded(
              child: InkWell(
                onTap: () => _send('prev'),
                child: Container(
                  color: const Color(0xFF1A1A1A),
                  margin: const EdgeInsets.all(4),
                  child: const Center(
                      child: Icon(Icons.chevron_left,
                          color: Colors.white, size: 60)),
                ),
              ),
            ),
            Expanded(
              child: InkWell(
                onTap: () => _send('next'),
                child: Container(
                  color: const Color(0xFF1A1A1A),
                  margin: const EdgeInsets.all(4),
                  child: const Center(
                      child: Icon(Icons.chevron_right,
                          color: Colors.white, size: 60)),
                ),
              ),
            ),
          ]),
        ),
        Container(
          height: 220,
          margin: const EdgeInsets.all(4),
          color: const Color(0xFF222222),
          child: LayoutBuilder(
            builder: (c, cons) {
              final size = Size(cons.maxWidth, cons.maxHeight);
              return GestureDetector(
                onPanStart: (d) => _laser(d.localPosition, size),
                onPanUpdate: (d) => _laser(d.localPosition, size),
                onPanEnd: (_) => _send('clearlaser'),
                child: const Center(
                    child: Text('在此拖动 = 激光笔',
                        style: TextStyle(color: Colors.white38))),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// 课堂投票卡片：题目 + 选项条(计票/百分比)，观众点击投票，主播可关闭。
class _PollCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final void Function(int)? onVote; // 观众投票；主播为 null
  final VoidCallback? onClose; // 主播关闭
  const _PollCard({required this.data, this.onVote, this.onClose});

  @override
  Widget build(BuildContext context) {
    final opts = (data['options'] as List?)?.cast<dynamic>() ?? const [];
    final counts = (data['counts'] as List?)?.cast<dynamic>() ?? const [];
    final total = counts.fold<int>(0, (a, b) => a + (b as num).toInt());
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFFD24A), width: 1)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Text('📊 ', style: TextStyle(fontSize: 14)),
          Expanded(
              child: Text('${data['q']}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600))),
          if (onClose != null)
            GestureDetector(
                onTap: onClose,
                child: const Icon(Icons.close, color: Colors.white54, size: 18)),
        ]),
        const SizedBox(height: 8),
        for (var i = 0; i < opts.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              onTap: onVote == null ? null : () => onVote!(i),
              child: Stack(children: [
                Container(
                  height: 30,
                  decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(6)),
                ),
                FractionallySizedBox(
                  widthFactor: total == 0
                      ? 0.0
                      : ((counts[i] as num).toInt() / total).clamp(0.0, 1.0),
                  child: Container(
                    height: 30,
                    decoration: BoxDecoration(
                        color: const Color(0x66FFD24A),
                        borderRadius: BorderRadius.circular(6)),
                  ),
                ),
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(children: [
                      Expanded(
                          child: Text('${opts[i]}',
                              style: const TextStyle(color: Colors.white))),
                      Text('${counts.length > i ? counts[i] : 0}',
                          style: const TextStyle(color: Colors.white70)),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        Text('共 $total 票${onVote != null ? " · 点选项投票" : ""}',
            style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ]),
    );
  }
}

/// 演示工具：无 / 画笔 / 激光笔 / 聚光灯。
enum _SlideTool { none, pen, laser, spot }

/// PPT 演示：任意格式已在服务端统一转 pptx + 拆成每页 PNG，这里按 URL 显示。
/// 可切页 + 画笔注释 + 激光笔/聚光灯；直播中把「幻灯片+注释+激光/聚光」的合成画面
/// 直接当直播帧(JPEG 省流)推给公网观众（不依赖屏幕录制、清晰、Android 也能演示）。
/// readOnly=true 时是观众端只读翻页(无工具、不广播)。
class SlidePresenter extends StatefulWidget {
  final List<String> slideUrls; // 每页 PNG 的绝对 URL
  final String? lid; // 非空=直播中，广播当前页
  final bool readOnly; // 观众端只读翻页
  final VoidCallback? onInsertVideo; // 主播：插入/展示一个视频给观众
  const SlidePresenter(
      {super.key,
      required this.slideUrls,
      this.lid,
      this.readOnly = false,
      this.onInsertVideo});
  @override
  State<SlidePresenter> createState() => _SlidePresenterState();
}

class _SlidePresenterState extends State<SlidePresenter> {
  final _pc = PageController();
  final _boundaryKey = GlobalKey(); // 抓合成画面(幻灯片+注释+激光/聚光)当直播帧
  int _page = 0;
  _SlideTool _tool = _SlideTool.none;
  Color _color = const Color(0xFFFF3B30);
  final Map<int, List<_Stroke>> _strokes = {}; // 每页笔画
  _Stroke? _cur;
  Offset? _pointer; // 激光笔/聚光灯当前位置
  Timer? _castT;
  Timer? _ctrlT;
  bool _castInFlight = false;
  int _lastCtrlSeq = 0; // 已消费的遥控指令序号

  bool get _live => widget.lid != null;

  @override
  void initState() {
    super.initState();
    // 直播中：定时把当前合成画面推成直播帧（翻页/注释/激光都会被下一拍带上）。
    if (_live && !widget.readOnly) {
      _castT = Timer.periodic(
          const Duration(milliseconds: 1000), (_) => _broadcast());
      // 消费手机遥控指令(翻页/激光)。
      _ctrlT = Timer.periodic(
          const Duration(milliseconds: 700), (_) => _pollControl());
    }
  }

  @override
  void dispose() {
    _castT?.cancel();
    _ctrlT?.cancel();
    _pc.dispose();
    super.dispose();
  }

  Future<void> _pollControl() async {
    final s = await PlatformService.liveState(widget.lid!);
    if (!mounted || s == null) return;
    final c = s['control'];
    if (c is! Map) return;
    final seq = (c['seq'] as num?)?.toInt() ?? 0;
    if (seq <= _lastCtrlSeq) return;
    _lastCtrlSeq = seq;
    switch (c['action']) {
      case 'next':
        _jump(1);
        break;
      case 'prev':
        _jump(-1);
        break;
      case 'goto':
        final p = (c['page'] as num?)?.toInt() ?? 0;
        if (p >= 0 && p < widget.slideUrls.length) {
          _pc.animateToPage(p,
              duration: const Duration(milliseconds: 200), curve: Curves.ease);
        }
        break;
      case 'laser':
        final box = context.findRenderObject();
        if (box is RenderBox) {
          final x = (c['x'] as num?)?.toDouble() ?? 0;
          final y = (c['y'] as num?)?.toDouble() ?? 0;
          setState(() {
            _tool = _SlideTool.laser;
            _pointer = Offset(x * box.size.width, y * box.size.height);
          });
        }
        break;
      case 'clearlaser':
        setState(() => _pointer = null);
        break;
    }
  }

  Future<void> _exportAnnotated() async {
    try {
      final bound = _boundaryKey.currentContext?.findRenderObject();
      if (bound is! RenderRepaintBoundary) return;
      final image = await bound.toImage(pixelRatio: 2.0);
      final bd = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bd == null) return;
      final home = Platform.environment['HOME'] ?? '.';
      final dir = Directory('$home/Downloads');
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/直播批注_第${_page + 1}页_$ts.png';
      await File(path).writeAsBytes(bd.buffer.asUint8List());
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已导出到 $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  Future<void> _broadcast() async {
    if (_castInFlight || !_live || !mounted) return;
    _castInFlight = true;
    try {
      final bound = _boundaryKey.currentContext?.findRenderObject();
      if (bound is! RenderRepaintBoundary) return;
      // 抓帧目标宽 ~1280，隧道也扛得住(JPEG ~100-200KB)。
      final lw = bound.size.width;
      final pr = lw > 0 ? (1280 / lw).clamp(0.4, 2.0) : 1.0;
      final image = await bound.toImage(pixelRatio: pr.toDouble());
      final bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = image.width, h = image.height;
      image.dispose();
      if (bd == null) return;
      final jpg = await PlatformService.rgbaToJpg(bd.buffer.asUint8List(), w, h);
      await PlatformService.liveFrame(widget.lid!, jpg);
    } catch (_) {
    } finally {
      _castInFlight = false;
    }
  }

  void _jump(int d) {
    final n = (_page + d).clamp(0, widget.slideUrls.length - 1);
    _pc.animateToPage(n,
        duration: const Duration(milliseconds: 200), curve: Curves.ease);
  }

  void _cycleTool() {
    setState(() {
      _tool = _SlideTool.values[(_tool.index + 1) % _SlideTool.values.length];
      if (_tool != _SlideTool.laser && _tool != _SlideTool.spot) _pointer = null;
    });
  }

  String get _toolLabel => switch (_tool) {
        _SlideTool.none => '工具(关)',
        _SlideTool.pen => '画笔',
        _SlideTool.laser => '激光笔',
        _SlideTool.spot => '聚光灯',
      };

  IconData get _toolIcon => switch (_tool) {
        _SlideTool.none => Icons.touch_app_outlined,
        _SlideTool.pen => Icons.edit,
        _SlideTool.laser => Icons.my_location,
        _SlideTool.spot => Icons.light_mode,
      };

  @override
  Widget build(BuildContext context) {
    final strokes = _strokes[_page] ?? const <_Stroke>[];
    final toolActive = !widget.readOnly && _tool != _SlideTool.none;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(children: [
          // 幻灯片 + 注释 + 激光/聚光 一起包进 RepaintBoundary，广播的就是这块。
          RepaintBoundary(
            key: _boundaryKey,
            child: Stack(children: [
              Positioned.fill(child: Container(color: Colors.black)),
              PageView.builder(
                controller: _pc,
                physics: toolActive
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: widget.slideUrls.length,
                onPageChanged: (i) {
                  setState(() => _page = i);
                  if (_live && !widget.readOnly) {
                    _broadcast(); // 翻页立即广播，别等下一拍
                    PlatformService.liveMark(widget.lid!, '第${i + 1}页'); // 录播章节
                  }
                },
                itemBuilder: (_, i) => Center(
                  child: Image.network(
                    widget.slideUrls[i],
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    loadingBuilder: (c, child, prog) => prog == null
                        ? child
                        : const Center(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                    errorBuilder: (_, __, ___) => Center(
                        child: Text('第 ${i + 1} 页加载失败',
                            style: const TextStyle(color: Colors.white54))),
                  ),
                ),
              ),
              // 注释 + 激光/聚光 叠加层(进广播画面)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _OverlayPainter(
                      strokes: [...strokes, if (_cur != null) _cur!],
                      tool: _tool,
                      pointer: _pointer,
                    ),
                  ),
                ),
              ),
            ]),
          ),
          // 工具手势层(在 RepaintBoundary 外，手势本身不进画面)
          if (toolActive)
            Positioned.fill(
              child: GestureDetector(
                onPanStart: (d) => setState(() {
                  if (_tool == _SlideTool.pen) {
                    _cur = _Stroke(_color, [d.localPosition]);
                  } else {
                    _pointer = d.localPosition;
                  }
                }),
                onPanUpdate: (d) => setState(() {
                  if (_tool == _SlideTool.pen) {
                    _cur?.points.add(d.localPosition);
                  } else {
                    _pointer = d.localPosition;
                  }
                }),
                onPanEnd: (_) => setState(() {
                  if (_tool == _SlideTool.pen && _cur != null) {
                    _strokes.putIfAbsent(_page, () => []).add(_cur!);
                    _cur = null;
                  }
                  // 激光/聚光松手即隐(pointer 保留最后位置一拍也行，这里清掉)
                  if (_tool != _SlideTool.pen) _pointer = null;
                }),
              ),
            ),
          // 顶部
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Colors.black.withValues(alpha: 0.4),
              child: Row(children: [
                Text('${_page + 1} / ${widget.slideUrls.length}',
                    style: const TextStyle(color: Colors.white)),
                if (widget.readOnly) ...[
                  const SizedBox(width: 8),
                  const Text('观看模式',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ],
                const Spacer(),
                if (!widget.readOnly) ...[
                  if (widget.onInsertVideo != null)
                    IconButton(
                        tooltip: '插入视频',
                        icon: const Icon(Icons.movie_outlined,
                            color: Colors.white70),
                        onPressed: widget.onInsertVideo),
                  IconButton(
                      tooltip: '导出本页批注',
                      icon: const Icon(Icons.download_outlined,
                          color: Colors.white70),
                      onPressed: _exportAnnotated),
                  IconButton(
                      tooltip: '清除本页注释',
                      icon: const Icon(Icons.cleaning_services_outlined,
                          color: Colors.white70),
                      onPressed: () => setState(() => _strokes.remove(_page))),
                ],
                GestureDetector(
                  onTap: () => Navigator.of(context).maybePop(),
                  child: const Text('关闭',
                      style: TextStyle(
                          color: Color(0xFFE5424D),
                          fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ),
          // 底部控制
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              color: Colors.black.withValues(alpha: 0.4),
              child: Row(children: [
                IconButton(
                    icon: const Icon(Icons.chevron_left,
                        color: Colors.white, size: 30),
                    onPressed: () => _jump(-1)),
                IconButton(
                    icon: const Icon(Icons.chevron_right,
                        color: Colors.white, size: 30),
                    onPressed: () => _jump(1)),
                const Spacer(),
                if (!widget.readOnly) ...[
                  // 颜色(画笔/激光共用)
                  for (final c in const [
                    Color(0xFFFF3B30),
                    Color(0xFFFFCC00),
                    Color(0xFF34C759),
                    Color(0xFF0A84FF)
                  ])
                    GestureDetector(
                      onTap: () => setState(() {
                        _color = c;
                        if (_tool == _SlideTool.none) _tool = _SlideTool.pen;
                      }),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: (_color == c)
                                    ? Colors.white
                                    : Colors.transparent,
                                width: 2)),
                      ),
                    ),
                  const SizedBox(width: 8),
                  // 工具切换：无→画笔→激光笔→聚光灯
                  TextButton.icon(
                    onPressed: _cycleTool,
                    icon: Icon(_toolIcon,
                        size: 18,
                        color: _tool == _SlideTool.none
                            ? Colors.white54
                            : const Color(0xFFFFD24A)),
                    label: Text(_toolLabel,
                        style: TextStyle(
                            fontSize: 12,
                            color: _tool == _SlideTool.none
                                ? Colors.white54
                                : const Color(0xFFFFD24A))),
                  ),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Stroke {
  final Color color;
  final List<Offset> points;
  _Stroke(this.color, this.points);
}

/// 画笔注释 + 激光笔 + 聚光灯 合成层（都在 RepaintBoundary 内，会进直播广播画面）。
class _OverlayPainter extends CustomPainter {
  final List<_Stroke> strokes;
  final _SlideTool tool;
  final Offset? pointer;
  _OverlayPainter({required this.strokes, required this.tool, this.pointer});

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      for (var i = 0; i < s.points.length - 1; i++) {
        canvas.drawLine(s.points[i], s.points[i + 1], paint);
      }
      if (s.points.length == 1) {
        canvas.drawPoints(ui.PointMode.points, s.points, paint);
      }
    }
    final p = pointer;
    if (p == null) return;
    if (tool == _SlideTool.spot) {
      // 聚光灯：四周压暗，只亮手指处一个圆(用 clear 挖洞前先铺暗层)。
      const r = 110.0;
      final layer = Paint();
      canvas.saveLayer(Offset.zero & size, layer);
      canvas.drawRect(Offset.zero & size,
          Paint()..color = Colors.black.withValues(alpha: 0.62));
      canvas.drawCircle(
          p,
          r,
          Paint()
            ..blendMode = BlendMode.clear
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24));
      canvas.restore();
    } else if (tool == _SlideTool.laser) {
      // 激光笔：红色发光点。
      canvas.drawCircle(
          p,
          22,
          Paint()
            ..color = const Color(0x55FF1F1F)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14));
      canvas.drawCircle(p, 9, Paint()..color = const Color(0xFFFF3B30));
      canvas.drawCircle(p, 4, Paint()..color = const Color(0xFFFFFFFF));
    }
  }

  @override
  bool shouldRepaint(_OverlayPainter old) => true;
}
