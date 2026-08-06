import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show LicenseEntry, LicenseRegistry;
import '../services/license_translate_service.dart';

/// 按包名归组的许可证数据，逻辑对齐 Flutter 内置 LicensePage 的分组方式：
/// 一个包可能对应多条 LicenseEntry（比如同时带了 LICENSE 和 NOTICE）。
class _LicenseData {
  final List<LicenseEntry> licenses = <LicenseEntry>[];
  final Map<String, List<int>> packageLicenseBindings = <String, List<int>>{};
  final List<String> packages = <String>[];
  String? firstPackage;

  void addLicense(LicenseEntry entry) {
    for (final package in entry.packages) {
      if (!packageLicenseBindings.containsKey(package)) {
        packageLicenseBindings[package] = <int>[];
        firstPackage ??= package;
        packages.add(package);
      }
      packageLicenseBindings[package]!.add(licenses.length);
    }
    licenses.add(entry);
  }

  void sortPackages() {
    packages.sort((a, b) {
      if (a == firstPackage) return -1;
      if (b == firstPackage) return 1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
  }
}

/// 自定义的「查看许可」列表页：数据源和 Flutter 内置 LicensePage 一样(用
/// LicenseRegistry)，但每个包的详情页里多一个「翻译成中文」按钮。
class LicenseListPageZh extends StatefulWidget {
  final String? applicationName;
  final String? applicationVersion;

  const LicenseListPageZh({
    super.key,
    this.applicationName,
    this.applicationVersion,
  });

  @override
  State<LicenseListPageZh> createState() => _LicenseListPageZhState();
}

class _LicenseListPageZhState extends State<LicenseListPageZh> {
  late final Future<_LicenseData> _future = LicenseRegistry.licenses
      .fold<_LicenseData>(
        _LicenseData(),
        (prev, entry) => prev..addLicense(entry),
      )
      .then((data) => data..sortPackages());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.applicationName != null
            ? '${widget.applicationName} 使用的开源许可'
            : '许可'),
      ),
      body: FutureBuilder<_LicenseData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('加载许可证信息失败：${snapshot.error}'));
          }
          final data = snapshot.data;
          if (data == null || data.packages.isEmpty) {
            return const Center(child: Text('没有找到许可证信息'));
          }
          return ListView.separated(
            itemCount: data.packages.length + 1,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              if (i == 0) return _header(context);
              final name = data.packages[i - 1];
              final entries = data.packageLicenseBindings[name]!
                  .map((idx) => data.licenses[idx])
                  .toList();
              return ListTile(
                title: Text(name),
                subtitle: Text('${entries.length} 份许可'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      LicenseDetailPageZh(packageName: name, entries: entries),
                )),
              );
            },
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context) {
    if (widget.applicationName == null && widget.applicationVersion == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.applicationName != null)
            Text(widget.applicationName!,
                style: Theme.of(context).textTheme.titleLarge),
          if (widget.applicationVersion != null)
            Text(widget.applicationVersion!,
                style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class LicenseDetailPageZh extends StatefulWidget {
  final String packageName;
  final List<LicenseEntry> entries;

  const LicenseDetailPageZh({
    super.key,
    required this.packageName,
    required this.entries,
  });

  @override
  State<LicenseDetailPageZh> createState() => _LicenseDetailPageZhState();
}

enum _TransState { idle, loading, done, error }

class _LicenseDetailPageZhState extends State<LicenseDetailPageZh> {
  // 每条 LicenseEntry 各自的正文（不提前拼成一坨），翻译时也是逐条处理，
  // 这样内置兜底翻译才能给每一条各自匹配正确的模板，而不是整包只认第一条。
  List<String>? _entryTexts;
  String? _loadError;
  String? _translatedText;
  bool _fromBundled = false;
  _TransState _state = _TransState.idle;
  bool _showTranslated = false;

  @override
  void initState() {
    super.initState();
    _loadOriginal();
  }

  Future<void> _loadOriginal() async {
    try {
      final texts = <String>[];
      for (final entry in widget.entries) {
        final paragraphs = await Future(() => entry.paragraphs.toList());
        texts.add(paragraphs.map((p) => p.text).join('\n\n'));
      }
      if (mounted) setState(() => _entryTexts = texts);
    } catch (e) {
      if (mounted) setState(() => _loadError = '加载许可证正文失败：$e');
    }
  }

  Future<void> _translate() async {
    final entryTexts = _entryTexts;
    if (entryTexts == null || _state == _TransState.loading) return;
    setState(() => _state = _TransState.loading);
    try {
      final result = await LicenseTranslateService.translate(entryTexts);
      if (!mounted) return;
      setState(() {
        _translatedText = result.text;
        _fromBundled = result.fromBundled;
        _showTranslated = true;
        _state = _TransState.done;
      });
      if (result.note != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result.note!)));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _TransState.error);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('翻译失败，请稍后重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final entryTexts = _entryTexts;
    final original = entryTexts?.join('\n\n');
    final hasContent = original != null && original.trim().isNotEmpty;
    final showingTranslated = _showTranslated && _translatedText != null;
    return Scaffold(
      appBar: AppBar(title: Text(widget.packageName)),
      body: _loadError != null
          ? Center(child: Text(_loadError!))
          : original == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (hasContent)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Row(
                          children: [
                            if (_translatedText == null)
                              FilledButton.icon(
                                onPressed: _state == _TransState.loading
                                    ? null
                                    : _translate,
                                icon: _state == _TransState.loading
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.translate, size: 18),
                                label: const Text('翻译成中文'),
                              )
                            else
                              TextButton.icon(
                                onPressed: () => setState(() =>
                                    _showTranslated = !_showTranslated),
                                icon: const Icon(Icons.swap_horiz, size: 18),
                                label:
                                    Text(showingTranslated ? '查看原文' : '查看中文翻译'),
                              ),
                            if (showingTranslated) ...[
                              const SizedBox(width: 8),
                              Text(
                                _fromBundled ? '内置翻译·仅供参考' : '机器翻译·仅供参考',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant),
                              ),
                            ],
                          ],
                        ),
                      ),
                    const Divider(height: 24),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        child: SelectableText(
                          hasContent
                              ? (showingTranslated
                                  ? _translatedText!
                                  : original)
                              : '（这份许可证没有正文内容）',
                          style: const TextStyle(fontSize: 13, height: 1.6),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
