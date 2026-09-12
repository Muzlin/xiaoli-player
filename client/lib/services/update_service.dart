import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'platform_service.dart';

/// 一次可用更新的信息。
class UpdateInfo {
  final String version;
  final String url;
  final String notes;
  UpdateInfo({required this.version, required this.url, required this.notes});
}

/// 检查更新：平台公网 /version（国内直连稳）→ 公网 git（raw.githubusercontent）→ GitHub Releases。
/// 所有公网源并行探测，总耗时≈最慢一个源（约 3 秒内），谁先确认有新版本就用谁。
class UpdateService {
  /// 当前版本（与 pubspec version 保持一致）。
  static const currentVersion = '2.48.2';

  /// GitHub 仓库（永久托管备份）。
  static const repo = 'Muzlin/xiaoli-player';
  static const releasePage = 'https://github.com/$repo/releases/latest';
  static const githubApi =
      'https://api.github.com/repos/$repo/releases/latest';

  /// 公网 version.json 镜像源：raw.githubusercontent 主源；GitHub raw 重定向端点兜底。
  /// （曾用 jsDelivr CDN，但它多次 503「No healthy backends」且无法自愈，已移除。）
  static const _versionJsonUrls = [
    'https://raw.githubusercontent.com/$repo/flutter-client/version.json',
    'https://github.com/$repo/raw/flutter-client/version.json',
  ];

  final http.Client _http;
  UpdateService([http.Client? client]) : _http = client ?? http.Client();

  /// 有新版返回更新信息；无更新或失败返回 null（不打扰用户）。
  /// 平台是首选（自建 cloudflared 隧道，国内直连快、地址由 GitHub 指针自愈）；
  /// 平台没跑/数据过期时，公网 git 与 GitHub Releases 并行兜底。
  Future<UpdateInfo?> check() async {
    final results = await Future.wait([
      _checkPlatform(),
      _checkCdn(),
      _checkGithub(),
    ]);
    for (final r in results) {
      if (r != null) return r; // 平台优先，其次公网 CDN，最后 GitHub API
    }
    return null;
  }

  /// 当前平台对应的安装包资源名。
  static String _platformAsset() {
    if (Platform.isMacOS) return 'xiaoli-player-macos.zip';
    if (Platform.isAndroid) return 'xiaoli-player-android.apk';
    if (Platform.isWindows) return 'xiaoli-player-windows.zip';
    return '';
  }

  /// 当前平台在 GitHub Releases 最新版的直接下载地址。
  /// 自动更新统一走这里：服务器 /dl/ 目录里的旧包会过期，之前因此装回旧版。
  static String get latestAssetUrl =>
      'https://github.com/$repo/releases/latest/download/${_platformAsset()}';

  /// 公网 git 镜像（raw.githubusercontent / GitHub raw）：拿最新版本号与下载资源。
  /// 平台挂了或数据过期时兜底，全公网可用、无需任何本地服务。
  Future<UpdateInfo?> _checkCdn() async {
    for (final u in _versionJsonUrls) {
      try {
        final r = await _http
            .get(Uri.parse(u))
            .timeout(const Duration(seconds: 6));
        if (r.statusCode != 200) continue;
        final m = jsonDecode(r.body) as Map<String, dynamic>;
        final latest = (m['version'] ?? '') as String;
        if (latest.isEmpty || !isNewer(latest, currentVersion)) return null;
        var dl = (m['download_url'] ?? '') as String;
        if (dl.isEmpty) {
          final asset = _platformAsset();
          if (asset.isNotEmpty) {
            dl = 'https://github.com/$repo/releases/latest/download/$asset';
          }
        }
        if (dl.isEmpty) return null;
        return UpdateInfo(
          version: latest,
          url: dl,
          notes: (m['notes'] ?? '') as String,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<UpdateInfo?> _checkPlatform() async {
    try {
      final base = PlatformService.current;
      final r = await _http
          .get(Uri.parse('$base/version'))
          .timeout(const Duration(seconds: 5));
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
      }).timeout(const Duration(seconds: 6));
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
