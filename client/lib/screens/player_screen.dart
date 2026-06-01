import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../api/api_client.dart';
import '../api/models.dart';
import '../player/playback_source.dart';

export '../player/playback_source.dart';

class PlayerScreen extends StatefulWidget {
  final PlaybackSource source;
  const PlayerScreen({super.key, required this.source});

  /// 便捷构造：播放后端的某个媒体项（流式 + 鉴权头）。
  factory PlayerScreen.forItem(ApiClient api, MediaItem item) => PlayerScreen(
        source: PlaybackSource.stream(
          api.streamUrl(item.id),
          api.authHeaders(),
          title: item.originalName,
        ),
      );

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  StreamSubscription<String>? _errorSub;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 播放失败（鉴权失败、格式不支持等）时给出可读提示，不黑屏不崩溃。
    _errorSub = _player.stream.error.listen((e) {
      if (mounted) setState(() => _error = e);
    });
    _player.open(
      Media(widget.source.resource, httpHeaders: widget.source.headers),
    );
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.source.title)),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '播放失败：$_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            )
          : Video(controller: _controller),
    );
  }
}
