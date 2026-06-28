import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/platform_service.dart';
import '../services/native_qr.dart';

/// 收付款：我的收付款二维码 + 扫一扫(向对方转账) + 选联系人转账。
class PayPage extends StatefulWidget {
  const PayPage({super.key});
  @override
  State<PayPage> createState() => _PayPageState();
}

class _PayPageState extends State<PayPage> {
  String _uid = '';
  String _nick = '';
  Uint8List? _qr;
  int _balance = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = await PlatformService.walletUid();
    final p = await SharedPreferences.getInstance();
    final nick = (p.getString('profile_name') ?? '').trim();
    final bal = await PlatformService.getBalance();
    final qr = await NativeQr.generate(
        'qubo:pay:$uid:${Uri.encodeComponent(nick)}');
    if (!mounted) return;
    setState(() {
      _uid = uid;
      _nick = nick;
      _balance = bal;
      _qr = qr;
      _loading = false;
    });
  }

  Future<void> _scan() async {
    final r = await NativeQr.scan();
    if (!mounted || r == null) return;
    if (r.startsWith('qubo:pay:')) {
      final parts = r.substring('qubo:pay:'.length).split(':');
      final uid = parts.isNotEmpty ? parts[0] : '';
      final nick = parts.length > 1 ? Uri.decodeComponent(parts[1]) : uid;
      if (uid == _uid) {
        _snack('这是你自己的收付款码');
        return;
      }
      if (uid.isNotEmpty) {
        _transferTo(uid, nick.isEmpty ? uid : nick);
        return;
      }
    }
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('扫描结果'),
        content: SelectableText(r),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('好')),
        ],
      ),
    );
  }

  Future<void> _pickAndTransfer() async {
    final users = await PlatformService.users();
    if (!mounted) return;
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
              padding: EdgeInsets.all(14),
              child: Text('选择转账对象',
                  style: TextStyle(fontWeight: FontWeight.w600))),
          if (users.isEmpty)
            const Padding(
                padding: EdgeInsets.all(20),
                child: Text('通讯录还没人，先去消息里加联系人',
                    style: TextStyle(color: Colors.black45))),
          for (final u in users)
            ListTile(
              leading: const CircleAvatar(
                  radius: 16,
                  backgroundColor: Color(0xFF07C160),
                  child: Icon(Icons.person, color: Colors.white, size: 18)),
              title: Text('${u['nick']}'),
              onTap: () => Navigator.pop(c, u),
            ),
        ]),
      ),
    );
    if (picked == null) return;
    _transferTo('${picked['uid']}', '${picked['nick']}');
  }

  Future<void> _transferTo(String uid, String nick) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('转账给 $nick'),
        content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '金额（兑换币）')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('转账')),
        ],
      ),
    );
    final amt = int.tryParse(ctrl.text.trim()) ?? 0;
    ctrl.dispose();
    if (ok != true || amt <= 0) return;
    final d = await PlatformService.chatPacket(
        scope: 'dm', target: uid, ptype: 'transfer', amount: amt);
    if (!mounted) return;
    if (d?['ok'] == true) {
      _snack('已转账 $amt 兑换币给 $nick，等对方收款');
      _load();
    } else {
      _snack('${d?['error'] ?? '转账失败'}');
    }
  }

  void _snack(String s) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F2),
      appBar: AppBar(title: const Text('收付款')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(children: [
                    Text(_nick.isEmpty ? '我的收付款码' : '$_nick 的收付款码',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    const Text('让对方「扫一扫」此码即可向你转账',
                        style: TextStyle(fontSize: 12, color: Colors.black45)),
                    const SizedBox(height: 16),
                    if (_qr != null)
                      Image.memory(_qr!, width: 220, height: 220)
                    else
                      Container(
                        width: 220,
                        height: 220,
                        alignment: Alignment.center,
                        color: const Color(0xFFF0F0F0),
                        child: const Text('二维码暂仅 Mac 端支持\n安卓端用下方「转账」选联系人',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.black45)),
                      ),
                    const SizedBox(height: 12),
                    Text('余额：$_balance 兑换币',
                        style: const TextStyle(color: Color(0xFF07C160))),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF07C160),
                        minimumSize: const Size.fromHeight(48)),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('扫一扫'),
                    onPressed: NativeQr.supported ? _scan : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFE3A93B),
                        minimumSize: const Size.fromHeight(48)),
                    icon: const Icon(Icons.paid),
                    label: const Text('转账'),
                    onPressed: _pickAndTransfer,
                  ),
                ),
              ]),
              if (!NativeQr.supported)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('扫一扫 / 收付款码目前仅 Mac 端支持；安卓端用「转账」选联系人。',
                      style: TextStyle(fontSize: 12, color: Colors.black45)),
                ),
            ]),
    );
  }
}
