import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// 一条 B站搜索结果（视频/音乐）。
class BiliTrack {
  final String bvid;
  final String title;
  final String author;
  BiliTrack({required this.bvid, required this.title, required this.author});
}

/// 接入哔哩哔哩：联网搜索中文音乐内容，并取音频流播放。
///
/// 搜索与取流都需要 wbi 签名（B站反爬）；播放音频流需带 Referer。
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
  String? _buvid3;
  String? _mixinKey;

  BilibiliService([http.Client? client]) : _http = client ?? http.Client();

  /// 播放音频流时需要带的请求头（防盗链）。
  Map<String, String> get playHeaders =>
      {'Referer': referer, 'User-Agent': _ua};

  Map<String, String> get _headers => {
        'User-Agent': _ua,
        'Referer': referer,
        if (_buvid3 != null) 'Cookie': 'buvid3=$_buvid3',
      };

  Future<void> _ensureInit() async {
    if (_mixinKey != null) return;
    // buvid3（反爬 cookie）
    try {
      final r = await _http.get(
        Uri.parse('https://api.bilibili.com/x/frontend/finger/spi'),
        headers: {'User-Agent': _ua},
      );
      _buvid3 = jsonDecode(r.body)['data']['b_3'] as String?;
    } catch (_) {}
    // wbi 密钥
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

  String _enc(String s) =>
      Uri.encodeComponent(s.replaceAll(RegExp(r"[!'()*]"), ''));

  /// 对参数做 wbi 签名，返回完整 query 字符串。
  String _sign(Map<String, String> params) {
    params['wts'] =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final keys = params.keys.toList()..sort();
    final q = keys.map((k) => '${_enc(k)}=${_enc(params[k]!)}').join('&');
    params['w_rid'] = md5.convert(utf8.encode(q + _mixinKey!)).toString();
    final all = [...keys, 'w_rid'];
    return all.map((k) => '${_enc(k)}=${_enc(params[k]!)}').join('&');
  }

  /// 联网搜索。失败返回空列表。
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
            final title =
                (m['title'] as String? ?? '').replaceAll(RegExp(r'<[^>]+>'), '');
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

  /// 取某视频的可播放地址：优先「音视频合一」的 mp4（能显示画面+声音），
  /// 否则退回音频流。失败返回 null。
  Future<String?> getMediaUrl(String bvid) async {
    try {
      await _ensureInit();
      final view = jsonDecode((await _http.get(
              Uri.parse(
                  'https://api.bilibili.com/x/web-interface/view?bvid=$bvid'),
              headers: _headers))
          .body);
      final cid = view['data']['cid'].toString();
      // 优先 durl：音视频合一的 mp4，可直接播放画面+声音
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
      // 退回 dash 音频流（纯音频）
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
