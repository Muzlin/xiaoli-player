import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'playback_source.dart';

/// 全局唯一播放器：独立于任何界面，退出播放页/切到后台后仍继续播放。
/// 播放页只是「附着」到它，不再各自 new Player / dispose。
class PlayerHolder {
  PlayerHolder._() {
    _player = Player();
    _controller = VideoController(_player);
    _player.stream.playing.listen((p) => playing.value = p);
  }
  static final PlayerHolder i = PlayerHolder._();

  late final Player _player;
  late final VideoController _controller;
  Player get player => _player;
  VideoController get controller => _controller;

  /// 当前正在播放的源（null=没有内容）。主界面据此显示迷你播放条。
  final ValueNotifier<PlaybackSource?> current = ValueNotifier<PlaybackSource?>(null);

  /// 播放页是否正在前台（在栈顶）。迷你条仅在「有内容且播放页不在前台」时显示。
  final ValueNotifier<bool> screenOpen = ValueNotifier<bool>(false);

  /// 实时播放/暂停态（供迷你条按钮）。
  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);

  void playPause() {
    if (_player.state.playing) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  /// 彻底停止并清空（迷你条「关闭」）。
  Future<void> stop() async {
    await _player.stop();
    current.value = null;
  }
}
