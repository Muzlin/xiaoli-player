import 'dart:io';

/// 播放源：既可以是后端的鉴权流（URL + headers），也可以是本地文件路径。
/// 单独成文件、不依赖 media_kit，便于纯 Dart 单测。
class PlaybackSource {
  final String resource; // URL 或本地文件绝对路径
  final Map<String, String>? headers;
  final String title;
  const PlaybackSource._(this.resource, this.headers, this.title);

  factory PlaybackSource.stream(String url, Map<String, String> headers,
          {String title = ''}) =>
      PlaybackSource._(url, headers, title);

  factory PlaybackSource.local(String path) =>
      PlaybackSource._(path, null, path.split(Platform.pathSeparator).last);
}
