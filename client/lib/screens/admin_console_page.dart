import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// App 内嵌的「后台管理台」窗口：直接加载经济管理台网页(带 pw，免二次输入)。
/// 支持 macOS(WKWebView) / Windows(WebView2) / Android(系统 WebView)。
class AdminConsolePage extends StatefulWidget {
  final String url;
  const AdminConsolePage({super.key, required this.url});

  @override
  State<AdminConsolePage> createState() => _AdminConsolePageState();
}

class _AdminConsolePageState extends State<AdminConsolePage> {
  InAppWebViewController? _c;
  bool _loading = true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('后台管理台'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => _c?.reload(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '在浏览器打开',
            onPressed: () {},
            icon: const Icon(Icons.open_in_new),
            // 预留(需要时可接 url_launcher)
          ),
        ],
        bottom: _loading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                    minHeight: 2, color: cs.primary),
              )
            : null,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          useShouldOverrideUrlLoading: false,
          transparentBackground: false,
        ),
        onWebViewCreated: (c) => _c = c,
        onLoadStart: (c, u) {
          if (mounted) setState(() => _loading = true);
        },
        onLoadStop: (c, u) {
          if (mounted) setState(() => _loading = false);
        },
        onReceivedError: (c, req, err) {
          if (mounted) setState(() => _loading = false);
        },
      ),
    );
  }
}
