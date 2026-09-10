import 'dart:async';
import 'package:flutter/material.dart';
import '../services/account_service.dart';
import '../services/platform_service.dart';

/// 登录/注册/忘记密码/验证码登录。首次打开必须登录，登录态 30 天，
/// 过期后回到这里重新输入账号密码。
///
/// 手机验证码不依赖短信：服务端把验证码作为**系统通知**推给该账号
/// 已经登录的设备，请在另一台设备上查看。
class LoginPage extends StatefulWidget {
  final void Function(Map<String, dynamic> session, bool justRegistered)
      onLoggedIn;
  const LoginPage({super.key, required this.onLoggedIn});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

enum _Mode { login, register, forgot }

class _LoginPageState extends State<LoginPage> {
  static const _accent = Color(0xFFF26B21);

  _Mode _mode = _Mode.login;
  bool _useCode = false; // 登录方式：密码 / 验证码
  bool _busy = false;
  bool _warming = true;
  String? _err;

  final _u = TextEditingController();
  final _p = TextEditingController();
  final _p2 = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _newPw = TextEditingController();

  Timer? _cdTimer;
  int _cd = 0;

  @override
  void initState() {
    super.initState();
    _warmup();
  }

  @override
  void dispose() {
    _cdTimer?.cancel();
    _u.dispose();
    _p.dispose();
    _p2.dispose();
    _phone.dispose();
    _code.dispose();
    _newPw.dispose();
    super.dispose();
  }

  Future<void> _warmup() async {
    try {
      await PlatformService.loadLocal();
    } catch (_) {}
    try {
      await PlatformService.loadRemoteUrl();
    } catch (_) {}
    if (mounted) setState(() => _warming = false);
  }

  void _setErr(String? e) {
    if (mounted) setState(() => _err = e);
  }

