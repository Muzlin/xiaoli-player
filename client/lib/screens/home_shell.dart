import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../player/playback_source.dart';
import '../services/bilibili_service.dart';
import '../services/transcribe_service.dart';
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
  final List<BiliUser> _accountResults = []; // 搜索到的 B站账号
  static const _winChannel = MethodChannel('xiaoli/window');
  bool _launchAtLogin = false;
  bool _backgroundRun = false;
  bool _hotkey = false;
  int _hotkeyCode = 35; // ⌥⌘P 默认(P=35)
  int _hotkeyMods = 2304; // cmd256|option2048
  String _hotkeyLabel = '⌥⌘P';
  bool _hideHotkey = false;
  int _hideHotkeyCode = 4; // ⌥⌘H 默认(H=4)
  int _hideHotkeyMods = 2304;
  String _hideHotkeyLabel = '⌥⌘H';
  bool _blockQuit = false;
  String? _pwdHash;
  final Set<String> _protectedKeys = {};
  final Map<String, int> _resume = {}; // 断点续播：track key→秒
  Timer? _urlTimer; // 定时重读本机平台地址
  bool _publicHealthy = true;
  bool _useLan = false;
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
    _loadAppSettings();
    _loadProtection();
    _loadResume();
    _loadAutoNext();
    if (Platform.isMacOS) {
      _urlTimer = Timer.periodic(
          const Duration(seconds: 30), (_) => _refreshPlatformUrl());
      _refreshPlatformUrl();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showDisclaimer();
      _silentCheckUpdate();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _urlTimer?.cancel();
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

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  /// 下载视频到「下载」目录，带进度弹窗（B站异步解析流地址；平台/直链直接下）。
  static const _videoFmts = ['mp4', 'mkv', 'mov', 'webm', 'avi', 'ts'];
  static const _audioFmts = ['mp3', 'm4a', 'aac', 'flac', 'wav'];

  Future<String?> _pickFormat() {
    return showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('选择保存格式'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Text('视频',
                style: TextStyle(color: Colors.black54, fontSize: 12)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final fm in _videoFmts)
                  ActionChip(
                      label: Text(fm),
                      onPressed: () => Navigator.pop(context, fm)),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text('音频（仅提取声音）',
                style: TextStyle(color: Colors.black54, fontSize: 12)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final fm in _audioFmts)
                  ActionChip(
                      label: Text(fm),
                      onPressed: () => Navigator.pop(context, fm)),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<bool> _ffmpegConvert(String src, String dest, String fmt) async {
    final ff = TranscribeService.ffmpeg;
    if (ff == null) return false;
    const audio = {'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus'};
    bool good() => File(dest).existsSync() && File(dest).lengthSync() > 0;
    try {
      if (audio.contains(fmt)) {
        final r = await Process.run(ff, ['-y', '-i', src, '-vn', dest]);
        return r.exitCode == 0 && good();
      }
      final copy = await Process.run(ff, ['-y', '-i', src, '-c', 'copy', dest]);
      if (copy.exitCode == 0 && good()) return true;
      final tr = await Process.run(ff, ['-y', '-i', src, dest]);
      return tr.exitCode == 0 && good();
    } catch (_) {
      return false;
    }
  }

  Future<void> _download(Track t) async {
    if (t.isLocal || !mounted) return;
    final fmt = await _pickFormat();
    if (fmt == null || !mounted) return;
    final safe = t.name.replaceAll(RegExp(r'[^\w一-龥 .-]'), '_');
    final dest = await FilePicker.platform.saveFile(
      dialogTitle: '保存到…',
      fileName: '$safe.$fmt',
    );
    if (dest == null || !mounted) return;
    final progress = ValueNotifier<String>('解析地址…');
    var cancelled = false;
    var dialogOpen = true;
    void closeDialog() {
      if (dialogOpen && mounted) {
        dialogOpen = false;
        Navigator.of(context).pop();
      }
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('下载视频'),
        content: ValueListenableBuilder<String>(
          valueListenable: progress,
          builder: (_, sx, __) => Row(
            mainAxisSize: MainAxisSize.min,
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
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              closeDialog();
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );

    String? url;
    Map<String, String> headers = const {};
    if (t.bvid != null) {
      url = await _bili.getMediaUrl(t.bvid!);
      headers = _bili.playHeaders;
    } else {
      url = t.url;
    }
    if (cancelled) return;
    if (url == null) {
      closeDialog();
      _snack('获取下载地址失败');
      return;
    }
    final tmp =
        '${Directory.systemTemp.path}/xldl_${DateTime.now().millisecondsSinceEpoch}.src';
    try {
      progress.value = '连接中…';
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(headers);
      final resp =
          await http.Client().send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode >= 400) {
        closeDialog();
        _snack('下载失败 ${resp.statusCode}');
        return;
      }
      final total = resp.contentLength ?? 0;
      var received = 0;
      final sink = File(tmp).openWrite();
      await for (final chunk in resp.stream) {
        if (cancelled) break;
        sink.add(chunk);
        received += chunk.length;
        final mb = (received / 1048576).toStringAsFixed(1);
        progress.value = total > 0
            ? '下载 $mb / ${(total / 1048576).toStringAsFixed(1)} MB'
            : '下载 $mb MB';
      }
      await sink.close();
      if (cancelled) {
        try {
          File(tmp).deleteSync();
        } catch (_) {}
        return;
      }
      if (TranscribeService.ffmpeg != null) {
        progress.value = '转换为 $fmt…（大文件需等一会）';
        final ok = await _ffmpegConvert(tmp, dest, fmt);
        try {
          File(tmp).deleteSync();
        } catch (_) {}
        if (!ok) {
          closeDialog();
          _snack('转换失败（试试别的格式）');
          return;
        }
      } else {
        File(tmp).copySync(dest);
        try {
          File(tmp).deleteSync();
        } catch (_) {}
      }
      closeDialog();
      _snack('已保存到 $dest');
    } catch (e) {
      try {
        File(tmp).deleteSync();
      } catch (_) {}
      closeDialog();
      _snack('下载出错：$e');
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
    final users = await _bili.searchUsers(q);
    if (!mounted) return;
    setState(() {
      _searchingOnline = false;
      _accountResults
        ..clear()
        ..addAll(users);
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
    await PlatformService.loadLocal();
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
        onCompleted: () {
          _resume.remove(t.key);
          _saveResume();
          _onTrackCompleted();
        },
        onFollow: t.bvid != null ? () => _followUp(t.bvid!) : null,
        onLoadComments: t.bvid != null
            ? (pn) => _bili.getComments(t.bvid!, pn: pn)
            : null,
        onPostComment:
            t.bvid != null ? (msg) => _bili.postComment(t.bvid!, msg) : null,
        startAt: Duration(seconds: _resume[t.key] ?? 0),
        onSavePos: (sec) {
          _resume[t.key] = sec;
          _saveResume();
        },
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

  String _fmtFans(int n) {
    if (n >= 10000) {
      return '${(n / 10000).toStringAsFixed(n >= 1000000 ? 0 : 1)}万';
    }
    return '$n';
  }

  static const _loginPlist = 'com.xiaoli.player.plist';

  Future<void> _refreshPlatformUrl() async {
    final before = PlatformService.current;
    await PlatformService.loadLocal();
    final healthy = await _platform.publicHealthy();
    if (!mounted) return;
    setState(() => _publicHealthy = healthy);
    if (PlatformService.current != before) _loadPlatform();
  }

  Future<void> _setLanIp() async {
    final ctrl = TextEditingController(text: PlatformService.customLanIp ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('局域网服务器 IP'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '如 10.10.10.5（留空=自动探测）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text('自动探测到：${PlatformService.detectedIp ?? "未探测到"}',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    final ip = ctrl.text.trim();
    PlatformService.customLanIp = ip.isEmpty ? null : ip;
    final p = await SharedPreferences.getInstance();
    if (ip.isEmpty) {
      await p.remove('lan_ip');
    } else {
      await p.setString('lan_ip', ip);
    }
    if (!mounted) return;
    setState(() {});
    if (_useLan) _loadPlatform();
  }

  Future<void> _loadAppSettings() async {
    if (!Platform.isMacOS) return;
    var login = false, bg = false, hk = false, hidehk = false, bq = false;
    try {
      final home = Platform.environment['HOME'] ?? '';
      login = File('$home/Library/LaunchAgents/$_loginPlist').existsSync();
    } catch (_) {}
    try {
      bg = (await _winChannel.invokeMethod<bool>('backgroundRunEnabled')) ??
          false;
    } catch (_) {}
    try {
      hk = (await _winChannel.invokeMethod<bool>('hotkeyEnabled')) ?? false;
      hidehk =
          (await _winChannel.invokeMethod<bool>('hideHotkeyEnabled')) ?? false;
      bq = (await _winChannel.invokeMethod<bool>('blockQuitEnabled')) ?? false;
    } catch (_) {}
    try {
      final p = await SharedPreferences.getInstance();
      _hotkeyCode = p.getInt('hotkey_code') ?? _hotkeyCode;
      _hotkeyMods = p.getInt('hotkey_mods') ?? _hotkeyMods;
      _hotkeyLabel = p.getString('hotkey_label') ?? _hotkeyLabel;
      _hideHotkeyCode = p.getInt('hide_hotkey_code') ?? _hideHotkeyCode;
      _hideHotkeyMods = p.getInt('hide_hotkey_mods') ?? _hideHotkeyMods;
      _hideHotkeyLabel = p.getString('hide_hotkey_label') ?? _hideHotkeyLabel;
      PlatformService.customLanIp = p.getString('lan_ip');
    } catch (_) {}
    if (mounted) {
      setState(() {
        _launchAtLogin = login;
        _backgroundRun = bg;
        _hotkey = hk;
        _hideHotkey = hidehk;
        _blockQuit = bq;
      });
    }
  }

  Future<void> _setLaunchAtLogin(bool on) async {
    setState(() => _launchAtLogin = on);
    try {
      final home = Platform.environment['HOME'] ?? '';
      final dir = Directory('$home/Library/LaunchAgents');
      final file = File('${dir.path}/$_loginPlist');
      if (on) {
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final exe = Platform.resolvedExecutable;
        file.writeAsStringSync('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0"><dict>\n'
            '<key>Label</key><string>com.xiaoli.player</string>\n'
            '<key>ProgramArguments</key><array><string>$exe</string></array>\n'
            '<key>RunAtLoad</key><true/>\n'
            '</dict></plist>\n');
      } else {
        if (file.existsSync()) file.deleteSync();
      }
    } catch (_) {}
  }

  Future<void> _setBackgroundRun(bool on) async {
    setState(() => _backgroundRun = on);
    try {
      await _winChannel.invokeMethod('setBackgroundRun', {'on': on});
    } catch (_) {}
  }

  Future<void> _setHotkeyEnabled(bool on) async {
    setState(() => _hotkey = on);
    try {
      await _winChannel.invokeMethod(
          'setHotkey', {'on': on, 'code': _hotkeyCode, 'mods': _hotkeyMods});
    } catch (_) {}
  }

  static final _modKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
  };

  Future<Map<String, dynamic>?> _recordCombo(String title) async {
    final node = FocusNode();
    int? code;
    var mods = 0;
    var label = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(title),
          content: RawKeyboardListener(
            focusNode: node..requestFocus(),
            onKey: (e) {
              if (e is! RawKeyDownEvent) return;
              final d = e.data;
              if (d is! RawKeyEventDataMacOs) return;
              if (_modKeys.contains(e.logicalKey)) return;
              var m = 0;
              if (e.isControlPressed) m |= 4096;
              if (e.isAltPressed) m |= 2048;
              if (e.isShiftPressed) m |= 512;
              if (e.isMetaPressed) m |= 256;
              if (m == 0) return;
              code = d.keyCode;
              mods = m;
              final sb = StringBuffer();
              if (e.isControlPressed) sb.write('⌃');
              if (e.isAltPressed) sb.write('⌥');
              if (e.isShiftPressed) sb.write('⇧');
              if (e.isMetaPressed) sb.write('⌘');
              sb.write(e.logicalKey.keyLabel.toUpperCase());
              label = sb.toString();
              setD(() {});
            },
            child: SizedBox(
              height: 64,
              child: Center(
                child: Text(
                  label.isEmpty ? '请按下快捷键\n（需含 ⌘ / ⌥ / ⌃ / ⇧）' : label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: code == null ? null : () => Navigator.pop(ctx, true),
                child: const Text('确定')),
          ],
        ),
      ),
    );
    node.dispose();
    if (ok == true && code != null) {
      return {'code': code!, 'mods': mods, 'label': label};
    }
    return null;
  }

  Future<void> _recordHotkey() async {
    final r = await _recordCombo('设置「唤起」快捷键');
    if (r == null) return;
    setState(() {
      _hotkeyCode = r['code'] as int;
      _hotkeyMods = r['mods'] as int;
      _hotkeyLabel = r['label'] as String;
    });
    final p = await SharedPreferences.getInstance();
    await p.setInt('hotkey_code', _hotkeyCode);
    await p.setInt('hotkey_mods', _hotkeyMods);
    await p.setString('hotkey_label', _hotkeyLabel);
    await _winChannel.invokeMethod('setHotkey',
        {'on': _hotkey, 'code': _hotkeyCode, 'mods': _hotkeyMods});
  }

  Future<void> _recordHideHotkey() async {
    final r = await _recordCombo('设置「隐藏」快捷键');
    if (r == null) return;
    setState(() {
      _hideHotkeyCode = r['code'] as int;
      _hideHotkeyMods = r['mods'] as int;
      _hideHotkeyLabel = r['label'] as String;
    });
    final p = await SharedPreferences.getInstance();
    await p.setInt('hide_hotkey_code', _hideHotkeyCode);
    await p.setInt('hide_hotkey_mods', _hideHotkeyMods);
    await p.setString('hide_hotkey_label', _hideHotkeyLabel);
    await _winChannel.invokeMethod('setHideHotkey',
        {'on': _hideHotkey, 'code': _hideHotkeyCode, 'mods': _hideHotkeyMods});
  }

  Future<void> _setHideHotkeyEnabled(bool on) async {
    setState(() => _hideHotkey = on);
    try {
      await _winChannel.invokeMethod('setHideHotkey',
          {'on': on, 'code': _hideHotkeyCode, 'mods': _hideHotkeyMods});
    } catch (_) {}
  }

  Future<void> _setBlockQuit(bool on) async {
    setState(() => _blockQuit = on);
    try {
      await _winChannel.invokeMethod('setBlockQuit', {'on': on});
    } catch (_) {}
  }

  Future<void> _loadResume() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('resume_v1');
    if (raw == null || !mounted) return;
    try {
      final m = (jsonDecode(raw) as Map)
          .map((k, v) => MapEntry(k as String, (v as num).toInt()));
      _resume
        ..clear()
        ..addAll(m);
    } catch (_) {}
  }

  Future<void> _saveResume() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('resume_v1', jsonEncode(_resume));
  }

  Future<void> _loadProtection() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _pwdHash = p.getString('app_pwd_hash');
      _protectedKeys
        ..clear()
        ..addAll(p.getStringList('protected_keys') ?? []);
    });
  }

  String _pwdSha(String s) => sha256.convert(utf8.encode(s)).toString();

  Future<bool> _promptPassword() async {
    if (_pwdHash == null) return true;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请输入密码'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(hintText: '密码'),
          onSubmitted: (_) =>
              Navigator.pop(ctx, _pwdSha(ctrl.text) == _pwdHash),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, _pwdSha(ctrl.text) == _pwdHash),
              child: const Text('确定')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _guard(String key, FutureOr<void> Function() action) async {
    if (_pwdHash != null && _protectedKeys.contains(key)) {
      if (!await _promptPassword()) return;
    }
    await action();
  }

  void _openUser(BiliUser u) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _UserVideosPage(
        bili: _bili,
        mid: u.mid,
        name: u.uname,
        onPlay: (bvid, title) => _play(Track.bili(title, bvid)),
      ),
    ));
  }

  Widget _accountsBar(ColorScheme cs) {
    return Container(
      height: 104,
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('账号',
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.black54,
                    fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children:
                  _accountResults.take(15).map((u) => _accountChip(cs, u)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountChip(ColorScheme cs, BiliUser u) {
    return GestureDetector(
      onTap: () => _openUser(u),
      child: Container(
        width: 72,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: Colors.black12,
              backgroundImage:
                  u.avatar.isNotEmpty ? NetworkImage(u.avatar) : null,
              child: u.avatar.isEmpty
                  ? const Icon(Icons.person, color: Colors.white70)
                  : null,
            ),
            const SizedBox(height: 4),
            Text(u.uname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11)),
            if (u.fans > 0)
              Text('${_fmtFans(u.fans)}粉',
                  style: const TextStyle(fontSize: 10, color: Colors.black45)),
          ],
        ),
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
        if (_query.isNotEmpty && _accountResults.isNotEmpty)
          _accountsBar(cs),
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
          title: Text('小李播放器 v2.19.1'),
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
        if (Platform.isMacOS) ...[
          SwitchListTile(
            secondary: const Icon(Icons.power_settings_new),
            title: const Text('开机自动启动'),
            value: _launchAtLogin,
            onChanged: (v) =>
                _guard('launchAtLogin', () => _setLaunchAtLogin(v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('后台运行'),
            subtitle: const Text('关窗口不退出，点 Dock 图标重新打开',
                style: TextStyle(fontSize: 12)),
            value: _backgroundRun,
            onChanged: (v) =>
                _guard('backgroundRun', () => _setBackgroundRun(v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.block),
            title: const Text('禁止退出'),
            subtitle: const Text('开启后 ⌘Q 也退不出，需在此关闭',
                style: TextStyle(fontSize: 12)),
            value: _blockQuit,
            onChanged: (v) =>
                _guard('blockQuit', () => _setBlockQuit(v)),
          ),
          ListTile(
            leading: const Icon(Icons.keyboard_outlined),
            title: const Text('全局快捷键唤起'),
            subtitle: Text('当前：$_hotkeyLabel · 点这里改键',
                style: const TextStyle(fontSize: 12)),
            trailing: Switch(
                value: _hotkey,
                onChanged: (v) => _guard('hotkey', () => _setHotkeyEnabled(v))),
            onTap: _recordHotkey,
          ),
          ListTile(
            leading: const Icon(Icons.keyboard_hide_outlined),
            title: const Text('全局快捷键隐藏'),
            subtitle: Text('当前：$_hideHotkeyLabel · 一键隐藏窗口 · 点这里改键',
                style: const TextStyle(fontSize: 12)),
            trailing: Switch(
                value: _hideHotkey,
                onChanged: (v) =>
                    _guard('hideHotkey', () => _setHideHotkeyEnabled(v))),
            onTap: _recordHideHotkey,
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('密码保护'),
            subtitle: const Text('设密码 + 自选哪些操作/设置需要密码',
                style: TextStyle(fontSize: 12)),
            onTap: () async {
              if (_pwdHash != null && !await _promptPassword()) return;
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const _PasswordProtectPage()));
              _loadProtection();
            },
          ),
        ],
        ListTile(
          leading: const Icon(Icons.cloud_download_outlined),
          title: const Text('官方下载网址'),
          isThreeLine: true,
          subtitle: Text(
            '${PlatformService.downloadUrl}\n'
            '${PlatformService.useLan ? "● 局域网模式" : (_publicHealthy ? "● 公网正常" : "⚠ 公网限流/抽风中，建议切局域网")}',
            style: TextStyle(
                fontSize: 12,
                color: (!_publicHealthy && !PlatformService.useLan)
                    ? Colors.orange
                    : Colors.black54),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: '复制',
            onPressed: () {
              Clipboard.setData(
                  ClipboardData(text: PlatformService.downloadUrl));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制下载网址')));
              }
            },
          ),
          onTap: () async {
            final uri = Uri.parse(PlatformService.downloadUrl);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
        ),
        SwitchListTile(
          secondary: Icon(Icons.lan_outlined,
              color: (!_publicHealthy && !_useLan) ? Colors.orange : null),
          title: const Text('切换到局域网服务器'),
          subtitle: Text(
            _publicHealthy
                ? '公网正常时无需开启；同 WiFi 设备可用 ${PlatformService.lanBase}'
                : '公网正在限流/抽风，开启即用局域网（同 WiFi 内秒开）',
            style: const TextStyle(fontSize: 12),
          ),
          value: _useLan,
          onChanged: (v) => _guard('useLan', () {
            PlatformService.setUseLan(v);
            setState(() => _useLan = v);
            _loadPlatform();
          }),
        ),
        ListTile(
          leading: const Icon(Icons.router_outlined),
          title: const Text('局域网服务器 IP'),
          subtitle: Text('当前 ${PlatformService.lanBase}（点击修改，留空=自动探测）',
              style: const TextStyle(fontSize: 12)),
          onTap: () => _guard('useLan', _setLanIp),
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
  bool _followed = false;

  Future<void> _toggleFollow() async {
    final msg =
        await widget.bili.followUp(widget.mid, act: _followed ? 2 : 1);
    if (!mounted) return;
    setState(() => _followed = !_followed);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

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
      appBar: AppBar(
        title: Text('${widget.name} 的视频'),
        actions: [
          TextButton.icon(
            onPressed: _toggleFollow,
            icon: Icon(_followed ? Icons.check : Icons.add, size: 18),
            label: Text(_followed ? '已关注' : '关注'),
          ),
        ],
      ),
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


class _PasswordProtectPage extends StatefulWidget {
  const _PasswordProtectPage();
  @override
  State<_PasswordProtectPage> createState() => _PasswordProtectPageState();
}

class _PasswordProtectPageState extends State<_PasswordProtectPage> {
  static const _ch = MethodChannel('xiaoli/window');
  static const _items = [
    ['quit', '退出 App'],
    ['launchAtLogin', '开机自动启动'],
    ['backgroundRun', '后台运行'],
    ['blockQuit', '禁止退出'],
    ['hotkey', '全局快捷键唤起'],
    ['hideHotkey', '全局快捷键隐藏'],
    ['useLan', '切换到局域网服务器'],
  ];
  String? _hash;
  final Set<String> _protected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _hash = p.getString('app_pwd_hash');
      _protected
        ..clear()
        ..addAll(p.getStringList('protected_keys') ?? []);
    });
  }

  String _sha(String s) => sha256.convert(utf8.encode(s)).toString();

  Future<void> _syncQuit() async {
    final on = _protected.contains('quit') && _hash != null;
    try {
      await _ch.invokeMethod('setQuitPassword', {'on': on, 'hash': _hash ?? ''});
    } catch (_) {}
  }

  Future<void> _setPassword() async {
    final p1 = TextEditingController();
    final p2 = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: p1,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: '新密码')),
            TextField(
                controller: p2,
                obscureText: true,
                decoration: const InputDecoration(labelText: '确认密码')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    if (p1.text.isEmpty || p1.text != p2.text) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('两次密码不一致或为空')));
      }
      return;
    }
    final h = _sha(p1.text);
    final p = await SharedPreferences.getInstance();
    await p.setString('app_pwd_hash', h);
    setState(() => _hash = h);
    await _syncQuit();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('密码已设置')));
    }
  }

  Future<void> _clearPassword() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('app_pwd_hash');
    setState(() => _hash = null);
    await _syncQuit();
  }

  Future<void> _toggle(String key, bool on) async {
    setState(() {
      if (on) {
        _protected.add(key);
      } else {
        _protected.remove(key);
      }
    });
    final p = await SharedPreferences.getInstance();
    await p.setStringList('protected_keys', _protected.toList());
    if (key == 'quit') await _syncQuit();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('密码保护')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.password),
            title: Text(_hash == null ? '设置密码' : '修改密码'),
            subtitle: Text(_hash == null ? '未设置密码' : '已设置',
                style: const TextStyle(fontSize: 12)),
            trailing: _hash == null
                ? null
                : TextButton(
                    onPressed: _clearPassword, child: const Text('清除')),
            onTap: _setPassword,
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('勾选的操作/设置改动时需要密码（先设密码）',
                style: TextStyle(color: Colors.black54, fontSize: 13)),
          ),
          for (final it in _items)
            CheckboxListTile(
              title: Text(it[1]),
              value: _protected.contains(it[0]),
              onChanged:
                  _hash == null ? null : (v) => _toggle(it[0], v ?? false),
            ),
        ],
      ),
    );
  }
}
