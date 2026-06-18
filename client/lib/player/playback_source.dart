import 'dart:io';

/// 播放源：在线流（URL + headers）或本地文件路径。
/// [isVideo] 标记是否含画面（决定播放页显示视频还是音乐封面）。
class PlaybackSource {
  final String resource; // URL 或本地文件绝对路径
  final Map<String, String>? headers;
  final String title;
  final bool isVideo;
  final Future<String?>? subtitleFuture; // B站自带字幕(SRT)，异步取，可空
  final String? coverUrl; // 封面图 URL（用于封面取色 F39）
  const PlaybackSource._(this.resource, this.headers, this.title, this.isVideo,
      [this.subtitleFuture, this.coverUrl]);

  factory PlaybackSource.stream(String url, Map<String, String> headers,
          {String title = '',
          bool isVideo = false,
          Future<String?>? subtitleFuture,
          String? coverUrl}) =>
      PlaybackSource._(url, headers, title, isVideo, subtitleFuture, coverUrl);

  factory PlaybackSource.local(String path, {String? title}) {
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    const audioExts = {
      'mp3', 'flac', 'aac', 'wav', 'm4a', 'aiff', 'aif', 'ogg', 'opus',
      'wma', 'ape', 'alac', 'mid', 'amr'
    };
    return PlaybackSource._(
      path,
      null,
      title ?? path.split(Platform.pathSeparator).last,
      !audioExts.contains(ext), // 音频后缀→封面，其余→视频画面
    );
  }
}
