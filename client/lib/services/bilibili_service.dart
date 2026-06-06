import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// 一条联网搜索结果（视频/音乐）。
class BiliTrack {
  final String bvid;
  final String title;
  final String author;
  BiliTrack({required this.bvid, required this.title, required this.author});
}

/// 联网搜索中文音乐内容并取可播放地址（搜索/取流需 wbi 签名，播放需 Referer）。
class BilibiliService {
  static const _ua =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';
  static const referer = 'https://www.bilibili.com';

  static const _mixinTab = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52
  ];

  final http.Client _http;
  String _cookie = '';
  String _userCookie = ''; // 登录 cookie（含 SESSDATA），绕过匿名限流
  String? _mixinKey;

  BilibiliService([http.Client? client]) : _http = client ?? http.Client();

  /// 设置 B站登录 cookie：可粘整段 cookie，或只粘 SESSDATA 的值。空字符串=退出登录。
  void setUserCookie(String raw) {
    final s = raw.trim();
    _userCookie = s.isEmpty
        ? ''
        : (s.contains('=') ? s : 'SESSDATA=$s');
  }

  bool get isLoggedIn => _userCookie.isNotEmpty;

  /// 播放音频/视频流时需要带的请求头（防盗链）。
  Map<String, String> get playHeaders =>
      {'Referer': referer, 'User-Agent': _ua};

  Map<String, String> get _headers {
    final parts = <String>[];
    if (_userCookie.isNotEmpty) parts.add(_userCookie); // 登录 cookie 优先
    if (_cookie.isNotEmpty) parts.add(_cookie);
    return {
      'User-Agent': _ua,
      'Referer': referer,
      if (parts.isNotEmpty) 'Cookie': parts.join('; '),
    };
  }

  /// 获取完整 cookie（降低风控）+ wbi 密钥。
  Future<void> _ensureInit() async {
    if (_mixinKey != null && _cookie.isNotEmpty) return;
    var buvid3 = '';
    var buvid4 = '';
    // 1) 访问首页拿 Set-Cookie 里的 buvid3
    try {
      final home = await _http
          .get(Uri.parse('https://www.bilibili.com'),
              headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 8));
      final sc = home.headers['set-cookie'] ?? '';
      final m = RegExp(r'buvid3=([^;,\s]+)').firstMatch(sc);
      if (m != null) buvid3 = m.group(1)!;
    } catch (_) {}
    // 2) spi 拿 buvid3 + buvid4（更权威）
    try {
      final spi = jsonDecode((await _http
              .get(Uri.parse('https://api.bilibili.com/x/frontend/finger/spi'),
                  headers: {'User-Agent': _ua})
              .timeout(const Duration(seconds: 8)))
          .body);
      final b3 = spi['data']?['b_3'] as String?;
      final b4 = spi['data']?['b_4'] as String?;
      if (b3 != null && b3.isNotEmpty) buvid3 = b3;
      if (b4 != null) buvid4 = b4;
    } catch (_) {}
    final nut = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _cookie =
        'buvid3=$buvid3; buvid4=$buvid4; b_nut=$nut; CURRENT_FNVAL=4048; '
        'header_theme_version=CLOSE; enable_web_push=DISABLE';
    // 3) wbi 密钥
    final nav = jsonDecode((await _http.get(
            Uri.parse('https://api.bilibili.com/x/web-interface/nav'),
            headers: _headers))
        .body);
    final wbi = nav['data']['wbi_img'];
    final ik = (wbi['img_url'] as String).split('/').last.split('.').first;
    final sk = (wbi['sub_url'] as String).split('/').last.split('.').first;
    final orig = ik + sk;
    final sb = StringBuffer();
    for (final i in _mixinTab) {
      if (i < orig.length) sb.write(orig[i]);
    }
    _mixinKey = sb.toString().substring(0, 32);
  }

  /// 清洗 B站标题：去掉搜索高亮 <em> 等 HTML 标签、解码常见实体。保留正文。
  static String cleanTitle(String raw) {
    var s = raw;
    const entities = {
      '&amp;': '&',
      '&lt;': '<',
      '&gt;': '>',
      '&quot;': '"',
      '&#34;': '"',
      '&#39;': "'",
      '&apos;': "'",
      '&nbsp;': ' ',
    };
    entities.forEach((k, v) => s = s.replaceAll(k, v));
    // 解码后可能又冒出 < >，统一再去一遍标签
    s = s.replaceAll(RegExp(r'<[^>]*>'), '');
    // 残留数字实体（十进制 &#123; 与十六进制 &#x1F600;）
    s = s.replaceAll(RegExp(r'&#(?:\d+|[xX][0-9A-Fa-f]+);'), '');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _enc(String s) =>
      Uri.encodeComponent(s.replaceAll(RegExp(r"[!'()*]"), ''));

  String _sign(Map<String, String> params) {
    params['wts'] =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final keys = params.keys.toList()..sort();
    final q = keys.map((k) => '${_enc(k)}=${_enc(params[k]!)}').join('&');
    params['w_rid'] = md5.convert(utf8.encode(q + _mixinKey!)).toString();
    final all = [...keys, 'w_rid'];
    return all.map((k) => '${_enc(k)}=${_enc(params[k]!)}').join('&');
  }

  /// 联网搜索（单次请求，靠完整 cookie 降低风控）。失败/被限流返回空列表。
  Future<List<BiliTrack>> search(String keyword) async {
    if (keyword.trim().isEmpty) return [];
    try {
      await _ensureInit();
      final qs = _sign({
        'search_type': 'video',
        'keyword': keyword,
        'page': '1',
      });
      final r = await _http
          .get(
            Uri.parse(
                'https://api.bilibili.com/x/web-interface/wbi/search/type?$qs'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      final d = jsonDecode(r.body);
      final res = (d['data']?['result'] as List?) ?? [];
      return res
          .map((e) {
            final m = e as Map<String, dynamic>;
            final title = cleanTitle(m['title'] as String? ?? '');
            return BiliTrack(
              bvid: (m['bvid'] ?? '') as String,
              title: title,
              author: (m['author'] ?? '') as String,
            );
          })
          .where((t) => t.bvid.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 取 B站 自带字幕（AI/CC），转成 SRT 文本；无字幕或失败返回 null。
  Future<String?> getSubtitles(String bvid) async {
    try {
      await _ensureInit();
      final view = jsonDecode((await _http.get(
              Uri.parse(
                  'https://api.bilibili.com/x/web-interface/view?bvid=$bvid'),
              headers: _headers))
          .body);
      final cid = view['data']['cid'].toString();
      final qs = _sign({'bvid': bvid, 'cid': cid});
      final v2 = jsonDecode((await _http.get(
              Uri.parse('https://api.bilibili.com/x/player/wbi/v2?$qs'),
              headers: _headers))
          .body);
      final subs = (v2['data']?['subtitle']?['subtitles'] as List?) ?? [];
      if (subs.isEmpty) return null;
      // 优先中文/AI中文，否则第一条
      final sel = subs.firstWhere(
        (s) {
          final lan = (s['lan'] as String? ?? '');
          return lan.startsWith('zh') || lan.contains('ai-zh') || lan == 'ai-zh';
        },
        orElse: () => subs.first,
      ) as Map;
      var url = (sel['subtitle_url'] as String? ?? '');
      if (url.isEmpty) return null;
      if (url.startsWith('//')) url = 'https:$url';
      final body = jsonDecode((await _http
              .get(Uri.parse(url), headers: {'User-Agent': _ua}))
          .body);
      final lines = (body['body'] as List?) ?? [];
      if (lines.isEmpty) return null;
      return _toSrt(lines);
    } catch (_) {
      return null;
    }
  }

  static String _toSrt(List lines) {
    final sb = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i] as Map;
      final from = (l['from'] as num).toDouble();
      final to = (l['to'] as num).toDouble();
      final content = (l['content'] as String? ?? '');
      sb.writeln('${i + 1}');
      sb.writeln('${_srtTime(from)} --> ${_srtTime(to)}');
      sb.writeln(content);
      sb.writeln();
    }
    return sb.toString();
  }

  static String _srtTime(double sec) {
    final h = (sec ~/ 3600).toString().padLeft(2, '0');
    final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).floor().toString().padLeft(2, '0');
    final ms = (((sec - sec.floorToDouble()) * 1000).round())
        .toString()
        .padLeft(3, '0');
    return '$h:$m:$s,$ms';
  }

  /// 取某视频的可播放地址：优先「音视频合一」的 mp4，否则退回音频流。
  Future<String?> getMediaUrl(String bvid) async {
    try {
      await _ensureInit();
      final view = jsonDecode((await _http.get(
              Uri.parse(
                  'https://api.bilibili.com/x/web-interface/view?bvid=$bvid'),
              headers: _headers))
          .body);
      final cid = view['data']['cid'].toString();
      final qs1 = _sign({
        'bvid': bvid,
        'cid': cid,
        'qn': '64',
        'fnval': '1',
        'platform': 'html5',
      });
      final pu1 = jsonDecode((await _http.get(
              Uri.parse('https://api.bilibili.com/x/player/wbi/playurl?$qs1'),
              headers: _headers))
          .body);
      final durl = pu1['data']?['durl'] as List?;
      if (durl != null && durl.isNotEmpty) {
        final u = durl.first['url'];
        if (u is String && u.isNotEmpty) return u;
      }
      final qs2 = _sign({'bvid': bvid, 'cid': cid, 'fnval': '16'});
      final pu2 = jsonDecode((await _http.get(
              Uri.parse('https://api.bilibili.com/x/player/wbi/playurl?$qs2'),
              headers: _headers))
          .body);
      final audio = (pu2['data']?['dash']?['audio'] as List?) ?? [];
      if (audio.isNotEmpty) return audio.first['baseUrl'] as String;
      return null;
    } catch (_) {
      return null;
    }
  }
}
