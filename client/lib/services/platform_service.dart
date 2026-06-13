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
  /// 兜底地址（隧道默认值）。生效地址 [_base] 启动时可被本机 public_url.txt 覆盖。
  static const baseUrl =
      'https://translator-themes-activated-column.trycloudflare.com';
  static String _base = baseUrl; // 公网地址
  static bool useLan = false; // 切到局域网服务器
  static String? _lanIp; // 本机局域网 IP

  static String? customLanIp; // 用户自定义局域网 IP（优先于自动探测）
  static String? get detectedIp => _lanIp; // 自动探测到的 IP

  static String get _lanHost =>
      (customLanIp != null && customLanIp!.trim().isNotEmpty)
          ? customLanIp!.trim()
          : (_lanIp ?? 'localhost');

  /// 局域网地址（同 WiFi 设备可访问，公网抽风时兜底）。
  static String get lanBase => 'http://$_lanHost:8900';

  /// 当前生效地址：局域网模式用 lanBase，否则公网 _base。
  static String get current => useLan ? lanBase : _base;

  /// 读公网地址(public_url.txt) + 探测局域网 IP。
  static Future<void> loadLocal() async {
    if (!Platform.isMacOS) return;
    try {
      final home = Platform.environment['HOME'] ?? '';
      final f = File('$home/xiaoli-platform/public_url.txt');
      if (f.existsSync()) {
        final u = f.readAsStringSync().trim();
        if (u.startsWith('https://')) _base = u;
      }
    } catch (_) {}
    try {
      for (final ni
          in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in ni.addresses) {
          if (!a.isLoopback &&
              (a.address.startsWith('10.') ||
                  a.address.startsWith('192.168.') ||
                  a.address.startsWith('172.'))) {
            _lanIp = a.address;
          }
        }
      }
    } catch (_) {}
  }

  static void setUseLan(bool v) => useLan = v;

  /// 官方下载页地址（随 current 变）。
  static String get downloadUrl => '$current/download';

  final http.Client _http;
  PlatformService([http.Client? c]) : _http = c ?? http.Client();

  /// 公网当前是否健康（限流/抽风时 false）。
  Future<bool> publicHealthy() async {
    try {
      final r = await _http
          .get(Uri.parse('$_base/health'))
          .timeout(const Duration(seconds: 8));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static String videoUrl(String id) => '$current/video/$id';

  Future<List<PlatformVideo>> search(String q) async {
    try {
      final r = await _http
          .get(Uri.parse('$current/search?q=${Uri.encodeComponent(q)}'))
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
  static List<String> get _uploadBases => [
        'http://localhost:8900',
        'http://10.10.10.5:8900',
        _base,
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
