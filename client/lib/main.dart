import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'app.dart';
import 'restart_widget.dart';

/// 是否开机后台启动（LaunchAgent 带 --bg）：后台运行但不自动放音乐。
bool get bgLaunch => !kIsWeb && Platform.executableArguments.contains('--bg');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Web 上 media_kit 原生播放不可用，跳过初始化（桌面/移动端正常）。
  if (!kIsWeb) {
    MediaKit.ensureInitialized();
  }
  runApp(const RestartWidget(child: MediaApp()));
}
