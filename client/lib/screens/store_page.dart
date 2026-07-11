import 'package:flutter/material.dart';
import '../services/platform_service.dart';
import '../services/coin_ledger.dart';

/// 兑换商城：用小李兑换币购买挂件/主题/道具。owned 来自 /mylists。
class StorePage extends StatefulWidget {
  const StorePage({super.key});
  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  bool _loading = true;
  bool _buying = false;
  int _balance = 0;
  List<Map<String, dynamic>> _items = [];
  Set<String> _owned = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await PlatformService.storeItems();
    final bal = await PlatformService.getBalance();
    final mine = await PlatformService.myLists();
    if (!mounted) return;
    setState(() {
      _items = items;
      _balance = bal;
      _owned = (mine['owned'] ?? const []).toSet();
      _loading = false;
    });
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _buy(Map<String, dynamic> p) async {
    if (_buying) return;
    final item = '${p['item'] ?? ''}';
    final name = '${p['name'] ?? item}';
    final price = (p['price'] as num?)?.toInt() ?? 0;
    final consumable = p['type'] == 'consumable';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('购买 $name'),
        content: Text('花 $price 小李兑换币兑换「$name」？\n当前余额：$_balance'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认兑换')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _buying = true);
    final d = await PlatformService.storeBuy(item);
    if (!mounted) return;
    setState(() => _buying = false);
    if (d == null) {
      _toast('网络异常，兑换失败');
      return;
    }
    if (d['ok'] == true) {
      final bal = (d['balance'] as num?)?.toInt() ?? _balance;
      await CoinLedger.add(-price, '兑换商城·$name', bal);
      setState(() {
        _balance = bal;
        _owned = ((d['owned'] as List?) ?? _owned.toList())
            .map((e) => e.toString())
            .toSet();
      });
      _toast(consumable ? '兑换成功！道具已到账' : '兑换成功！「$name」已拥有');
    } else {
      final bal = (d['balance'] as num?)?.toInt();
      if (bal != null) setState(() => _balance = bal);
      _toast('${d['error'] ?? '兑换失败'}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('兑换商城'),
        actions: [
          IconButton(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(14)),
                  child: Row(children: [
                    Icon(Icons.account_balance_wallet, color: cs.primary),
                    const SizedBox(width: 10),
                    const Text('我的兑换币'),
                    const Spacer(),
                    Text('$_balance',
                        style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: cs.primary)),
                  ]),
                ),
                Expanded(
                  child: _items.isEmpty
                      ? const Center(
                          child: Text('商城暂无商品',
                              style: TextStyle(color: Colors.black38)))
                      : GridView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 220,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.92,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (_, i) {
                            final p = _items[i];
                            final item = '${p['item'] ?? ''}';
                            final name = '${p['name'] ?? item}';
                            final price = (p['price'] as num?)?.toInt() ?? 0;
                            final consumable = p['type'] == 'consumable';
                            final owned = _owned.contains(item) && !consumable;
                            return Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      name.split(' ').first,
                                      style: const TextStyle(fontSize: 34),
                                      textAlign: TextAlign.center,
                                    ),
                                    Text(
                                      name.contains(' ')
                                          ? name.substring(name.indexOf(' ') + 1)
                                          : name,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                    owned
                                        ? OutlinedButton(
                                            onPressed: null,
                                            child: const Text('已拥有'))
                                        : FilledButton(
                                            onPressed:
                                                _buying ? null : () => _buy(p),
                                            child: Text('🪙 $price'),
                                          ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
