import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:http/http.dart' as http;
import 'package:wakelock_plus/wakelock_plus.dart';
import '../player/playback_source.dart';
import '../services/transcribe_service.dart';
import '../services/bilibili_service.dart';
import '../text_scale.dart';
import 'package:file_picker/file_picker.dart';

export '../player/playback_source.dart';

/// 播放页：音频显示封面+进度+控制；视频显示画面。基于 media_kit/libmpv，支持所有格式。
class PlayerScreen extends StatefulWidget {
  final PlaybackSource source;
  final bool isFavorite; // 进入时是否已收藏
  final VoidCallback? onToggleFavorite; // 切换收藏（由列表页提供）
  final VoidCallback? onCompleted; // 播完且未单曲循环时回调（自动连播）
  final VoidCallback? onFollow; // 关注当前 UP主（仅 B站）
  final Future<List<BiliComment>> Function(int pn)? onLoadComments; // 评论分页(仅 B站)
  final Future<String> Function(String message)? onPostComment; // 发评论(仅 B站)
  final Duration startAt; // 断点续播起点
  final void Function(int seconds)? onSavePos; // 保存播放进度
  final Future<List<Danmaku>> Function()? onLoadDanmaku; // 加载弹幕(仅B站)
  final Future<String> Function(String msg, int progressMs, int color)?
      onPostDanmaku;
  final Future<String> Function()? onLike; // B站点赞
  final Future<String> Function(int multiply)? onCoin; // B站投币
  final Future<String> Function()? onTriple; // B站一键三连
  final String? bvid; // B站 bvid(分享链接)
  final int seekStep; // 快进/快退步长
  final List<int> bookmarks; // 时间戳书签(秒)
  final void Function(List<int>)? onSaveBookmarks;
  final double initialSpeed; // 该视频上次倍速
  final void Function(double)? onSaveSpeed;
  final Future<void> Function()? onAddToFav; // 收藏到B站
  final Future<List<Map<String, dynamic>>> Function()? onLoadParts; // 分P列表
  final void Function(String cid, String name)? onPlayPart; // 播放某分P
  final Future<void> Function(int score)? onRate; // 平台视频评分
  final Future<List<SubtitleOption>> Function()? onLoadSubtitleOptions; // F13
  final Future<Map<String, String?>> Function()? onLoadMultiSubtitles; // F14
  const PlayerScreen({
    super.key,
    required this.source,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.onCompleted,
    this.onFollow,
    this.onLoadComments,
    this.onPostComment,
    this.startAt = Duration.zero,
    this.onSavePos,
    this.onLoadDanmaku,
    this.onPostDanmaku,
    this.onLike,
    this.onCoin,
    this.onTriple,
    this.bvid,
    this.seekStep = 10,
    this.bookmarks = const [],
    this.onSaveBookmarks,
    this.initialSpeed = 0,
    this.onSaveSpeed,
    this.onAddToFav,
    this.onLoadParts,
    this.onPlayPart,
    this.onRate,
    this.onLoadSubtitleOptions,
    this.onLoadMultiSubtitles,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  final List<StreamSubscription<dynamic>> _subs = [];

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _hasVideo = false;
  String? _error;
  double _speed = 1.0;

  bool _isWebVideo = false; // 网络视频（B站等），可能带烧录角标水印
  bool _cropEdges = false; // 放大裁边，把角落水印推出画面
  bool _audioOnly = false; // 只听声音、显示封面，彻底不显示带水印的画面
  int _aspectMode = 0; // 画面比例：0=适应 1=填充裁切 2=拉伸铺满
  static const List<BoxFit> _aspectFits = [
    BoxFit.contain,
    BoxFit.cover,
    BoxFit.fill
  ];
  static const List<String> _aspectNames = ['适应', '填充裁切', '拉伸铺满'];

  String? _subtitle; // 字幕(SRT)：B站自带或本地AI生成
  bool _subtitleOn = false;
  bool _subApplied = false;
  bool _transcribing = false;
  bool _resumed = false;
  int _lastSavedSec = 0;

  // 桌面悬浮字幕（仅 macOS）
  static const _dsChannel = MethodChannel('xiaoli/desktop_subtitle');
  static const _winChannel = MethodChannel('xiaoli/window');
  bool _desktopSub = false;
  bool _mini = false; // 小窗播放(仅macOS)
  double _dsOpacity = 0.5;
  List<_Cue> _dcues = const [];
  int _dLast = -1;

  void _setDesktopSub(bool on) {
    setState(() => _desktopSub = on);
    if (on) {
      _dcues = _parseSrt(_subtitle ?? '');
      _dLast = -1;
      _dsChannel.invokeMethod('show');
      _dsChannel.invokeMethod('setOpacity', {'opacity': _dsOpacity});
      _pushDesktopSub(_position);
    } else {
      _dsChannel.invokeMethod('hide');
    }
  }

  void _pushDesktopSub(Duration pos) {
    if (_dcues.isEmpty) return;
    final i = _dcues.indexWhere((c) => pos >= c.start && pos < c.end);
    if (i != _dLast) {
      _dLast = i;
      _dsChannel.invokeMethod('update', {'text': i >= 0 ? _dcues[i].text : ''});
    }
  }

  void _showDesktopSubSheet() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2B2B33),
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('桌面悬浮字幕',
                    style: TextStyle(color: Colors.white)),
                subtitle: const Text('置顶在屏幕顶部显示，可拖动',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: _desktopSub,
                onChanged: (v) {
                  _setDesktopSub(v);
                  setSheet(() {});
                },
              ),
              ListTile(
                title: const Text('背景透明度',
                    style: TextStyle(color: Colors.white)),
                subtitle: Slider(
                  value: _dsOpacity,
                  activeColor: cs.primary,
                  onChanged: _desktopSub
                      ? (v) {
                          setState(() => _dsOpacity = v);
                          setSheet(() {});
                          _dsChannel
                              .invokeMethod('setOpacity', {'opacity': v});
                        }
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showComments() {
    final load = widget.onLoadComments;
    if (load == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF24242C),
      isScrollControlled: true,
      builder: (_) => _CommentsSheet(load: load, post: widget.onPostComment),
    );
  }
  void _seekRel(int seconds) {
    var t = _position + Duration(seconds: seconds);
    if (t < Duration.zero) t = Duration.zero;
    if (_duration > Duration.zero && t > _duration) t = _duration;
    _player.seek(t);
  }

  void _frameStep(bool forward) {
    _player.pause();
    var t = _position + Duration(milliseconds: forward ? 40 : -40);
    if (t < Duration.zero) t = Duration.zero;
    _player.seek(t);
  }

  void _rotateVideo() => setState(() => _rotation = (_rotation + 1) % 4);
  void _flipVideo() => setState(() => _flipH = !_flipH);

  void _copyLink() {
    final r = widget.source.resource;
    Clipboard.setData(ClipboardData(text: r));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r.startsWith('http') ? '已复制播放链接' : '已复制路径'),
        duration: const Duration(milliseconds: 1200)));
  }

  Future<void> _jumpTo() async {
    final ctrl = TextEditingController(text: _fmt(_position));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳转到'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration:
              const InputDecoration(hintText: '分:秒 或 时:分:秒，如 1:23'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('跳转')),
        ],
      ),
    );
    if (ok != true) return;
    final parts =
        ctrl.text.trim().split(':').map((e) => int.tryParse(e) ?? 0).toList();
    var sec = 0;
    for (final p in parts) {
      sec = sec * 60 + p;
    }
    _player.seek(Duration(seconds: sec));
  }

  void _toggleSentenceRepeat() {
    if (_dcues.isEmpty) _dcues = _parseSrt(_subtitle ?? '');
    if (_dcues.isEmpty || !_subtitleOn) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先加载并开启字幕')));
      return;
    }
    setState(() {
      if (!_sentenceRepeat) {
        _sentenceRepeat = true;
        _repeatCount = 2;
      } else if (_repeatCount == 2) {
        _repeatCount = 3;
      } else {
        _sentenceRepeat = false;
      }
      _curCue = -1;
      _repeated = 0;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            _sentenceRepeat ? '逐句复读 $_repeatCount 遍' : '逐句复读关闭'),
        duration: const Duration(milliseconds: 1000)));
  }

  // F38: 把 A-B 标记区间（或当前往后 6 秒）导出为 GIF。仅 macOS+本地视频。
  Future<void> _exportGif() async {
    final src = widget.source.resource;
    final ff = TranscribeService.ffmpeg;
    if (src.startsWith('http') || ff == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('GIF 导出仅支持本地视频（需 ffmpeg）')));
      return;
    }
    var start = _aPoint ?? _position;
    var end = _bPoint ?? (start + const Duration(seconds: 6));
    if (end <= start) end = start + const Duration(seconds: 6);
    var dur = (end - start).inMilliseconds / 1000.0;
    if (dur > 60) dur = 60; // 限 60 秒
    final path = await FilePicker.platform
        .saveFile(dialogTitle: '导出 GIF', fileName: 'clip.gif');
    if (path == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('生成 GIF 中…（A-B 区间）')));
    try {
      final r = await Process.run(ff, [
        '-y',
        '-ss',
        '${start.inMilliseconds / 1000.0}',
        '-t',
        '$dur',
        '-i',
        src,
        '-vf',
        'fps=12,scale=480:-1:flags=lanczos',
        '-loop',
        '0',
        path,
      ]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r.exitCode == 0 ? 'GIF 已保存 → $path' : 'GIF 生成失败')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('出错：$e')));
      }
    }
  }

  Future<void> _batchFrames() async {
    final src = widget.source.resource;
    if (src.startsWith('http')) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('批量截帧仅支持本地视频')));
      return;
    }
    if (TranscribeService.ffmpeg == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('需要 ffmpeg')));
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('截帧中…（每 5 秒一帧）')));
    try {
      final r = await Process.run(TranscribeService.ffmpeg!, [
        '-hide_banner',
        '-i',
        src,
        '-vf',
        'fps=1/5',
        '$dir/frame_%04d.png',
      ]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                r.exitCode == 0 ? '截帧完成 → $dir' : '截帧失败(ffmpeg)')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('出错：$e')));
      }
    }
  }

  void _cycleAB() {
    setState(() {
      if (_aPoint == null) {
        _aPoint = _position;
      } else if (_bPoint == null) {
        if (_position > _aPoint!) {
          _bPoint = _position;
        } else {
          _aPoint = _position;
        }
      } else {
        _aPoint = null;
        _bPoint = null;
      }
    });
    final msg = _bPoint != null
        ? 'A-B 循环开启：${_fmt(_aPoint!)} → ${_fmt(_bPoint!)}'
        : _aPoint != null
            ? '已设 A 点 ${_fmt(_aPoint!)}，再点设 B 点'
            : 'A-B 循环已清除';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg), duration: const Duration(milliseconds: 1300)));
  }

  Future<void> _screenshot() async {
    try {
      final bytes = await _player.screenshot(format: 'image/png');
      if (bytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('截图失败')));
        }
        return;
      }
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存截图到…',
        fileName: '小李播放器截图_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      if (path == null) return;
      await File(path).writeAsBytes(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已保存截图：$path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('截图出错：$e')));
      }
    }
  }

  void _toggleMini() {
    setState(() => _mini = !_mini);
    _winChannel.invokeMethod('setMini', {'on': _mini});
  }

  Widget _miniView(ColorScheme cs) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _videoView()),
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              tooltip: '退出小窗',
              icon: const Icon(Icons.close_fullscreen,
                  color: Colors.white70, size: 18),
              onPressed: _toggleMini,
            ),
          ),
        ],
      ),
    );
  }

  static List<_Cue> _parseSrt(String srt) {
    final cues = <_Cue>[];
    final timeRe = RegExp(
        r'(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)');
    for (final block in srt.replaceAll('\r\n', '\n').split(RegExp(r'\n\n+'))) {
      final lines = block.split('\n');
      final ti = lines.indexWhere(timeRe.hasMatch);
      if (ti < 0) continue;
      final m = timeRe.firstMatch(lines[ti])!;
      Duration d(int a, int b, int c, int e) =>
          Duration(hours: a, minutes: b, seconds: c, milliseconds: e);
      final start = d(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!),
          int.parse(m[4]!));
      final end = d(int.parse(m[5]!), int.parse(m[6]!), int.parse(m[7]!),
          int.parse(m[8]!));
      final text = lines.skip(ti + 1).join(' ').trim();
      if (text.isNotEmpty) cues.add(_Cue(start, end, text));
    }
    return cues;
  }

  // 音量 / 循环 / 睡眠定时
  double _volume = 100;
  bool _muted = false;
  bool _loop = false;
  Duration? _aPoint; // A-B 循环 A 点
  Duration? _bPoint; // A-B 循环 B 点
  int _rotation = 0; // 旋转 0/1/2/3×90°
  bool _danmakuOn = false;
  List<Danmaku> _danmaku = const [];
  bool _danmakuLoading = false;
  double _dmOpacity = 1.0;
  double _dmFontScale = 1.0;
  int _dmSpeed = 9;
  int _dmMaxActive = 60;
  List<String> _dmBlock = const [];
  List<RegExp> _dmBlockRegex = const []; // F8 弹幕正则屏蔽
  List<String> _dmPresets = const []; // F9 快捷发送预设
  double _dmTopBlocked = 0; // F10 顶部禁区%
  double _dmBottomBlocked = 0; // F10 底部禁区%
  Map<int, int> _danmakuHistogram = const {}; // F11 弹幕热力(秒→条数)
  String? _subtitleEn; // F14 英文字幕(双语)
  bool _bilingualMode = false; // F14 双语开关
  bool _uiCompact = false; // F23 极简UI
  Color _savedAccent = const Color(0xFFF26B21); // F39 取色前的主题色
  bool _autoPalette = false; // F39 封面取色开关
  bool _paletteApplied = false; // F39 是否已改过主题色
  Duration? _dragPreview; // F22 滑动进度预览
  bool _isDragSeeking = false; // F22
  IconData? _seekHintIcon; // F20 双击快进视觉反馈
  Offset? _doubleTapAt; // F20 双击位置
  Tracks? _tracks;
  bool _onTop = false;
  bool _stopAtEnd = false;
  double _dim = 0.0;
  double? _vw, _vh;
  double _preLongRate = 1.0;
  bool _longPressing = false;
  final List<int> _marks = [];
  int _subOffsetMs = 0; // 字幕延迟
  List<Map<String, dynamic>> _parts = const []; // 分P
  bool _fadeOut = false; // 结束淡出
  bool _sentenceRepeat = false;
  int _repeatCount = 2;
  int _curCue = -1;
  int _repeated = 0;
  bool _flipH = false; // 水平镜像
  Timer? _sleepTimer;
  int? _sleepMin;
  bool _sleepExit = false; // 到点退出app(否则暂停)

  bool _fav = false; // 播放页内收藏态
  bool _fullscreen = false;
  bool _fsControls = true; // 全屏时控件浮层是否显示

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _player.setVolume(_muted ? 0 : _volume);
  }

  void _setVolume(double v) {
    setState(() {
      _volume = v;
      _muted = false;
    });
    _player.setVolume(v);
  }

  void _nudgeVolume(double d) {
    _setVolume((_volume + d).clamp(0, 200));
    _saveVolume();
  }

  Future<void> _saveVolume() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('player_volume', _volume);
  }

  void _toggleLoop() {
    setState(() => _loop = !_loop);
    _player.setPlaylistMode(_loop ? PlaylistMode.single : PlaylistMode.none);
  }

  void _setSleep(int? min) {
    _sleepTimer?.cancel();
    setState(() => _sleepMin = min);
    if (min != null) {
      _sleepTimer = Timer(Duration(minutes: min), () {
        if (!mounted) return;
        if (_sleepExit) {
          exit(0);
        }
        _player.pause();
        setState(() => _sleepMin = null);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('睡眠定时到，已暂停播放')));
      });
    }
  }

  void _enterFullscreen() {
    setState(() {
      _fullscreen = true;
      _fsControls = true;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _exitFullscreen() {
    setState(() => _fullscreen = false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Widget _videoView() {
    final video = ClipRect(
      child: Transform.rotate(
        angle: _rotation * 1.5707963267948966,
        child: Transform.scale(
          scaleX: _flipH ? -1.0 : 1.0,
          child: Transform.scale(
            scale: _cropEdges ? 1.22 : 1.0,
            child: Video(
                controller: _controller,
                controls: NoVideoControls,
                fit: _aspectFits[_aspectMode]),
          ),
        ),
      ),
    );
    if (!_danmakuOn) return video;
    return Stack(
      fit: StackFit.expand,
      children: [
        video,
        Positioned.fill(
          child: IgnorePointer(
            child: _DanmakuLayer(
                items: _danmaku,
                position: _position,
                playing: _playing,
                opacity: _dmOpacity,
                fontScale: _dmFontScale,
                speedSec: _dmSpeed,
                maxActive: _dmMaxActive,
                block: _dmBlock,
                blockRegex: _dmBlockRegex,
                topBlocked: _dmTopBlocked,
                bottomBlocked: _dmBottomBlocked),
          ),
        ),
      ],
    );
  }

  Future<void> _toggleDanmaku() async {
    if (!_danmakuOn && _danmaku.isEmpty && widget.onLoadDanmaku != null) {
      setState(() => _danmakuLoading = true);
      final list = await widget.onLoadDanmaku!();
      if (!mounted) return;
      setState(() {
        _danmaku = list;
        _danmakuLoading = false;
        _danmakuOn = list.isNotEmpty;
      });
      _computeDanmakuHistogram();
      if (list.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有获取到弹幕')));
      }
      return;
    }
    // 无 B站弹幕源（本地/平台视频）且还没导入：走文件导入。
    if (!_danmakuOn && _danmaku.isEmpty && widget.onLoadDanmaku == null) {
      await _importDanmakuFile();
      return;
    }
    setState(() => _danmakuOn = !_danmakuOn);
  }

  // F11: 把弹幕按整数秒分桶计数，供热力时间轴使用。
  void _computeDanmakuHistogram() {
    final h = <int, int>{};
    for (final d in _danmaku) {
      final s = d.time.floor();
      h[s] = (h[s] ?? 0) + 1;
    }
    _danmakuHistogram = h;
  }

  // F12: 从 SRT/VTT/JSON 文件导入弹幕，投射到任意视频上。
  Future<void> _importDanmakuFile() async {
    final res = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['srt', 'vtt', 'json', 'ass']);
    if (res == null || res.files.single.path == null) return;
    final path = res.files.single.path!;
    try {
      final text = await File(path).readAsString();
      final list = path.toLowerCase().endsWith('.json')
          ? Danmaku.parseJson(text)
          : Danmaku.parseSrt(text);
      if (!mounted) return;
      if (list.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('文件里没有可用弹幕')));
        return;
      }
      setState(() {
        _danmaku = list;
        _danmakuOn = true;
      });
      _computeDanmakuHistogram();
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入 ${list.length} 条弹幕')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  Future<void> _sendDanmaku() async {
    final ctrl = TextEditingController();
    var color = 0xFFFFFF;
    const palette = [
      0xFFFFFF, 0xFE0302, 0xFF7204, 0xFFD302, 0x00CD00,
      0x00FFFF, 0x4266BE, 0xFF69B4, 0x9B9B9B, 0x222222,
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('发弹幕'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_dmPresets.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final p in _dmPresets)
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(0, 32)),
                        onPressed: () => setD(() => ctrl.text = p),
                        child: Text(p),
                      ),
                  ],
                ),
              if (_dmPresets.isNotEmpty) const SizedBox(height: 6),
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLength: 100,
                decoration: InputDecoration(
                  hintText: '在 ${_fmt(_position)} 处发一条',
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in palette)
                    GestureDetector(
                      onTap: () => setD(() => color = c),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Color(0xFF000000 | c),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color == c
                                ? Colors.blueAccent
                                : Colors.black26,
                            width: color == c ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('发送')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final msg = ctrl.text.trim();
    if (msg.isEmpty || widget.onPostDanmaku == null) return;
    final ms = _position.inMilliseconds;
    final err = await widget.onPostDanmaku!(msg, ms, color);
    if (!mounted) return;
    if (err.isEmpty) {
      setState(() {
        _danmaku = [..._danmaku, Danmaku(ms / 1000.0, msg, color)]
          ..sort((a, b) => a.time.compareTo(b.time));
        _danmakuOn = true;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('弹幕已发送')));
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('发送失败：$err')));
    }
  }

  // F39: 下载封面、采样主色、设为临时主题强调色（退出时还原）。
  Future<void> _applyCoverPalette() async {
    final url = widget.source.coverUrl;
    if (url == null || url.isEmpty) return;
    try {
      final r = await http
          .get(Uri.parse(url), headers: {'User-Agent': 'Mozilla/5.0'})
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final codec = await ui.instantiateImageCodec(r.bodyBytes,
          targetWidth: 32, targetHeight: 32);
      final frame = await codec.getNextFrame();
      final data =
          await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return;
      final bytes = data.buffer.asUint8List();
      var rs = 0, gs = 0, bs = 0, n = 0;
      for (var i = 0; i + 3 < bytes.length; i += 4) {
        final r8 = bytes[i], g8 = bytes[i + 1], b8 = bytes[i + 2];
        final mx = [r8, g8, b8].reduce((a, b) => a > b ? a : b);
        final mn = [r8, g8, b8].reduce((a, b) => a < b ? a : b);
        if (mx - mn < 28) continue; // 跳过灰白，取有彩度的
        rs += r8;
        gs += g8;
        bs += b8;
        n++;
      }
      if (n == 0) return;
      var col = HSLColor.fromColor(
          Color.fromARGB(255, rs ~/ n, gs ~/ n, bs ~/ n));
      // 校正亮度保证可读
      col = col.withLightness(col.lightness.clamp(0.40, 0.60));
      if (!mounted) return;
      _savedAccent = accentNotifier.value;
      accentNotifier.value = col.toColor();
    } catch (_) {}
  }

  // F16: 应用上次记住的音轨/字幕语言。
  Future<void> _applyPreferredTracks(Tracks t) async {
    try {
      final p = await SharedPreferences.getInstance();
      final pa = p.getString('preferred_audio_lang');
      final ps = p.getString('preferred_subtitle_lang');
      if (pa != null && pa.isNotEmpty) {
        for (final a in t.audio) {
          if ((a.language ?? a.id) == pa) {
            await _player.setAudioTrack(a);
            break;
          }
        }
      }
      if (ps != null && ps.isNotEmpty) {
        for (final s in t.subtitle) {
          if ((s.language ?? s.id) == ps) {
            await _player.setSubtitleTrack(s);
            break;
          }
        }
      }
    } catch (_) {}
  }

  // F20: 左/右三分之一双击快退/快进，中间双击进全屏。
  void _handleDoubleTapZone() {
    final w = MediaQuery.of(context).size.width;
    final x = _doubleTapAt?.dx ?? w / 2;
    if (x < w * 0.34) {
      _seekRel(-widget.seekStep);
      _flashSeekHint(Icons.fast_rewind);
    } else if (x > w * 0.66) {
      _seekRel(widget.seekStep);
      _flashSeekHint(Icons.fast_forward);
    } else {
      _enterFullscreen();
    }
  }

  void _flashSeekHint(IconData icon) {
    setState(() => _seekHintIcon = icon);
    Future.delayed(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _seekHintIcon = null);
    });
  }

  void _longRate(bool on) {
    if (on) {
      _preLongRate = _speed;
      _player.setRate(2.0);
      setState(() => _longPressing = true);
    } else {
      _player.setRate(_preLongRate);
      setState(() => _longPressing = false);
    }
  }

  void _toggleOnTop() {
    setState(() => _onTop = !_onTop);
    _winChannel.invokeMethod('setAlwaysOnTop', {'on': _onTop});
  }

  void _showTracks() {
    final t = _tracks;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2B2B33),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (t != null && t.audio.isNotEmpty) ...[
                const ListTile(
                    dense: true,
                    title: Text('音轨',
                        style: TextStyle(color: Colors.white54, fontSize: 12))),
                for (final a in t.audio)
                  ListTile(
                    leading: const Icon(Icons.audiotrack, color: Colors.white70),
                    title: Text(a.title ?? a.language ?? a.id,
                        style: const TextStyle(color: Colors.white)),
                    onTap: () {
                      _player.setAudioTrack(a);
                      SharedPreferences.getInstance().then((p) => p.setString(
                          'preferred_audio_lang', a.language ?? a.id));
                      Navigator.pop(context);
                    },
                  ),
              ],
              if (t != null && t.subtitle.isNotEmpty) ...[
                const ListTile(
                    dense: true,
                    title: Text('内嵌字幕轨',
                        style: TextStyle(color: Colors.white54, fontSize: 12))),
                for (final sub in t.subtitle)
                  ListTile(
                    leading:
                        const Icon(Icons.subtitles, color: Colors.white70),
                    title: Text(sub.title ?? sub.language ?? sub.id,
                        style: const TextStyle(color: Colors.white)),
                    onTap: () {
                      _player.setSubtitleTrack(sub);
                      SharedPreferences.getInstance().then((p) => p.setString(
                          'preferred_subtitle_lang', sub.language ?? sub.id));
                      Navigator.pop(context);
                    },
                  ),
              ],
              if (t == null || (t.audio.isEmpty && t.subtitle.isEmpty))
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('没有可选轨道',
                      style: TextStyle(color: Colors.white54)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showVideoInfo() {
    final b = StringBuffer();
    if ((_vw ?? 0) > 0) b.writeln('分辨率：${_vw!.toInt()} × ${_vh!.toInt()}');
    b.writeln('时长：${_fmt(_duration)}');
    final t = _tracks;
    if (t != null) {
      b.writeln('音轨：${t.audio.length} 条');
      b.writeln('内嵌字幕轨：${t.subtitle.length} 条');
    }
    b.write('来源：${widget.source.resource}');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('视频信息'),
        content: SelectableText(b.toString()),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  void _showDimSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2B2B33),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          child: Row(
            children: [
              const Icon(Icons.nightlight_round, color: Colors.white70),
              const SizedBox(width: 8),
              const Text('画面调暗',
                  style: TextStyle(color: Colors.white)),
              Expanded(
                child: Slider(
                  value: _dim,
                  max: 0.85,
                  onChanged: (v) {
                    setState(() => _dim = v);
                    setS(() {});
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _coin() async {
    if (widget.onCoin == null) return;
    final ctrl = TextEditingController(text: '2');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('投币'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '投几个币'),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 6),
            const Text('B站每视频上限 2 个，超出会按 2 个投',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('投币')),
        ],
      ),
    );
    if (ok != true) return;
    final want = int.tryParse(ctrl.text.trim()) ?? 0;
    if (want <= 0) return;
    final use = want > 2 ? 2 : want;
    final msg = await widget.onCoin!(use);
    if (mounted) {
      final extra = want > 2 ? '（你想投 $want 个，但 B站每视频上限 2 个）' : '';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$msg$extra')));
    }
  }

  void _addMark() {
    setState(() {
      _marks.add(_position.inSeconds);
      _marks.sort();
    });
    widget.onSaveBookmarks?.call(_marks);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已加书签 ${_fmt(_position)}'),
        duration: const Duration(milliseconds: 1000)));
  }

  void _showMarks() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2B2B33),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('时间戳书签',
                        style: TextStyle(color: Colors.white54, fontSize: 12))),
                if (_marks.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('还没有书签（点右上角书签按钮添加）',
                          style: TextStyle(color: Colors.white54))),
                for (final m in _marks)
                  ListTile(
                    leading:
                        const Icon(Icons.bookmark, color: Colors.white70),
                    title: Text(_fmt(Duration(seconds: m)),
                        style: const TextStyle(color: Colors.white)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.white54),
                      onPressed: () {
                        setState(() => _marks.remove(m));
                        widget.onSaveBookmarks?.call(_marks);
                        setS(() {});
                      },
                    ),
                    onTap: () {
                      _player.seek(Duration(seconds: m));
                      Navigator.pop(ctx);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _exportSubtitle() async {
    if (_subtitle == null || _subtitle!.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前没有字幕')));
      return;
    }
    final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出字幕',
        fileName: '字幕_${DateTime.now().millisecondsSinceEpoch}.srt');
    if (path == null) return;
    await File(path).writeAsString(_subtitle!);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导出 $path')));
    }
  }

  Future<void> _exportDanmaku() async {
    if (_danmaku.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有弹幕（先开弹幕加载）')));
      return;
    }
    final b = StringBuffer();
    for (final d in _danmaku) {
      b.writeln('[${_fmt(Duration(seconds: d.time.toInt()))}] ${d.text}');
    }
    final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出弹幕',
        fileName: '弹幕_${DateTime.now().millisecondsSinceEpoch}.txt');
    if (path == null) return;
    await File(path).writeAsString(b.toString());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出 ${_danmaku.length} 条弹幕')));
    }
  }

  void _copyBiliLink() {
    if (widget.bvid == null) return;
    Clipboard.setData(ClipboardData(
        text: 'https://www.bilibili.com/video/${widget.bvid}'));
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制 B站 视频链接')));
  }

  void _showParts() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2B2B33),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('分P 选集',
                      style: TextStyle(color: Colors.white54, fontSize: 12))),
              for (final pt in _parts)
                ListTile(
                  leading: Text('P${pt['page']}',
                      style: const TextStyle(color: Colors.white70)),
                  title: Text('${pt['part']}',
                      style: const TextStyle(color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  onTap: () {
                    widget.onPlayPart?.call(
                        pt['cid'] as String, 'P${pt['page']} ${pt['part']}');
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showRate() async {
    final score = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('给这个平台视频评分'),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 1; i <= 5; i++)
              IconButton(
                icon: const Icon(Icons.star, color: Colors.amber),
                onPressed: () => Navigator.pop(ctx, i),
              ),
          ],
        ),
      ),
    );
    if (score == null) return;
    await widget.onRate?.call(score);
  }

  Future<void> _bvAction(Future<String> Function()? fn) async {
    if (fn == null) return;
    final msg = await fn();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _autoLoadSidecarSub(String videoPath) {
    final dot = videoPath.lastIndexOf('.');
    if (dot < 0) return;
    final base = videoPath.substring(0, dot);
    for (final ext in ['.srt', '.ass', '.vtt']) {
      final fs = File('$base$ext');
      if (fs.existsSync()) {
        try {
          final content = fs.readAsStringSync();
          if (content.isNotEmpty) {
            _subtitle = content;
            _subtitleOn = true;
            _subApplied = false;
          }
        } catch (_) {}
        break;
      }
    }
  }

  Future<void> _loadSubtitleFile() async {
    final res = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['srt', 'ass', 'vtt', 'txt']);
    final path = res?.files.single.path;
    if (path == null) return;
    try {
      final content = await File(path).readAsString();
      if (!mounted) return;
      setState(() {
        _subtitle = content;
        _subtitleOn = true;
        _subApplied = false;
      });
      _applySubtitle();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已加载外挂字幕')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('字幕加载失败：$e')));
      }
    }
  }

  Widget _dmSlider(String label, double v, double min, double max,
      ValueChanged<double> onCh, StateSetter setS) {
    return Row(children: [
      SizedBox(
          width: 110,
          child: Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 13))),
      Expanded(
        child: Slider(
          value: v.clamp(min, max),
          min: min,
          max: max,
          onChanged: (x) {
            onCh(x);
            setS(() {});
          },
        ),
      ),
    ]);
  }

  Future<void> _saveDmPresets() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('danmaku_presets', jsonEncode(_dmPresets));
  }

  // F13/F14: 字幕语言选择 + 双语对照。
  Future<void> _showSubtitleOptions() async {
    final loader = widget.onLoadSubtitleOptions;
    if (loader == null) return;
    final opts = await loader();
    if (!mounted) return;
    if (opts.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('这个视频没有字幕轨')));
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2B2B33),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
                dense: true,
                title: Text('选择字幕语言',
                    style: TextStyle(color: Colors.white70))),
            for (final o in opts)
              ListTile(
                dense: true,
                leading: const Icon(Icons.closed_caption, color: Colors.white54),
                title: Text(o.lanDoc,
                    style: const TextStyle(color: Colors.white)),
                subtitle: o.author.isEmpty
                    ? null
                    : Text(o.author,
                        style: const TextStyle(color: Colors.white38)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final srt = await _bili.downloadSubtitle(o.url);
                  if (!mounted || srt == null) return;
                  setState(() {
                    _subtitle = srt;
                    _subtitleOn = true;
                  });
                  _applySubtitle();
                },
              ),
            if (widget.onLoadMultiSubtitles != null)
              SwitchListTile(
                value: _bilingualMode,
                title: const Text('中英双语对照',
                    style: TextStyle(color: Colors.white)),
                onChanged: (on) async {
                  Navigator.pop(ctx);
                  if (on) {
                    final m = await widget.onLoadMultiSubtitles!();
                    if (!mounted) return;
                    setState(() {
                      _subtitle = m['zh'] ?? _subtitle;
                      _subtitleEn = m['en'];
                      _bilingualMode = m['en'] != null;
                      _subtitleOn = true;
                    });
                    if (m['en'] == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('没有英文字幕，已用单语')));
                    }
                  } else {
                    setState(() => _bilingualMode = false);
                  }
                  _applySubtitle();
                },
              ),
          ],
        ),
      ),
    );
  }

  final BilibiliService _bili = BilibiliService();

  // F15: 在字幕里搜词，列出所有出现时间，点击跳转。
  void _showSubtitleSearch() {
    final cues = _parseSrt(_subtitle ?? '');
    if (cues.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前没有字幕')));
      return;
    }
    final ctrl = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF2B2B33),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) {
          final q = ctrl.text.trim().toLowerCase();
          final hits = q.isEmpty
              ? cues
              : cues.where((c) => c.text.toLowerCase().contains(q)).toList();
          return Padding(
            padding: EdgeInsets.fromLTRB(
                16, 14, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: '搜字幕…',
                    hintStyle: TextStyle(color: Colors.white38),
                    prefixIcon: Icon(Icons.search, color: Colors.white54),
                  ),
                  onChanged: (_) => setS(() {}),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: MediaQuery.of(ctx).size.height * 0.4,
                  child: ListView.builder(
                    itemCount: hits.length,
                    itemBuilder: (_, i) => ListTile(
                      dense: true,
                      leading: Text(_fmt(hits[i].start),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                      title: Text(hits[i].text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white)),
                      onTap: () {
                        _player.seek(hits[i].start);
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showDanmakuSettings() {
    final blockCtrl = TextEditingController(text: _dmBlock.join(' '));
    final regexCtrl = TextEditingController(
        text: _dmBlockRegex.map((r) => r.pattern).join('\n'));
    final presetCtrl = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF2B2B33),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(
              16, 14, 16, 28 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('弹幕设置',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
                _dmSlider('不透明度', _dmOpacity, 0.2, 1.0,
                    (v) => setState(() => _dmOpacity = v), setS),
                _dmSlider('字号', _dmFontScale, 0.6, 1.8,
                    (v) => setState(() => _dmFontScale = v), setS),
                _dmSlider('速度(大=慢)', _dmSpeed.toDouble(), 4, 16,
                    (v) => setState(() => _dmSpeed = v.round()), setS),
                _dmSlider('密度上限', _dmMaxActive.toDouble(), 10, 100,
                    (v) => setState(() => _dmMaxActive = v.round()), setS),
                _dmSlider('顶部禁区(%)', _dmTopBlocked, 0, 50, (v) {
                  setState(() => _dmTopBlocked = v);
                  SharedPreferences.getInstance()
                      .then((p) => p.setDouble('dm_top_blocked', v));
                }, setS),
                _dmSlider('底部禁区(%)', _dmBottomBlocked, 0, 50, (v) {
                  setState(() => _dmBottomBlocked = v);
                  SharedPreferences.getInstance()
                      .then((p) => p.setDouble('dm_bottom_blocked', v));
                }, setS),
                const SizedBox(height: 6),
                TextField(
                  controller: blockCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: '屏蔽词（空格分隔）',
                    labelStyle: TextStyle(color: Colors.white54),
                  ),
                  onChanged: (val) => setState(() => _dmBlock = val
                      .split(RegExp(r'\s+'))
                      .where((e) => e.isNotEmpty)
                      .toList()),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: regexCtrl,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: '正则屏蔽（每行一条）',
                    labelStyle: TextStyle(color: Colors.white54),
                  ),
                  onChanged: (val) async {
                    final list = <RegExp>[];
                    for (final line in val.split('\n')) {
                      final t = line.trim();
                      if (t.isEmpty) continue;
                      try {
                        list.add(RegExp(t, caseSensitive: false));
                      } catch (_) {}
                    }
                    setState(() => _dmBlockRegex = list);
                    final p = await SharedPreferences.getInstance();
                    await p.setString('dm_block_regex', val);
                  },
                ),
                const SizedBox(height: 10),
                const Text('快捷发送预设',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final p in _dmPresets)
                      Chip(
                        label: Text(p),
                        backgroundColor: const Color(0xFF3A3A44),
                        labelStyle: const TextStyle(color: Colors.white),
                        deleteIconColor: Colors.white54,
                        onDeleted: () async {
                          setState(() => _dmPresets =
                              _dmPresets.where((x) => x != p).toList());
                          await _saveDmPresets();
                          setS(() {});
                        },
                      ),
                  ],
                ),
                TextField(
                  controller: presetCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: '加一个预设，回车保存',
                    hintStyle: TextStyle(color: Colors.white38),
                  ),
                  onSubmitted: (val) async {
                    final t = val.trim();
                    if (t.isEmpty || _dmPresets.contains(t)) return;
                    setState(() => _dmPresets = [..._dmPresets, t]);
                    presetCtrl.clear();
                    await _saveDmPresets();
                    setS(() {});
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fullscreenView(ColorScheme cs) {
    final durMs = _duration.inMilliseconds.toDouble();
    final posMs =
        _position.inMilliseconds.clamp(0, _duration.inMilliseconds).toDouble();
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _fsControls = !_fsControls),
        child: Stack(
          children: [
            Positioned.fill(child: _videoView()),
            if (_fsControls) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black54,
                  padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top + 4, bottom: 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.fullscreen_exit,
                            color: Colors.white),
                        tooltip: '退出全屏',
                        onPressed: _exitFullscreen,
                      ),
                      Expanded(
                        child: Text(widget.source.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black54,
                  padding: EdgeInsets.fromLTRB(
                      8, 4, 8, MediaQuery.of(context).padding.bottom + 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(_playing ? Icons.pause : Icons.play_arrow,
                            color: Colors.white),
                        onPressed: () => _player.playOrPause(),
                      ),
                      Text(_fmt(_position),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                      Expanded(
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 3,
                            thumbColor: cs.primary,
                            activeTrackColor: cs.primary,
                            inactiveTrackColor: Colors.white24,
                            overlayShape: SliderComponentShape.noOverlay,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                          ),
                          child: Slider(
                            min: 0,
                            max: durMs > 0 ? durMs : 1,
                            value: durMs > 0 ? posMs : 0,
                            onChanged: (v) =>
                                _player.seek(Duration(milliseconds: v.toInt())),
                          ),
                        ),
                      ),
                      Text(_fmt(_duration),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _applySubtitle() {
    var srt = _subtitle;
    if (srt == null) return;
    // F14: 双语模式把中英两条字幕合并显示。
    if (_bilingualMode && _subtitleEn != null && _subtitleEn!.isNotEmpty) {
      srt = _mergeBilingual(srt, _subtitleEn!);
    }
    _player.setSubtitleTrack(_subtitleOn
        ? SubtitleTrack.data(
            _subOffsetMs == 0 ? srt : _shiftSrt(srt, _subOffsetMs))
        : SubtitleTrack.no());
  }

  // F14: 以第一条字幕为时间轴，把第二条里时间最接近的文本拼到下一行。
  String _mergeBilingual(String a, String b) {
    final ca = _parseSrt(a);
    final cb = _parseSrt(b);
    if (ca.isEmpty) return b;
    if (cb.isEmpty) return a;
    final sb = StringBuffer();
    for (var i = 0; i < ca.length; i++) {
      final c = ca[i];
      // 找时间重叠或最接近的第二语言句
      _Cue? match;
      var bestGap = const Duration(days: 1);
      for (final x in cb) {
        if (x.start < c.end && x.end > c.start) {
          match = x;
          break;
        }
        final gap = (x.start - c.start).abs();
        if (gap < bestGap) {
          bestGap = gap;
          if (gap < const Duration(seconds: 1)) match = x;
        }
      }
      sb.writeln('${i + 1}');
      sb.writeln('${_srt(c.start)} --> ${_srt(c.end)}');
      sb.writeln(c.text);
      if (match != null) sb.writeln(match.text);
      sb.writeln();
    }
    return sb.toString();
  }

  String _srt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final ms = d.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
    return '$h:$m:$s,$ms';
  }

  String _shiftSrt(String srt, int offsetMs) {
    final re = RegExp(r'(\d{2}):(\d{2}):(\d{2}),(\d{3})');
    return srt.replaceAllMapped(re, (m) {
      var ms = int.parse(m[1]!) * 3600000 +
          int.parse(m[2]!) * 60000 +
          int.parse(m[3]!) * 1000 +
          int.parse(m[4]!) +
          offsetMs;
      if (ms < 0) ms = 0;
      final h = ms ~/ 3600000;
      ms %= 3600000;
      final mn = ms ~/ 60000;
      ms %= 60000;
      final sec = ms ~/ 1000;
      final mmm = ms % 1000;
      return '${h.toString().padLeft(2, '0')}:${mn.toString().padLeft(2, '0')}'
          ':${sec.toString().padLeft(2, '0')},${mmm.toString().padLeft(3, '0')}';
    });
  }

  void _adjustSubDelay(int deltaMs) {
    setState(() => _subOffsetMs += deltaMs);
    _applySubtitle();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text('字幕延迟 ${(_subOffsetMs / 1000).toStringAsFixed(1)} 秒'),
        duration: const Duration(milliseconds: 900)));
  }

  /// 本地 AI 生成字幕（用于 B站 也没字幕的视频/音频）。
  Future<void> _aiSubtitle() async {
    if (_transcribing) return;
    setState(() => _transcribing = true);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('AI 生成字幕中…需要下载音频+转写，可能要几十秒'),
        duration: Duration(seconds: 4)));
    final srt = await TranscribeService.transcribe(
      widget.source.resource,
      headers: widget.source.headers,
    );
    if (!mounted) return;
    setState(() {
      _transcribing = false;
      if (srt != null) {
        _subtitle = srt;
        _subtitleOn = true;
        _subApplied = true;
      }
    });
    if (srt != null) {
      _applySubtitle();
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('AI 字幕已生成')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('生成失败：可能无人声、或工具/模型缺失')));
    }
  }

  String _fmtSpeed(double s) {
    final r = (s * 100).round() / 100;
    return r == r.roundToDouble() ? '${r.toInt()}x' : '${r}x';
  }

  void _setSpeed(double v) {
    v = (v * 100).round() / 100;
    if (v < 0.1) v = 0.1; // 下限防止卡死；上限无限制
    setState(() => _speed = v);
    _player.setRate(v);
    SharedPreferences.getInstance().then((p) => p.setDouble('player_speed', v));
    widget.onSaveSpeed?.call(v);
  }

  Future<void> _customSleep() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义睡眠分钟'),
        content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: '分钟')),
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
    if (ok != true) return;
    final m = int.tryParse(ctrl.text.trim()) ?? 0;
    if (m > 0) _setSleep(m);
  }

  void _showSpeedSheet() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2B2B33),
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) {
          void apply(double v) {
            _setSpeed(v);
            setSheet(() {});
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('播放速度  ${_fmtSpeed(_speed)}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline,
                          color: Colors.white),
                      onPressed: () => apply(_speed - 0.25),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          activeTrackColor: cs.primary,
                          thumbColor: cs.primary,
                          inactiveTrackColor: Colors.white24,
                          overlayShape: SliderComponentShape.noOverlay,
                        ),
                        child: Slider(
                          min: 0.25,
                          max: 5.0,
                          value: _speed.clamp(0.25, 5.0),
                          onChanged: apply,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline,
                          color: Colors.white),
                      onPressed: () => apply(_speed + 0.25),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final s in const [0.5, 1.0, 1.5, 2.0, 3.0])
                      ActionChip(
                        label: Text(_fmtSpeed(s)),
                        backgroundColor: const Color(0xFF3A3A44),
                        labelStyle: const TextStyle(color: Colors.white),
                        onPressed: () => apply(s),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('滑块 0.25x–5x；用 − / ＋ 可超过 5x，无上限',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isWebVideo =
        widget.source.isVideo && widget.source.resource.startsWith('http');
    _cropEdges = _isWebVideo; // 网络视频默认裁边去角标水印
    _fav = widget.isFavorite;
    _marks.addAll(widget.bookmarks);
    if (!widget.source.resource.startsWith('http')) {
      _autoLoadSidecarSub(widget.source.resource);
    }
    if (widget.onLoadParts != null) {
      widget.onLoadParts!().then((p) {
        if (mounted && p.length > 1) setState(() => _parts = p);
      });
    }
    _subs.add(_player.stream.completed.listen((done) {
      if (done && !_loop && !_stopAtEnd && mounted) widget.onCompleted?.call();
    }));
    _subs.add(_player.stream.position.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
      if (_desktopSub) _pushDesktopSub(p);
      if (_aPoint != null && _bPoint != null && p >= _bPoint!) {
        _player.seek(_aPoint!);
      }
      if (_fadeOut && _playing && _duration > Duration.zero) {
        final rem = (_duration - p).inMilliseconds;
        if (rem > 0 && rem < 6000) {
          _player.setVolume((_muted ? 0.0 : _volume) * (rem / 6000));
        }
      }
      if (_sentenceRepeat && _dcues.isNotEmpty && _subtitleOn) {
        final i = _dcues.indexWhere((c) => p >= c.start && p < c.end);
        if (i >= 0 && i != _curCue) {
          _curCue = i;
          _repeated = 0;
        } else if (_curCue >= 0 && p >= _dcues[_curCue].end) {
          _repeated++;
          if (_repeated < _repeatCount) {
            _player.seek(_dcues[_curCue].start);
          } else {
            _curCue = -1;
          }
        }
      }
      final sec = p.inSeconds;
      if (widget.onSavePos != null && sec > 0 && (sec - _lastSavedSec).abs() >= 5) {
        _lastSavedSec = sec;
        widget.onSavePos!(sec);
      }
    }));
    _subs.add(_player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
      if (!_resumed &&
          d > Duration.zero &&
          widget.startAt > const Duration(seconds: 3) &&
          widget.startAt < d - const Duration(seconds: 5)) {
        _resumed = true;
        _player.seek(widget.startAt);
      }
      // 媒体已加载（有时长）后再贴字幕，避免过早设置不生效
      if (!_subApplied && _subtitle != null && d > Duration.zero) {
        _subApplied = true;
        _applySubtitle();
      }
    }));
    _subs.add(_player.stream.playing.listen((p) {
      if (mounted) {
        setState(() {
          _playing = p;
          if (p) _error = null; // 成功起播 → 清残留错误，避免非致命错误误报“播放失败”
        });
      }
      // F45: Android 播放时保持唤醒，暂停立即释放省电。
      if (Platform.isAndroid) {
        p ? WakelockPlus.enable() : WakelockPlus.disable();
      }
      // F39: 首次起播按封面取色（开关开启时）。
      if (p && _autoPalette && !_paletteApplied) {
        _paletteApplied = true;
        _applyCoverPalette();
      }
    }));
    _subs.add(_player.stream.videoParams.listen((v) {
      final has = (v.w ?? 0) > 0 && (v.h ?? 0) > 0;
      if (mounted) {
        setState(() {
          _hasVideo = has;
          _vw = (v.w ?? 0).toDouble();
          _vh = (v.h ?? 0).toDouble();
        });
      }
    }));
    _subs.add(_player.stream.tracks.listen((t) {
      if (mounted) setState(() => _tracks = t);
      _applyPreferredTracks(t); // F16
    }));
    _subs.add(_player.stream.error.listen((e) {
      if (mounted) setState(() => _error = e);
    }));
    // F48: Android 屏幕锁定时暂停视频（音频可后台续播）。
    if (Platform.isAndroid) {
      const MethodChannel('xiaoli/screen_lock')
          .setMethodCallHandler((call) async {
        if (call.method == 'screenLocked' && mounted) {
          if (_hasVideo || widget.source.isVideo) _player.pause();
        }
        return null;
      });
    }
    _player.open(
      Media(widget.source.resource, httpHeaders: widget.source.headers),
    );
    // 字幕异步取到后默认开启（不阻塞起播）
    widget.source.subtitleFuture?.then((srt) {
      if (!mounted || srt == null || srt.isEmpty) return;
      setState(() {
        _subtitle = srt;
        _subtitleOn = true;
      });
      _applySubtitle();
    });
    SharedPreferences.getInstance().then((p) {
      final v = p.getDouble('player_volume');
      if (v != null && mounted) {
        setState(() => _volume = v);
        _player.setVolume(v);
      }
      final sp = widget.initialSpeed > 0
          ? widget.initialSpeed
          : p.getDouble('player_speed');
      if (sp != null && sp != 1.0 && mounted) {
        setState(() => _speed = sp);
        _player.setRate(sp);
      }
      _fadeOut = p.getBool('fade_out') ?? false;
      final am = p.getInt('aspect_mode');
      if (am != null && am != 0 && mounted) {
        setState(() => _aspectMode = am.clamp(0, 2));
      }
      // 弹幕预设/正则/禁区
      try {
        final pr = p.getString('danmaku_presets');
        if (pr != null) {
          _dmPresets = (jsonDecode(pr) as List).map((e) => '$e').toList();
        }
      } catch (_) {}
      final rx = p.getString('dm_block_regex');
      if (rx != null && rx.isNotEmpty) {
        final list = <RegExp>[];
        for (final line in rx.split('\n')) {
          final t = line.trim();
          if (t.isEmpty) continue;
          try {
            list.add(RegExp(t, caseSensitive: false));
          } catch (_) {}
        }
        _dmBlockRegex = list;
      }
      _dmTopBlocked = p.getDouble('dm_top_blocked') ?? 0;
      _dmBottomBlocked = p.getDouble('dm_bottom_blocked') ?? 0;
      final uc = p.getBool('player_ui_compact') ?? false;
      _autoPalette = p.getBool('auto_palette') ?? false;
      final sfs = p.getDouble('subtitle_font_scale');
      if (mounted) {
        setState(() {
          _uiCompact = uc;
          if (sfs != null) _dmFontScale = sfs;
        });
      }
      if ((p.getBool('fade_in') ?? false) && mounted) {
        final target = _muted ? 0.0 : _volume;
        _player.setVolume(0);
        var cur = 0.0;
        Timer.periodic(const Duration(milliseconds: 100), (tm) {
          cur += target / 15;
          if (cur >= target || !mounted) {
            _player.setVolume(target);
            tm.cancel();
          } else {
            _player.setVolume(cur);
          }
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 隐藏窗口(全局热键/Cmd+H)时暂停播放(仅 macOS)。
    if (Platform.isMacOS && state == AppLifecycleState.hidden) {
      _player.pause();
    }
  }

  @override
  void dispose() {
    if (_position > const Duration(seconds: 3)) {
      widget.onSavePos?.call(_position.inSeconds);
    }
    WidgetsBinding.instance.removeObserver(this);
    _sleepTimer?.cancel();
    if (_paletteApplied) accentNotifier.value = _savedAccent; // F39 还原主题色
    if (Platform.isAndroid) WakelockPlus.disable(); // F45
    if (_desktopSub) _dsChannel.invokeMethod('hide');
    if (_mini) _winChannel.invokeMethod('setMini', {'on': false});
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0
        ? '${d.inHours.toString().padLeft(2, '0')}:$m:$s'
        : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final durMs = _duration.inMilliseconds.toDouble();
    final posMs =
        _position.inMilliseconds.clamp(0, _duration.inMilliseconds).toDouble();
    final showVideo = !_audioOnly && (widget.source.isVideo || _hasVideo);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.space): () =>
            _player.playOrPause(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _player.seek(_position - const Duration(seconds: 10)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _player.seek(_position + const Duration(seconds: 10)),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _nudgeVolume(5),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _nudgeVolume(-5),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_fullscreen) _exitFullscreen();
        },
      },
      child: Focus(
        autofocus: true,
        child: (showVideo && _mini)
            ? _miniView(cs)
            : (showVideo && _fullscreen)
                ? _fullscreenView(cs)
                : Scaffold(
      backgroundColor: const Color(0xFF1E1E26),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E26),
        foregroundColor: Colors.white,
        title: Text(widget.source.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: _uiCompact ? '完整界面' : '极简界面',
            icon: Icon(_uiCompact ? Icons.unfold_more : Icons.unfold_less,
                color: Colors.white70),
            onPressed: () {
              setState(() => _uiCompact = !_uiCompact);
              SharedPreferences.getInstance()
                  .then((p) => p.setBool('player_ui_compact', _uiCompact));
            },
          ),
          if (widget.onToggleFavorite != null)
            IconButton(
              tooltip: _fav ? '取消收藏' : '收藏',
              icon: Icon(_fav ? Icons.favorite : Icons.favorite_border,
                  color: _fav ? Colors.redAccent : Colors.white70),
              onPressed: () {
                setState(() => _fav = !_fav);
                widget.onToggleFavorite!.call();
              },
            ),
          if (widget.onFollow != null)
            IconButton(
              tooltip: '关注 UP主',
              icon: const Icon(Icons.person_add_alt, color: Colors.white70),
              onPressed: widget.onFollow,
            ),
          if (widget.onLoadComments != null)
            IconButton(
              tooltip: '评论',
              icon: const Icon(Icons.comment_outlined, color: Colors.white70),
              onPressed: _showComments,
            ),
          if (_subtitle != null && Platform.isMacOS)
            IconButton(
              tooltip: '桌面悬浮字幕',
              icon: Icon(
                  _desktopSub
                      ? Icons.picture_in_picture
                      : Icons.picture_in_picture_outlined,
                  color: _desktopSub
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white70),
              onPressed: _showDesktopSubSheet,
            ),
          if (_subtitle != null)
            IconButton(
              tooltip: _subtitleOn ? '关闭字幕' : '显示字幕',
              icon: Icon(
                  _subtitleOn
                      ? Icons.closed_caption
                      : Icons.closed_caption_off,
                  color: _subtitleOn
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white70),
              onPressed: () {
                setState(() => _subtitleOn = !_subtitleOn);
                _applySubtitle();
              },
            ),
          if (_subtitle != null && !_uiCompact)
            IconButton(
              tooltip: '搜索字幕',
              icon: const Icon(Icons.manage_search, color: Colors.white70),
              onPressed: _showSubtitleSearch,
            ),
          if (_subtitle == null && TranscribeService.available)
            _transcribing
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white70)),
                  )
                : IconButton(
                    tooltip: 'AI 生成字幕（本地）',
                    icon: const Icon(Icons.subtitles_outlined,
                        color: Colors.white70),
                    onPressed: _aiSubtitle,
                  ),
          if (!_uiCompact && (widget.source.isVideo || _hasVideo)) ...[
            IconButton(
              tooltip: _audioOnly ? '显示画面' : '只听声音(显示封面·无水印)',
              icon: Icon(_audioOnly ? Icons.music_note : Icons.image_outlined,
                  color: _audioOnly
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white70),
              onPressed: () => setState(() => _audioOnly = !_audioOnly),
            ),
            if (!_audioOnly)
              IconButton(
                tooltip: _cropEdges ? '取消裁边' : '放大裁边·去角标水印',
                icon: Icon(_cropEdges ? Icons.crop : Icons.crop_free,
                    color: _cropEdges
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white70),
                onPressed: () => setState(() => _cropEdges = !_cropEdges),
              ),
            if (!_audioOnly)
              IconButton(
                tooltip: '画面比例·${_aspectNames[_aspectMode]}',
                icon: Icon(Icons.aspect_ratio,
                    color: _aspectMode == 0
                        ? Colors.white70
                        : Theme.of(context).colorScheme.primary),
                onPressed: () {
                  setState(() => _aspectMode = (_aspectMode + 1) % 3);
                  SharedPreferences.getInstance()
                      .then((p) => p.setInt('aspect_mode', _aspectMode));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      duration: const Duration(milliseconds: 700),
                      content: Text('画面比例：${_aspectNames[_aspectMode]}')));
                },
              ),
            if (!_audioOnly && Platform.isMacOS)
              IconButton(
                tooltip: '小窗播放',
                icon: Icon(
                    _mini
                        ? Icons.close_fullscreen
                        : Icons.picture_in_picture_alt,
                    color: _mini ? cs.primary : Colors.white70),
                onPressed: _toggleMini,
              ),
            if (widget.onLoadDanmaku != null)
              IconButton(
                tooltip: _danmakuOn ? '关闭弹幕' : '弹幕',
                icon: Icon(_danmakuOn ? Icons.forum : Icons.forum_outlined,
                    color: _danmakuOn
                        ? Colors.lightBlueAccent
                        : Colors.white70),
                onPressed: _danmakuLoading ? null : _toggleDanmaku,
              ),
            if (widget.onPostDanmaku != null)
              IconButton(
                tooltip: '发弹幕',
                icon: const Icon(Icons.add_comment_outlined,
                    color: Colors.white70),
                onPressed: _sendDanmaku,
              ),
            IconButton(
              tooltip: '加书签',
              icon: const Icon(Icons.bookmark_add_outlined,
                  color: Colors.white70),
              onPressed: _addMark,
            ),
            IconButton(
              tooltip: 'A-B 循环（复读片段）',
              icon: Icon(Icons.repeat_on_rounded,
                  color: _bPoint != null
                      ? Colors.greenAccent
                      : (_aPoint != null
                          ? Colors.orangeAccent
                          : Colors.white70)),
              onPressed: _cycleAB,
            ),
            if (!_audioOnly)
              IconButton(
                tooltip: '截图',
                icon: const Icon(Icons.photo_camera_outlined,
                    color: Colors.white70),
                onPressed: _screenshot,
              ),
            if (!_audioOnly)
              IconButton(
                tooltip: '全屏',
                icon: const Icon(Icons.fullscreen, color: Colors.white70),
                onPressed: _enterFullscreen,
              ),
          ],
          TextButton.icon(
            onPressed: _showSpeedSheet,
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12)),
            icon: const Icon(Icons.speed, size: 18, color: Colors.white70),
            label: Text(_fmtSpeed(_speed),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
          ),
          PopupMenuButton<String>(
            tooltip: '更多（循环 / 睡眠定时）',
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            color: const Color(0xFF2B2B33),
            onSelected: (v) {
              switch (v) {
                case 'loop':
                  _toggleLoop();
                  break;
                case 's0':
                  _setSleep(null);
                  break;
                case 's15':
                  _setSleep(15);
                  break;
                case 's30':
                  _setSleep(30);
                  break;
                case 's60':
                  _setSleep(60);
                  break;
                case 's_custom':
                  _customSleep();
                  break;
                case 'sleep_exit':
                  setState(() => _sleepExit = !_sleepExit);
                  break;
                case 'jump':
                  _jumpTo();
                  break;
                case 'fwd10':
                  _seekRel(widget.seekStep);
                  break;
                case 'rwd10':
                  _seekRel(-widget.seekStep);
                  break;
                case 'fb':
                  _frameStep(false);
                  break;
                case 'ff':
                  _frameStep(true);
                  break;
                case 'rot':
                  _rotateVideo();
                  break;
                case 'flip':
                  _flipVideo();
                  break;
                case 'copy':
                  _copyLink();
                  break;
                case 'like':
                  _bvAction(widget.onLike);
                  break;
                case 'coin':
                  _coin();
                  break;
                case 'triple':
                  _bvAction(widget.onTriple);
                  break;
                case 'dmset':
                  _showDanmakuSettings();
                  break;
                case 'subfile':
                  _loadSubtitleFile();
                  break;
                case 'marks':
                  _showMarks();
                  break;
                case 'exsub':
                  _exportSubtitle();
                  break;
                case 'sub_plus':
                  _adjustSubDelay(500);
                  break;
                case 'sub_minus':
                  _adjustSubDelay(-500);
                  break;
                case 'exdm':
                  _exportDanmaku();
                  break;
                case 'bililink':
                  _copyBiliLink();
                  break;
                case 'fav':
                  widget.onAddToFav?.call();
                  break;
                case 'parts':
                  _showParts();
                  break;
                case 'rate':
                  _showRate();
                  break;
                case 'tracks':
                  _showTracks();
                  break;
                case 'vinfo':
                  _showVideoInfo();
                  break;
                case 'dim':
                  _showDimSheet();
                  break;
                case 'ontop':
                  _toggleOnTop();
                  break;
                case 'stopend':
                  setState(() => _stopAtEnd = !_stopAtEnd);
                  break;
                case 'srepeat':
                  _toggleSentenceRepeat();
                  break;
                case 'frames':
                  _batchFrames();
                  break;
                case 'imdm':
                  _importDanmakuFile();
                  break;
                case 'gif':
                  _exportGif();
                  break;
                case 'subopts':
                  _showSubtitleOptions();
                  break;
              }
            },
            itemBuilder: (_) => [
              if (widget.onTriple != null) ...[
                const PopupMenuItem(
                    value: 'triple',
                    child: Text('一键三连 🎉',
                        style: TextStyle(color: Colors.white))),
                const PopupMenuItem(
                    value: 'like',
                    child:
                        Text('点赞 👍', style: TextStyle(color: Colors.white))),
                const PopupMenuItem(
                    value: 'coin',
                    child:
                        Text('投币 🪙', style: TextStyle(color: Colors.white))),
                const PopupMenuDivider(),
              ],
              if (widget.onLoadDanmaku != null || _danmaku.isNotEmpty)
                const PopupMenuItem(
                    value: 'dmset',
                    child:
                        Text('弹幕设置', style: TextStyle(color: Colors.white))),
              if (widget.onLoadDanmaku == null)
                const PopupMenuItem(
                    value: 'imdm',
                    child: Text('导入弹幕文件',
                        style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'subfile',
                  child: Text('加载外挂字幕',
                      style: TextStyle(color: Colors.white))),
              if (widget.onLoadSubtitleOptions != null)
                const PopupMenuItem(
                    value: 'subopts',
                    child: Text('字幕语言 / 双语',
                        style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'marks',
                  child:
                      Text('时间戳书签', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'exsub',
                  child: Text('导出字幕', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'sub_plus',
                  child: Text('字幕延迟 +0.5s',
                      style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'sub_minus',
                  child: Text('字幕提前 0.5s',
                      style: TextStyle(color: Colors.white))),
              if (widget.onLoadDanmaku != null)
                const PopupMenuItem(
                    value: 'exdm',
                    child:
                        Text('导出弹幕', style: TextStyle(color: Colors.white))),
              if (widget.bvid != null)
                const PopupMenuItem(
                    value: 'bililink',
                    child: Text('复制 B站 链接',
                        style: TextStyle(color: Colors.white))),
              if (widget.onAddToFav != null)
                const PopupMenuItem(
                    value: 'fav',
                    child: Text('收藏到 B站',
                        style: TextStyle(color: Colors.white))),
              if (widget.onRate != null)
                const PopupMenuItem(
                    value: 'rate',
                    child: Text('给视频评分',
                        style: TextStyle(color: Colors.white))),
              if (_parts.length > 1)
                PopupMenuItem(
                    value: 'parts',
                    child: Text('分P 选集（${_parts.length}）',
                        style: const TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'tracks',
                  child: Text('音轨 / 内嵌字幕',
                      style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'vinfo',
                  child: Text('视频信息', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'dim',
                  child:
                      Text('画面调暗', style: TextStyle(color: Colors.white))),
              if (Platform.isMacOS)
                CheckedPopupMenuItem(
                    value: 'ontop',
                    checked: _onTop,
                    child: const Text('窗口置顶',
                        style: TextStyle(color: Colors.white))),
              CheckedPopupMenuItem(
                  value: 'stopend',
                  checked: _stopAtEnd,
                  child: const Text('播完停止（不连播）',
                      style: TextStyle(color: Colors.white))),
              CheckedPopupMenuItem(
                  value: 'srepeat',
                  checked: _sentenceRepeat,
                  child: Text(
                      _sentenceRepeat ? '逐句复读 $_repeatCount遍' : '逐句复读(字幕)',
                      style: const TextStyle(color: Colors.white))),
              if (!widget.source.resource.startsWith('http'))
                const PopupMenuItem(
                    value: 'frames',
                    child: Text('批量截帧',
                        style: TextStyle(color: Colors.white))),
              if (Platform.isMacOS &&
                  TranscribeService.ffmpeg != null &&
                  !widget.source.resource.startsWith('http'))
                const PopupMenuItem(
                    value: 'gif',
                    child: Text('导出 GIF 片段(A-B)',
                        style: TextStyle(color: Colors.white))),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                value: 'loop',
                checked: _loop,
                child:
                    const Text('单曲循环', style: TextStyle(color: Colors.white)),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                enabled: false,
                child: Text('睡眠定时器',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
              CheckedPopupMenuItem(
                  value: 's0',
                  checked: _sleepMin == null,
                  child: const Text('关闭', style: TextStyle(color: Colors.white))),
              CheckedPopupMenuItem(
                  value: 's15',
                  checked: _sleepMin == 15,
                  child:
                      const Text('15 分钟', style: TextStyle(color: Colors.white))),
              CheckedPopupMenuItem(
                  value: 's30',
                  checked: _sleepMin == 30,
                  child:
                      const Text('30 分钟', style: TextStyle(color: Colors.white))),
              CheckedPopupMenuItem(
                  value: 's60',
                  checked: _sleepMin == 60,
                  child:
                      const Text('60 分钟', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 's_custom',
                  child:
                      Text('自定义…', style: TextStyle(color: Colors.white))),
              CheckedPopupMenuItem(
                  value: 'sleep_exit',
                  checked: _sleepExit,
                  child: const Text('到点退出App（否则暂停）',
                      style: TextStyle(color: Colors.white))),
              const PopupMenuDivider(),
              const PopupMenuItem(
                  value: 'jump',
                  child: Text('跳转到…', style: TextStyle(color: Colors.white))),
              PopupMenuItem(
                  value: 'fwd10',
                  child: Text('快进 ${widget.seekStep} 秒',
                      style: const TextStyle(color: Colors.white))),
              PopupMenuItem(
                  value: 'rwd10',
                  child: Text('快退 ${widget.seekStep} 秒',
                      style: const TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'fb',
                  child: Text('上一帧', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'ff',
                  child: Text('下一帧', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'rot',
                  child: Text('旋转 90°', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'flip',
                  child: Text('水平镜像', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'copy',
                  child:
                      Text('复制播放链接', style: TextStyle(color: Colors.white))),
            ],
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('播放失败：$_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            )
          : Column(
              children: [
                Expanded(
                  // 关掉自带控件浮层（它会在角上显示流的 media-title，B站含 bilibili）。
                  // _videoView 内 _cropEdges 放大 1.22 倍裁掉溢出，把角落水印推出画面。
                  child: GestureDetector(
                    onTap: () => _player.playOrPause(),
                    onDoubleTapDown: (d) => _doubleTapAt = d.globalPosition,
                    onDoubleTap: showVideo && !_audioOnly
                        ? _handleDoubleTapZone
                        : null,
                    onLongPressStart: (_) => _longRate(true),
                    onLongPressEnd: (_) => _longRate(false),
                    onVerticalDragUpdate: (d) {
                      final w = MediaQuery.of(context).size.width;
                      if (d.globalPosition.dx > w / 2) {
                        _setVolume((_volume - d.delta.dy).clamp(0, 200));
                      } else {
                        setState(() => _dim =
                            (_dim + d.delta.dy / 300).clamp(0.0, 0.85));
                      }
                    },
                    onHorizontalDragStart: (_) {
                      setState(() {
                        _isDragSeeking = true;
                        _dragPreview = _position;
                      });
                    },
                    onHorizontalDragUpdate: (d) {
                      final w = MediaQuery.of(context).size.width;
                      final delta = (d.delta.dx / w) * _duration.inSeconds * 1.2;
                      final next = (_dragPreview ?? _position) +
                          Duration(milliseconds: (delta * 1000).round());
                      setState(() => _dragPreview = Duration(
                          milliseconds: next.inMilliseconds
                              .clamp(0, _duration.inMilliseconds)));
                    },
                    onHorizontalDragEnd: (_) {
                      if (_dragPreview != null) _player.seek(_dragPreview!);
                      setState(() {
                        _isDragSeeking = false;
                        _dragPreview = null;
                      });
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        showVideo
                            ? _videoView()
                            : Center(child: _cover(cs)),
                        if (_dim > 0)
                          IgnorePointer(
                            child: Container(
                                color:
                                    Colors.black.withValues(alpha: _dim)),
                          ),
                        if (_isDragSeeking && _dragPreview != null)
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                  '${_fmt(_dragPreview!)} / ${_fmt(_duration)}',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 18)),
                            ),
                          ),
                        if (_seekHintIcon != null)
                          Center(
                            child: Icon(_seekHintIcon,
                                size: 56, color: Colors.white70),
                          ),
                        if (_longPressing)
                          const Positioned(
                            top: 12,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Text('2x ▶▶',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      shadows: [
                                        Shadow(
                                            color: Colors.black, blurRadius: 4)
                                      ])),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      if (_danmakuOn && _danmakuHistogram.isNotEmpty && durMs > 0)
                        _DanmakuHeatmapBar(
                          histogram: _danmakuHistogram,
                          durationSec: _duration.inSeconds,
                          accent: cs.primary,
                          onSeek: (sec) =>
                              _player.seek(Duration(seconds: sec)),
                        ),
                      SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 3,
                          thumbColor: cs.primary,
                          activeTrackColor: cs.primary,
                          inactiveTrackColor: Colors.white24,
                          overlayShape: SliderComponentShape.noOverlay,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6),
                        ),
                        child: Slider(
                          min: 0,
                          max: durMs > 0 ? durMs : 1,
                          value: durMs > 0 ? posMs : 0,
                          onChanged: (v) =>
                              _player.seek(Duration(milliseconds: v.toInt())),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_fmt(_position),
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          Text(_fmt(_duration),
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      iconSize: 34,
                      color: Colors.white,
                      icon: const Icon(Icons.replay_10),
                      onPressed: () =>
                          _player.seek(_position - const Duration(seconds: 10)),
                    ),
                    const SizedBox(width: 24),
                    Material(
                      color: cs.primary,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _player.playOrPause(),
                        child: SizedBox(
                          width: 68,
                          height: 68,
                          child: Icon(
                              _playing ? Icons.pause : Icons.play_arrow,
                              color: Colors.white,
                              size: 40),
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    IconButton(
                      iconSize: 34,
                      color: Colors.white,
                      icon: const Icon(Icons.forward_10),
                      onPressed: () =>
                          _player.seek(_position + const Duration(seconds: 10)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _volumeBar(cs),
                const SizedBox(height: 20),
              ],
            ),
        ),
      ),
    );
  }

  Widget _volumeBar(ColorScheme cs) {
    final shown = _muted ? 0.0 : _volume;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: [
          IconButton(
            iconSize: 22,
            color: Colors.white70,
            tooltip: _muted ? '取消静音' : '静音',
            icon: Icon(shown == 0
                ? Icons.volume_off
                : (shown < 50 ? Icons.volume_down : Icons.volume_up)),
            onPressed: _toggleMute,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbColor: cs.primary,
                activeTrackColor: cs.primary,
                inactiveTrackColor: Colors.white24,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                min: 0,
                max: 200,
                value: shown,
                onChanged: _setVolume,
                onChangeEnd: (_) => _saveVolume(),
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text('${shown.round()}',
                textAlign: TextAlign.end,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _cover(ColorScheme cs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 220,
          height: 220,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [cs.primary.withOpacity(0.85), cs.primary.withOpacity(0.4)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.music_note, color: Colors.white, size: 96),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            widget.source.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _Cue {
  final Duration start;
  final Duration end;
  final String text;
  const _Cue(this.start, this.end, this.text);
}


class _CommentsSheet extends StatefulWidget {
  final Future<List<BiliComment>> Function(int pn) load;
  final Future<String> Function(String message)? post;
  const _CommentsSheet({required this.load, this.post});
  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final List<BiliComment> _comments = [];
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  int _page = 0;
  bool _loading = false;
  bool _done = false;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) {
        _loadMore();
      }
    });
    _loadMore();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    final next = _page + 1;
    final list = await widget.load(next);
    if (!mounted) return;
    setState(() {
      _page = next;
      _comments.addAll(list);
      _loading = false;
      if (list.length < 20) _done = true;
    });
  }

  Future<void> _send() async {
    final msg = _input.text.trim();
    if (msg.isEmpty || widget.post == null || _posting) return;
    setState(() => _posting = true);
    final res = await widget.post!(msg);
    if (!mounted) return;
    setState(() => _posting = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res)));
    if (res.contains('成功')) {
      _input.clear();
      FocusScope.of(context).unfocus();
      setState(() {
        _comments.clear();
        _page = 0;
        _done = false;
      });
      _loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text('评论',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: (_comments.isEmpty && _done)
                  ? const Center(
                      child: Text('暂无评论',
                          style: TextStyle(color: Colors.white54)))
                  : ListView.separated(
                      controller: _scroll,
                      itemCount: _comments.length + 1,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: Colors.white12),
                      itemBuilder: (context, i) {
                        if (i == _comments.length) {
                          return Padding(
                            padding: const EdgeInsets.all(16),
                            child: Center(
                              child: _done
                                  ? const Text('没有更多了',
                                      style: TextStyle(
                                          color: Colors.white38, fontSize: 12))
                                  : const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                            ),
                          );
                        }
                        final c = _comments[i];
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 18,
                            backgroundColor: Colors.white12,
                            backgroundImage: c.avatar.isNotEmpty
                                ? NetworkImage(c.avatar)
                                : null,
                            child: c.avatar.isEmpty
                                ? const Icon(Icons.person,
                                    size: 18, color: Colors.white54)
                                : null,
                          ),
                          title: Text(c.uname,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                          subtitle: Text(c.content,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 14)),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.thumb_up_alt_outlined,
                                  size: 14, color: Colors.white38),
                              Text('${c.like}',
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 11)),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            if (widget.post != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 8, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        style: const TextStyle(color: Colors.white),
                        minLines: 1,
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: '发条友善的评论…',
                          hintStyle: const TextStyle(color: Colors.white38),
                          filled: true,
                          fillColor: Colors.white10,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: _posting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.send, color: cs.primary),
                      onPressed: _posting ? null : _send,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 弹幕图层：按播放进度发射弹幕，每条独立动画从右向左滚动；暂停/跳转同步。
class _DanmakuLayer extends StatefulWidget {
  final List<Danmaku> items;
  final Duration position;
  final bool playing;
  final double opacity;
  final double fontScale;
  final int speedSec;
  final int maxActive;
  final List<String> block;
  final List<RegExp> blockRegex;
  final double topBlocked; // 顶部禁区%
  final double bottomBlocked; // 底部禁区%
  const _DanmakuLayer(
      {required this.items,
      required this.position,
      required this.playing,
      this.opacity = 1.0,
      this.fontScale = 1.0,
      this.speedSec = 9,
      this.maxActive = 60,
      this.block = const [],
      this.blockRegex = const [],
      this.topBlocked = 0,
      this.bottomBlocked = 0});
  @override
  State<_DanmakuLayer> createState() => _DanmakuLayerState();
}

class _DmItem {
  final Key key;
  final String text;
  final Color color;
  final int track;
  _DmItem(this.key, this.text, this.color, this.track);
}

class _DanmakuLayerState extends State<_DanmakuLayer> {
  static const _tracks = 8;
  final List<_DmItem> _active = [];
  final List<double> _trackFreeAt = List.filled(_tracks, 0);
  double _lastSec = -2;
  int _idx = 0;

  @override
  void initState() {
    super.initState();
    _resync();
  }

  void _resync() {
    final pos = widget.position.inMilliseconds / 1000.0;
    _active.clear();
    for (var i = 0; i < _tracks; i++) {
      _trackFreeAt[i] = 0;
    }
    _idx = 0;
    while (_idx < widget.items.length && widget.items[_idx].time < pos) {
      _idx++;
    }
    _lastSec = pos;
  }

  @override
  void didUpdateWidget(_DanmakuLayer old) {
    super.didUpdateWidget(old);
    if (!identical(old.items, widget.items)) {
      setState(_resync);
      return;
    }
    final pos = widget.position.inMilliseconds / 1000.0;
    if ((pos - _lastSec).abs() > 1.5) {
      setState(_resync);
      return;
    }
    var fired = false;
    while (_idx < widget.items.length && widget.items[_idx].time <= pos) {
      _spawn(widget.items[_idx], pos);
      _idx++;
      fired = true;
    }
    _lastSec = pos;
    if (fired) setState(() {});
  }

  void _spawn(Danmaku d, double pos) {
    if (_active.length > widget.maxActive) return;
    if (widget.block.any((w) => w.isNotEmpty && d.text.contains(w))) return;
    if (widget.blockRegex.any((r) => r.hasMatch(d.text))) return;
    var track = 0;
    var best = double.infinity;
    for (var i = 0; i < _tracks; i++) {
      if (_trackFreeAt[i] < best) {
        best = _trackFreeAt[i];
        track = i;
      }
    }
    _trackFreeAt[track] = pos + 0.9;
    _active.add(_DmItem(
        UniqueKey(), d.text, Color(0xFF000000 | (d.color & 0xFFFFFF)), track));
  }

  void _remove(Key k) {
    if (mounted) setState(() => _active.removeWhere((d) => d.key == k));
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: widget.opacity,
      child: ClipRect(
        child: LayoutBuilder(builder: (context, c) {
          final h = c.maxHeight;
          final topPx = h * widget.topBlocked / 100;
          final botPx = h * (100 - widget.bottomBlocked) / 100;
          final lineH = 19.0 * widget.fontScale + 4;
          return Stack(
            children: [
              for (final d in _active)
                if (() {
                  final y = 6.0 + d.track * 27.0 * widget.fontScale;
                  return y >= topPx && (y + lineH) <= botPx;
                }())
                  _FlyingDanmaku(
                    key: d.key,
                    text: d.text,
                    color: d.color,
                    track: d.track,
                    playing: widget.playing,
                    fontScale: widget.fontScale,
                    speedSec: widget.speedSec,
                    onDone: () => _remove(d.key),
                  ),
            ],
          );
        }),
      ),
    );
  }
}

class _FlyingDanmaku extends StatefulWidget {
  final String text;
  final Color color;
  final int track;
  final bool playing;
  final double fontScale;
  final int speedSec;
  final VoidCallback onDone;
  const _FlyingDanmaku(
      {super.key,
      required this.text,
      required this.color,
      required this.track,
      required this.playing,
      required this.onDone,
      this.fontScale = 1.0,
      this.speedSec = 9});
  @override
  State<_FlyingDanmaku> createState() => _FlyingDanmakuState();
}

class _FlyingDanmakuState extends State<_FlyingDanmaku>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: Duration(seconds: widget.speedSec))
      ..addStatusListener((st) {
        if (st == AnimationStatus.completed) widget.onDone();
      });
    if (widget.playing) _c.forward();
  }

  @override
  void didUpdateWidget(_FlyingDanmaku old) {
    super.didUpdateWidget(old);
    if (widget.playing &&
        !_c.isAnimating &&
        _c.status != AnimationStatus.completed) {
      _c.forward();
    } else if (!widget.playing && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return AnimatedBuilder(
      animation: _c,
      builder: (ctx, _) {
        final x = w - _c.value * (w + 260);
        return Transform.translate(
          offset: Offset(x, 6.0 + widget.track * 27.0 * widget.fontScale),
          child: Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              color: widget.color,
              fontSize: 19 * widget.fontScale,
              fontWeight: FontWeight.w500,
              shadows: const [
                Shadow(color: Colors.black, blurRadius: 2),
                Shadow(color: Colors.black, blurRadius: 3),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// F11: 弹幕热力时间轴。把每秒弹幕数画成柱状条，点击跳转。
class _DanmakuHeatmapBar extends StatelessWidget {
  final Map<int, int> histogram;
  final int durationSec;
  final Color accent;
  final void Function(int sec) onSeek;
  const _DanmakuHeatmapBar(
      {required this.histogram,
      required this.durationSec,
      required this.accent,
      required this.onSeek});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          final w = context.size?.width ?? 1;
          final sec = (d.localPosition.dx / w * durationSec)
              .clamp(0, durationSec)
              .round();
          onSeek(sec);
        },
        child: CustomPaint(
          painter: _DanmakuHeatmapPainter(histogram, durationSec, accent),
          size: const Size(double.infinity, 18),
        ),
      ),
    );
  }
}

class _DanmakuHeatmapPainter extends CustomPainter {
  final Map<int, int> histogram;
  final int durationSec;
  final Color accent;
  _DanmakuHeatmapPainter(this.histogram, this.durationSec, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    if (durationSec <= 0 || histogram.isEmpty) return;
    final maxV =
        histogram.values.fold<int>(1, (a, b) => b > a ? b : a).toDouble();
    const buckets = 120;
    final agg = List<double>.filled(buckets, 0);
    histogram.forEach((sec, cnt) {
      final bi = (sec / durationSec * buckets).clamp(0, buckets - 1).floor();
      agg[bi] += cnt;
    });
    final bw = size.width / buckets;
    final paint = Paint();
    for (var i = 0; i < buckets; i++) {
      final h = (agg[i] / maxV).clamp(0.0, 1.0) * size.height;
      if (h <= 0) continue;
      paint.color = Color.lerp(
          accent.withValues(alpha: 0.35), Colors.redAccent, (agg[i] / maxV))!;
      canvas.drawRect(
          Rect.fromLTWH(i * bw, size.height - h, bw + 0.5, h), paint);
    }
  }

  @override
  bool shouldRepaint(_DanmakuHeatmapPainter old) =>
      old.histogram != histogram || old.durationSec != durationSec;
}
