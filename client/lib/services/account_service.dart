import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'platform_service.dart';

/// 小李账号：用户名+密码登录(30 天免登录)、手机号绑定、B站登录态云同步。
///
/// 账号的 uid = 钱包 uid。登录成功后把本机 wallet_uid 覆盖成账号主 uid，
/// 于是余额/收藏/昵称/私信/群聊等既有数据全部随账号走(服务端老接口不用改)。
/// 同一账号在其它设备登录会拿到同一个 uid，B站登录态也从服务端同步。
class AccountService {
  static const tokenKey = 'acc_token';
  static const userKey = 'acc_user';
  static const phoneKey = 'acc_phone';
  // 刚注册、还没选「绑定B站 / 跳过」时置 1：此期间不做 B站登录态云同步，
  // 等用户在注册引导里做出选择后再处理。
  static const biliPendingKey = 'acc_bili_pending';

  /// 依次尝试的服务器地址：本机(若在跑) → 隧道当前 → 内置兜底。
  static List<String> _bases() {
    final s = <String>[];
    if (PlatformService.localServerUp) s.add('http://localhost:8900');
    s.add(PlatformService.current);
    s.add(PlatformService.baseUrl);
    s.add('http://localhost:8900');
    return s.toSet().toList();
  }

  static Map<String, dynamic> _asMap(dynamic d) {
    if (d is Map<String, dynamic>) return d;
    if (d is Map) return Map<String, dynamic>.from(d);
    return {};
  }

  static Map<String, dynamic> _netErr() =>
      {'ok': false, 'error': '连不上服务器，请检查网络后重试'};

  static Future<Map<String, dynamic>?> _post(
      String path, Map<String, dynamic> body) async {
    for (final base in _bases()) {
      try {
        final r = await http
            .post(Uri.parse('$base$path'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode(body))
            .timeout(const Duration(seconds: 12));
        final d = jsonDecode(utf8.decode(r.bodyBytes));
        if (d is Map) return _asMap(d);
      } catch (_) {}
    }
    return null;
  }

  static Future<Map<String, dynamic>?> _get(String path) async {
    for (final base in _bases()) {
      try {
        final r = await http
            .get(Uri.parse('$base$path'))
            .timeout(const Duration(seconds: 12));
        final d = jsonDecode(utf8.decode(r.bodyBytes));
        if (d is Map) return _asMap(d);
      } catch (_) {}
    }
    return null;
  }

  // ===== 注册 / 登录 =====

  /// 注册。注册成功后服务端会签发 token，本机 wallet_uid 作为账号主 uid。
  static Future<Map<String, dynamic>> register(String u, String p) async {
    final uid = await PlatformService.walletUid();
    final d = await _post('/acc-register', {'u': u, 'p': p, 'uid': uid});
    return d ?? _netErr();
  }

  static Future<Map<String, dynamic>> login(String u, String p) async {
    final d = await _post('/acc-login', {'u': u, 'p': p});
    return d ?? _netErr();
  }

  /// 手机端「只输手机号即登录」：存在就登，不存在就直接建号(is_new=true)。
  static Future<Map<String, dynamic>> quickLogin(String phone) async {
    final uid = await PlatformService.walletUid();
    final d = await _post('/acc-quick-login', {'u': phone, 'uid': uid});
    return d ?? _netErr();
  }

  static Future<Map<String, dynamic>> codeLogin(String phone, String code) async {
    final d = await _post('/acc-code-login', {'phone': phone, 'code': code});
    return d ?? _netErr();
  }

  /// 发验证码。服务端把验证码作为**系统通知**推给该账号已登录的设备
  /// (不依赖短信)，所以请在另一台已登录设备上查看。
  static Future<Map<String, dynamic>> sendCode(String phone,
      {String purpose = 'login'}) async {
    final d =
        await _post('/acc-send-code', {'phone': phone, 'purpose': purpose});
    return d ?? _netErr();
  }

  static Future<Map<String, dynamic>> resetPassword(
      String phone, String code, String pw) async {
    final d = await _post('/acc-reset-pw',
        {'phone': phone, 'code': code, 'p': pw});
    return d ?? _netErr();
  }

  // ===== 本地登录态 =====

  static Future<String?> token() async {
    final p = await SharedPreferences.getInstance();
    final t = p.getString(tokenKey) ?? '';
    return t.isEmpty ? null : t;
  }

  static Future<String> currentUser() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(userKey) ?? '';
  }

