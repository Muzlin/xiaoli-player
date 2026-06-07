import 'dart:convert';
import 'package:http/http.dart' as http;

/// 一次可用更新的信息。
class UpdateInfo {
  final String version;
  final String url;
  final String notes;
  UpdateInfo({required this.version, required this.url, required this.notes});
}

/// 检查更新：拉取远端版本清单，与当前版本比较。
///
/// 清单是一段 JSON，形如：
/// { "version": "2.2.0", "url": "https://.../小李播放器.dmg", "notes": "修复若干问题" }
///
/// [manifestUrl] 现为占位地址；有了托管（如 GitHub Releases）后替换即可。
class UpdateService {
  /// 当前版本（与 pubspec version 保持一致）。
  static const currentVersion = '2.9.0';

  /// 更新清单地址（局域网更新服务）。
  static const manifestUrl = 'http://10.10.10.5:8899/latest.json';

  final http.Client _http;
  UpdateService([http.Client? client]) : _http = client ?? http.Client();

  /// 有新版返回更新信息；无更新或失败返回 null（不打扰用户）。
  Future<UpdateInfo?> check() async {
    try {
      final r = await _http
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      final latest = (m['version'] ?? '') as String;
      if (latest.isEmpty || !isNewer(latest, currentVersion)) return null;
      return UpdateInfo(
        version: latest,
        url: (m['url'] ?? '') as String,
        notes: (m['notes'] ?? '') as String,
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
