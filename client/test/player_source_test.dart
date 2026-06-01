import 'package:flutter_test/flutter_test.dart';
import 'package:media_client/player/playback_source.dart';

void main() {
  test('stream source carries url and headers', () {
    final s = PlaybackSource.stream(
        'http://h/media/1/stream', {'Authorization': 'Bearer t'});
    expect(s.resource, 'http://h/media/1/stream');
    expect(s.headers!['Authorization'], 'Bearer t');
  });

  test('local source carries path and no headers', () {
    final s = PlaybackSource.local('/tmp/movie.mkv');
    expect(s.resource, '/tmp/movie.mkv');
    expect(s.headers, isNull);
  });
}
