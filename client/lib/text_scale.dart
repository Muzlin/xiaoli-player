import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 全局界面文字缩放系数（0.8~1.5）。设置页调整，MaterialApp 应用。
final ValueNotifier<double> textScaleNotifier = ValueNotifier<double>(1.0);

/// 全局主题强调色（默认橙）。
final ValueNotifier<Color> accentNotifier =
    ValueNotifier<Color>(const Color(0xFFF26B21));

/// 主题模式：跟随系统/浅色/深色。
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

/// App 内显示名（后台可改；OS 级名字仍是打包时的）。默认小李播放器。
final ValueNotifier<String> appNameNotifier =
    ValueNotifier<String>('小李播放器');

/// 官方下载网址（后台「下载源」开关决定 GitHub releases 或平台下载页）。空=用兜底。
final ValueNotifier<String> officialDownloadNotifier =
    ValueNotifier<String>('');
