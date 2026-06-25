import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 小李兑换币流水账本（纯本地，最近 200 条）。
/// 在签到/任务/投币/打赏/改名等收支成功后记一笔，个人中心可查。
class CoinLedger {
  static const _key = 'coin_ledger_v1';

  /// delta 正=收入、负=支出；reason 如 '每日签到'/'投币'/'打赏'/'改名'；balance 记当时余额。
  static Future<void> add(int delta, String reason, int balance) async {
    if (delta == 0) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    final list = raw == null ? <dynamic>[] : (jsonDecode(raw) as List);
    list.insert(0, {
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'delta': delta,
      'reason': reason,
      'bal': balance,
    });
    if (list.length > 200) list.removeRange(200, list.length);
    await p.setString(_key, jsonEncode(list));
  }

  static Future<List<Map<String, dynamic>>> entries() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }
}
