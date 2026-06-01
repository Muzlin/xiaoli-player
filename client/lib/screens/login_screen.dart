import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../auth/auth_store.dart';

class LoginScreen extends StatefulWidget {
  final ApiClient api;
  final AuthStore auth;
  final VoidCallback onSignedIn;

  const LoginScreen({
    super.key,
    required this.api,
    required this.auth,
    required this.onSignedIn,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit(Future<String> Function(String, String) action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await action(_email.text, _password.text);
      widget.api.setToken(token);
      await widget.auth.signIn(token);
      widget.onSignedIn();
    } catch (_) {
      setState(() => _error = '登录失败，请检查账号或密码');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('小李播放器')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              key: const Key('email'),
              controller: _email,
              decoration: const InputDecoration(labelText: '邮箱'),
            ),
            TextField(
              key: const Key('password'),
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  key: const Key('login'),
                  onPressed: _busy ? null : () => _submit(widget.api.login),
                  child: const Text('登录'),
                ),
                OutlinedButton(
                  key: const Key('register'),
                  onPressed: _busy ? null : () => _submit(widget.api.register),
                  child: const Text('注册'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
