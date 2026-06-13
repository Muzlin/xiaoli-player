import 'dart:async';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../player/playback_source.dart';
import '../services/transcribe_service.dart';
import '../services/bilibili_service.dart';
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
  Timer? _sleepTimer;
  int? _sleepMin;

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
    return ClipRect(
      child: Transform.scale(
        scale: _cropEdges ? 1.22 : 1.0,
        child: Video(controller: _controller, controls: NoVideoControls),
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
    final srt = _subtitle;
    if (srt == null) return;
    _player.setSubtitleTrack(
        _subtitleOn ? SubtitleTrack.data(srt) : SubtitleTrack.no());
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
    _subs.add(_player.stream.completed.listen((done) {
      if (done && !_loop && mounted) widget.onCompleted?.call();
    }));
    _subs.add(_player.stream.position.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
      if (_desktopSub) _pushDesktopSub(p);
      if (_aPoint != null && _bPoint != null && p >= _bPoint!) {
        _player.seek(_aPoint!);
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
      if (mounted) setState(() => _playing = p);
    }));
    _subs.add(_player.stream.videoParams.listen((v) {
      final has = (v.w ?? 0) > 0 && (v.h ?? 0) > 0;
      if (mounted && has != _hasVideo) setState(() => _hasVideo = has);
    }));
    _subs.add(_player.stream.error.listen((e) {
      if (mounted) setState(() => _error = e);
    }));
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
          if (widget.source.isVideo || _hasVideo) ...[
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
              }
            },
            itemBuilder: (_) => [
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
                  child: showVideo ? _videoView() : Center(child: _cover(cs)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
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
