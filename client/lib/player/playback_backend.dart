import 'package:media_kit/media_kit.dart';

abstract class PlaybackBackend {
  Future<void> open(String url, Map<String, String> headers);
  Future<void> setPlaying(bool value);
  Future<void> seek(Duration position);
  Future<void> setVolume(double value);
  Future<void> dispose();
}

class MediaKitBackend implements PlaybackBackend {
  final Player player;
  MediaKitBackend() : player = Player();

  @override
  Future<void> open(String url, Map<String, String> headers) =>
      player.open(Media(url, httpHeaders: headers));

  @override
  Future<void> setPlaying(bool value) =>
      value ? player.play() : player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> setVolume(double value) => player.setVolume(value);

  @override
  Future<void> dispose() => player.dispose();
}
