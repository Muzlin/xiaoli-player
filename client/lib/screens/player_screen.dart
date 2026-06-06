import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../player/playback_source.dart';

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
    _subs.add(_player.stream.position.listen((p) {
      if (mounted) setState(() => _position = p);
    }));
    _subs.add(_player.stream.duration.listen((d) {
      if (mounted) setState(() => _duration = d);
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
  }

  @override
  void dispose() {
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
                  child: (widget.source.isVideo || _hasVideo)
                      // 关掉自带控件浮层：它会在视频左上角显示流的 media-title
                      // （B站流标题含 bilibili）。本页已有自己的控制条。
                      ? Video(controller: _controller, controls: NoVideoControls)
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
