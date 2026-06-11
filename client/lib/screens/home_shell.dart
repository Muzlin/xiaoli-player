import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../player/playback_source.dart';
import '../services/bilibili_service.dart';
import '../services/platform_service.dart';
import '../services/update_service.dart';
import '../widgets/player_bar.dart';
import 'player_screen.dart';

/// 一首曲目：本地文件、内置热门、或 B站联网搜索结果。
class Track {
  final String name;
  final String? localPath;
  final String? url;
  final String? bvid; // B站视频，需异步取音频流
  final String tag; // '' | '热门' | 'B站'

  Track.local(this.localPath)
      : name = localPath!.split(Platform.pathSeparator).last,
        url = null,
        bvid = null,
        tag = '';

  Track.online(this.name, this.url, {this.tag = ''})
      : localPath = null,
        bvid = null;

  // B站来源：不显示来源标签（作者已并入 name 保留）。
  Track.bili(this.name, this.bvid, {this.tag = ''})
      : localPath = null,
        url = null;

  bool get isLocal => localPath != null;

  String get ext {
    final src = localPath ?? '';
    return src.contains('.') ? src.split('.').last.toUpperCase() : '';
  }

  /// 仅本地/直链可用；B站曲目在播放前异步解析。
  PlaybackSource toSource() => isLocal
      ? PlaybackSource.local(localPath!)
      : PlaybackSource.stream(url!, const {}, title: name);

  /// 收藏去重/比较用的唯一键。
  String get key => localPath ?? bvid ?? url ?? name;

  /// 至少有一个可播放来源，才是有效曲目（防止损坏的收藏数据导致播放崩溃）。
  bool get isValid => localPath != null || bvid != null || url != null;

  Map<String, dynamic> toJson() => {
        'name': name,
        'localPath': localPath,
        'url': url,
        'bvid': bvid,
        'tag': tag,
      };

  static Track fromJson(Map<String, dynamic> j) {
    if (j['localPath'] != null) return Track.local(j['localPath'] as String);
    if (j['bvid'] != null) {
      return Track.bili(j['name'] as String, j['bvid'] as String,
          tag: (j['tag'] as String?) ?? '');
    }
    return Track.online(j['name'] as String, j['url'] as String?,
        tag: (j['tag'] as String?) ?? '');
  }
}

