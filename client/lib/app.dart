import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'api/api_client.dart';
import 'api/models.dart';
import 'auth/auth_store.dart';
import 'screens/login_screen.dart';
import 'screens/library_screen.dart';
import 'screens/player_screen.dart';

class MediaApp extends StatefulWidget {
  final String baseUrl;
  const MediaApp({super.key, required this.baseUrl});

  @override
  State<MediaApp> createState() => _MediaAppState();
}

class _MediaAppState extends State<MediaApp> {
  late final ApiClient _api = ApiClient(baseUrl: widget.baseUrl);
  late final AuthStore _auth = AuthStore(storage: SecureTokenStorage());
  UserInfo? _user;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  /// 启动时尝试用已存储的 token 自动登录。
  Future<void> _restoreSession() async {
    await _auth.loadFromStorage();
    final token = _auth.token;
    if (token == null) return;
    _api.setToken(token);
    try {
      final user = await _api.me();
      if (mounted) setState(() => _user = user);
    } catch (_) {
      await _auth.signOut();
    }
  }

  Future<void> _onSignedIn() async {
    final user = await _api.me();
    if (mounted) setState(() => _user = user);
  }

  void _onSessionExpired() {
    _auth.signOut();
    if (mounted) setState(() => _user = null);
  }

  /// 管理员/属主下载：选保存位置后带鉴权头取字节写入。
  Future<void> _download(MediaItem item) async {
    final savePath =
        await FilePicker.platform.saveFile(fileName: item.originalName);
    if (savePath == null) return;
    final bytes = await _api.downloadBytes(item.id);
    await File(savePath).writeAsBytes(bytes);
  }

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '小李播放器',
      theme: ThemeData(useMaterial3: true),
      home: _user == null
          ? LoginScreen(api: _api, auth: _auth, onSignedIn: _onSignedIn)
          : LibraryScreen(
              api: _api,
              user: _user!,
              onPlay: (item) => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlayerScreen.forItem(_api, item),
                ),
              ),
              onDownload: _download,
              onSessionExpired: _onSessionExpired,
            ),
    );
  }
}
