import 'package:flutter/material.dart';
import '../services/account_service.dart';
import '../restart_widget.dart';

/// 账号与安全：显示注册账号、绑定手机号、绑定/管理 B站账号、修改密码、退出登录。
/// 个人中心可进入；注册成功后也会自动进入此页引导绑定手机号和 B站。
class AccountPage extends StatefulWidget {
  final bool biliLoggedIn;
  final String biliName;
  final Future<void> Function()? onBindBili;
  const AccountPage({
    super.key,
    this.biliLoggedIn = false,
    this.biliName = '',
    this.onBindBili,
  });

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  String _user = '';
  String _phone = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final u = await AccountService.currentUser();
    final p = await AccountService.currentPhone();
    if (mounted) {
      setState(() {
        _user = u;
        _phone = p;
        _loading = false;
      });
    }
  }

  void _toast(String s) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s)));
    }
  }

  Future<void> _bindPhone() async {
    final c = TextEditingController(text: _phone);
    final phone = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_phone.isEmpty ? '绑定手机号' : '更换手机号'),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.phone,
          maxLength: 20,
          decoration: const InputDecoration(
            hintText: '请输入手机号',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (phone == null || phone.isEmpty) return;
    final d = await AccountService.bindPhone(phone);
    if (!mounted) return;
    if (d['ok'] == true) {
      setState(() => _phone = phone);
      _toast('手机号已绑定');
    } else {
      _toast('${d['error'] ?? '绑定失败'}');
    }
  }

  Future<void> _changePassword() async {
    final oldC = TextEditingController();
    final newC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: oldC,
                obscureText: true,
                decoration: const InputDecoration(labelText: '原密码')),
            TextField(
                controller: newC,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新密码(至少6位)')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    if (newC.text.length < 6) {
      _toast('新密码至少6位');
      return;
    }
    final d = await AccountService.changePassword(oldC.text, newC.text);
    if (!mounted) return;
    _toast(d['ok'] == true ? '密码已修改' : '${d['error'] ?? '修改失败'}');
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需重新输入账号密码才能使用。\n服务器上的账号数据不会被删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出')),
        ],
      ),
    );
    if (ok != true) return;
    await AccountService.logout();
    if (mounted) RestartWidget.restart(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('账号与安全')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: cs.primary,
                    child: Text(
                        _user.isEmpty ? '?' : _user.substring(0, 1),
                        style: const TextStyle(color: Colors.white)),
                  ),
                  title: Text(_user.isEmpty ? '未登录' : _user),
                  subtitle: const Text('当前账号（同一账号在 Win / Mac / 安卓 数据互通）',
                      style: TextStyle(fontSize: 12)),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.phone_iphone),
                  title: Text(_phone.isEmpty ? '绑定手机号' : '手机号：$_phone'),
                  subtitle: Text(
                      _phone.isEmpty
                          ? '绑定后可用验证码登录 / 找回密码'
                          : '验证码会以系统通知发到你已登录的设备',
                      style: const TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _bindPhone,
                ),
                ListTile(
                  leading: Icon(
                      widget.biliLoggedIn ? Icons.verified_user : Icons.login,
                      color: widget.biliLoggedIn ? Colors.green : null),
                  title: Text(widget.biliLoggedIn
                      ? 'B站账号：${widget.biliName.isEmpty ? "已登录" : widget.biliName}'
                      : '绑定 B站账号'),
                  subtitle: const Text('B站登录态会随账号同步到其它设备',
                      style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: widget.onBindBili == null
                      ? null
                      : () => widget.onBindBili!(),
                ),
                ListTile(
                  leading: const Icon(Icons.password),
                  title: const Text('修改密码'),
                  subtitle: const Text('修改后其它设备需用新密码重新登录',
                      style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _changePassword,
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.red),
                  title: const Text('退出登录',
                      style: TextStyle(color: Colors.red)),
                  onTap: _logout,
                ),
              ],
            ),
    );
  }
}
