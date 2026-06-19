import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 本应用「视频平台」一条视频。
class PlatformVideo {
  final String id;
  final String title;
  final String uploader;
  final double rating;
  final int rcount;
  final String cat; // 分类：'视频' / '音乐'
  final int size; // 字节
  final int ts; // 上传时间戳(秒)
  final String? ghUrl; // GitHub Releases 永久备份链接(有则已备份)
  final bool hidden; // 已隐藏(不在公开搜索/列表显示)
  final bool pinned; // 已置顶/精选
  final int views; // 播放量
  final int coins; // 投币数
  final int likes; // 点赞数
  final int favs; // 收藏数
  PlatformVideo(
      {required this.id,
      required this.title,
      required this.uploader,
      this.rating = 0,
      this.rcount = 0,
      this.cat = '',
      this.size = 0,
      this.ts = 0,
      this.ghUrl,
      this.hidden = false,
      this.pinned = false,
      this.views = 0,
      this.coins = 0,
      this.likes = 0,
      this.favs = 0});
}

/// 本应用的共享视频平台：上传到自建服务器（cloudflared 公网），别人跨设备可搜可看。
class PlatformService {
  /// 平台公网地址（cloudflared 隧道）。隧道重启会变——所有平台启动时都会
  /// 从 [_remotePointer] 拉取当前地址，所以这里只是首次启动的兜底初值。
  static const baseUrl =
      'https://internal-apt-saturn-navy.trycloudflare.com';
  static String _base = baseUrl; // 公网地址（运行时由 GitHub 指针/本机文件刷新）

  /// 永久指针：GitHub 上的 public_url.txt 始终写着当前隧道地址。
  /// 服务器隧道一变，keepalive 脚本就把新址提交到这里；app 启动即拉取，
  /// 全平台通用、国内 api.github.com 可达，从此换隧道无需重新打包。
  static const _remotePointer =
      'https://api.github.com/repos/Muzlin/xiaoli-player/contents/public_url.txt?ref=flutter-client';
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

  /// 上传歌单 JSON 到平台，返回分享码(id)。
  static Future<String?> uploadPlaylist(String jsonBody) async {
    for (final base in _uploadBases) {
      try {
        final r = await http
            .post(Uri.parse('$base/upload-playlist'), body: jsonBody)
            .timeout(const Duration(seconds: 15));
        final id = jsonDecode(r.body)['id'];
        if (id != null) return id as String;
      } catch (_) {}
    }
    return null;
  }

  /// 给平台视频评分(1-5)。
  static Future<String?> rate(String id, int score) async {
    try {
      final r = await http
          .get(Uri.parse('$current/rate?id=$id&score=$score'))
          .timeout(const Duration(seconds: 10));
      final d = jsonDecode(r.body);
      if (d['ok'] == true) return '已评分 ★$score（平均 ${d['rating']}）';
      return '评分失败';
    } catch (e) {
      return '评分出错：$e';
    }
  }

