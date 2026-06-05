import 'package:flutter/material.dart';
import 'screens/home_shell.dart';

class MediaApp extends StatelessWidget {
  const MediaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '小李播放器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFF26B21)),
        scaffoldBackgroundColor: const Color(0xFFF7F7FA),
      ),
      home: const HomeShell(),
    );
  }
}