  static Future<String> currentPhone() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(phoneKey) ?? '';
  }

  /// 用本地 token 恢复登录态(30 天有效)。成功返回会话并把账号主 uid 写回钱包。
  static Future<Map<String, dynamic>?> restore() async {
    final t = await token();
    if (t == null) return null;
    final d = await _post('/acc-token', {'tk': t});
    if (d != null && d['ok'] == true) {
      await applySession(d, token: t);
      return d;
    }
    return null;
  }

  /// 登录/注册成功：持久化 token、账号名、手机号，并把账号主 uid 设为钱包 uid。
  static Future<void> applySession(Map<String, dynamic> d,
      {String? token, bool fresh = false}) async {
    final p = await SharedPreferences.getInstance();
    final t = token ?? d['token'];
    if (t is String && t.isNotEmpty) await p.setString(tokenKey, t);
    if (d['u'] != null) await p.setString(userKey, '${d['u']}');
    if (d['phone'] != null) await p.setString(phoneKey, '${d['phone']}');
    final uid = d['uid'];
    if (uid is String && uid.isNotEmpty) {
      await PlatformService.setWalletUid(uid);
    }
    // 新建账号：先不继承/同步本机 B站登录，等注册引导里选「绑定 / 跳过」；
    // 普通登录：清掉标记，B站登录态随账号同步(登录响应里带就直接落盘)。
    await p.setString(biliPendingKey, fresh ? '1' : '0');
    // 新用户没有名称：默认显示名就是手机号(可在个人资料里改)。
    if (fresh) {
      final cur = (p.getString('profile_name') ?? '').trim();
      final ph = d['phone'];
      if (cur.isEmpty && ph is String && ph.isNotEmpty) {
        await p.setString('profile_name', ph);
      }
    }
    final bili = d['bili'];
    if (!fresh && bili is String && bili.isNotEmpty) {
      await p.setString('bili_cookie', bili);
    }
  }

  static Future<bool> biliChoicePending() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(biliPendingKey) == '1';
  }

  static Future<void> clearBiliPending() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(biliPendingKey, '0');
  }

  /// 退出登录：清本地 token/账号信息/钱包 uid/B站登录，服务器账号数据不动。
  static Future<void> logout() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(tokenKey);
    await p.remove(userKey);
    await p.remove(phoneKey);
    await p.remove('bili_cookie');
    await PlatformService.setWalletUid('');
  }

  // ===== 安全设置 =====

  static Future<Map<String, dynamic>> bindPhone(String phone) async {
    final t = await token();
    if (t == null) return {'ok': false, 'error': '未登录'};
    final d = await _post('/acc-bind-phone', {'tk': t, 'phone': phone});
    if (d != null && d['ok'] == true) {
      final p = await SharedPreferences.getInstance();
      await p.setString(phoneKey, phone);
    }
    return d ?? _netErr();
  }

  static Future<Map<String, dynamic>> changePassword(
      String oldPw, String newPw) async {
    final t = await token();
    if (t == null) return {'ok': false, 'error': '未登录'};
    final d = await _post('/acc-set-pw',
        {'tk': t, 'old': oldPw, 'new': newPw});
    return d ?? _netErr();
  }

  /// 把本机 B站登录 cookie 推到账号云端(其它设备登录同账号即可同步)。
  /// 传空字符串=把退出登录的状态也同步出去。
  static Future<void> bindBili(String cookie) async {
    final t = await token();
    if (t == null) return;
    await _post('/acc-bind-bili', {'tk': t, 'cookie': cookie});
  }

  // ===== 扫码登录 =====
  /// 电脑端(申请方)：创建扫码登录会话，返回 {qid, secret, url}。
  static Future<Map<String, dynamic>> qrNew() async {
    final d = await _post('/acc-qr-new', {});
    return d ?? _netErr();
  }

  /// 电脑端轮询会话状态；confirmed 时带 token/uid/u，可直接 applySession。
  static Future<Map<String, dynamic>?> qrPoll(String qid, String secret) =>
      _get('/acc-qr-poll?qid=${Uri.encodeComponent(qid)}'
          '&secret=${Uri.encodeComponent(secret)}');

  /// 已登录设备扫码确认：传 qid+secret(或整段 content 由服务端解析)。
  static Future<Map<String, dynamic>> qrConfirm(
      {required String qid, required String secret, String content = ''}) async {
    final t = await token();
    if (t == null) return {'ok': false, 'error': '请先登录账号再扫码'};
    final d = await _post('/acc-qr-scan',
        {'tk': t, 'qid': qid, 'secret': secret, 'content': content});
    return d ?? _netErr();
  }

  /// 拉账号云端的 B站登录态。未登录/失败返回 null。
  static Future<String?> getBili() async {
    final t = await token();
    if (t == null) return null;
    final d = await _get('/acc-bili?tk=${Uri.encodeComponent(t)}');
    if (d != null && d['ok'] == true) return '${d['cookie'] ?? ''}';
    return null;
  }
}