  /// 用分享码取回歌单 JSON。
  static Future<String?> getPlaylistJson(String id) async {
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/playlist/$id'))
            .timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) return r.body;
      } catch (_) {}
    }
    return null;
  }

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

  /// 从 GitHub 永久指针拉取当前公网地址（所有平台）。
  /// 隧道地址变了也能自愈，无需重新打包 app。失败则保持现有地址。
  static Future<void> loadRemoteUrl() async {
    try {
      // 用 JSON contents API（base64）：比 raw CDN 端点更快反映最新提交。
      final r = await http.get(Uri.parse(_remotePointer), headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'xiaoli-player',
      }).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      var u = r.body.trim();
      if (u.startsWith('{')) {
        final m = jsonDecode(u) as Map<String, dynamic>;
        final c = ((m['content'] ?? '') as String).replaceAll('\n', '');
        u = utf8.decode(base64.decode(c)).trim();
      }
      if (u.startsWith('https://') && u.length < 200) _base = u;
    } catch (_) {}
  }

  static void setUseLan(bool v) => useLan = v;

  /// 官方下载页：自建平台页（国内直连稳，随 current 变；页内含 GitHub 永久链接）。
  static String get downloadUrl => '$current/download';

  /// GitHub Releases 永久地址（备份/永久链接）。
  static const githubReleases =
      'https://github.com/Muzlin/xiaoli-player/releases/latest';

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

  // ===== 小李兑换币钱包 =====
  static String? _uid;

  /// 本设备钱包 id（首次生成存 prefs）。
  static Future<String> walletUid() async {
    if (_uid != null) return _uid!;
    final p = await SharedPreferences.getInstance();
    var id = p.getString('wallet_uid') ?? '';
    if (id.isEmpty) {
      id = 'u${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(99999)}';
      await p.setString('wallet_uid', id);
    }
    _uid = id;
    return id;
  }

  /// 当前兑换币余额。
  static Future<int> getBalance() async {
    final uid = await walletUid();
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/wallet?uid=$uid'))
            .timeout(const Duration(seconds: 8));
        return ((jsonDecode(r.body)['balance'] ?? 0) as num).toInt();
      } catch (_) {}
    }
    return 0;
  }

  /// 给视频投币（+10 兑换币，同视频限一次）。返回服务器结果。
  static Future<Map<String, dynamic>?> coin(String videoId) async {
    final uid = await walletUid();
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/coin?uid=$uid&id=$videoId'))
            .timeout(const Duration(seconds: 10));
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
    }
    return null;
  }

  /// 点赞（免费）。[on] 给出目标状态(true=赞/false=取消)，服务器幂等设置——
  /// 慢请求/重试都不会来回切。返回 {ok, liked:bool, likes:新计数}。
  static Future<Map<String, dynamic>?> like(String videoId, {bool? on}) async {
    return _engage('like', videoId, on);
  }

  /// 收藏（免费，幂等）。返回 {ok, faved:bool, favs:新计数}。
  static Future<Map<String, dynamic>?> fav(String videoId, {bool? on}) async {
    return _engage('fav', videoId, on);
  }

  static Future<Map<String, dynamic>?> _engage(
      String path, String videoId, bool? on) async {
    final uid = await walletUid();
    final st = on == null ? '' : '&state=${on ? 1 : 0}';
    // 传了目标状态=幂等，可安全重试备用地址；没传=切换，非幂等，只打当前地址。
    final bases = on == null ? <String>{current} : <String>{current, baseUrl};
    for (final base in bases) {
      try {
        final r = await http
            .get(Uri.parse('$base/$path?uid=$uid&id=$videoId$st'))
            .timeout(const Duration(seconds: 10));
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
    }
    return null;
  }

  /// 每日签到领兑换币。返回 {ok, already, reward, balance}。
  static Future<Map<String, dynamic>?> signIn() async {
    final uid = await walletUid();
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/sign?uid=$uid'))
            .timeout(const Duration(seconds: 8));
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
    }
    return null;
  }

  /// 本设备的投币/点赞/收藏视频 id 列表。
  static Future<Map<String, List<String>>> myLists() async {
    final uid = await walletUid();
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/mylists?uid=$uid'))
            .timeout(const Duration(seconds: 8));
        final d = jsonDecode(r.body);
        if (d is Map) {
          List<String> g(String k) =>
              ((d[k] as List?) ?? []).map((e) => e.toString()).toList();
          return {'coined': g('coined'), 'liked': g('liked'), 'faved': g('faved')};
        }
      } catch (_) {}
    }
    return {'coined': [], 'liked': [], 'faved': []};
  }

  /// 启动登记本设备 + 取封号状态。返回 {ok, banned, ban_msg, ban_phone}。
  /// 取不到(离线)返回 null——按"未封号"处理，不误锁用户。
  static Future<Map<String, dynamic>?> checkin() async {
    final uid = await walletUid();
    final plat = Platform.operatingSystem;
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/checkin?uid=$uid&plat=$plat'))
            .timeout(const Duration(seconds: 8));
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
    }
    return null;
  }

  /// 被封用户点「联系管理员」→ 通知管理台。
  static Future<bool> contactAdmin() async {
    final uid = await walletUid();
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/contact-admin?uid=$uid'))
            .timeout(const Duration(seconds: 8));
        if (jsonDecode(r.body)['ok'] == true) return true;
      } catch (_) {}
    }
    return false;
  }

  /// 本设备对某视频的三连状态 + 各计数（一次取齐，开播放页时调一次）。
  /// 返回 {ok, balance, coined_this, liked_this, faved_this, coins, likes, favs}。
  static Future<Map<String, dynamic>?> videoState(String videoId) async {
    final uid = await walletUid();
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/wallet?uid=$uid&id=$videoId'))
            .timeout(const Duration(seconds: 8));
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
    }
    return null;
  }

  /// 花兑换币做某动作（如 rename）。后台 prices 决定价格。返回结果(ok/need/balance)。
  static Future<Map<String, dynamic>?> spend(String action) async {
    final uid = await walletUid();
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/spend?uid=$uid&action=$action'))
            .timeout(const Duration(seconds: 10));
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
    }
    return null;
  }

  /// 取 App 内显示名（后台设的；空则用默认）。
  static Future<String> getAppName() async {
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/version'))
            .timeout(const Duration(seconds: 6));
        return (jsonDecode(r.body)['app_name'] ?? '') as String;
      } catch (_) {}
    }
    return '';
  }

  /// 拉 /version 全量（app_name / download_url 等后台可改项）。失败 null。
  static Future<Map<String, dynamic>?> fetchVersionInfo() async {
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/version'))
            .timeout(const Duration(seconds: 6));
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
    }
    return null;
  }

  /// 取免责声明（后台设的；空则 app 用内置默认）。
  static Future<String> getDisclaimer() async {
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/version'))
            .timeout(const Duration(seconds: 6));
        return (jsonDecode(r.body)['disclaimer'] ?? '') as String;
      } catch (_) {}
    }
    return '';
  }

  /// 后台：上传下一版应用文件(which=mac|apk|win)覆盖官网下载。仅局域网+口令。
  static Future<bool> uploadAppFile(String which, String path) async {
    final bytes = await File(path).readAsBytes();
    for (final base in {'http://localhost:8900', lanBase}) {
      try {
        final r = await http
            .post(Uri.parse('$base/admin/upload-app?which=$which'),
                headers: {'X-Admin-Token': _adminToken}, body: bytes)
            .timeout(const Duration(minutes: 10));
        if (jsonDecode(r.body)['ok'] == true) return true;
      } catch (_) {}
    }
    return false;
  }

  /// 取平台公告（管理员在后台设的，公开可读）。
  static Future<String> getNotice() async {
    for (final base in {current, baseUrl}) {
      try {
        final r = await http
            .get(Uri.parse('$base/notice'))
            .timeout(const Duration(seconds: 6));
        final d = jsonDecode(r.body);
        return (d['notice'] ?? '') as String;
      } catch (_) {}
    }
    return '';
  }

  /// 后台管理软口令（与 server.py ADMIN_TOKEN 一致）。
  static const _adminToken = 'xladmin-9f2c7b';

  /// 后台管理通用调用：GET /admin/<action>，自动带软口令。返回解析后的 JSON（失败 null）。
  static Future<Map<String, dynamic>?> adminGet(String action,
      {Map<String, String> params = const {}}) async {
    final qs = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    for (final base in {'http://localhost:8900', lanBase, current}) {
      try {
        final uri = qs.isEmpty
            ? '$base/admin/$action'
            : '$base/admin/$action?$qs';
        final r = await http.get(Uri.parse(uri),
            headers: {'X-Admin-Token': _adminToken}) // 令牌走头，不进日志
            .timeout(const Duration(seconds: 15));
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
    }
    return null;
  }

  /// 后台管理：导入/恢复 index（POST，body=导出的 JSON 文本）。返回成功条数或 null。
  static Future<int?> adminImport(String jsonText) async {
    for (final base in {'http://localhost:8900', lanBase, current}) {
      try {
        final r = await http
            .post(Uri.parse('$base/admin/import'),
                headers: {
                  'Content-Type': 'application/json',
                  'X-Admin-Token': _adminToken,
                },
                body: jsonText)
            .timeout(const Duration(seconds: 20));
        final d = jsonDecode(r.body);
        if (d['ok'] == true) return (d['count'] ?? 0) as int;
      } catch (_) {}
    }
    return null;
  }

  /// 后台管理：取全部视频（含隐藏）+ 管理字段。
  static Future<List<PlatformVideo>> adminList() async {
    final d = await adminGet('videos');
    final list = (d?['videos'] as List?) ?? [];
    return list
        .map((e) => PlatformVideo(
              id: (e['id'] ?? '') as String,
              title: (e['title'] ?? '') as String,
              uploader: (e['uploader'] ?? '') as String,
              rating: ((e['rating'] ?? 0) as num).toDouble(),
              rcount: ((e['rcount'] ?? 0) as num).toInt(),
              cat: (e['cat'] ?? '') as String,
              size: ((e['size'] ?? 0) as num).toInt(),
              ts: ((e['ts'] ?? 0) as num).toInt(),
              ghUrl: e['gh_url'] as String?,
              hidden: e['hidden'] == true,
              pinned: e['pinned'] == true,
              views: ((e['views'] ?? 0) as num).toInt(),
              coins: ((e['coins'] ?? 0) as num).toInt(),
              likes: ((e['likes'] ?? 0) as num).toInt(),
              favs: ((e['favs'] ?? 0) as num).toInt(),
            ))
        .where((v) => v.id.isNotEmpty)
        .toList();
  }

  /// 后台管理：删除一条平台/云端视频。返回是否成功。
  static Future<bool> deleteVideo(String id) async {
    for (final base in {'http://localhost:8900', lanBase, current}) {
      try {
        final r = await http.get(
            Uri.parse('$base/delete?id=${Uri.encodeComponent(id)}'),
            headers: {'X-Admin-Token': _adminToken}).timeout(
            const Duration(seconds: 10));
        if (jsonDecode(r.body)['ok'] == true) return true;
      } catch (_) {}
    }
    return false;
  }

  /// 云端缓存：把已解析的视频直链+请求头交给平台服务器，由服务器下载存储，
  /// 并后台备份到 GitHub Releases。带软口令(防公网匿名滥用)。返回 null 成功，否则错误串。
  static Future<String?> cloudFetch(String title, String uploader, String url,
      Map<String, String> headers, String ext) async {
    final body = jsonEncode({
      'title': title,
      'uploader': uploader,
      'url': url,
      'headers': headers,
      'ext': ext,
    });
    String lastErr = '服务器连不上';
    for (final base in _uploadBases) {
      try {
        final h = await http
            .get(Uri.parse('$base/health'))
            .timeout(const Duration(seconds: 3));
        if (h.statusCode != 200) continue;
        final r = await http
            .post(Uri.parse('$base/cloud-fetch'),
                headers: {
                  'Content-Type': 'application/json',
                  'X-Admin-Token': _adminToken, // 云端缓存需令牌(防公网匿名滥用)
                },
                body: body)
            .timeout(const Duration(minutes: 15));
        final d = jsonDecode(r.body);
        if (d['ok'] == true) return null;
        lastErr = '${d['error'] ?? r.statusCode}';
      } catch (e) {
        lastErr = '$e';
        continue;
      }
    }
    return lastErr;
  }

  Future<List<PlatformVideo>> search(String q,
      {String cat = '', String sort = ''}) async {
    try {
      final catQs = cat.isEmpty ? '' : '&cat=${Uri.encodeComponent(cat)}';
      final sortQs = sort.isEmpty ? '' : '&sort=${Uri.encodeComponent(sort)}';
      final r = await _http
          .get(Uri.parse(
              '$current/search?q=${Uri.encodeComponent(q)}$catQs$sortQs'))
          .timeout(const Duration(seconds: 15));
      final list = (jsonDecode(r.body) as List?) ?? [];
      return list
          .map((e) => PlatformVideo(
                id: (e['id'] ?? '') as String,
                title: (e['title'] ?? '') as String,
                uploader: (e['uploader'] ?? '') as String,
                rating: ((e['rating'] ?? 0) as num).toDouble(),
                rcount: ((e['rcount'] ?? 0) as num).toInt(),
                cat: (e['cat'] ?? '') as String,
                size: ((e['size'] ?? 0) as num).toInt(),
                ts: ((e['ts'] ?? 0) as num).toInt(),
                ghUrl: e['gh_url'] as String?,
                views: ((e['views'] ?? 0) as num).toInt(),
                coins: ((e['coins'] ?? 0) as num).toInt(),
                likes: ((e['likes'] ?? 0) as num).toInt(),
                favs: ((e['favs'] ?? 0) as num).toInt(),
              ))
          .where((v) => v.id.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<PlatformVideo>> list({String cat = '', String sort = ''}) =>
      search('', cat: cat, sort: sort);

  /// 下载平台视频到 [destPath]，onProgress(已收字节, 总字节)。返回 null 成功，否则错误串。
  Future<String?> downloadVideo(String videoId, String destPath,
      {void Function(int received, int total)? onProgress}) async {
    try {
      final req = http.Request('GET', Uri.parse(videoUrl(videoId)));
      final resp = await _http.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return 'HTTP ${resp.statusCode}';
      final total = resp.contentLength ?? 0;
      var received = 0;
      final sink = File(destPath).openWrite();
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (onProgress != null) onProgress(received, total);
        }
      } finally {
        await sink.close(); // 异常路径也要关，避免句柄泄漏
      }
      return null;
    } catch (e) {
      try {
        final f = File(destPath); // 出错删掉半截文件
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      return '$e';
    }
  }

  /// 生成批量下载脚本（aria2/wget），返回脚本文本。失败返回 null。
  Future<String?> exportScript(List<String> ids, String fmt) async {
    try {
      final idsQs = ids.join(',');
      final r = await _http
          .get(Uri.parse(
              '$current/export-script?ids=${Uri.encodeComponent(idsQs)}&fmt=$fmt'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      return r.body;
    } catch (_) {
      return null;
    }
  }

  /// 带进度的上传：yield 进度(0~1)，最后一项为 1.0；出错抛异常。msg 通过 lastMessage 取。
  String lastUploadMessage = '';
  Stream<double> uploadWithProgress(
      String path, String title, String uploader) async* {
    final file = File(path);
    if (!file.existsSync()) {
      lastUploadMessage = '文件不存在';
      throw Exception(lastUploadMessage);
    }
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : 'mp4';
    final total = await file.length();
    final query = '?title=${Uri.encodeComponent(title)}'
        '&uploader=${Uri.encodeComponent(uploader)}&ext=$ext';
    String lastErr = '服务器连不上';
    for (final base in _uploadBases) {
      try {
        final h = await _http
            .get(Uri.parse('$base/health'))
            .timeout(const Duration(seconds: 3));
        if (h.statusCode != 200) continue;
        var sent = 0;
        final controller = StreamController<double>();
        final req = http.StreamedRequest('POST', Uri.parse('$base/upload$query'));
        req.headers['Content-Type'] = 'application/octet-stream';
        req.contentLength = total;
        final respFuture = _http.send(req);
        // 分块喂数据，边喂边报进度；喂完关闭进度流。
        // 读文件出错也要关闭进度流，否则下面 yield* 会一直挂到 20 分钟超时。
        () async {
          try {
            await for (final chunk in file.openRead()) {
              req.sink.add(chunk);
              sent += chunk.length;
              if (!controller.isClosed) {
                controller.add(total == 0 ? 0 : sent / total);
              }
            }
          } catch (e) {
            if (!controller.isClosed) controller.addError(e);
          } finally {
            try {
              req.sink.close();
            } catch (_) {}
            if (!controller.isClosed) await controller.close();
          }
        }();
        yield* controller.stream;
        final streamed = await respFuture.timeout(const Duration(minutes: 20));
        final body = await streamed.stream.bytesToString();
        final d = jsonDecode(body);
        if (d['ok'] == true) {
          lastUploadMessage = '上传成功！别人搜「$title」就能看到';
          yield 1.0;
          return;
        }
        lastErr = '${d['error'] ?? streamed.statusCode}';
      } catch (e) {
        lastErr = '$e';
        continue;
      }
    }
    lastUploadMessage = '上传失败：$lastErr（确保平台服务器在运行）';
    throw Exception(lastUploadMessage);
  }

  /// 上传优先级：本机直传(秒级) → 局域网 → 公网(慢，兜底)。
  /// cloudflared 免费隧道上传极慢，故同机/同网时直传服务器。
  static List<String> get _uploadBases => [
        'http://localhost:8900',
        lanBase, // 自动探测的局域网地址（随网络自愈，不再写死 IP）
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
