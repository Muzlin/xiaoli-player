import 'dart:convert';
import 'package:http/http.dart' as http;
import 'platform_service.dart';

/// 一次可用更新的信息。
class UpdateInfo {
  final String version;
  final String url;
  final String notes;
  UpdateInfo({required this.version, required this.url, required this.notes});
}

/// 检查更新：优先问自建平台 /version（国内直连稳），拿不到再退 GitHub Releases。
class UpdateService {
  /// 当前版本（与 pubspec version 保持一致）。
  static const currentVersion = '2.39.13';

  /// GitHub 仓库（永久托管备份）。
  static const repo = 'Muzlin/xiaoli-player';
  static const releasePage = 'https://github.com/$repo/releases/latest';
  static const githubApi =
      'https://api.github.com/repos/$repo/releases/latest';

  final http.Client _http;
  UpdateService([http.Client? client]) : _http = client ?? http.Client();

  /// 有新版返回更新信息；无更新或失败返回 null（不打扰用户）。
  Future<UpdateInfo?> check() async {
    // 1) 先问平台 /version（可达），下载跳平台页（页内含 GitHub 永久链接）。
    final viaPlatform = await _checkPlatform();
    if (viaPlatform != null) return viaPlatform;
    // 2) 退而求其次：问 GitHub（需代理可达）。
    return _checkGithub();
  }

  Future<UpdateInfo?> _checkPlatform() async {
    try {
      final base = PlatformService.current;
      final r = await _http
          .get(Uri.parse('$base/version'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return null;
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      final latest = (m['version'] ?? '') as String;
      if (latest.isEmpty || !isNewer(latest, currentVersion)) return null;
      // 官方下载地址由后台「下载源」开关决定（GitHub releases 或 平台下载页）。
      final dl = (m['download_url'] ?? '') as String;
      return UpdateInfo(
        version: latest,
        url: dl.isNotEmpty ? dl : '$base/download',
        notes: (m['notes'] ?? '') as String,
      );
    } catch (_) {
      return null;
    }
  }

  Future<UpdateInfo?> _checkGithub() async {
    try {
      final r = await _http.get(Uri.parse(githubApi), headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'xiaoli-player',
      }).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      var latest = (m['tag_name'] ?? '') as String; // 形如 v2.37.0
      if (latest.startsWith('v') || latest.startsWith('V')) {
        latest = latest.substring(1);
      }
      if (latest.isEmpty || !isNewer(latest, currentVersion)) return null;
      return UpdateInfo(
        version: latest,
        url: (m['html_url'] ?? releasePage) as String,
        notes: (m['body'] ?? '') as String,
      );
    } catch (_) {
      return null;
    }
  }

  /// 语义版本比较：a 是否比 b 新。
  static bool isNewer(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (var i = 0; i < pa.length || i < pb.length; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
