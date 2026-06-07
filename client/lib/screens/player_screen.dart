import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../player/playback_source.dart';
import '../services/transcribe_service.dart';
import '../services/tts_service.dart';

export '../player/playback_source.dart';

/// 播放页：音频显示封面+进度+控制；视频显示画面。基于 media_kit/libmpv，支持所有格式。
class PlayerScreen extends StatefulWidget {
  final PlaybackSource source;
  const PlayerScreen({super.key, required this.source});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
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

  bool _dubbing = false; // 配音：用系统语音朗读字幕，并静音原声
  List<_Cue> _cues = const [];
  int _lastSpoken = -1;

  void _toggleDub() {
    if (_subtitle == null) return;
    setState(() => _dubbing = !_dubbing);
    if (_dubbing) {
      _cues = _parseSrt(_subtitle!);
      _lastSpoken = -1;
      _player.setVolume(0); // 静音原声，只听配音
    } else {
      _player.setVolume(100);
      TtsService.stop();
    }
  }

  void _maybeSpeak(Duration pos) {
    if (_cues.isEmpty) return;
    final i = _cues.indexWhere((c) => pos >= c.start && pos < c.end);
    if (i >= 0 && i != _lastSpoken) {
      _lastSpoken = i;
      TtsService.speak(_cues[i].text);
    }
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
    _isWebVideo =
        widget.source.isVideo && widget.source.resource.startsWith('http');
    _cropEdges = _isWebVideo; // 网络视频默认裁边去角标水印
    _subs.add(_player.stream.position.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
      if (_dubbing) _maybeSpeak(p);
    }));
    _subs.add(_player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
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
  }

  @override
  void dispose() {
    TtsService.stop();
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
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E26),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E26),
        foregroundColor: Colors.white,
        title: Text(widget.source.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
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
          if (_subtitle != null)
            IconButton(
              tooltip: _dubbing ? '关闭配音(恢复原声)' : '配音·朗读字幕(静音原声)',
              icon: Icon(
                  _dubbing
                      ? Icons.record_voice_over
                      : Icons.record_voice_over_outlined,
                  color: _dubbing
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white70),
              onPressed: _toggleDub,
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
                  child: (!_audioOnly && (widget.source.isVideo || _hasVideo))
                      // 关掉自带控件浮层（它会在角上显示流的 media-title，B站含 bilibili）。
                      // _cropEdges：放大 1.22 倍并裁掉溢出，把角落烧录水印推出画面。
                      ? ClipRect(
                          child: Transform.scale(
                            scale: _cropEdges ? 1.22 : 1.0,
                            child: Video(
                                controller: _controller,
                                controls: NoVideoControls),
                          ),
                        )
                      : Center(child: _cover(cs)),
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
                const SizedBox(height: 32),
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

/// 一条字幕（用于配音按时朗读）。
class _Cue {
  final Duration start;
  final Duration end;
  final String text;
  const _Cue(this.start, this.end, this.text);
}
