import 'package:flutter/material.dart';
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

  Future<void> _onSignedIn() async {
    final user = await _api.me();
    setState(() => _user = user);
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
            ),
    );
  }
}
