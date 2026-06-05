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
                  child: _hasVideo
                      ? Video(controller: _controller)
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
