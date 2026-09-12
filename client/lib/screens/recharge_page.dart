import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/account_service.dart';
import '../services/native_qr.dart';

/// 充值：1 元 = rate 积分（默认 10）。
/// 真实支付走微信支付 Native：下单后 code_url 可用【本机已登录的微信】直接打开付款
/// （weixin:// 链接），也可展示二维码用手机微信扫。服务端 recharge_mock=true 时为模拟支付。
class RechargePage extends StatefulWidget {
  const RechargePage({super.key});
  @override
  State<RechargePage> createState() => _RechargePageState();
}

class _RechargePageState extends State<RechargePage> {
  bool _enabled = false, _mock = false;
  int _rate = 10, _min = 1;
  int _yuan = 10;
  bool _busy = false;
  String? _err;
  String? _otn, _codeUrl, _payQr;
  String _mode = 'mock';
  bool _paid = false;
  bool _confirming = false;
  int _points = 0;
  Timer? _poll;
  final _custom = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _custom.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final d = await AccountService.versionInfo();
    if (!mounted) return;
    setState(() {
      _enabled = d?['recharge_enabled'] == true;
      _mock = d?['recharge_mock'] == true;
      _rate = (d?['recharge_rate'] as num?)?.toInt() ?? 10;
      _min = (d?['recharge_min'] as num?)?.toInt() ?? 1;
      _mode = '${d?['recharge_mode'] ?? (_mock ? 'mock' : 'wechat')}';
      if (_yuan < _min) _yuan = _min;
    });
  }

  void _toast(String s) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s)));
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _err = null;
      _paid = false;
    });
    final d = await AccountService.rechargeCreate(_yuan);
    if (!mounted) return;
    setState(() => _busy = false);
    if (d['ok'] != true) {
      setState(() => _err = '${d['error'] ?? '下单失败'}');
      return;
    }
    setState(() {
      _otn = '${d['out_trade_no']}';
      _points = (d['points'] as num?)?.toInt() ?? _yuan * _rate;
      _codeUrl = '${d['code_url'] ?? ''}';
      _mode = '${d['mode'] ?? _mode}';
      _payQr = '${d['pay_qr'] ?? ''}';
      _confirming = false;
    });
    if (_mode == 'wechat' && _codeUrl != null && _codeUrl!.isNotEmpty) {
      await _openWeChat();
    }
    _startPoll();
  }

  Future<void> _openWeChat() async {
    final u = _codeUrl;
    if (u == null || u.isEmpty) return;
    // Native 的 code_url 形如 weixin://wxpay/bizpayurl?pr=xxx，
    // 用本机已登录的微信直接打开即可付款。
    final uri = Uri.tryParse(u);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _toast('未能唤起微信，请用手机扫下方二维码付款');
    }
  }

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (t) async {
      final otn = _otn;
      if (otn == null) return;
      final d = await AccountService.rechargeStatus(otn);
      if (!mounted) return;
      if (d != null && d['status'] == 'paid') {
        t.cancel();
        setState(() => _paid = true);
        _toast('充值成功，+$_points 积分');
      }
    });
  }

  Future<void> _markPaid() async {
    final otn = _otn;
    if (otn == null) return;
    final d = await AccountService.rechargeMarkPaid(otn);
    if (!mounted) return;
    if (d['ok'] == true) {
      setState(() => _confirming = true);
      _toast('已提交，等待管理员确认到账');
      _startPoll();
    } else {
      _toast('${d['error'] ?? '失败'}');
    }
  }

  Future<void> _mockPay() async {
    final otn = _otn;
    if (otn == null) return;
    final d = await AccountService.rechargeMockPay(otn);
    if (!mounted) return;
    if (d['ok'] == true) {
      setState(() => _paid = true);
      _toast('模拟支付成功，+$_points 积分');
    } else {
      _toast('${d['error'] ?? '失败'}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('充值')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_enabled)
            Card(
              color: Colors.orange.shade50,
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('充值暂未开放（后台开启后可用）'),
              ),
            ),
          Text('1 元 = $_rate 积分',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: cs.primary)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final y in [1, 5, 10, 30, 50, 100])
                ChoiceChip(
                  label: Text('$y 元'),
                  selected: _yuan == y,
                  onSelected: (_) => setState(() => _yuan = y),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Text('自定义：'),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: _custom,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(isDense: true, hintText: '元'),
                  onChanged: (v) {
                    final n = int.tryParse(v.trim());
                    if (n != null && n >= _min) setState(() => _yuan = n);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Text('= ${_yuan * _rate} 积分',
                  style: TextStyle(color: cs.primary)),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: (_enabled && !_busy) ? _create : null,
              icon: const Icon(Icons.wechat),
              label: Text(_busy ? '下单中…' : '微信充值 $_yuan 元'),
            ),
          ),
          if (_err != null) ...[
            const SizedBox(height: 10),
            Text(_err!, style: const TextStyle(color: Colors.red)),
          ],
          if (_otn != null && !_paid) ...[
            const SizedBox(height: 18),
            const Text('请完成支付：',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_mode == 'mock')
              FilledButton(
                onPressed: _mockPay,
                child: const Text('模拟支付（测试）'),
              ),
            if (_mode == 'manual') ...[
              if (_payQr != null && _payQr!.isNotEmpty)
                Center(
                  child: Image.network(_payQr!, width: 220, height: 220,
                      errorBuilder: (_, __, ___) =>
                          const Text('收款码加载失败')),
                )
              else
                const Text('管理员尚未设置收款码，请稍后再试',
                    style: TextStyle(color: Colors.orange)),
              const SizedBox(height: 8),
              Text('请扫码转账 $_yuan 元（备注：${_otn ?? ''}）',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              if (!_confirming)
                FilledButton(
                    onPressed: _markPaid,
                    child: const Text('我已付款'))
              else
                const Text('已提交，等待管理员确认到账…',
                    style: TextStyle(color: Colors.orange)),
            ],
            if (_mode == 'wechat' && _codeUrl != null && _codeUrl!.isNotEmpty) ...[
              Center(
                child: FutureBuilder(
                  future: NativeQr.generate(_codeUrl!),
                  builder: (c, s) {
                    final b = s.data;
                    if (b == null) return const Text('二维码生成中…');
                    return Image.memory(b, width: 220, height: 220);
                  },
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _openWeChat,
                icon: const Icon(Icons.open_in_new),
                label: const Text('用本机微信打开付款'),
              ),
              const Text('也可用手机微信扫上方二维码付款',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                  textAlign: TextAlign.center),
            ],
          ],
          if (_paid)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Column(children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 48),
                Text('充值成功，+$_points 积分',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回')),
              ]),
            ),
        ],
      ),
    );
  }
}
