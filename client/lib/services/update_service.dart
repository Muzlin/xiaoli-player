import 'dart:convert';
import 'package:http/http.dart' as http;

/// 一次可用更新的信息。
class UpdateInfo {
  final String version;
  final String url;
  final String notes;
  UpdateInfo({required this.version, required this.url, required this.notes});
}

/// 检查更新：从 GitHub Releases 拉取最新版本，与当前版本比较。
class UpdateService {
  /// 当前版本（与 pubspec version 保持一致）。
  static const currentVersion = '2.36.0';

  /// GitHub 仓库（永久托管，发版即更新）。
  static const repo = 'Muzlin/xiaoli-player';

  /// 最新 Release 的 API 地址。
  static const manifestUrl =
      'https://api.github.com/repos/$repo/releases/latest';

  /// 下载页（永久地址，给用户跳转）。
  static const releasePage = 'https://github.com/$repo/releases/latest';

  final http.Client _http;
  UpdateService([http.Client? client]) : _http = client ?? http.Client();

  /// 有新版返回更新信息；无更新或失败返回 null（不打扰用户）。
  Future<UpdateInfo?> check() async {
    try {
      final r = await _http.get(Uri.parse(manifestUrl), headers: {
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
