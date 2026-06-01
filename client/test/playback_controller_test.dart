import 'package:flutter_test/flutter_test.dart';
import 'package:media_client/player/playback_backend.dart';
import 'package:media_client/player/playback_controller.dart';

class FakeBackend implements PlaybackBackend {
  String? openedUrl;
  Map<String, String>? openedHeaders;
  bool playing = false;
  Duration? seekedTo;
  bool disposed = false;

  @override
  Future<void> open(String url, Map<String, String> headers) async {
    openedUrl = url;
    openedHeaders = headers;
    playing = true;
  }

  @override
  Future<void> setPlaying(bool value) async => playing = value;

  @override
  Future<void> seek(Duration position) async => seekedTo = position;

  @override
  Future<void> setVolume(double value) async {}

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  test('open delegates url + headers and sets playing', () async {
    final backend = FakeBackend();
    final c = PlaybackController(backend);
    await c.open('http://h/media/1/stream', {'Authorization': 'Bearer tok'});
    expect(backend.openedUrl, 'http://h/media/1/stream');
    expect(backend.openedHeaders!['Authorization'], 'Bearer tok');
    expect(c.isPlaying, true);
  });

  test('togglePlayPause flips state', () async {
    final backend = FakeBackend();
    final c = PlaybackController(backend);
    await c.open('u', {});
    await c.togglePlayPause();
    expect(c.isPlaying, false);
    expect(backend.playing, false);
  });

  test('dispose tears down backend', () async {
    final backend = FakeBackend();
    final c = PlaybackController(backend);
    await c.dispose();
    expect(backend.disposed, true);
  });
}
