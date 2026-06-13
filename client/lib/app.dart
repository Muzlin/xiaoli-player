import 'package:flutter/material.dart';
import 'screens/home_shell.dart';
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
      // 全局文字缩放：跟随 textScaleNotifier。
      builder: (context, child) => ValueListenableBuilder<double>(
        valueListenable: textScaleNotifier,
        builder: (context, scale, _) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
      home: const HomeShell(),
    ),
    ),
    );
  }
}