/// 桌面音乐播放器风格主界面：侧栏 + 顶部搜索（B站） + 列表 + 底部播放条。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static final List<Track> _hotTracks = [
    Track.online('钢琴轻音乐 · Demo',
        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
        tag: '热门'),
    Track.online('电子节拍 · Demo',
        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3',
        tag: '热门'),
    Track.online('吉他旋律 · Demo',
        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3',
        tag: '热门'),
    Track.online('放松音乐 · Demo',
        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-8.mp3',
        tag: '热门'),
  ];

  final List<Track> _localTracks = [];
  final List<Track> _onlineTracks = [];
  final BilibiliService _bili = BilibiliService();
  final PlatformService _platform = PlatformService();
  final List<Track> _platformTracks = []; // 平台上传的视频(别人/自己)
  final UpdateService _update = UpdateService();
  Track? _current;
  String _query = '';
  int _navIndex = 0;
  Timer? _searchDebounce;
  bool _searchingOnline = false;
  bool _biliLoggedIn = false;

  final List<Track> _favorites = [];
  final List<Track> _myVideos = []; // 我的视频（本地收录 / 可发布到B站）
  final List<String> _searchHistory = [];
  final TextEditingController _searchCtrl = TextEditingController();
  bool _autoNext = true; // 播完自动连播（推荐/下一首）
  Map<String, dynamic>? _account; // B站 登录账号信息（昵称/头像）

  // 外观：自定义背景（图片或纯色）+ 透明度。背景图会复制进 app 容器，重启不丢。
  String? _bgImagePath;
  int? _bgColorValue;
  double _bgOpacity = 0.6;

  static const _prefsKey = 'local_tracks_v1';
  static const _biliCookieKey = 'bili_cookie';
  static const _favKey = 'favorites_v1';
  static const _myVideosKey = 'my_videos_v1';
  static const _historyKey = 'search_history_v1';
  static const _bgImageKey = 'bg_image_v1';
  static const _bgColorKey = 'bg_color_v1';
  static const _bgOpacityKey = 'bg_opacity_v1';
  static const _sidebarColor = Color(0xFF2B2B33);
  static const _topbarColor = Color(0xFF35353F);
  static const _baseBg = Color(0xFFF7F7FA);
  static const _bgPresetColors = [
    Color(0xFF1E1E26),
    Color(0xFF263238),
    Color(0xFF0D47A1),
    Color(0xFF1B5E20),
    Color(0xFF4A148C),
    Color(0xFFF26B21),
  ];

  bool get _hasCustomBg => _bgImagePath != null || _bgColorValue != null;

  // 底部播放条副标题：有标签显标签，本地显扩展名，B站等无则不显（避免空 Text 占位）。
  String? get _currentSubtitle {
    final t = _current;
    if (t == null) return null;
    if (t.tag.isNotEmpty) return t.tag;
    return t.ext.isEmpty ? null : t.ext;
  }

  List<Track> get _playQueue =>
      [..._hotTracks, ..._localTracks, ..._onlineTracks];

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _loadBiliCookie();
    _loadAppearance();
    _loadFavorites();
    _loadMyVideos();
    _loadHistory();
    _loadPlatform();
    _loadAutoNext();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showDisclaimer();
      _silentCheckUpdate();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final paths = prefs.getStringList(_prefsKey) ?? [];
    if (!mounted) return;
    setState(() {
      for (final p in paths) {
        if (File(p).existsSync() &&
            !_localTracks.any((t) => t.localPath == p)) {
          _localTracks.add(Track.local(p));
        }
      }
    });
  }

  Future<void> _saveLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _prefsKey, _localTracks.map((t) => t.localPath!).toList());
  }

  // ---- 收藏 ----
  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_favKey);
    if (raw == null || !mounted) return;
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      setState(() {
        _favorites
          ..clear()
          ..addAll(list.map(Track.fromJson).where((t) => t.isValid));
      });
    } catch (_) {}
  }

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _favKey, jsonEncode(_favorites.map((t) => t.toJson()).toList()));
  }

  bool _isFav(Track t) => _favorites.any((f) => f.key == t.key);

  Future<void> _toggleFav(Track t) async {
    setState(() {
      final i = _favorites.indexWhere((f) => f.key == t.key);
      if (i >= 0) {
        _favorites.removeAt(i);
      } else {
        _favorites.add(t);
      }
    });
    await _saveFavorites();
  }

  /// 下载视频到「下载」目录（B站异步解析流地址；平台/直链直接下）。
  Future<void> _download(Track t) async {
    if (t.isLocal || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('准备下载…')));
    String? url;
    Map<String, String> headers = const {};
    if (t.bvid != null) {
      url = await _bili.getMediaUrl(t.bvid!);
      headers = _bili.playHeaders;
    } else {
      url = t.url;
    }
    if (url == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('获取下载地址失败')));
      }
      return;
    }
    try {
      final dir = (await getDownloadsDirectory()) ??
          await getApplicationDocumentsDirectory();
      final safe = t.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final dest = '${dir.path}/$safe.mp4';
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(headers);
      final resp = await http.Client().send(req);
      if (resp.statusCode >= 400) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('下载失败 ${resp.statusCode}')));
        }
        return;
      }
      await resp.stream.pipe(File(dest).openWrite());
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已下载到 $dest')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('下载出错：$e')));
      }
    }
  }

  // ---- 我的视频（本地收录 / 发布到B站） ----
  Future<void> _loadMyVideos() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_myVideosKey);
    if (raw == null || !mounted) return;
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      setState(() {
        _myVideos
          ..clear()
          ..addAll(list.map(Track.fromJson).where((t) => t.isValid));
      });
    } catch (_) {}
  }

  Future<void> _saveMyVideos() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _myVideosKey, jsonEncode(_myVideos.map((t) => t.toJson()).toList()));
  }

  Future<void> _addMyVideo() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.video);
    final p = r?.files.single.path;
    if (p == null) return;
    setState(() {
      if (!_myVideos.any((t) => t.localPath == p)) {
        _myVideos.add(Track.local(p));
      }
    });
    await _saveMyVideos();
  }

  Widget _myVideosView(ColorScheme cs) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: _addMyVideo,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加视频'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _showPublish,
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: const Text('发布到B站'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _uploadToPlatform,
                icon: const Icon(Icons.upload_outlined, size: 18),
                label: const Text('上传到平台'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _myVideos.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有视频\n点「添加视频」收录本地视频；点「发布到B站」投稿',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54)),
                  ),
                )
              : ListView.separated(
                  itemCount: _myVideos.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _trackRow(cs, _myVideos[i], i),
                ),
        ),
      ],
    );
  }

  Future<void> _showPublish() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.video);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    final name = picked!.files.single.name;
    final titleCtrl = TextEditingController(
        text: name.contains('.')
            ? name.substring(0, name.lastIndexOf('.'))
            : name);
    final act = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('发布视频到 B站'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('文件：$name',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                  labelText: '标题', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            const Text(
                '⚠️ 原生投稿是实验性的：B站风控严、可能失败；上传即真实公开发布到你的账号。失败请改用「网页发布」。',
                style: TextStyle(fontSize: 12, color: Colors.redAccent)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'web'),
            child: const Text('网页发布'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'upload'),
            child: const Text('确认上传'),
          ),
        ],
      ),
    );
    if (act == 'web') {
      final uri =
          Uri.parse('https://member.bilibili.com/platform/upload/video/frame');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }
    if (act != 'upload') return;
    final title = titleCtrl.text.trim().isEmpty ? name : titleCtrl.text.trim();
    final statusN = ValueNotifier<String>('准备上传…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: ValueListenableBuilder<String>(
          valueListenable: statusN,
          builder: (_, sx, __) => Row(
            children: [
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 16),
              Expanded(child: Text(sx)),
            ],
          ),
        ),
      ),
    );
    final msg =
        await _bili.uploadVideo(path, title, onStatus: (sx) => statusN.value = sx);
    if (!mounted) return;
    Navigator.of(context).pop();
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('发布结果'),
        content: Text(msg),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('好'))
        ],
      ),
    );
  }

  // ---- 搜索记录 ----
  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_historyKey) ?? [];
    if (!mounted) return;
    setState(() {
      _searchHistory
        ..clear()
        ..addAll(list);
    });
  }

  Future<void> _addHistory(String kw) async {
    kw = kw.trim();
    if (kw.isEmpty) return;
    setState(() {
      _searchHistory.remove(kw);
      _searchHistory.insert(0, kw); // 不限数量
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_historyKey, _searchHistory);
  }

  Future<void> _clearHistory() async {
    setState(() => _searchHistory.clear());
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  // ---- 自动连播 ----
  Future<void> _loadAutoNext() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool('auto_next_v1');
    if (v != null && mounted) setState(() => _autoNext = v);
  }

  Future<void> _saveAutoNext(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_next_v1', v);
  }

  /// 一首播完（未单曲循环）后：B站放相关推荐，其它放队列下一首。
  Future<void> _onTrackCompleted() async {
    if (!_autoNext) return;
    final cur = _current;
    if (cur == null) return;
    if (cur.bvid != null) {
      final rel = await _bili.getRelated(cur.bvid!);
      if (rel.isNotEmpty && mounted) {
        final b = rel.first;
        _play(
          Track.bili(
              b.author.isEmpty ? b.title : '${b.title} - ${b.author}', b.bvid),
          replace: true,
        );
        return;
      }
    }
    final q = _playQueue;
    final i = q.indexWhere((t) => t.key == cur.key);
    if (i >= 0 && i < q.length - 1 && mounted) {
      _play(q[i + 1], replace: true);
    }
  }

  // ---- B站 账号 / 关注 ----
  Future<void> _loadAccount() async {
    final a = _biliLoggedIn ? await _bili.getAccountInfo() : null;
    if (mounted) setState(() => _account = a);
  }

  Future<void> _followUp(String bvid) async {
    final owner = await _bili.getOwner(bvid);
    final midRaw = owner?['mid'];
    final mid = midRaw is num ? midRaw.toInt() : int.tryParse('$midRaw');
    if (owner == null || mid == null || mid <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('获取 UP主 信息失败')));
      }
      return;
    }
    final msg = await _bili.followUp(mid);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${owner['name']}：$msg')));
    }
  }

  void _showFollowings() {
    final mid = _account?['mid'];
    final midInt = mid is num ? mid.toInt() : int.tryParse('$mid');
    if (midInt == null || midInt <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录 B站')));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _FollowingsPage(
              bili: _bili,
              mid: midInt,
              onPlay: (bvid, title) => _play(Track.bili(title, bvid)),
            )));
  }

  Future<void> _loadAppearance() async {
    final prefs = await SharedPreferences.getInstance();
    final img = prefs.getString(_bgImageKey);
    final col = prefs.getInt(_bgColorKey);
    final op = prefs.getDouble(_bgOpacityKey);
    if (!mounted) return;
    setState(() {
      _bgImagePath =
          (img != null && img.isNotEmpty && File(img).existsSync()) ? img : null;
      _bgColorValue = _bgImagePath != null ? null : col; // 图/色互斥：图优先
      if (op != null) _bgOpacity = op.clamp(0.0, 1.0);
    });
  }

  Future<void> _saveAppearance() async {
    final prefs = await SharedPreferences.getInstance();
    if (_bgImagePath != null) {
      await prefs.setString(_bgImageKey, _bgImagePath!);
    } else {
      await prefs.remove(_bgImageKey);
    }
    if (_bgColorValue != null) {
      await prefs.setInt(_bgColorKey, _bgColorValue!);
    } else {
      await prefs.remove(_bgColorKey);
    }
    await prefs.setDouble(_bgOpacityKey, _bgOpacity);
  }

  /// 选背景图：复制进 app 支持目录（沙箱内永久可读），存容器内路径。
  Future<void> _pickBgImage() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image);
    final src = r?.files.single.path;
    if (src == null) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final ext = src.contains('.') ? src.split('.').last : 'img';
      final dest =
          '${dir.path}/bg_${DateTime.now().millisecondsSinceEpoch}.$ext';
      // 删掉上一张复制进来的背景，避免容器堆积
      final old = _bgImagePath;
      if (old != null &&
          old.startsWith(dir.path) &&
          old.contains('${Platform.pathSeparator}bg_')) {
        try {
          File(old).deleteSync();
        } catch (_) {}
      }
      await File(src).copy(dest);
      if (!mounted) return;
      setState(() {
        _bgImagePath = dest;
        _bgColorValue = null;
      });
      await _saveAppearance();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('设置背景失败：$e')));
      }
    }
  }

  void _setBgColor(Color? c) {
    setState(() {
      _bgColorValue = c?.value;
      _bgImagePath = null;
    });
    _saveAppearance();
  }

  Future<void> _resetBg() async {
    final old = _bgImagePath;
    setState(() {
      _bgImagePath = null;
      _bgColorValue = null;
      _bgOpacity = 0.6;
    });
    if (old != null && old.contains('${Platform.pathSeparator}bg_')) {
      try {
        File(old).deleteSync();
      } catch (_) {}
    }
    await _saveAppearance();
  }

  /// 自定义背景铺满内容区身后（完整不透明）；侧栏/顶栏不透明仍盖住。
  /// 背景透出多少 + 文字可读性由 _content 的 _baseBg 蒙层按「透明度」控制。
  Widget _withBackground(Widget child) {
    if (!_hasCustomBg) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: _bgImagePath != null
              ? Image.file(
                  File(_bgImagePath!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(color: _baseBg),
                )
              : ColoredBox(color: Color(_bgColorValue!)),
        ),
        child,
      ],
    );
  }

  /// 内容区：有自定义背景时盖一层 _baseBg 蒙层（透明度 = 1 − 背景透出度），
  /// 透明度滑块越大背景越显、越小越接近常规浅色界面；深色背景下文字也清晰。
  Widget _content(ColorScheme cs) {
    final view = _navIndex == 0
        ? _libraryView(cs)
        : _navIndex == 1
            ? _favoritesView(cs)
            : _navIndex == 2
                ? _myVideosView(cs)
                : _settingsView(cs);
    if (!_hasCustomBg) return view;
    return ColoredBox(
      color: _baseBg.withValues(alpha: (1 - _bgOpacity).clamp(0.0, 1.0)),
      child: view,
    );
  }

  Future<void> _loadBiliCookie() async {
    final prefs = await SharedPreferences.getInstance();
    // 一次性登录导入：存在 ~/小李播放器/bili_login.txt 就读进来并删除。
    // 由 app 自己写进它真正用的 prefs，绕开外部改 prefs/沙箱容器/cfprefsd 不生效的坑。
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) {
        final f = File('$home/小李播放器/bili_login.txt');
        if (f.existsSync()) {
          final fc = f.readAsStringSync().trim();
          if (fc.isNotEmpty) await prefs.setString(_biliCookieKey, fc);
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    final c = prefs.getString(_biliCookieKey) ?? '';
    if (c.isNotEmpty) _bili.setUserCookie(c);
    if (mounted) setState(() => _biliLoggedIn = c.isNotEmpty);
    if (c.isNotEmpty) _loadAccount();
  }

  Future<void> _showBiliLogin() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('B站登录'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '登录后搜索用你的账号身份，几乎不受限流。获取 Cookie：\n'
                '1. 电脑浏览器登录 bilibili.com\n'
                '2. 按 F12 → 顶部「应用/Application」→ 左侧 Cookies → 选 bilibili.com\n'
                '3. 找到 SESSDATA，复制它的值\n'
                '4. 粘贴到下面（粘整段 Cookie 也行）',
                style: TextStyle(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: '粘贴 SESSDATA 的值，或整段 Cookie…',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (_biliLoggedIn)
            TextButton(
              onPressed: () => Navigator.of(context).pop('__logout__'),
              child: const Text('退出登录', style: TextStyle(color: Colors.red)),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              _showQrLogin();
            },
            icon: const Icon(Icons.qr_code, size: 18),
            label: const Text('扫码登录'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('用Cookie登录'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final cookie = result == '__logout__' ? '' : result;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_biliCookieKey, cookie);
    _bili.setUserCookie(cookie);
    if (!mounted) return;
    setState(() {
      _biliLoggedIn = cookie.isNotEmpty;
      if (cookie.isEmpty) _account = null;
    });
    if (cookie.isNotEmpty) _loadAccount();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(cookie.isNotEmpty ? '已登录 B站，搜索更稳定了' : '已退出登录')),
    );
    if (cookie.isNotEmpty && _query.trim().isNotEmpty) _searchOnline(_query);
  }

  Future<void> _showQrLogin() async {
    final qr = await _bili.qrGenerate();
    if (!mounted) return;
    if (qr == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('生成二维码失败，请重试')));
      return;
    }
    final qrImg =
        'https://api.qrserver.com/v1/create-qr-code/?size=240x240&data=${Uri.encodeComponent(qr['url']!)}';
    String status = '请用 B站 手机 App 扫码登录';
    Timer? poll;
    await showDialog<void>(
      context: context,
      barrierDismissible: false, // 防止点遮罩关闭后轮询仍在跑
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          poll ??= Timer.periodic(const Duration(seconds: 2), (t) async {
            if (!ctx.mounted) {
              t.cancel();
              return;
            }
            final res = await _bili.qrPoll(qr['key']!);
            if (!ctx.mounted) {
              t.cancel();
              return;
            }
            switch (res['state']) {
              case 'scanned':
                setS(() => status = '已扫码，请在手机上点「确认登录」');
                break;
              case 'expired':
                t.cancel();
                setS(() => status = '二维码已过期，请关闭重开');
                break;
              case 'done':
                t.cancel();
                final cookie = res['cookie'] ?? '';
                if (cookie.isEmpty) {
                  setS(() => status = '登录失败：未取到有效凭据，请重试');
                  break;
                }
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString(_biliCookieKey, cookie);
                _bili.setUserCookie(cookie);
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (mounted) {
                  setState(() => _biliLoggedIn = true);
                  _loadAccount();
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('扫码登录成功 ✓')));
                  if (_query.trim().isNotEmpty) _searchOnline(_query);
                }
                break;
            }
          });
          return AlertDialog(
            title: const Text('扫码登录 B站'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.network(qrImg,
                    width: 200,
                    height: 200,
                    errorBuilder: (_, _, _) => const SizedBox(
                        width: 200,
                        height: 200,
                        child: Center(child: Text('二维码加载失败')))),
                const SizedBox(height: 12),
                Text(status, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 4),
                const Text('扫码登录会拿到完整凭据，关注等功能可用',
                    style: TextStyle(fontSize: 11, color: Colors.black45)),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('关闭')),
            ],
          );
        },
      ),
    );
    poll?.cancel();
  }

  Future<void> _showDisclaimer() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('免责声明'),
        content: const SingleChildScrollView(
          child: Text(
            '「小李播放器」是一款媒体播放器，仅供学习与个人使用。\n\n'
            '联网搜索内容来自公开网络平台；版权归原作者/平台所有，'
            '请勿用于任何商业或侵权用途，使用本软件产生的一切后果由使用者自行承担。\n\n'
            '点击「同意」即表示你已阅读并接受以上条款。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('同意'),
          ),
        ],
      ),
    );
  }

  Future<void> _silentCheckUpdate() async {
    final info = await _update.check();
    if (info != null && mounted) _showUpdateDialog(info);
  }

  Future<void> _checkUpdateManually() async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final info = await _update.check();
    if (!mounted) return;
    Navigator.of(context).pop();
    if (info != null) {
      _showUpdateDialog(info);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已是最新版本 v${UpdateService.currentVersion}')),
      );
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('发现新版本 v${info.version}'),
        content: SingleChildScrollView(
          child: Text(info.notes.isEmpty ? '有可用更新，建议下载最新版本。' : info.notes),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              final uri = Uri.tryParse(info.url);
              if (uri != null) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text('前往下载'),
          ),
        ],
      ),
    );
  }

  Future<void> _addFiles() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (r == null) return;
    setState(() {
      for (final f in r.files) {
        if (f.path != null && !_localTracks.any((t) => t.localPath == f.path)) {
          _localTracks.add(Track.local(f.path!));
        }
      }
    });
    await _saveLocal();
  }

  void _onSearchChanged(String v) {
    setState(() => _query = v);
    _searchDebounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() => _onlineTracks.clear());
      return;
    }
    _searchDebounce =
        Timer(const Duration(milliseconds: 500), () => _searchOnline(v));
  }

  Future<void> _searchOnline(String q) async {
    setState(() => _searchingOnline = true);
    final results = await _bili.search(q);
    final plat = await _platform.search(q);
    if (!mounted) return;
    setState(() {
      _searchingOnline = false;
      _onlineTracks
        ..clear()
        ..addAll(plat.map(_platTrack))
        ..addAll(results.map((b) => Track.bili(
              b.author.isEmpty ? b.title : '${b.title} - ${b.author}',
              b.bvid,
            )));
    });
    if (results.isNotEmpty || plat.isNotEmpty) _addHistory(q);
  }

  // ---- 共享视频平台 ----
  Track _platTrack(PlatformVideo v) => Track.online(
      v.uploader.isEmpty ? v.title : '${v.title} · ${v.uploader}',
      PlatformService.videoUrl(v.id),
      tag: '平台');

  Future<void> _loadPlatform() async {
    final vs = await _platform.list();
    if (!mounted) return;
    setState(() {
      _platformTracks
        ..clear()
        ..addAll(vs.map(_platTrack));
    });
  }

  Future<void> _uploadToPlatform() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.video);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    final fname = picked!.files.single.name;
    final titleCtrl = TextEditingController(
        text: fname.contains('.')
            ? fname.substring(0, fname.lastIndexOf('.'))
            : fname);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('上传到本应用平台'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('文件：$fname',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                  labelText: '标题', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            const Text('上传后任何人在本应用搜索都能看到、跨设备播放。',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('上传')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Expanded(child: Text('上传中…大视频较慢，请稍候')),
        ]),
      ),
    );
    final uploader = _account?['uname']?.toString() ?? '匿名';
    final title = titleCtrl.text.trim().isEmpty ? fname : titleCtrl.text.trim();
    final msg = await _platform.upload(path, title, uploader);
    if (!mounted) return;
    Navigator.of(context).pop();
    _loadPlatform();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _play(Track t, {bool replace = false}) async {
    setState(() => _current = t);
    PlaybackSource src;
    if (t.bvid != null) {
      // B站：先弹 loading，异步取音频流
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
      final subFut = _bili.getSubtitles(t.bvid!); // 并发取字幕，不阻塞起播
      final url = await _bili.getMediaUrl(t.bvid!);
      if (mounted) Navigator.of(context).pop();
      if (url == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('获取音频失败，换一首试试')),
          );
        }
        return;
      }
      src = PlaybackSource.stream(url, _bili.playHeaders,
          title: t.name, isVideo: true, subtitleFuture: subFut);
    } else {
      src = t.toSource();
    }
    if (!mounted) return;
    final route = MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(
        source: src,
        isFavorite: _isFav(t),
        onToggleFavorite: () => _toggleFav(t),
        onCompleted: () => _onTrackCompleted(),
        onFollow: t.bvid != null ? () => _followUp(t.bvid!) : null,
      ),
    );
    if (replace) {
      // 自动连播：收起所有已堆叠的播放页，保持 [列表页, 当前播放页]
      Navigator.of(context).pushAndRemoveUntil(route, (r) => r.isFirst);
    } else {
      Navigator.of(context).push(route);
    }
  }

  void _prev() {
    final list = _playQueue;
    if (_current == null || list.isEmpty) return;
    final i = list.indexWhere((t) => t.name == _current!.name);
    if (i > 0) _play(list[i - 1]);
  }

  void _next() {
    final list = _playQueue;
    if (_current == null || list.isEmpty) return;
    final i = list.indexWhere((t) => t.name == _current!.name);
    if (i >= 0 && i < list.length - 1) _play(list[i + 1]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: _baseBg,
      body: _withBackground(
        Row(
          children: [
            _sidebar(cs),
            Expanded(
              child: Column(
                children: [
                  _topbar(cs),
                  Expanded(child: _content(cs)),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: PlayerBar(
        title: _current?.name,
        subtitle: _currentSubtitle,
        onPrev: _prev,
        onNext: _next,
        onPlayPause: () {
          if (_current != null) _play(_current!);
        },
      ),
    );
  }

  Widget _sidebar(ColorScheme cs) {
    return Container(
      width: 72,
      color: _sidebarColor,
      child: Column(
        children: [
          const SizedBox(height: 20),
          Icon(Icons.music_video, color: cs.primary, size: 30),
          const SizedBox(height: 24),
          _navIcon(Icons.library_music, 0, cs),
          _navIcon(Icons.favorite, 1, cs),
          _navIcon(Icons.video_library, 2, cs),
          _navIcon(Icons.settings, 3, cs),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _navIcon(IconData icon, int index, ColorScheme cs) {
    final selected = _navIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: IconButton(
        onPressed: () => setState(() => _navIndex = index),
        icon: Icon(icon, color: selected ? cs.primary : Colors.white60),
      ),
    );
  }

  Widget _topbar(ColorScheme cs) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: _topbarColor,
      child: Row(
        children: [
          const Text(
            '音乐',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _searchCtrl,
                onChanged: _onSearchChanged,
                onSubmitted: (v) {
                  _addHistory(v);
                  _searchOnline(v);
                },
                textInputAction: TextInputAction.search,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '搜索歌曲（可搜中文歌）…',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon:
                      const Icon(Icons.search, color: Colors.white38, size: 20),
                  filled: true,
                  fillColor: _sidebarColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _addFiles,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加文件'),
          ),
        ],
      ),
    );
  }

  Widget _libraryView(ColorScheme cs) {
    final q = _query.toLowerCase();
    final List<Track> items;
    if (q.isEmpty) {
      items = [..._platformTracks, ..._hotTracks, ..._localTracks];
    } else {
      final local = [..._hotTracks, ..._localTracks]
          .where((t) => t.name.toLowerCase().contains(q))
          .toList();
      items = [...local, ..._onlineTracks];
    }
    return Column(
      children: [
        if (_searchingOnline) const LinearProgressIndicator(minHeight: 2),
        if (_query.isEmpty && _searchHistory.isNotEmpty) _historyBar(cs),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search,
                          size: 64, color: cs.primary.withOpacity(0.4)),
                      const SizedBox(height: 12),
                      Text(
                        q.isEmpty
                            ? '搜索歌曲，或点右上角「添加文件」加本地音乐'
                            : (_searchingOnline
                                ? '搜索中…'
                                : '没搜到「$_query」\n（搜太频繁会被平台限流，过会儿再试或换个词）'),
                        style: const TextStyle(color: Colors.black54),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _trackRow(cs, items[i], i),
                ),
        ),
      ],
    );
  }

  void _showRowMenu(Track t, Offset pos) {
    final items = <PopupMenuEntry<String>>[
      PopupMenuItem(value: 'fav', child: Text(_isFav(t) ? '取消收藏' : '收藏')),
    ];
    if (t.isLocal) {
      items.add(const PopupMenuItem(value: 'remove', child: Text('从列表移除')));
    }
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: items,
    ).then((v) {
      if (!mounted || v == null) return;
      if (v == 'fav') {
        _toggleFav(t);
      } else if (v == 'remove') {
        _removeLocal(t);
      }
    });
  }

  void _removeLocal(Track t) {
    setState(() {
      _localTracks.removeWhere((x) => x.localPath == t.localPath);
      _favorites.removeWhere((x) => x.key == t.key); // 同步删收藏，避免引用已删文件
      if (_current?.key == t.key) _current = null;
    });
    _saveLocal();
    _saveFavorites();
  }

  Widget _trackRow(ColorScheme cs, Track t, int i) {
    final selected = t.name == _current?.name;
    Color? tagColor;
    if (t.tag == '热门') tagColor = Colors.orange;
    final icon = t.isLocal
        ? Icons.music_note
        : (t.bvid != null ? Icons.smart_display : Icons.cloud_outlined);
    return InkWell(
      onTap: () => _play(t),
      onSecondaryTapDown: (d) => _showRowMenu(t, d.globalPosition),
      child: Container(
        color: selected ? cs.primary.withOpacity(0.12) : null,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child:
                  Text('${i + 1}', style: const TextStyle(color: Colors.black45)),
            ),
            Icon(icon, color: cs.primary, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (tagColor != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child:
                    Text(t.tag, style: TextStyle(color: tagColor, fontSize: 12)),
              ),
            IconButton(
              icon: Icon(_isFav(t) ? Icons.favorite : Icons.favorite_border,
                  size: 20),
              color: _isFav(t) ? Colors.redAccent : Colors.black38,
              tooltip: _isFav(t) ? '取消收藏' : '收藏',
              onPressed: () => _toggleFav(t),
            ),
            if (!t.isLocal)
              IconButton(
                icon: const Icon(Icons.download_outlined, size: 20),
                color: Colors.black38,
                tooltip: '下载',
                onPressed: () => _download(t),
              ),
            IconButton(
              icon: const Icon(Icons.play_circle_outline),
              color: cs.primary,
              onPressed: () => _play(t),
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyBar(ColorScheme cs) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history, size: 16, color: Colors.black45),
              const SizedBox(width: 4),
              const Text('搜索记录',
                  style: TextStyle(color: Colors.black54, fontSize: 13)),
              const Spacer(),
              TextButton(
                onPressed: _clearHistory,
                style: TextButton.styleFrom(
                    minimumSize: const Size(0, 0),
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: const Text('清空', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 132),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final h in _searchHistory)
                    ActionChip(
                      label: Text(h, style: const TextStyle(fontSize: 13)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        _searchCtrl.text = h;
                        _searchDebounce?.cancel();
                        setState(() => _query = h);
                        _searchOnline(h); // 点历史词立即搜，不等防抖
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _favoritesView(ColorScheme cs) {
    if (_favorites.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.favorite_border,
                size: 64, color: cs.primary.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            const Text('还没有收藏\n点歌曲右侧的 ♡ 即可收藏',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54)),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: _favorites.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => _trackRow(cs, _favorites[i], i),
    );
  }

  Widget _colorDot(Color? c) {
    final cs = Theme.of(context).colorScheme;
    final selected = c == null
        ? !_hasCustomBg
        : (_bgImagePath == null && _bgColorValue == c.value);
    return GestureDetector(
      onTap: () => _setBgColor(c),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: c ?? Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? cs.primary : Colors.black26,
            width: selected ? 3 : 1,
          ),
        ),
        child: c == null
            ? const Icon(Icons.block, size: 15, color: Colors.black38)
            : null,
      ),
    );
  }

  Widget _settingsView(ColorScheme cs) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('设置',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: cs.primary)),
        const SizedBox(height: 16),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('小李播放器 v2.11.2'),
          subtitle: Text('媒体播放器 · 支持所有格式（基于 libmpv）'),
        ),
        ListTile(
          leading: const Icon(Icons.system_update),
          title: const Text('检查更新'),
          subtitle: const Text('检测并下载最新版本'),
          onTap: _checkUpdateManually,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.playlist_play),
          title: const Text('自动连播'),
          subtitle: const Text('一首播完（未开单曲循环）自动播放推荐/下一首'),
          value: _autoNext,
          onChanged: (v) {
            setState(() => _autoNext = v);
            _saveAutoNext(v);
          },
        ),
        const Divider(height: 32),
        Text('外观',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold, color: cs.primary)),
        ListTile(
          leading: const Icon(Icons.wallpaper),
          title: const Text('背景图片'),
          subtitle: Text(_bgImagePath != null
              ? '已设置自定义背景图'
              : '点此选择一张图片作为界面背景'),
          trailing: _hasCustomBg
              ? IconButton(
                  icon: const Icon(Icons.restore),
                  tooltip: '恢复默认背景',
                  onPressed: _resetBg,
                )
              : null,
          onTap: _pickBgImage,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              const Text('纯色背景：'),
              const SizedBox(width: 8),
              for (final c in _bgPresetColors) _colorDot(c),
              _colorDot(null),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('背景透明度'),
                  Text('${(_bgOpacity * 100).round()}%',
                      style: TextStyle(color: cs.primary)),
                ],
              ),
              Slider(
                value: _bgOpacity,
                min: 0,
                max: 1,
                activeColor: cs.primary,
                onChanged: _hasCustomBg
                    ? (v) => setState(() => _bgOpacity = v)
                    : null,
                onChangeEnd: (_) => _saveAppearance(),
              ),
              if (!_hasCustomBg)
                const Text('先选背景图或纯色，再调透明度',
                    style: TextStyle(color: Colors.black38, fontSize: 12)),
            ],
          ),
        ),
        const Divider(height: 32),
        const ListTile(
          leading: Icon(Icons.travel_explore),
          title: Text('联网搜索'),
          subtitle: Text('搜索框输入歌名，联网搜索（可搜中文歌）'),
        ),
        ListTile(
          leading: (_account != null && _account!['face'] is String)
              ? CircleAvatar(
                  radius: 16,
                  backgroundImage: NetworkImage(_account!['face'] as String),
                  onBackgroundImageError: (_, __) {},
                )
              : Icon(_biliLoggedIn ? Icons.verified_user : Icons.login,
                  color: _biliLoggedIn ? Colors.green : null),
          title: Text(_account?['uname'] != null
              ? 'B站：${_account!['uname']}'
              : (_biliLoggedIn ? 'B站 · 已登录' : 'B站登录')),
          subtitle: Text(_biliLoggedIn
              ? '已登录 · 搜索不受限流（点此可退出/重登）'
              : '未登录 · 点此登录（扫码或粘贴 Cookie）'),
          onTap: _showBiliLogin,
        ),
        if (_biliLoggedIn)
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('我的关注 / 关注管理'),
            subtitle: const Text('查看并管理你关注的 UP主（可取关）'),
            onTap: _showFollowings,
          ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('免责声明'),
          onTap: _showDisclaimer,
        ),
      ],
    );
  }
}

