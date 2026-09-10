import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'screens/home_shell.dart';
import 'screens/login_page.dart';
import 'services/account_service.dart';
import 'services/platform_service.dart';
import 'text_scale.dart';

class MediaApp extends StatelessWidget {
  const MediaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: accentNotifier,
      builder: (context, accent, _) => ValueListenableBuilder<ThemeMode>(
        valueListenable: themeModeNotifier,
        builder: (context, mode, __) => MaterialApp(
      title: '小李播放器',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      themeMode: mode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: accent),
        scaffoldBackgroundColor: const Color(0xFFF7F7FA),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme:
            ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
      ),
      // 全局文字缩放：跟随 textScaleNotifier。外层包 RepaintBoundary 供
      // 「经同意的屏幕共享」抓帧(仅本 app 画面，不含其它软件/桌面)。
      builder: (context, child) => RepaintBoundary(
        key: PlatformService.screenShareKey,
        child: ValueListenableBuilder<double>(
          valueListenable: textScaleNotifier,
          builder: (context, scale, _) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
      home: const _AuthGate(),
    ),
    ),
    );
  }
}

/// 登录门：首次打开/登录态过期(30天)必须先登录。启动时用本地 token 静默
/// 恢复；失败则显示登录页。登录成功进入 [HomeShell]。
class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _checking = true;
  Map<String, dynamic>? _session;
  bool _justRegistered = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await PlatformService.loadLocal();
    } catch (_) {}
    try {
      await PlatformService.loadRemoteUrl();
    } catch (_) {}
    Map<String, dynamic>? s;
    try {
      s = await AccountService.restore();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _session = s;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_circle_fill,
                  size: 64, color: Color(0xFFF26B21)),
              SizedBox(height: 14),
              Text('小李播放器'),
              SizedBox(height: 14),
              CircularProgressIndicator(),
            ],
          ),
        ),
      );
    }
    if (_session == null) {
      return LoginPage(onLoggedIn: (s, justRegistered) {
        setState(() {
          _session = s;
          _justRegistered = justRegistered;
        });
      });
    }
    return HomeShell(showBindPrompt: _justRegistered);
  }
}