  void _startCooldown() {
    _cd = 60;
    _cdTimer?.cancel();
    _cdTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _cd--);
      if (_cd <= 0) t.cancel();
    });
  }

  Future<void> _sendCode({required String purpose}) async {
    final phone = _phone.text.trim();
    if (phone.isEmpty) {
      _setErr('请先填写手机号');
      return;
    }
    setState(() => _busy = true);
    _setErr(null);
    final d = await AccountService.sendCode(phone, purpose: purpose);
    if (!mounted) return;
    setState(() => _busy = false);
    if (d['ok'] == true) {
      _startCooldown();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('验证码已通过系统通知发送到你已登录该账号的设备，请查看通知'),
        duration: Duration(seconds: 4),
      ));
      if (d['code'] != null) {
        // 仅调试模式(服务端 account_debug)会回传，方便自测。
        _setErr('调试验证码：${d['code']}');
      }
    } else {
      _setErr('${d['error'] ?? '发送失败'}');
    }
  }

  Future<void> _doLogin() async {
    final d = _useCode
        ? await AccountService.codeLogin(_phone.text.trim(), _code.text.trim())
        : await AccountService.login(_u.text.trim(), _p.text);
    await _finish(d, justRegistered: false);
  }

  Future<void> _doRegister() async {
    if (_p.text != _p2.text) {
      _setErr('两次输入的密码不一致');
      return;
    }
    final d = await AccountService.register(_u.text.trim(), _p.text);
    await _finish(d, justRegistered: true);
  }

  Future<void> _doReset() async {
    final d = await AccountService.resetPassword(
        _phone.text.trim(), _code.text.trim(), _newPw.text);
    if (!mounted) return;
    if (d['ok'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('密码已重置，请用新密码登录')));
      setState(() {
        _mode = _Mode.login;
        _useCode = false;
        _p.clear();
      });
      _setErr(null);
    } else {
      _setErr('${d['error'] ?? '重置失败'}');
    }
  }

  Future<void> _finish(Map<String, dynamic> d,
      {required bool justRegistered}) async {
    if (!mounted) return;
    if (d['ok'] == true) {
      _setErr(null);
      await AccountService.applySession(d);
      if (mounted) widget.onLoggedIn(d, justRegistered);
    } else {
      _setErr('${d['error'] ?? '操作失败'}');
    }
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() => _busy = true);
    _setErr(null);
    try {
      await fn();
    } catch (e) {
      _setErr('出错：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF23232B), Color(0xFF3A2A22)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.play_circle_fill,
                      size: 64, color: _accent),
                  const SizedBox(height: 10),
                  const Text('小李播放器',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    _warming ? '正在连接服务器…' : '登录后数据随账号走，支持 Win / Mac / 安卓',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 22),
                  Card(
                    color: const Color(0xFF2E2E38),
                    elevation: 8,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                      child: _form(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _segBtn('登录', _mode == _Mode.login,
                () => setState(() => _mode = _Mode.login)),
            _segBtn('注册', _mode == _Mode.register,
                () => setState(() => _mode = _Mode.register)),
            _segBtn('忘记密码', _mode == _Mode.forgot,
                () => setState(() => _mode = _Mode.forgot)),
          ],
        ),
        const SizedBox(height: 18),
        if (_mode == _Mode.login) ..._loginForm(),
        if (_mode == _Mode.register) ..._registerForm(),
        if (_mode == _Mode.forgot) ..._forgotForm(),
        if (_err != null) ...[
          const SizedBox(height: 12),
          Text(_err!,
              style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 13)),
        ],
      ],
    );
  }

  Widget _segBtn(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? _accent : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(label,
              style: TextStyle(
                  color: active ? Colors.white : Colors.white60,
                  fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _tf(TextEditingController c, String hint,
      {bool obscure = false, TextInputType? keyboard, int? maxLength}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: obscure,
        keyboardType: keyboard,
        maxLength: maxLength,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: hint,
          counterText: '',
          hintStyle: const TextStyle(color: Colors.white38),
          filled: true,
          fillColor: const Color(0xFF3B3B47),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
    );
  }

  Widget _primary(String label, VoidCallback onTap) {
    return SizedBox(
      height: 48,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: _accent,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
        onPressed: _busy ? null : onTap,
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : Text(label,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
      ),
    );
  }

  List<Widget> _loginForm() {
    return [
      if (_useCode) ...[
        _tf(_phone, '手机号', keyboard: TextInputType.phone, maxLength: 20),
        Row(
          children: [
            Expanded(
                child: _tf(_code, '验证码', keyboard: TextInputType.number,
                    maxLength: 6)),
            const SizedBox(width: 8),
            SizedBox(
              height: 46,
              child: OutlinedButton(
                onPressed: (_busy || _cd > 0)
                    ? null
                    : () => _run(() => _sendCode(purpose: 'login')),
                style: OutlinedButton.styleFrom(
                    foregroundColor: _accent,
                    side: const BorderSide(color: _accent)),
                child: Text(_cd > 0 ? '$_cd s' : '获取验证码'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _primary('登录', () => _run(_doLogin)),
        TextButton(
          onPressed: () => setState(() => _useCode = false),
          child: const Text('用账号密码登录',
              style: TextStyle(color: Colors.white54)),
        ),
      ] else ...[
        _tf(_u, '用户名', maxLength: 20),
        _tf(_p, '密码', obscure: true, maxLength: 64),
        const SizedBox(height: 4),
        _primary('登录', () => _run(_doLogin)),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () => setState(() => _useCode = true),
              child: const Text('验证码登录',
                  style: TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => setState(() => _mode = _Mode.register),
              child: const Text('没有账号？去注册',
                  style: TextStyle(color: Colors.white54)),
            ),
          ],
        ),
      ],
    ];
  }

  List<Widget> _registerForm() {
    return [
      _tf(_u, '用户名(2-20位，中文/字母/数字/下划线)', maxLength: 20),
      _tf(_p, '密码(至少6位)', obscure: true, maxLength: 64),
      _tf(_p2, '确认密码', obscure: true, maxLength: 64),
      const SizedBox(height: 4),
      _primary('注册并进入', () => _run(_doRegister)),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('注册后可绑定手机号和 B站账号，换设备登录自动同步',
            style: TextStyle(color: Colors.white38, fontSize: 12),
            textAlign: TextAlign.center),
      ),
    ];
  }

  List<Widget> _forgotForm() {
    return [
      _tf(_phone, '已绑定的手机号',
          keyboard: TextInputType.phone, maxLength: 20),
      Row(
        children: [
          Expanded(
              child: _tf(_code, '验证码', keyboard: TextInputType.number,
                  maxLength: 6)),
          const SizedBox(width: 8),
          SizedBox(
            height: 46,
            child: OutlinedButton(
              onPressed: (_busy || _cd > 0)
                  ? null
                  : () => _run(() => _sendCode(purpose: 'reset')),
              style: OutlinedButton.styleFrom(
                  foregroundColor: _accent,
                  side: const BorderSide(color: _accent)),
              child: Text(_cd > 0 ? '$_cd s' : '获取验证码'),
            ),
          ),
        ],
      ),
      _tf(_newPw, '新密码(至少6位)', obscure: true, maxLength: 64),
      const SizedBox(height: 4),
      _primary('重置密码', () => _run(_doReset)),
      TextButton(
        onPressed: () => setState(() => _mode = _Mode.login),
        child:
            const Text('返回登录', style: TextStyle(color: Colors.white54)),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('验证码通过系统通知发到你已登录该账号的设备',
            style: TextStyle(color: Colors.white38, fontSize: 12),
            textAlign: TextAlign.center),
      ),
    ];
  }
}

