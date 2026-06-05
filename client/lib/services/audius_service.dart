import 'dart:convert';
import 'package:http/http.dart' as http;

/// 一首在线搜索到的歌曲。
class OnlineTrack {
  final String id;
  final String title;
  final String artist;
  final String streamUrl;
  OnlineTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.streamUrl,
  });
}

/// 接入 Audius（合法的免费在线音乐平台）做联网搜索与流式播放。
class AudiusService {
  static const _appName = 'XiaoliPlayer';
  static const _fallbackHost = 'https://discoveryprovider.audius.co';

  final http.Client _http;
  String? _host;

  AudiusService([http.Client? client]) : _http = client ?? http.Client();

  /// 解析一个可用的 Audius 发现节点（结果缓存）。
  Future<String> _resolveHost() async {
    if (_host != null) return _host!;
    try {
      final r = await _http
          .get(Uri.parse('https://api.audius.co'))
          .timeout(const Duration(seconds: 8));
      final hosts = (jsonDecode(r.body)['data'] as List).cast<String>();
      _host = hosts.isNotEmpty ? hosts.first : _fallbackHost;
    } catch (_) {
      _host = _fallbackHost;
    }
    return _host!;
  }

  /// 按关键词联网搜索歌曲。失败返回空列表（不抛异常）。
  Future<List<OnlineTrack>> search(String query) async {
    if (query.trim().isEmpty) return [];
    try {
      final host = await _resolveHost();
      final uri = Uri.parse(
          '$host/v1/tracks/search?query=${Uri.encodeQueryComponent(query)}&app_name=$_appName');
      final r = await _http.get(uri).timeout(const Duration(seconds: 12));
      if (r.statusCode >= 400) return [];
      final data = (jsonDecode(r.body)['data'] as List?) ?? [];
      return data.map((e) {
        final m = e as Map<String, dynamic>;
        final id = m['id'].toString();
        return OnlineTrack(
          id: id,
          title: (m['title'] ?? '未知') as String,
          artist: ((m['user'] as Map?)?['name'] ?? '') as String,
          streamUrl: '$host/v1/tracks/$id/stream?app_name=$_appName',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }
}
