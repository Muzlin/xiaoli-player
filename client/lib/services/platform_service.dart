import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// 本应用「视频平台」一条视频。
class PlatformVideo {
  final String id;
  final String title;
  final String uploader;
  final double rating;
  final int rcount;
  final String cat; // 分类：'视频' / '音乐'
  PlatformVideo(
      {required this.id,
      required this.title,
      required this.uploader,
      this.rating = 0,
      this.rcount = 0,
      this.cat = ''});
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
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null) onProgress(received, total);
      }
      await sink.close();
      return null;
    } catch (e) {
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
