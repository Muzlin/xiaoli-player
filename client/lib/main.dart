import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // 指向后端。Android 模拟器访问宿主用 10.0.2.2。
  const baseUrl =
      String.fromEnvironment('BASE_URL', defaultValue: 'http://localhost:8000');
  runApp(const MediaApp(baseUrl: baseUrl));
}
