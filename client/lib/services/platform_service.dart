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
  static const baseUrl = 'https://mill-vid-analyses-pendant.trycloudflare.com';

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

  /// 上传视频到平台。返回给用户的提示。
  Future<String> upload(String path, String title, String uploader) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return '文件不存在';
      final ext = path.contains('.') ? path.split('.').last.toLowerCase() : 'mp4';
      final bytes = await file.readAsBytes();
      final r = await _http
          .post(
            Uri.parse('$baseUrl/upload'
                '?title=${Uri.encodeComponent(title)}'
                '&uploader=${Uri.encodeComponent(uploader)}&ext=$ext'),
            headers: {'Content-Type': 'application/octet-stream'},
            body: bytes,
          )
          .timeout(const Duration(minutes: 15));
      final d = jsonDecode(r.body);
      if (d['ok'] == true) return '上传成功！别人搜「$title」就能看到';
      return '上传失败：${d['error'] ?? r.statusCode}';
    } catch (e) {
      return '上传出错：$e';
    }
  }
}