/// 「我的关注」页：列出关注的 UP主，可取关。
class _FollowingsPage extends StatefulWidget {
  final BilibiliService bili;
  final int mid;
  final void Function(String bvid, String title) onPlay;
  const _FollowingsPage(
      {required this.bili, required this.mid, required this.onPlay});

  @override
  State<_FollowingsPage> createState() => _FollowingsPageState();
}

class _FollowingsPageState extends State<_FollowingsPage> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await widget.bili.getFollowings(widget.mid);
    if (mounted) setState(() {
      _list = l;
      _loading = false;
    });
  }

  Future<void> _unfollow(Map<String, dynamic> u) async {
    final mid = u['mid'];
    final midInt = mid is num ? mid.toInt() : int.tryParse('$mid');
    if (midInt == null) return;
    final msg = await widget.bili.followUp(midInt, act: 2);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('${u['uname']}：$msg')));
    if (msg.contains('取消')) {
      setState(() => _list.removeWhere((x) => x['mid'] == u['mid']));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('我的关注（${_list.length}）')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _list.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('没有关注，或 B站 接口受限（关注列表可能被设为隐私）',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54)),
                  ),
                )
              : ListView.separated(
                  itemCount: _list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final u = _list[i];
                    final face = u['face'];
                    final mid = u['mid'];
                    final midInt =
                        mid is num ? mid.toInt() : int.tryParse('$mid');
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: face is String && face.isNotEmpty
                            ? NetworkImage(face)
                            : null,
                        onBackgroundImageError: (_, _) {},
                        child: face is String && face.isNotEmpty
                            ? null
                            : const Icon(Icons.person),
                      ),
                      title: Text(u['uname']?.toString() ?? ''),
                      subtitle: Text(u['sign']?.toString() ?? '',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: midInt == null
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => _UserVideosPage(
                                    bili: widget.bili,
                                    mid: midInt,
                                    name: u['uname']?.toString() ?? 'UP主',
                                    onPlay: widget.onPlay,
                                  ))),
                      trailing: TextButton(
                        onPressed: () => _unfollow(u),
                        child: const Text('取关',
                            style: TextStyle(color: Colors.red)),
                      ),
                    );
                  },
                ),
    );
  }
}

/// 某 UP主 的投稿视频页：点视频即播放。
class _UserVideosPage extends StatefulWidget {
  final BilibiliService bili;
  final int mid;
  final String name;
  final void Function(String bvid, String title) onPlay;
  const _UserVideosPage(
      {required this.bili,
      required this.mid,
      required this.name,
      required this.onPlay});

  @override
  State<_UserVideosPage> createState() => _UserVideosPageState();
}

class _UserVideosPageState extends State<_UserVideosPage> {
  List<BiliTrack> _list = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await widget.bili.getUserVideos(widget.mid);
    if (mounted) {
      setState(() {
        _list = l;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.name} 的视频')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _list.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('没拿到视频（B站 空间接口风控较严，过会再试）',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54)),
                  ),
                )
              : ListView.separated(
                  itemCount: _list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final v = _list[i];
                    return ListTile(
                      leading: Icon(Icons.smart_display, color: cs.primary),
                      title: Text(v.title,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => widget.onPlay(v.bvid, v.title),
                    );
                  },
                ),
    );
  }
}
