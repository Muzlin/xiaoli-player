import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DlState { queued, running, done, failed, canceled }

/// 一个下载/缓存任务。
class DownloadTask {
  final String id; // 唯一键（曲目 key）
  final String name;
  final bool cache; // true=缓存到 app 目录(离线可播)；false=另存到用户路径
  final String destPath; // 目标文件路径
  // 解析出真正流地址（B站要异步取，平台/直链直接给）。
  final Future<String?> Function() resolveUrl;
  final Map<String, String> headers;
  DlState state = DlState.queued;
  int received = 0;
  int total = 0;
  String? error;
  bool _cancel = false;
  DownloadTask({
    required this.id,
    required this.name,
    required this.cache,
    required this.destPath,
    required this.resolveUrl,
    this.headers = const {},
  });

  double get progress => total > 0 ? received / total : 0;
  String get sizeText {
    final r = (received / 1048576).toStringAsFixed(1);
    return total > 0
        ? '$r / ${(total / 1048576).toStringAsFixed(1)} MB'
        : '$r MB';
  }
}

/// 后台下载/缓存管理器：任务在后台跑，UI 不阻塞；缓存项可离线播放。
class DownloadManager extends ChangeNotifier {
  static final DownloadManager instance = DownloadManager._();
  DownloadManager._();

  final List<DownloadTask> tasks = []; // 最新在前
  // 已缓存：key -> {name, path}
  final Map<String, Map<String, String>> cached = {};
  int _running = 0;
  static const _maxConcurrent = 2;
  static const _cacheKey = 'cached_videos_v1';

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/cache_videos');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 启动时加载缓存索引（剔除已被删的文件）。
  Future<void> loadCache() async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_cacheKey);
      if (s != null) {
        (jsonDecode(s) as Map).forEach((k, v) {
          final m = (v as Map).map((a, b) => MapEntry('$a', '$b'));
          if (File(m['path'] ?? '').existsSync()) {
            cached[k as String] = m;
          }
        });
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _saveCacheIndex() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_cacheKey, jsonEncode(cached));
  }

  bool isCached(String key) => cached.containsKey(key);
  String? cachedPath(String key) => cached[key]?['path'];

  /// 缓存一个视频到 app 目录（离线可播）。已在下载/已缓存则忽略。
  Future<void> cacheVideo(String key, String name,
      Future<String?> Function() resolveUrl,
      {Map<String, String> headers = const {}, String ext = 'mp4'}) async {
    if (cached.containsKey(key) ||
        tasks.any((t) => t.id == key && t.state != DlState.failed)) {
      return;
    }
    final dir = await _cacheDir();
    final safe = key.replaceAll(RegExp(r'[^\w]'), '_');
    final dest = '${dir.path}/$safe.$ext';
    final task = DownloadTask(
        id: key,
        name: name,
        cache: true,
        destPath: dest,
        resolveUrl: resolveUrl,
        headers: headers);
    tasks.insert(0, task);
    notifyListeners();
    _pump();
  }

  /// 另存视频到用户指定路径（后台进行）。
  Future<void> saveVideo(String key, String name, String destPath,
      Future<String?> Function() resolveUrl,
      {Map<String, String> headers = const {}}) async {
    final task = DownloadTask(
        id: '$key#${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        cache: false,
        destPath: destPath,
        resolveUrl: resolveUrl,
        headers: headers);
    tasks.insert(0, task);
    notifyListeners();
    _pump();
  }

  void cancel(DownloadTask t) {
    t._cancel = true;
    if (t.state == DlState.queued) {
      t.state = DlState.canceled;
      notifyListeners();
    }
  }

  void removeTask(DownloadTask t) {
    tasks.remove(t);
    notifyListeners();
  }

  void clearFinished() {
    tasks.removeWhere((t) =>
        t.state == DlState.done ||
        t.state == DlState.failed ||
        t.state == DlState.canceled);
    notifyListeners();
  }

  Future<void> deleteCached(String key) async {
    final m = cached.remove(key);
    if (m != null) {
      try {
        final f = File(m['path'] ?? '');
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      await _saveCacheIndex();
      notifyListeners();
    }
  }

  int get activeCount => tasks
      .where((t) => t.state == DlState.queued || t.state == DlState.running)
      .length;

  void _pump() {
    if (_running >= _maxConcurrent) return;
    final next = tasks.firstWhere(
        (t) => t.state == DlState.queued && !t._cancel,
        orElse: () => _none);
    if (identical(next, _none)) return;
    _run(next);
    _pump(); // 尝试再启动一个
  }

  static final DownloadTask _none = DownloadTask(
      id: '', name: '', cache: false, destPath: '', resolveUrl: () async => null);

  Future<void> _run(DownloadTask t) async {
    _running++;
    t.state = DlState.running;
    notifyListeners();
    final tmp = '${t.destPath}.part';
    try {
      final url = await t.resolveUrl();
      if (t._cancel) {
        t.state = DlState.canceled;
        return;
      }
      if (url == null || url.isEmpty) {
        t.state = DlState.failed;
        t.error = '取地址失败';
        return;
      }
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(t.headers);
      final resp =
          await http.Client().send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode >= 400) {
        t.state = DlState.failed;
        t.error = 'HTTP ${resp.statusCode}';
        return;
      }
      t.total = resp.contentLength ?? 0;
      final sink = File(tmp).openWrite();
      var lastNotify = 0;
      await for (final chunk in resp.stream) {
        if (t._cancel) break;
        sink.add(chunk);
        t.received += chunk.length;
        // 限频通知，避免刷爆 UI
        final now = t.received ~/ 524288; // 每 0.5MB
        if (now != lastNotify) {
          lastNotify = now;
          notifyListeners();
        }
      }
      await sink.close();
      if (t._cancel) {
        _safeDelete(tmp);
        t.state = DlState.canceled;
        return;
      }
      // 完成：把 .part 移到目标
      _safeDelete(t.destPath);
      File(tmp).renameSync(t.destPath);
      t.state = DlState.done;
      if (t.cache) {
        cached[t.id] = {'name': t.name, 'path': t.destPath};
        await _saveCacheIndex();
      }
    } catch (e) {
      _safeDelete(tmp);
      t.state = DlState.failed;
      t.error = '$e';
    } finally {
      _running--;
      notifyListeners();
      _pump();
    }
  }

  void _safeDelete(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}
