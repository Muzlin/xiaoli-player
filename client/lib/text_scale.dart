import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 全局界面文字缩放系数（0.8~1.5）。设置页调整，MaterialApp 应用。
final ValueNotifier<double> textScaleNotifier = ValueNotifier<double>(1.0);

/// 全局主题强调色（默认橙）。
final ValueNotifier<Color> accentNotifier =
    ValueNotifier<Color>(const Color(0xFFF26B21));
