import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// 本应用「视频平台」一条视频。
class PlatformVideo {
  final String id;
  final String title;
  final String uploader;
  PlatformVideo({required this.id, required this.title, required this.uploader});
}

/// 本应用的共享视频平台：上传到自建服务器（cloudflared 公网），别人跨设备可搜可看。
class PlatformService {
  /// 平台公网地址（cloudflared 隧道）。隧道重启会变，届时需更新。
  static const baseUrl =
      'https://cleaner-heel-vacation-breach.trycloudflare.com';

  /// 官方下载页（公网，发给别人装 app）。
  static String get downloadUrl => '$baseUrl/download';

  final http.Client _http;
  PlatformService([http.Client? c]) : _http = c ?? http.Client();

  static String videoUrl(String id) => '$baseUrl/video/$id';

  Future<List<PlatformVideo>> search(String q) async {
    try {
      final r = await _http
          .get(Uri.parse('$baseUrl/search?q=${Uri.encodeComponent(q)}'))
          .timeout(const Duration(seconds: 15));
      final list = (jsonDecode(r.body) as List?) ?? [];
      return list
          .map((e) => PlatformVideo(
                id: (e['id'] ?? '') as String,
                title: (e['title'] ?? '') as String,
                uploader: (e['uploader'] ?? '') as String,
              ))
          .where((v) => v.id.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<PlatformVideo>> list() => search('');

  /// 上传优先级：本机直传(秒级) → 局域网 → 公网(慢，兜底)。
  /// cloudflared 免费隧道上传极慢，故同机/同网时直传服务器。
  static const _uploadBases = [
    'http://localhost:8900',
    'http://10.10.10.5:8900',
    baseUrl,
  ];

  /// 上传视频到平台。返回给用户的提示。
  Future<String> upload(String path, String title, String uploader) async {
    final file = File(path);
    if (!file.existsSync()) return '文件不存在';
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : 'mp4';
    final bytes = await file.readAsBytes();
    final query = '?title=${Uri.encodeComponent(title)}'
        '&uploader=${Uri.encodeComponent(uploader)}&ext=$ext';
    String lastErr = '服务器连不上';
    for (final base in _uploadBases) {
      try {
        final h = await _http
            .get(Uri.parse('$base/health'))
            .timeout(const Duration(seconds: 3));
        if (h.statusCode != 200) continue;
        final r = await _http
            .post(Uri.parse('$base/upload$query'),
                headers: {'Content-Type': 'application/octet-stream'},
                body: bytes)
            .timeout(const Duration(minutes: 20));
        final d = jsonDecode(r.body);
        if (d['ok'] == true) return '上传成功！别人搜「$title」就能看到';
        lastErr = '${d['error'] ?? r.statusCode}';
      } catch (e) {
        lastErr = '$e';
        continue;
      }
    }
    return '上传失败：$lastErr（确保平台服务器在运行）';
  }
}
