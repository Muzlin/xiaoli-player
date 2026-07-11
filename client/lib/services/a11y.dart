import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 无障碍设置(#14)：减弱动效 / 触感反馈 / 高对比。
/// 静态标志(全局读)+ ValueNotifier(高对比需触发重建)。启动时 load()。
class A11y {
  static bool reduceMotion = false; // 减弱动效：动画时长归零/换淡入
  static bool haptics = false; // 触感反馈：seek/切歌/点赞轻震
  static final ValueNotifier<bool> highContrast = ValueNotifier(false); // 高对比文字

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    reduceMotion = p.getBool('a11y_reduce_motion') ?? false;
    haptics = p.getBool('a11y_haptics') ?? false;
    highContrast.value = p.getBool('a11y_high_contrast') ?? false;
  }

  static Future<void> setReduceMotion(bool v) async {
    reduceMotion = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('a11y_reduce_motion', v);
  }

  static Future<void> setHaptics(bool v) async {
    haptics = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('a11y_haptics', v);
  }

  static Future<void> setHighContrast(bool v) async {
    highContrast.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('a11y_high_contrast', v);
  }

  /// 触感反馈(开关受控)。在 seek/切歌/点赞等处调用。
  static void tap() {
    if (haptics) HapticFeedback.selectionClick();
  }

  /// 动画时长：减弱动效时归零。
  static Duration motion(Duration d) => reduceMotion ? Duration.zero : d;
}
