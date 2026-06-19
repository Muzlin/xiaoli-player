import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:math';
import '../text_scale.dart';
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
import '../services/download_manager.dart';
import '../player/player_holder.dart';
import '../widgets/player_bar.dart';
import 'player_screen.dart';
import 'stats_screen.dart';

/// 一首曲目：本地文件、内置热门、或 B站联网搜索结果。
class Track {
  final String name;
  final String? localPath;
  final String? url;
  final String? bvid; // B站视频，需异步取音频流
  final String tag; // '' | '热门' | 'B站'
  final String? cid; // B站分P的cid(可选)
  final String pic; // 封面图 URL（F39 封面取色，不持久化）

  Track.local(this.localPath)
      : name = localPath!.split(Platform.pathSeparator).last,
        url = null,
        bvid = null,
        tag = '',
        cid = null,
        pic = '';

  Track.online(this.name, this.url, {this.tag = '', this.pic = ''})
      : localPath = null,
        bvid = null,
        cid = null;

  // B站来源：不显示来源标签（作者已并入 name 保留）。
  Track.bili(this.name, this.bvid, {this.tag = '', this.cid, this.pic = ''})
      : localPath = null,
        url = null;

  bool get isLocal => localPath != null;

  String get ext {
    final src = localPath ?? '';
    return src.contains('.') ? src.split('.').last.toUpperCase() : '';
  }

  static const _audioExtSet = {
    'mp3', 'flac', 'aac', 'wav', 'm4a', 'aiff', 'aif', 'ogg', 'opus',
    'wma', 'ape', 'alac', 'mid', 'amr'
  };

  /// 是否视频(用于库筛选)。本地按后缀；B站=视频；在线按 _onlineIsVideo。
  bool get isVideoTrack {
    if (isLocal) return !_audioExtSet.contains(ext.toLowerCase());
    if (bvid != null) return true;
    return _onlineIsVideo();
  }

  /// 仅本地/直链可用；B站曲目在播放前异步解析。
  PlaybackSource toSource() => isLocal
      ? PlaybackSource.local(localPath!)
      : PlaybackSource.stream(url!, const {
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        }, title: name, isVideo: _onlineIsVideo(), coverUrl: pic.isEmpty ? null : pic);

  // 在线 URL 按扩展名判断音/视频：音频后缀→封面，其余(含无后缀/m3u8/mp4)→视频画面。
  bool _onlineIsVideo() {
    final u = (url ?? '').split('?').first.toLowerCase();
    const audioExts = {
      'mp3', 'flac', 'aac', 'wav', 'm4a', 'aiff', 'aif', 'ogg', 'opus',
      'wma', 'ape', 'alac', 'mid', 'amr'
    };
    final ext = u.contains('.') ? u.split('.').last : '';
    return !audioExts.contains(ext);
  }

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
        if (cid != null) 'cid': cid, // 多 P 视频要记住具体分 P
      };

  static Track fromJson(Map<String, dynamic> j) {
    if (j['localPath'] != null) return Track.local(j['localPath'] as String);
    if (j['bvid'] != null) {
      return Track.bili(j['name'] as String, j['bvid'] as String,
          tag: (j['tag'] as String?) ?? '', cid: j['cid'] as String?);
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

  // 封号拦截：被管理台封禁的设备进入即挡，显示提示+客服电话+联系管理员按钮。
  bool _banned = false;
  String _banMsg = '账号已被封，请联系管理员';
  String _banPhone = '17713538952';

  final List<Track> _localTracks = [];
  final List<Track> _onlineTracks = [];
  final BilibiliService _bili = BilibiliService();
  final PlatformService _platform = PlatformService();
  final List<Track> _platformTracks = []; // 平台上传的视频(别人/自己)
  final Map<String, bool> _platIsVideo = {}; // 平台曲目 key→是否视频(服务器分类)
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
  final List<Track> _history = []; // 最近播放
  bool _shuffle = false; // 随机播放
  int _skipIntro = 0; // 片头跳过秒数
  String _profileName = ''; // 本机显示名
  String? _profileAvatar; // 本机头像路径
  final Map<String, List<int>> _bookmarks = {}; // 书签 track key→秒列表
  int _seekStep = 10; // 快进/快退步长
  String _searchOrder = ''; // B站搜索排序
  String _searchTid = ''; // F5 B站分区
  String _platformCatFilter = ''; // F3 平台分区
  String _platformSort = ''; // F4 平台排序
  List<String> _searchSuggestions = const []; // F6 搜索建议
  Timer? _suggestDebounce;
  String _localFilter = 'all'; // 库类型筛选
  final Map<String, String> _localTags = {}; // 本地标签：track key→标签
  String _tagFilter = ''; // 当前标签筛选（''=全部）
  double _listDensity = 1.0; // F24 列表密度 0.75/1.0/1.25
  bool _autoPalette = false; // F39 封面取色开关
  bool _guestMode = false; // F49 访客模式（不记录历史）
  int _watchSec = 0; // 累计观看秒
  final Map<String, double> _speeds = {}; // 倍速按视频记忆
  final Map<String, List<Track>> _playlists = {}; // 本地歌单
  bool _fadeIn = false; // 起播音量淡入
  bool _fadeOut = false; // 结束淡出
  Timer? _urlTimer; // 定时重读本机平台地址
  Timer? _banTimer; // 每5秒查封号状态(封/解封即时生效)
  bool _publicHealthy = true;
  bool _useLan = false;
  final UpdateService _update = UpdateService();
  bool _speedTesting = false; // 测网速进行中
  String? _speedResult; // 测速结果文案
  int _settingsTaps = 0; // 连点设置进后台管理
  DateTime? _lastSettingsTap;
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
  String _playMode = 'queue'; // F1 连播策略: recommend|queue|stop
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
    _loadPlayHistory();
    _loadAutoNext();
    DownloadManager.instance.loadCache(); // 加载离线缓存索引
    DownloadManager.instance.onComplete = (t) {
      if (!mounted) return;
      if (t.state == DlState.done) {
        _snack(t.cache ? '已缓存：${t.name}' : '已下载：${t.name}');
      } else {
        _snack('下载失败：${t.name}');
      }
    };
    // 所有平台：启动即从 GitHub 指针拉当前公网地址，并定时刷新（隧道换址自愈）。
    _refreshPlatformUrl();
    _urlTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => _refreshPlatformUrl());
    if (Platform.isAndroid) _initAndroidChannels();
    _initOpenFileChannel(); // 「打开方式」用本 app 打开音视频文件
    _loadAppName(); // App 内显示名（后台可改）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showDisclaimer();
      _silentCheckUpdate();
    });
    _checkBan(); // 启动登记设备 + 查封号
    // 每5秒查一次封号状态：管理台一封号/解封，App 内 5 秒内即时生效。
    _banTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _checkBan());
  }

  // 登记本设备并查封号；封/解封都即时反映(双向)。离线/失败=保持现状(不误锁)。
  Future<void> _checkBan() async {
    final d = await PlatformService.checkin();
    if (d == null || !mounted) return;
    final banned = d['banned'] == true;
    if (banned == _banned) return; // 状态没变，不重建
    setState(() {
      _banned = banned;
      if (banned) {
        final m = (d['ban_msg'] ?? '').toString();
        final p = (d['ban_phone'] ?? '').toString();
        if (m.isNotEmpty) _banMsg = m;
        if (p.isNotEmpty) _banPhone = p;
      }
    });
  }

  Future<void> _contactAdmin() async {
    final ok = await PlatformService.contactAdmin();
    _snack(ok ? '已通知管理员，请耐心等待处理' : '通知失败，请直接拨打客服电话');
  }

  // 封号拦截页：占满全屏，禁用一切功能，只能联系管理员。
  Widget _bannedScreen(ColorScheme cs) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E26),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.gpp_bad_outlined,
                    color: Color(0xFFE05A4F), size: 76),
                const SizedBox(height: 20),
                const Text('账号已被封',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),
                Text(_banMsg,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 15)),
                const SizedBox(height: 10),
                Text('客服电话：$_banPhone',
                    style: TextStyle(
                        color: cs.primary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _contactAdmin,
                  icon: const Icon(Icons.support_agent),
                  label: const Text('联系管理员'),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(220, 48)),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _banPhone));
                    _snack('客服电话已复制');
                  },
                  icon: const Icon(Icons.copy, size: 16, color: Colors.white54),
                  label: const Text('复制电话',
                      style: TextStyle(color: Colors.white54)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// App 内显示名 + 官方下载网址：先用缓存即时显示，再后台拉 /version 最新（后台可改）。
  Future<void> _loadAppName() async {
    final p = await SharedPreferences.getInstance();
    final cn = p.getString('app_name_cache') ?? '';
    if (cn.isNotEmpty) appNameNotifier.value = cn;
    final cd = p.getString('download_url_cache') ?? '';
    if (cd.isNotEmpty) officialDownloadNotifier.value = cd;
    final m = await PlatformService.fetchVersionInfo();
    if (m == null) return;
    final name = (m['app_name'] ?? '') as String;
    final dl = (m['download_url'] ?? '') as String;
    if (name.isNotEmpty) {
      appNameNotifier.value = name;
      await p.setString('app_name_cache', name);
    }
    if (dl.isNotEmpty) {
      officialDownloadNotifier.value = dl;
      await p.setString('download_url_cache', dl);
    }
  }

  /// 官方下载网址：后台「下载源」配置优先（GitHub/平台），否则兜底平台下载页。
  String get _officialDownload => officialDownloadNotifier.value.isNotEmpty
      ? officialDownloadNotifier.value
      : PlatformService.downloadUrl;

  /// 系统「打开方式」选小李播放器时，原生把文件路径经此 channel 交过来播放。
  void _initOpenFileChannel() {
    if (!Platform.isMacOS && !Platform.isAndroid) return;
    const ch = MethodChannel('xiaoli/openfile');
    ch.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) {
        _openExternalFile(call.arguments as String);
      }
      return null;
    });
    // 拉取启动时缓存的待播文件（双击文件启动 app 的情况）。
    ch.invokeMethod('getPending').then((v) {
      if (v is List) {
        final paths = v.whereType<String>().toList();
        if (paths.isEmpty) return;
        for (final p in paths) {
          if (!_localTracks.any((x) => x.localPath == p)) {
            _localTracks.insert(0, Track.local(p));
          }
        }
        _saveLocal();
        if (mounted) setState(() {});
        _play(Track.local(paths.first));
      }
    }).catchError((_) {});
  }

  /// 把外部打开的单个文件加入本地库并播放。
  void _openExternalFile(String path) {
    if (path.isEmpty || !mounted) return;
    if (!_localTracks.any((x) => x.localPath == path)) {
      setState(() => _localTracks.insert(0, Track.local(path)));
      _saveLocal();
    }
    _play(Track.local(path));
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _suggestDebounce?.cancel();
    _urlTimer?.cancel();
    _banTimer?.cancel();
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
    final client = http.Client();
    try {
      progress.value = '连接中…';
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(headers);
      final resp =
          await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode >= 400) {
        closeDialog();
        _snack('下载失败 ${resp.statusCode}');
        return;
      }
      final total = resp.contentLength ?? 0;
      var received = 0;
      final sink = File(tmp).openWrite();
      try {
        await for (final chunk in resp.stream) {
          if (cancelled) break;
          sink.add(chunk);
          received += chunk.length;
          final mb = (received / 1048576).toStringAsFixed(1);
          progress.value = total > 0
              ? '下载 $mb / ${(total / 1048576).toStringAsFixed(1)} MB'
              : '下载 $mb MB';
        }
      } finally {
        await sink.close(); // 异常/取消也要关
      }
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
    } finally {
      client.close();
    }
  }

  /// 给一个在线曲目生成「解析真实流地址」的回调 + 请求头（B站异步取流，平台/直链直接给）。
  (Future<String?> Function(), Map<String, String>) _resolveFor(Track t) {
    if (t.bvid != null) {
      return (() => _bili.getMediaUrl(t.bvid!, cid: t.cid), _bili.playHeaders);
    }
    return (() async => t.url, const {
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        });
  }

  /// 缓存到本地（离线可播），后台进行，不阻塞。单个用，会弹提示。
  void _cacheVideo(Track t) {
    if (_enqueueCache(t)) _snack('已加入缓存，后台下载中…');
  }

  /// 把一个在线曲目排队缓存（不弹提示，供批量复用）。返回是否成功入队。
  bool _enqueueCache(Track t) {
    if (t.isLocal) return false;
    final (resolve, headers) = _resolveFor(t);
    // 用真实后缀命名，离线播放才能正确判定音/视频（音频→封面，视频→画面）。
    var ext = 'mp4';
    if (t.bvid == null && t.url != null) {
      final u = t.url!.split('?').first.toLowerCase();
      if (u.contains('.')) {
        final e = u.split('.').last;
        if (e.isNotEmpty && e.length <= 4) ext = e;
      }
    }
    DownloadManager.instance
        .cacheVideo(t.key, t.name, resolve, headers: headers, ext: ext);
    return true;
  }

  /// 列表顶部的「全部缓存」条：当前页有未缓存的在线视频时显示，一键全选缓存。
  Widget _batchCacheBar(List<Track> items) {
    return AnimatedBuilder(
      animation: DownloadManager.instance,
      builder: (_, __) {
        final online = items
            .where((t) =>
                !t.isLocal && !DownloadManager.instance.isCached(t.key))
            .toList();
        if (online.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
          child: Row(
            children: [
              const Icon(Icons.offline_pin_outlined,
                  size: 16, color: Colors.white54),
              const SizedBox(width: 6),
              Expanded(
                child: Text('本页 ${online.length} 个在线视频可离线缓存',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white54)),
              ),
              TextButton.icon(
                onPressed: () => _cacheBatch(online),
                icon: const Icon(Icons.download, size: 16),
                label: const Text('全部缓存'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 云端缓存：解析直链后交给平台服务器下载+备份到 GitHub（不阻塞 UI 用对话框等结果）。
  Future<void> _cloudCache(Track t) async {
    if (t.isLocal || !mounted) return;
    final (resolve, headers) = _resolveFor(t);
    var ext = 'mp4';
    if (t.bvid == null && t.url != null) {
      final u = t.url!.split('?').first.toLowerCase();
      if (u.contains('.')) {
        final e = u.split('.').last;
        if (e.isNotEmpty && e.length <= 4) ext = e;
      }
    }
    final status = ValueNotifier<String>('解析地址…');
    var open = true;
    void close() {
      if (open && mounted) {
        open = false;
        Navigator.of(context).pop();
      }
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('云端缓存中'),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (_, s, __) => Text(s),
              ),
            ),
          ],
        ),
      ),
    );
    try {
      final url = await resolve();
      if (url == null || url.isEmpty) {
        close();
        _snack('取地址失败');
        return;
      }
      status.value = '服务器下载并备份中…（大视频需等一会）';
      final err =
          await PlatformService.cloudFetch(t.name, '云端', url, headers, ext);
      close();
      _snack(err == null
          ? '已云端缓存：平台可搜到、已备份 GitHub，换设备也能看'
          : '云端缓存失败：$err');
    } catch (e) {
      close();
      _snack('云端缓存出错：$e');
    }
  }

  /// 批量缓存一组在线曲目（跳过本地/已缓存），弹一条汇总提示。
  void _cacheBatch(Iterable<Track> tracks) {
    var n = 0;
    for (final t in tracks) {
      if (!t.isLocal && !DownloadManager.instance.isCached(t.key)) {
        if (_enqueueCache(t)) n++;
      }
    }
    _snack(n == 0 ? '没有可缓存的在线视频' : '已加入缓存队列：$n 个，后台下载中');
  }

  /// 后台下载到用户选定路径，不阻塞（可去看别的视频）。
  Future<void> _bgDownload(Track t) async {
    if (t.isLocal || !mounted) return;
    final safe = t.name.replaceAll(RegExp(r'[^\w一-龥 .-]'), '_');
    final dest = await FilePicker.platform.saveFile(
      dialogTitle: '后台下载到…',
      fileName: '$safe.mp4',
    );
    if (dest == null || !mounted) return;
    final (resolve, headers) = _resolveFor(t);
    DownloadManager.instance
        .saveVideo(t.key, t.name, dest, resolve, headers: headers);
    _snack('已在后台下载，可去看别的视频');
  }

  /// 下载/缓存面板入口按钮（带活动任务角标），监听 DownloadManager 变化。
  Widget _downloadsButton() {
    return AnimatedBuilder(
      animation: DownloadManager.instance,
      builder: (_, __) {
        final n = DownloadManager.instance.activeCount;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              onPressed: _showDownloadsPanel,
              tooltip: '下载 / 离线缓存',
              icon: const Icon(Icons.download_outlined, color: Colors.white70),
            ),
            if (n > 0)
              Positioned(
                right: 4,
                top: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: accentNotifier.value,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('$n',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 下载任务 + 已缓存列表面板（底部弹层，实时刷新）。
  void _showDownloadsPanel() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF22222A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => AnimatedBuilder(
        animation: DownloadManager.instance,
        builder: (ctx, __) {
          final dm = DownloadManager.instance;
          final tasks = dm.tasks;
          final cached = dm.cached.entries.toList();
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            maxChildSize: 0.92,
            builder: (_, scroll) => Column(
              children: [
                const SizedBox(height: 10),
                Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      const Text('下载 / 离线缓存',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      const Spacer(),
                      if (tasks.any((t) =>
                          t.state == DlState.done ||
                          t.state == DlState.failed ||
                          t.state == DlState.canceled))
                        TextButton(
                            onPressed: dm.clearFinished,
                            child: const Text('清除已完成')),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: scroll,
                    children: [
                      if (tasks.isEmpty && cached.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(40),
                          child: Center(
                              child: Text('暂无下载任务\n长按曲目可「缓存(离线)」或「后台下载」',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.white38))),
                        ),
                      for (final t in tasks) _taskTile(t),
                      if (cached.isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                          child: Text('已缓存（离线可看）',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 13)),
                        ),
                      for (final e in cached)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.offline_pin,
                              color: Colors.greenAccent),
                          title: Text(e.value['name'] ?? e.key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white)),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.white38),
                            tooltip: '删除缓存',
                            onPressed: () => dm.deleteCached(e.key),
                          ),
                          onTap: () {
                            final p = e.value['path'];
                            if (p == null || !File(p).existsSync()) {
                              dm.deleteCached(e.key);
                              return;
                            }
                            Navigator.pop(ctx);
                            _play(Track.local(p));
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _taskTile(DownloadTask t) {
    final dm = DownloadManager.instance;
    IconData icon;
    Color color;
    String sub;
    switch (t.state) {
      case DlState.done:
        icon = Icons.check_circle;
        color = Colors.greenAccent;
        sub = t.cache ? '已缓存 · ${t.sizeText}' : '已保存 · ${t.sizeText}';
        break;
      case DlState.failed:
        icon = Icons.error_outline;
        color = Colors.redAccent;
        sub = '失败：${t.error ?? ''}';
        break;
      case DlState.canceled:
        icon = Icons.cancel_outlined;
        color = Colors.white38;
        sub = '已取消';
        break;
      case DlState.running:
        icon = Icons.downloading;
        color = accentNotifier.value;
        sub =
            '${(t.progress * 100).toStringAsFixed(0)}% · ${t.sizeText}';
        break;
      default:
        icon = Icons.schedule;
        color = Colors.white54;
        sub = '排队中…';
    }
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(t.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(sub, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          if (t.state == DlState.running)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: t.total > 0 ? t.progress : null,
                minHeight: 3,
                backgroundColor: Colors.white12,
              ),
            ),
        ],
      ),
      trailing: (t.state == DlState.running || t.state == DlState.queued)
          ? IconButton(
              icon: const Icon(Icons.close, color: Colors.white38),
              tooltip: '取消',
              onPressed: () => dm.cancel(t),
            )
          : IconButton(
              icon: const Icon(Icons.clear, color: Colors.white24),
              tooltip: '移除',
              onPressed: () => dm.removeTask(t),
            ),
    );
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
    final m = prefs.getString('play_mode_v1');
    if (m != null) {
      if (mounted) setState(() => _playMode = m);
    } else {
      // 从旧的 bool 开关迁移
      final v = prefs.getBool('auto_next_v1');
      if (v != null && mounted) setState(() => _playMode = v ? 'queue' : 'stop');
    }
  }

  Future<void> _savePlayMode(String m) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('play_mode_v1', m);
  }


  /// 一首播完（未单曲循环）后：B站放相关推荐，其它放队列下一首。
  Future<void> _onTrackCompleted() async {
    if (_playMode == 'stop') return;
    final cur = _current;
    if (cur == null) return;
    // 推荐模式：B站放相关推荐。
    if (_playMode == 'recommend' && cur.bvid != null) {
      final rel = await _bili.getRelated(cur.bvid!);
      if (rel.isNotEmpty && mounted) {
        final b = rel.first;
        _play(
          Track.bili(
              b.author.isEmpty ? b.title : '${b.title} - ${b.author}', b.bvid,
              pic: b.pic),
          replace: true,
        );
        return;
      }
    }
    // 队列模式（或推荐取不到时）：放队列下一首。
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
                : _navIndex == 4
                    ? _historyView(cs)
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

  static const _disclaimerDefault =
      '「小李播放器」是一款媒体播放器，仅供学习与个人使用。\n\n'
      '联网搜索内容来自公开网络平台；版权归原作者/平台所有，'
      '请勿用于任何商业或侵权用途，使用本软件产生的一切后果由使用者自行承担。\n\n'
      '点击「同意」即表示你已阅读并接受以上条款。';

  Future<void> _showDisclaimer() async {
    // 免责声明文案后台可改：用上次缓存(或内置默认)立即显示，不卡启动；同时后台拉最新供下次。
    final p = await SharedPreferences.getInstance();
    final cached = p.getString('disclaimer_text') ?? '';
    final text = cached.isNotEmpty ? cached : _disclaimerDefault;
    PlatformService.getDisclaimer().then((r) {
      if (r.isNotEmpty) p.setString('disclaimer_text', r);
    });
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('免责声明'),
        content: SingleChildScrollView(child: Text(text)),
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

  /// 测到平台服务器的下载速度（拉一段固定大小数据，算 MB/s）。
  Future<void> _runSpeedTest() async {
    setState(() {
      _speedTesting = true;
      _speedResult = '测速中…';
    });
    final client = http.Client();
    try {
      final sw = Stopwatch()..start();
      final url = '${PlatformService.current}/speedtest?mb=15';
      final req = http.Request('GET', Uri.parse(url));
      final resp =
          await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        if (mounted) {
          setState(() => _speedResult = '测速失败：HTTP ${resp.statusCode}');
        }
        return;
      }
      var bytes = 0;
      await for (final c in resp.stream) {
        bytes += c.length;
      }
      sw.stop();
      final secs = sw.elapsedMilliseconds / 1000.0;
      final mb = bytes / 1048576;
      final speed = secs > 0 ? mb / secs : 0; // MB/s
      final mbps = speed * 8; // Mbps
      final where = PlatformService.useLan ? '局域网' : '公网';
      if (mounted) {
        setState(() => _speedResult =
            '${speed.toStringAsFixed(1)} MB/s · ${mbps.toStringAsFixed(0)} Mbps · $where');
      }
    } catch (_) {
      if (mounted) setState(() => _speedResult = '测速失败：网络异常或服务器未开');
    } finally {
      client.close();
      if (mounted) setState(() => _speedTesting = false);
    }
  }

  /// 连续快速点击「设置」5 次→进入隐藏的后台管理。
  void _onSettingsTap() {
    final now = DateTime.now();
    if (_lastSettingsTap == null ||
        now.difference(_lastSettingsTap!) > const Duration(milliseconds: 1500)) {
      _settingsTaps = 1;
    } else {
      _settingsTaps++;
    }
    _lastSettingsTap = now;
    if (_settingsTaps >= 5) {
      _settingsTaps = 0;
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const _AdminPage()));
    }
  }

  /// 清空全部离线缓存（先确认，告知释放多少空间）。
  Future<void> _clearCacheConfirm() async {
    final bytes = await DownloadManager.instance.totalCacheBytes();
    if (!mounted) return;
    final mb = (bytes / 1048576).toStringAsFixed(1);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空离线缓存'),
        content: Text('将删除全部已缓存视频，释放约 $mb MB 空间。确定？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) {
      await DownloadManager.instance.clearAllCache();
      if (mounted) _snack('已清空离线缓存，释放 $mb MB');
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    // macOS/Android 支持一键自动更新（下载→替换→重启，全程不用手动）。
    final canAuto = Platform.isMacOS || Platform.isAndroid;
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
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              final uri = Uri.tryParse(info.url);
              if (uri != null) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text('前往下载'),
          ),
          if (canAuto)
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                _autoUpdate(info);
              },
              icon: const Icon(Icons.bolt, size: 18),
              label: const Text('自动更新'),
            ),
        ],
      ),
    );
  }

  /// 一键自动更新：下载对应平台安装包→替换→重启，全程无需手动。
  Future<void> _autoUpdate(UpdateInfo info) async {
    final base = PlatformService.current;
    if (Platform.isMacOS) {
      await _autoUpdateMac('$base/dl/xiaoli-mac.zip', info.version);
    } else if (Platform.isAndroid) {
      await _autoUpdateAndroid('$base/dl/xiaoli-android.apk', info.version);
    }
  }

  /// 带进度对话框下载文件到 [dest]。成功 true。[status]/[progress] 实时更新弹窗。
  Future<bool> _downloadInto(String url, String dest,
      ValueNotifier<double> progress, ValueNotifier<String> status) async {
    final client = http.Client();
    final req = http.Request('GET', Uri.parse(url));
    try {
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        status.value = '下载失败：HTTP ${resp.statusCode}';
        return false;
      }
      final total = resp.contentLength ?? 0;
      final sink = File(dest).openWrite();
      var recv = 0;
      try {
        await for (final c in resp.stream) {
          sink.add(c);
          recv += c.length;
          if (total > 0) {
            progress.value = recv / total;
            status.value =
                '下载中 ${(recv / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB';
          } else {
            status.value = '下载中 ${(recv / 1048576).toStringAsFixed(1)} MB';
          }
        }
      } finally {
        await sink.close(); // 异常路径也要关，避免句柄泄漏
      }
      return true;
    } finally {
      client.close();
    }
  }

  /// macOS：下载 zip→解压→替换 .app→重启（写一个待我退出后执行的脚本）。
  Future<void> _autoUpdateMac(String url, String version) async {
    final tmp = Directory.systemTemp.path;
    final zipPath = '$tmp/xiaoli_update_$version.zip';
    final extractDir = '$tmp/xiaoli_update_$version';
    final progress = ValueNotifier<double>(0);
    final status = ValueNotifier<String>('准备下载…');
    var dialogOpen = true;
    void close() {
      if (dialogOpen && mounted) {
        dialogOpen = false;
        Navigator.of(context).pop();
      }
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('自动更新中'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, v, __) => LinearProgressIndicator(value: v > 0 ? v : null),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, s, __) => Text(s, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
    try {
      if (!await _downloadInto(url, zipPath, progress, status)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        close();
        return;
      }
      status.value = '解压中…';
      final ed = Directory(extractDir);
      if (ed.existsSync()) ed.deleteSync(recursive: true);
      ed.createSync(recursive: true);
      final unzip =
          await Process.run('/usr/bin/unzip', ['-o', zipPath, '-d', extractDir]);
      if (unzip.exitCode != 0) {
        status.value = '解压失败';
        await Future<void>.delayed(const Duration(seconds: 2));
        close();
        return;
      }
      // 找到解压出的 .app（可能在子目录里）
      String? newApp;
      for (final e in ed.listSync(recursive: true)) {
        if (e is Directory && e.path.endsWith('.app')) {
          newApp = e.path;
          break;
        }
      }
      if (newApp == null) {
        status.value = '安装包格式异常（未找到 .app）';
        await Future<void>.delayed(const Duration(seconds: 2));
        close();
        return;
      }
      // 当前 .app = 可执行文件往上三层
      final exe = Platform.resolvedExecutable;
      final destApp = File(exe).parent.parent.parent.path;
      status.value = '安装中…即将自动重启';
      final scriptPath = '$tmp/xiaoli_update.sh';
      // 等本进程退出后再替换：先拷到 .new 验证完整，再原子替换，
      // 旧 app 只有在新 app 就位后才删除——任何一步失败都回滚并重开旧版，绝不把用户搞到没 app。
      final script = '#!/bin/bash\n'
          'PID="\$1"\n'
          'DEST="$destApp"\n'
          'NEW="$newApp"\n'
          'STAGE="\$DEST.new"\n'
          'BAK="\$DEST.bak"\n'
          'for i in \$(seq 1 60); do kill -0 "\$PID" 2>/dev/null || break; sleep 0.2; done\n'
          'sleep 0.4\n'
          'rm -rf "\$STAGE" "\$BAK"\n'
          'cp -R "\$NEW" "\$STAGE" || { open "\$DEST"; exit 1; }\n'
          'if [ ! -d "\$STAGE/Contents/MacOS" ]; then rm -rf "\$STAGE"; open "\$DEST"; exit 1; fi\n'
          'xattr -dr com.apple.quarantine "\$STAGE" 2>/dev/null\n'
          'mv "\$DEST" "\$BAK" 2>/dev/null\n'
          'mv "\$STAGE" "\$DEST" || { mv "\$BAK" "\$DEST"; open "\$DEST"; exit 1; }\n'
          'rm -rf "\$BAK"\n'
          'open "\$DEST"\n';
      File(scriptPath).writeAsStringSync(script);
      await Process.run('/bin/chmod', ['+x', scriptPath]);
      await Process.start('/bin/bash', [scriptPath, '$pid'],
          mode: ProcessStartMode.detached);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      exit(0); // 退出后脚本接管替换并重启
    } catch (e) {
      status.value = '自动更新失败：$e';
      await Future<void>.delayed(const Duration(seconds: 2));
      close();
      _snack('自动更新失败，请用「前往下载」手动更新');
    }
  }

  /// Android：下载 apk→调起系统安装器（需用户确认安装）。
  Future<void> _autoUpdateAndroid(String url, String version) async {
    final dir = await getExternalStorageDirectory();
    if (dir == null) {
      _snack('无法获取存储目录');
      return;
    }
    final apkPath = '${dir.path}/xiaoli-$version.apk';
    final progress = ValueNotifier<double>(0);
    final status = ValueNotifier<String>('准备下载…');
    var dialogOpen = true;
    void close() {
      if (dialogOpen && mounted) {
        dialogOpen = false;
        Navigator.of(context).pop();
      }
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('自动更新中'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, v, __) => LinearProgressIndicator(value: v > 0 ? v : null),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, s, __) => Text(s, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
    try {
      if (!await _downloadInto(url, apkPath, progress, status)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        close();
        return;
      }
      status.value = '启动安装器…';
      await const MethodChannel('xiaoli/installer')
          .invokeMethod('install', {'path': apkPath});
      close();
    } catch (e) {
      close();
      _snack('自动更新失败：$e（可用「前往下载」手动更新）');
    }
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
    _suggestDebounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() {
        _onlineTracks.clear();
        _searchSuggestions = const [];
      });
      return;
    }
    // F6: 300ms 拉取搜索建议（防过期）。
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () async {
      final sug = await _bili.searchSuggest(v);
      if (mounted && v == _searchCtrl.text) {
        setState(() => _searchSuggestions = sug);
      }
    });
    _searchDebounce =
        Timer(const Duration(milliseconds: 500), () => _searchOnline(v));
  }

  Future<void> _searchOnline(String q) async {
    setState(() {
      _searchingOnline = true;
      _searchSuggestions = const [];
    });
    final results = await _bili.search(q, order: _searchOrder, tid: _searchTid);
    final plat = await _platform.search(q,
        cat: _platformCatFilter, sort: _platformSort);
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
              pic: b.pic,
            )));
    });
    if (results.isNotEmpty || plat.isNotEmpty) _addHistory(q);
  }

  // ---- 共享视频平台 ----
  Track _platTrack(PlatformVideo v) {
    final star = v.rating > 0 ? '★${v.rating} ' : '';
    final base = v.uploader.isEmpty ? v.title : '${v.title} · ${v.uploader}';
    return Track.online('$star$base', PlatformService.videoUrl(v.id),
        tag: '平台');
  }

  Future<void> _ratePlat(String url, int score) async {
    final id = url.split('/').last;
    final msg = await PlatformService.rate(id, score);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg ?? '评分失败')));
      _loadPlatform();
    }
  }

  Future<void> _loadPlatform() async {
    await PlatformService.loadLocal();
    final vs = await _platform.list();
    if (!mounted) return;
    setState(() {
      _platformTracks.clear();
      _platIsVideo.clear();
      for (final v in vs) {
        final t = _platTrack(v);
        _platformTracks.add(t);
        if (v.cat.isNotEmpty) _platIsVideo[t.key] = v.cat != '音乐';
      }
    });
  }

  // 类型判断：平台曲目优先用服务器分类，其余按曲目本身。
  bool _trackIsVideo(Track t) => _platIsVideo[t.key] ?? t.isVideoTrack;

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
    final uploader = _profileName.isNotEmpty
        ? _profileName
        : (_account?['uname']?.toString() ?? '匿名');
    final title = titleCtrl.text.trim().isEmpty ? fname : titleCtrl.text.trim();
    final msg = await _platform.upload(path, title, uploader);
    if (!mounted) return;
    Navigator.of(context).pop();
    _loadPlatform();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _play(Track t, {bool replace = false}) async {
    setState(() => _current = t);
    _pushPlayHistory(t);
    PlaybackSource src;
    final cachedFile = DownloadManager.instance.cachedPath(t.key);
    if (cachedFile != null && File(cachedFile).existsSync()) {
      // 已离线缓存：直接放本地文件，无需联网解析
      src = PlaybackSource.local(cachedFile, title: t.name);
    } else if (t.bvid != null) {
      // B站：先弹 loading，异步取音频流
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
      final subFut = _bili.getSubtitles(t.bvid!); // 并发取字幕，不阻塞起播
      final url = await _bili.getMediaUrl(t.bvid!, cid: t.cid);
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
          title: t.name,
          isVideo: true,
          subtitleFuture: subFut,
          coverUrl: t.pic.isEmpty ? null : t.pic);
    } else {
      src = t.toSource();
    }
    if (!mounted) return;
    _pushPlayer(t, src, replace: replace);
  }

  /// 构建并跳转到播放页。attach=true 用于从迷你条恢复——附着到已在播放的全局播放器，不重新起播。
  void _pushPlayer(Track t, PlaybackSource src,
      {bool replace = false, bool attach = false}) {
    final cachedFile = DownloadManager.instance.cachedPath(t.key);
    final route = MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(
        source: src,
        attach: attach,
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
        startAt: Duration(seconds: _resume[t.key] ?? _skipIntro),
        onSavePos: (sec) {
          _resume[t.key] = sec;
          _watchSec += 5;
          _saveResume();
        },
        onLoadDanmaku: t.bvid != null ? () => _bili.getDanmaku(t.bvid!) : null,
        onPostDanmaku: t.bvid != null
            ? (msg, ms, color) =>
                _bili.postDanmaku(t.bvid!, msg, ms, color: color)
            : null,
        onLike: t.bvid != null ? () => _bili.likeVideo(t.bvid!) : null,
        onCoin:
            t.bvid != null ? (n) => _bili.coinVideo(t.bvid!, multiply: n) : null,
        onTriple: t.bvid != null ? () => _bili.tripleVideo(t.bvid!) : null,
        bvid: t.bvid,
        // 平台视频→传 id，播放页显示「点赞/投币/收藏」三连。
        platformId:
            (t.tag == '平台' && t.url != null) ? t.url!.split('/').last : null,
        seekStep: _seekStep,
        bookmarks: _bookmarks[t.key] ?? const [],
        onSaveBookmarks: (list) {
          _bookmarks[t.key] = list;
          _saveBookmarks();
        },
        initialSpeed: _speeds[t.key] ?? 0,
        onSaveSpeed: (sp) {
          _speeds[t.key] = sp;
          _saveSpeeds();
        },
        onAddToFav: t.bvid != null ? () => _addToBiliFav(t.bvid!) : null,
        onLoadParts:
            t.bvid != null ? () => _bili.getVideoParts(t.bvid!) : null,
        onPlayPart: t.bvid != null
            ? (cid, name) =>
                _play(Track.bili(name, t.bvid!, cid: cid), replace: true)
            : null,
        onRate: t.tag == '平台' && t.url != null
            ? (score) => _ratePlat(t.url!, score)
            : null,
        onLoadSubtitleOptions:
            t.bvid != null ? () => _bili.getSubtitleOptions(t.bvid!) : null,
        onLoadMultiSubtitles:
            t.bvid != null ? () => _bili.getMultiSubtitles(t.bvid!) : null,
        // 本地/已缓存无需再缓存；其余在线视频可一键缓存离线看
        onCache: (t.isLocal || cachedFile != null)
            ? null
            : () => _cacheVideo(t),
      ),
    );
    if (replace) {
      // 自动连播：收起所有已堆叠的播放页，保持 [列表页, 当前播放页]
      Navigator.of(context).pushAndRemoveUntil(route, (r) => r.isFirst);
    } else {
      Navigator.of(context).push(route);
    }
  }

  // F46/F47: Android 原生通道——音量键换曲、接收系统分享链接。
  void _initAndroidChannels() {
    const MethodChannel('xiaoli/volume').setMethodCallHandler((call) async {
      if (call.method == 'next') {
        _next();
      } else if (call.method == 'prev') {
        _prev();
      }
      return null;
    });
    void openShared(String url) {
      if (!url.startsWith('http')) return;
      final name = Uri.tryParse(url)?.pathSegments.lastWhere(
              (s) => s.isNotEmpty,
              orElse: () => url) ??
          url;
      _play(Track.online(name, url, tag: '分享'));
    }

    const shareCh = MethodChannel('xiaoli/share');
    shareCh.setMethodCallHandler((call) async {
      if (call.method == 'onSharedUrl' && call.arguments is String) {
        openShared(call.arguments as String);
      }
      return null;
    });
    // 冷启动时主动拉一次（分享拉起 app 的场景）。
    shareCh.invokeMethod<String>('getSharedUrl').then((url) {
      if (url != null && url.isNotEmpty) openShared(url);
    }).catchError((_) {});
  }

  void _prev() {
    final list = _playQueue;
    if (_current == null || list.isEmpty) return;
    final i = list.indexWhere((t) => t.key == _current!.key);
    if (i > 0) _play(list[i - 1]);
  }

  void _next() {
    final list = _playQueue;
    if (_current == null || list.isEmpty) return;
    final i = list.indexWhere((t) => t.key == _current!.key);
    if (_shuffle && list.length > 1) {
      var j = Random().nextInt(list.length);
      if (j == i) j = (j + 1) % list.length;
      _play(list[j]);
      return;
    }
    if (i >= 0 && i < list.length - 1) _play(list[i + 1]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_banned) return _bannedScreen(cs); // 封号拦截：挡在所有功能之前
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
      bottomNavigationBar: AnimatedBuilder(
        animation: Listenable.merge(
            [PlayerHolder.i.playing, PlayerHolder.i.current]),
        builder: (_, __) => PlayerBar(
          title: _current?.name,
          subtitle: _currentSubtitle,
          isPlaying: PlayerHolder.i.playing.value,
          onPrev: _prev,
          onNext: _next,
          onPlayPause: () {
            // 全局播放器已有内容→真正暂停/继续（后台也在播）；否则从头起播。
            if (PlayerHolder.i.current.value != null) {
              PlayerHolder.i.playPause();
            } else if (_current != null) {
              _play(_current!);
            }
          },
          onTapInfo: () {
            // 点信息区→恢复播放页：若正在后台播同一内容，附着恢复(不重播)；否则重新起播。
            final src = PlayerHolder.i.current.value;
            if (src != null && _current != null) {
              _pushPlayer(_current!, src, attach: true);
            } else if (_current != null) {
              _play(_current!);
            }
          },
        ),
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
          _navIcon(Icons.history, 4, cs),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: IconButton(
              tooltip: '个人中心',
              onPressed: _openPersonalCenter,
              icon: const Icon(Icons.account_circle_outlined,
                  color: Colors.white60),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: IconButton(
              tooltip: '创作中心',
              onPressed: _openCreatorCenter,
              icon: const Icon(Icons.workspace_premium_outlined,
                  color: Colors.white60),
            ),
          ),
          _navIcon(Icons.settings, 3, cs),
          const Spacer(),
        ],
      ),
    );
  }

  void _openPersonalCenter() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _PersonalCenterPage(
        onPlay: (id, title) =>
            _play(Track.online(title, PlatformService.videoUrl(id), tag: '平台')),
      ),
    ));
  }

  void _openCreatorCenter() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _CreatorCenterPage(
        onUpload: _uploadToPlatform,
        onMyVideos: () {
          Navigator.of(context).pop();
          setState(() => _navIndex = 2);
        },
        onStats: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => StatsScreen(history: _history, watchSec: _watchSec),
        )),
        onPlay: (id, title) =>
            _play(Track.online(title, PlatformService.videoUrl(id), tag: '平台')),
      ),
    ));
  }

  Widget _navIcon(IconData icon, int index, ColorScheme cs) {
    final selected = _navIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: IconButton(
        onPressed: () {
          setState(() => _navIndex = index);
          // F26: 记住上次所在 tab。
          SharedPreferences.getInstance()
              .then((p) => p.setInt('last_nav', index));
          if (index == 3) _onSettingsTap(); // 连点设置5次→后台管理
        },
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
          PopupMenuButton<String>(
            tooltip: '排序',
            icon: const Icon(Icons.sort, color: Colors.white70),
            color: const Color(0xFF2B2B33),
            onSelected: (v) {
              if (v.startsWith('o_')) {
                setState(() =>
                    _searchOrder = v == 'o_default' ? '' : v.substring(2));
                if (_query.trim().isNotEmpty) _searchOnline(_query);
              } else if (v.startsWith('t_')) {
                setState(() =>
                    _searchTid = v == 't_0' ? '' : v.substring(2));
                SharedPreferences.getInstance()
                    .then((p) => p.setString('search_tid_v1', _searchTid));
                if (_query.trim().isNotEmpty) _searchOnline(_query);
              } else if (v.startsWith('p_')) {
                setState(() =>
                    _platformSort = v == 'p_default' ? '' : v.substring(2));
                if (_query.trim().isNotEmpty) _searchOnline(_query);
              } else if (v == 'l_name') {
                _sortLocal();
              } else if (v == 'l_recent') {
                final r = _localTracks.reversed.toList();
                setState(() => _localTracks
                  ..clear()
                  ..addAll(r));
                _saveLocalOrder();
              } else if (v == 'l_shuffle') {
                setState(() => _localTracks.shuffle());
                _saveLocalOrder();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  enabled: false,
                  child: Text('B站搜索排序',
                      style: TextStyle(color: Colors.white38, fontSize: 12))),
              CheckedPopupMenuItem(
                  value: 'o_default',
                  checked: _searchOrder == '',
                  child:
                      const Text('综合', style: TextStyle(color: Colors.white))),
              CheckedPopupMenuItem(
                  value: 'o_click',
                  checked: _searchOrder == 'click',
                  child: const Text('最多播放',
                      style: TextStyle(color: Colors.white))),
              CheckedPopupMenuItem(
                  value: 'o_pubdate',
                  checked: _searchOrder == 'pubdate',
                  child: const Text('最新发布',
                      style: TextStyle(color: Colors.white))),
              const PopupMenuDivider(),
              const PopupMenuItem(
                  enabled: false,
                  child: Text('B站分区',
                      style: TextStyle(color: Colors.white38, fontSize: 12))),
              for (final e in const [
                ['t_0', '全部', ''],
                ['t_1', '动画', '1'],
                ['t_3', '音乐', '3'],
                ['t_4', '游戏', '4'],
                ['t_11', '电视剧', '11'],
                ['t_23', '电影', '23'],
                ['t_119', '鬼畜', '119'],
              ])
                CheckedPopupMenuItem(
                    value: e[0],
                    checked: _searchTid == e[2],
                    child: Text(e[1],
                        style: const TextStyle(color: Colors.white))),
              const PopupMenuDivider(),
              const PopupMenuItem(
                  enabled: false,
                  child: Text('平台视频排序',
                      style: TextStyle(color: Colors.white38, fontSize: 12))),
              CheckedPopupMenuItem(
                  value: 'p_default',
                  checked: _platformSort == '',
                  child:
                      const Text('默认', style: TextStyle(color: Colors.white))),
              CheckedPopupMenuItem(
                  value: 'p_time',
                  checked: _platformSort == 'time',
                  child: const Text('最新上传',
                      style: TextStyle(color: Colors.white))),
              CheckedPopupMenuItem(
                  value: 'p_rating',
                  checked: _platformSort == 'rating',
                  child: const Text('评分最高',
                      style: TextStyle(color: Colors.white))),
              const PopupMenuDivider(),
              const PopupMenuItem(
                  value: 'l_name',
                  child: Text('本地按名称排序',
                      style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'l_recent',
                  child: Text('本地最近添加在前',
                      style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: 'l_shuffle',
                  child: Text('本地随机打乱',
                      style: TextStyle(color: Colors.white))),
            ],
          ),
          PopupMenuButton<String>(
            tooltip: 'B站发现',
            icon: const Icon(Icons.explore_outlined, color: Colors.white70),
            color: const Color(0xFF2B2B33),
            onSelected: (v) {
              if (v == 'fav') {
                _openFavFolders();
                return;
              }
              Future<List<BiliTrack>> Function() fn;
              String title;
              if (v == 'popular') {
                fn = () => _bili.getPopular();
                title = 'B站 热门';
              } else if (v == 'toview') {
                fn = () => _bili.getToView();
                title = '稍后再看';
              } else if (v == 'dynamic') {
                fn = () => _bili.getDynamicFeed();
                title = '关注动态';
              } else {
                fn = () => _bili.getHistory();
                title = '观看历史';
              }
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => _BiliListPage(
                      title: title,
                      fetch: fn,
                      onPlay: (bvid, t) => _play(Track.bili(t, bvid)),
                      onCacheAll: (l) =>
                          _cacheBatch(l.map((b) => Track.bili(b.title, b.bvid))))));
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'popular',
                  child:
                      Text('🔥 B站热门', style: TextStyle(color: Colors.white))),
              PopupMenuItem(
                  value: 'toview',
                  child:
                      Text('⏰ 稍后再看', style: TextStyle(color: Colors.white))),
              PopupMenuItem(
                  value: 'history',
                  child:
                      Text('🕐 观看历史', style: TextStyle(color: Colors.white))),
              PopupMenuItem(
                  value: 'dynamic',
                  child:
                      Text('📡 关注动态', style: TextStyle(color: Colors.white))),
              PopupMenuItem(
                  value: 'fav',
                  child:
                      Text('⭐ 我的收藏夹', style: TextStyle(color: Colors.white))),
            ],
          ),
          const SizedBox(width: 8),
          _downloadsButton(),
          IconButton(
            onPressed: _openUrl,
            tooltip: '打开网址 / 直播流',
            icon: const Icon(Icons.link, color: Colors.white70),
          ),
          const SizedBox(width: 4),
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
    await PlatformService.loadRemoteUrl(); // 所有平台：GitHub 指针取最新隧道地址
    await PlatformService.loadLocal(); // Mac：本机 public_url.txt 覆盖 + 探 LAN
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
    if (!Platform.isMacOS && !Platform.isWindows) return;
    var login = false, bg = false, hk = false, hidehk = false, bq = false;
    if (Platform.isMacOS) {
      try {
        final home = Platform.environment['HOME'] ?? '';
        login = File('$home/Library/LaunchAgents/$_loginPlist').existsSync();
      } catch (_) {}
    }
    try {
      bg = (await _winChannel.invokeMethod<bool>('backgroundRunEnabled')) ??
          false;
      bq = (await _winChannel.invokeMethod<bool>('blockQuitEnabled')) ?? false;
    } catch (_) {}
    if (Platform.isMacOS) {
      try {
        hk = (await _winChannel.invokeMethod<bool>('hotkeyEnabled')) ?? false;
        hidehk =
            (await _winChannel.invokeMethod<bool>('hideHotkeyEnabled')) ?? false;
      } catch (_) {}
    }
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
    _skipIntro = p.getInt('skip_intro') ?? 0;
    _profileName = p.getString('profile_name') ?? '';
    _profileAvatar = p.getString('profile_avatar');
    _seekStep = p.getInt('seek_step') ?? 10;
    _watchSec = p.getInt('watch_sec') ?? 0;
    _fadeIn = p.getBool('fade_in') ?? false;
    _fadeOut = p.getBool('fade_out') ?? false;
    textScaleNotifier.value = p.getDouble('text_scale') ?? 1.0;
    final ac = p.getInt('accent_color');
    if (ac != null) accentNotifier.value = Color(ac);
    themeModeNotifier.value =
        ThemeMode.values[(p.getInt('theme_mode') ?? 0).clamp(0, 2)];
    _searchTid = p.getString('search_tid_v1') ?? '';
    _listDensity = p.getDouble('list_density') ?? 1.0;
    _autoPalette = p.getBool('auto_palette') ?? false;
    _guestMode = p.getBool('guest_mode') ?? false;
    // F26: 启动导航。-1=记住上次；否则固定到该 tab。
    final sn = p.getInt('startup_nav') ?? -1;
    _navIndex = sn >= 0 ? sn : (p.getInt('last_nav') ?? 0);
    try {
      final tg = p.getString('local_tags_v1');
      if (tg != null) {
        (jsonDecode(tg) as Map)
            .forEach((k, v) => _localTags[k as String] = v as String);
      }
    } catch (_) {}
    try {
      final pl = p.getString('playlists_v1');
      if (pl != null) {
        (jsonDecode(pl) as Map).forEach((k, v) => _playlists[k as String] =
            (v as List)
                .map((e) => Track.fromJson(e as Map<String, dynamic>))
                .where((t) => t.isValid)
                .toList());
      }
    } catch (_) {}
    try {
      final sm = p.getString('speeds_v1');
      if (sm != null) {
        (jsonDecode(sm) as Map)
            .forEach((k, v) => _speeds[k as String] = (v as num).toDouble());
      }
    } catch (_) {}
    try {
      final bm = p.getString('bookmarks_v1');
      if (bm != null) {
        (jsonDecode(bm) as Map).forEach((k, v) =>
            _bookmarks[k as String] =
                (v as List).map((e) => (e as num).toInt()).toList());
      }
    } catch (_) {}
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
    await p.setInt('watch_sec', _watchSec);
  }

  Future<void> _saveBookmarks() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('bookmarks_v1', jsonEncode(_bookmarks));
  }

  Future<void> _saveSpeeds() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('speeds_v1', jsonEncode(_speeds));
  }

  Future<void> _savePlaylists() async {
    final p = await SharedPreferences.getInstance();
    final m = _playlists.map(
        (k, v) => MapEntry(k, v.map((t) => t.toJson()).toList()));
    await p.setString('playlists_v1', jsonEncode(m));
  }

  Future<void> _saveLocalOrder() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        _prefsKey, _localTracks.map((t) => t.localPath!).toList());
  }

  Future<void> _importFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    const exts = {
      'mp4', 'mkv', 'mov', 'webm', 'avi', 'ts', 'flv', 'm4v', 'mp3', 'm4a',
      'aac', 'flac', 'wav', 'ogg', 'opus', 'wma', 'aiff', 'ape'
    };
    var added = 0;
    try {
      await for (final e
          in Directory(dir).list(recursive: true, followLinks: false)) {
        if (e is File) {
          final pth = e.path;
          final ext = pth.contains('.') ? pth.split('.').last.toLowerCase() : '';
          if (exts.contains(ext) &&
              !_localTracks.any((t) => t.localPath == pth)) {
            _localTracks.add(Track.local(pth));
            added++;
          }
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
    await _saveLocalOrder();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已导入 $added 个媒体文件')));
  }

  Future<void> _cleanupLocal() async {
    final before = _localTracks.length;
    _localTracks.removeWhere(
        (t) => t.localPath != null && !File(t.localPath!).existsSync());
    final removed = before - _localTracks.length;
    if (!mounted) return;
    setState(() {});
    await _saveLocalOrder();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('清理了 $removed 个失效文件')));
  }

  Future<void> _setFadeIn(bool v) async {
    setState(() => _fadeIn = v);
    final p = await SharedPreferences.getInstance();
    await p.setBool('fade_in', v);
  }

  Future<void> _addToPlaylist(Track t) async {
    final names = _playlists.keys.toList();
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('加入歌单'),
        children: [
          for (final n in names)
            SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, n),
                child: Text('$n（${_playlists[n]!.length}）')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '__new__'),
              child: const Text('＋ 新建歌单')),
        ],
      ),
    );
    if (choice == null) return;
    var name = choice;
    if (choice == '__new__') {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('新建歌单'),
          content: TextField(controller: ctrl, autofocus: true),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('创建')),
          ],
        ),
      );
      if (ok != true || ctrl.text.trim().isEmpty) return;
      name = ctrl.text.trim();
    }
    final list = _playlists[name] ??= [];
    if (!list.any((x) => x.key == t.key)) list.add(t);
    await _savePlaylists();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已加入歌单「$name」')));
    }
  }

  Future<void> _setSkipIntro() async {
    final ctrl = TextEditingController(text: '$_skipIntro');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('片头跳过秒数'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '0 = 关闭'),
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
    final v = int.tryParse(ctrl.text.trim()) ?? 0;
    setState(() => _skipIntro = v < 0 ? 0 : v);
    final p = await SharedPreferences.getInstance();
    await p.setInt('skip_intro', _skipIntro);
  }

  Future<void> _sortLocal() async {
    setState(() => _localTracks.sort((a, b) => a.name.compareTo(b.name)));
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        _prefsKey, _localTracks.map((t) => t.localPath!).toList());
  }

  Future<void> _backup() async {
    final data = {
      'favorites': _favorites.map((t) => t.toJson()).toList(),
      'history': _history.map((t) => t.toJson()).toList(),
      'resume': _resume,
      'bookmarks': _bookmarks,
      'profile_name': _profileName,
    };
    final path = await FilePicker.platform.saveFile(
        dialogTitle: '备份数据', fileName: '小李播放器备份.json');
    if (path == null) return;
    await File(path).writeAsString(jsonEncode(data));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已备份到 $path')));
    }
  }

  Future<void> _restore() async {
    final res = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    final path = res?.files.single.path;
    if (path == null) return;
    try {
      final data = jsonDecode(await File(path).readAsString()) as Map;
      if (data['favorites'] is List) {
        _favorites
          ..clear()
          ..addAll((data['favorites'] as List)
              .map((e) => Track.fromJson(e as Map<String, dynamic>))
              .where((t) => t.isValid));
        await _saveFavorites();
      }
      if (data['history'] is List) {
        _history
          ..clear()
          ..addAll((data['history'] as List)
              .map((e) => Track.fromJson(e as Map<String, dynamic>))
              .where((t) => t.isValid));
        await _savePlayHistory();
      }
      if (data['resume'] is Map) {
        _resume
          ..clear()
          ..addAll((data['resume'] as Map)
              .map((k, v) => MapEntry(k as String, (v as num).toInt())));
        await _saveResume();
      }
      if (data['bookmarks'] is Map) {
        _bookmarks
          ..clear()
          ..addAll((data['bookmarks'] as Map).map((k, v) => MapEntry(
              k as String,
              (v as List).map((e) => (e as num).toInt()).toList())));
        await _saveBookmarks();
      }
      if (data['profile_name'] is String) {
        _profileName = data['profile_name'] as String;
        final p = await SharedPreferences.getInstance();
        await p.setString('profile_name', _profileName);
      }
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已恢复备份')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('恢复失败：$e')));
      }
    }
  }

  Future<void> _editProfile() async {
    final ctrl = TextEditingController(text: _profileName);
    String? avatar = _profileAvatar;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('个人资料'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () async {
                  final res = await FilePicker.platform
                      .pickFiles(type: FileType.image);
                  final p = res?.files.single.path;
                  if (p != null) setD(() => avatar = p);
                },
                child: CircleAvatar(
                  radius: 38,
                  backgroundColor: Colors.black12,
                  backgroundImage:
                      avatar != null ? FileImage(File(avatar!)) : null,
                  child: avatar == null
                      ? const Icon(Icons.add_a_photo, color: Colors.white70)
                      : null,
                ),
              ),
              const SizedBox(height: 6),
              const Text('点头像换图', style: TextStyle(fontSize: 11, color: Colors.black45)),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(labelText: '显示名字'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() {
      _profileName = ctrl.text.trim();
      _profileAvatar = avatar;
    });
    final p = await SharedPreferences.getInstance();
    await p.setString('profile_name', _profileName);
    if (_profileAvatar != null) {
      await p.setString('profile_avatar', _profileAvatar!);
    } else {
      await p.remove('profile_avatar');
    }
  }

  Future<void> _changeBiliName() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改 B站 昵称'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '新昵称')),
            const SizedBox(height: 10),
            const Text(
                '⚠️ 这会真改你的 B站 账号昵称！\nB站 规则：首次免费、之后需购买改名卡，有冷却期、需手机实名绑定。失败会显示 B站 的提示。',
                style: TextStyle(fontSize: 12, color: Colors.orange)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认修改')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty) return;
    final msg = await _bili.changeUname(name);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<int?> _pickFavFolder() async {
    final folders = await _bili.getFavFolders();
    if (!mounted) return null;
    if (folders.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有收藏夹（需登录）')));
      return null;
    }
    return showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择收藏夹'),
        children: [
          for (final fo in folders)
            SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, fo['id'] as int),
                child: Text('${fo['title']}（${fo['count']}）')),
        ],
      ),
    );
  }

  Future<void> _openFavFolders() async {
    final mlid = await _pickFavFolder();
    if (mlid == null || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _BiliListPage(
            title: '收藏夹',
            fetch: () => _bili.getFavVideos(mlid),
            onPlay: (bvid, t) => _play(Track.bili(t, bvid)),
            onCacheAll: (l) =>
                _cacheBatch(l.map((b) => Track.bili(b.title, b.bvid))))));
  }

  Future<void> _addToBiliFav(String bvid) async {
    final mlid = await _pickFavFolder();
    if (mlid == null) return;
    final msg = await _bili.addToFav(bvid, mlid);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _changeBiliSign() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改 B站 签名'),
        content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: 2,
            decoration: const InputDecoration(labelText: '新个性签名')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认')),
        ],
      ),
    );
    if (ok != true) return;
    final msg = await _bili.changeSign(ctrl.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _showMyProfile() async {
    final info = await _bili.getMyProfile();
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('我的 B站 资料'),
        content: SelectableText(info),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  Future<void> _setFadeOut(bool v) async {
    setState(() => _fadeOut = v);
    final p = await SharedPreferences.getInstance();
    await p.setBool('fade_out', v);
  }

  Map<String, dynamic> _trackToJson(Track t) =>
      {'n': t.name, 'l': t.localPath, 'u': t.url, 'b': t.bvid, 't': t.tag};

  Track? _trackFromJson(Map m) {
    if (m['l'] != null) return Track.local(m['l'] as String);
    if (m['b'] != null) {
      return Track.bili((m['n'] ?? '') as String, m['b'] as String,
          tag: (m['t'] ?? '') as String);
    }
    if (m['u'] != null) {
      return Track.online((m['n'] ?? '') as String, m['u'] as String,
          tag: (m['t'] ?? '') as String);
    }
    return null;
  }

  Future<void> _loadPlayHistory() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('history_v1');
    if (raw == null || !mounted) return;
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => _trackFromJson(e as Map))
          .whereType<Track>()
          .toList();
      setState(() => _history
        ..clear()
        ..addAll(list));
    } catch (_) {}
  }

  Future<void> _savePlayHistory() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'history_v1', jsonEncode(_history.map(_trackToJson).toList()));
  }

  void _pushPlayHistory(Track t) {
    if (_guestMode) return; // F49 访客模式不记录
    _history.removeWhere((h) => h.key == t.key);
    _history.insert(0, t);
    if (_history.length > 40) _history.removeRange(40, _history.length);
    _savePlayHistory();
  }

  Future<void> _openUrl() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('打开网址 / 直播流'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://… (mp4 / m3u8 / 直播流)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('播放')),
        ],
      ),
    );
    if (ok != true) return;
    final url = ctrl.text.trim();
    if (!url.startsWith('http')) return;
    var name = '网络视频';
    final segs = Uri.tryParse(url)?.pathSegments ?? const [];
    for (final sg in segs.reversed) {
      if (sg.isNotEmpty) {
        name = sg;
        break;
      }
    }
    _play(Track.online(name, url, tag: '链接'));
  }

  Widget _historyView(ColorScheme cs) {
    if (_history.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history,
                size: 64, color: cs.primary.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            const Text('还没有播放记录',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54)),
          ],
        ),
      );
    }
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: TextButton.icon(
              onPressed: () {
                setState(() => _history.clear());
                _savePlayHistory();
              },
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('清空'),
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _history.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _trackRow(cs, _history[i], i),
          ),
        ),
      ],
    );
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

  Future<void> _followUser(BiliUser u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('关注 ${u.uname}？'),
        content: Text('${_fmtFans(u.fans)}粉丝'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('关注')),
        ],
      ),
    );
    if (ok != true) return;
    final msg = await _bili.followUp(u.mid);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
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
      onLongPress: () => _followUser(u),
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

  Widget _typeFilterBar(ColorScheme cs) {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final e in const [
            ['all', '全部'],
            ['video', '视频'],
            ['audio', '音乐'],
          ])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: FilterChip(
                label: Text(e[1]),
                selected: _localFilter == e[0],
                onSelected: (_) => setState(() => _localFilter = e[0]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tagFilterBar(ColorScheme cs) {
    final tags = _localTags.values.toSet().toList()..sort();
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            child: FilterChip(
              avatar: const Icon(Icons.label_outline, size: 16),
              label: const Text('全部标签'),
              selected: _tagFilter == '',
              onSelected: (_) => setState(() => _tagFilter = ''),
            ),
          ),
          for (final tag in tags)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: FilterChip(
                label: Text(tag),
                selected: _tagFilter == tag,
                onSelected: (_) =>
                    setState(() => _tagFilter = _tagFilter == tag ? '' : tag),
              ),
            ),
        ],
      ),
    );
  }

  // F6: 搜索建议词横条。
  Widget _suggestionsBar(ColorScheme cs) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final s in _searchSuggestions)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: ActionChip(
                avatar: const Icon(Icons.north_east, size: 14),
                label: Text(s),
                onPressed: () {
                  _searchCtrl.text = s;
                  setState(() {
                    _query = s;
                    _searchSuggestions = const [];
                  });
                  _addHistory(s);
                  _searchOnline(s);
                },
              ),
            ),
        ],
      ),
    );
  }

  // F3: 平台视频分区筛选条（全部/视频/音乐）。
  Widget _platformCatBar(ColorScheme cs) {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final e in const [
            ['', '全部'],
            ['视频', '视频'],
            ['音乐', '音乐'],
          ])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: FilterChip(
                label: Text('平台·${e[1]}'),
                selected: _platformCatFilter == e[0],
                onSelected: (_) {
                  setState(() => _platformCatFilter = e[0]);
                  if (_query.trim().isNotEmpty) _searchOnline(_query);
                },
              ),
            ),
        ],
      ),
    );
  }

  // F25: 预设主题包（强调色 + 深浅模式）一键套用。
  Future<void> _showThemePresets() async {
    const presets = [
      ['橙日', 0xFFF26B21, 0], // name, accent, themeModeIndex
      ['冰蓝夜', 0xFF4FC3F7, 2],
      ['樱花粉', 0xFFFF6F9C, 1],
      ['草原绿', 0xFF43A047, 1],
      ['暗夜紫', 0xFF7E57C2, 2],
      ['极简灰', 0xFF607D8B, 0],
      ['热血红', 0xFFE53935, 1],
      ['深海青', 0xFF00897B, 2],
    ];
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('快速主题包',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final pr in presets)
                    GestureDetector(
                      onTap: () async {
                        Navigator.pop(ctx);
                        setState(() {
                          accentNotifier.value = Color(pr[1] as int);
                          themeModeNotifier.value =
                              ThemeMode.values[pr[2] as int];
                        });
                        final p = await SharedPreferences.getInstance();
                        await p.setInt('accent_color', pr[1] as int);
                        await p.setInt('theme_mode', pr[2] as int);
                      },
                      child: Column(
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: Color(pr[1] as int),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: (pr[2] as int) == 2
                                      ? Colors.black87
                                      : Colors.white,
                                  width: 2),
                            ),
                            child: Icon(
                                (pr[2] as int) == 2
                                    ? Icons.dark_mode
                                    : (pr[2] as int) == 1
                                        ? Icons.light_mode
                                        : Icons.brightness_auto,
                                color: Colors.white70,
                                size: 18),
                          ),
                          const SizedBox(height: 4),
                          Text(pr[0] as String,
                              style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAccent() async {
    const colors = [
      0xFFF26B21, 0xFFFF3B30, 0xFFFF2D55, 0xFF007AFF, 0xFF34C759,
      0xFF00B0A0, 0xFF5856D6, 0xFFAF52DE, 0xFFFF9500, 0xFF8E8E93,
    ];
    final c = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('主题色'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final col in colors)
              GestureDetector(
                onTap: () => Navigator.pop(ctx, col),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Color(col),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: accentNotifier.value.value == col
                            ? Colors.black
                            : Colors.black12,
                        width: accentNotifier.value.value == col ? 3 : 1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (c == null) return;
    accentNotifier.value = Color(c);
    final p = await SharedPreferences.getInstance();
    await p.setInt('accent_color', c);
  }

  Widget _libraryView(ColorScheme cs) {
    final q = _query.toLowerCase();
    List<Track> items;
    if (q.isEmpty) {
      items = [..._platformTracks, ..._hotTracks, ..._localTracks];
      if (_localFilter != 'all') {
        items = items
            .where((t) => _localFilter == 'video'
                ? _trackIsVideo(t)
                : !_trackIsVideo(t))
            .toList();
      }
      if (_tagFilter.isNotEmpty) {
        items =
            items.where((t) => _localTags[t.key] == _tagFilter).toList();
      }
    } else {
      final local = [..._hotTracks, ..._localTracks]
          .where((t) => t.name.toLowerCase().contains(q))
          .toList();
      items = [...local, ..._onlineTracks];
    }
    return Column(
      children: [
        if (_searchingOnline) const LinearProgressIndicator(minHeight: 2),
        if (_query.isEmpty) _typeFilterBar(cs),
        if (_query.isEmpty && _localTags.isNotEmpty) _tagFilterBar(cs),
        if (_query.isEmpty && _searchHistory.isNotEmpty) _historyBar(cs),
        if (_query.isNotEmpty && _searchSuggestions.isNotEmpty)
          _suggestionsBar(cs),
        if (_query.isNotEmpty) _platformCatBar(cs),
        if (_query.isNotEmpty && _accountResults.isNotEmpty)
          _accountsBar(cs),
        _batchCacheBar(items),
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

  // F34: 把平台视频下载到本地，带进度对话框。
  Future<void> _downloadPlatformVideo(Track t) async {
    final id = t.url!.split('/').last;
    final safe = t.name.replaceAll(RegExp(r'[^\w一-龥 .-]'), '_');
    final dest = await FilePicker.platform
        .saveFile(dialogTitle: '保存平台视频到…', fileName: '$safe.mp4');
    if (dest == null || !mounted) return;
    final progress = ValueNotifier<String>('开始下载…');
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
      builder: (_) => AlertDialog(
        title: const Text('下载平台视频'),
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
      ),
    );
    final err = await PlatformService().downloadVideo(id, dest,
        onProgress: (recv, total) {
      final mb = (recv / 1048576).toStringAsFixed(1);
      progress.value = total > 0
          ? '$mb MB / ${(total / 1048576).toStringAsFixed(1)} MB'
          : '已下载 $mb MB';
    });
    closeDialog();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(err == null ? '已保存 $dest' : '下载失败：$err')));
  }

  void _showRowMenu(Track t, Offset pos) {
    final items = <PopupMenuEntry<String>>[
      PopupMenuItem(value: 'fav', child: Text(_isFav(t) ? '取消收藏' : '收藏')),
      const PopupMenuItem(value: 'playlist', child: Text('加入歌单')),
      const PopupMenuItem(value: 'copyname', child: Text('复制名称')),
    ];
    if (t.isLocal) {
      items.add(PopupMenuItem(
          value: 'tag',
          child: Text(_localTags.containsKey(t.key) ? '修改标签' : '设置标签')));
      items.add(const PopupMenuItem(value: 'remove', child: Text('从列表移除')));
    }
    if (t.tag == '平台' && t.url != null) {
      items.add(const PopupMenuItem(
          value: 'pdownload', child: Text('下载到本地')));
    }
    if (!t.isLocal && (t.bvid != null || t.url != null)) {
      if (DownloadManager.instance.isCached(t.key)) {
        items.add(
            const PopupMenuItem(value: 'uncache', child: Text('删除离线缓存')));
      } else {
        items.add(
            const PopupMenuItem(value: 'cache', child: Text('缓存到本地(离线)')));
      }
      items.add(const PopupMenuItem(
          value: 'cloud', child: Text('☁ 云端缓存(可分享/永久)')));
      items.add(const PopupMenuItem(value: 'bgdl', child: Text('后台下载到…')));
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
      } else if (v == 'playlist') {
        _addToPlaylist(t);
      } else if (v == 'tag') {
        _setTrackTag(t);
      } else if (v == 'pdownload') {
        _downloadPlatformVideo(t);
      } else if (v == 'cache') {
        _cacheVideo(t);
      } else if (v == 'cloud') {
        _cloudCache(t);
      } else if (v == 'uncache') {
        DownloadManager.instance.deleteCached(t.key);
        _snack('已删除离线缓存');
      } else if (v == 'bgdl') {
        _bgDownload(t);
      } else if (v == 'copyname') {
        Clipboard.setData(ClipboardData(text: t.name));
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已复制名称')));
      }
    });
  }

  Future<void> _saveLocalTags() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('local_tags_v1', jsonEncode(_localTags));
  }

  // 给本地曲目打/改标签（自定义文字），用于按标签分组浏览。
  Future<void> _setTrackTag(Track t) async {
    final cur = _localTags[t.key] ?? '';
    final ctrl = TextEditingController(text: cur);
    final existing = _localTags.values.toSet().toList()..sort();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置标签'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(hintText: '如：练歌 / 学习 / 收藏夹'),
            ),
            if (existing.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final e in existing)
                      ActionChip(
                          label: Text(e),
                          onPressed: () => Navigator.pop(ctx, e)),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          if (cur.isNotEmpty)
            TextButton(
                onPressed: () => Navigator.pop(ctx, '__clear__'),
                child: const Text('清除标签')),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (v == null) return;
    setState(() {
      if (v == '__clear__' || v.isEmpty) {
        _localTags.remove(t.key);
        if (_tagFilter.isNotEmpty && !_localTags.values.contains(_tagFilter)) {
          _tagFilter = '';
        }
      } else {
        _localTags[t.key] = v;
      }
    });
    await _saveLocalTags();
  }

  // F29: 检测本地重复文件（按文件名+大小分组），可一键移除多余项。
  Future<void> _detectDuplicates() async {
    final groups = <String, List<Track>>{};
    for (final t in _localTracks) {
      if (t.localPath == null) continue;
      final f = File(t.localPath!);
      if (!f.existsSync()) continue;
      final base = t.localPath!.split(Platform.pathSeparator).last;
      final key = '$base|${f.lengthSync()}';
      groups.putIfAbsent(key, () => []).add(t);
    }
    final dups = groups.values.where((g) => g.length > 1).toList();
    if (!mounted) return;
    if (dups.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有发现重复文件')));
      return;
    }
    // 默认保留每组第一项，其余勾选待删。
    final toRemove = <String>{};
    for (final g in dups) {
      for (var i = 1; i < g.length; i++) {
        toRemove.add(g[i].key);
      }
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('发现 ${dups.length} 组重复'),
          content: SizedBox(
            width: 360,
            height: 360,
            child: ListView(
              children: [
                for (final g in dups) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 2),
                    child: Text(
                        g.first.name.split(Platform.pathSeparator).last,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  for (final t in g)
                    CheckboxListTile(
                      dense: true,
                      value: toRemove.contains(t.key),
                      title: Text(t.localPath ?? t.name,
                          style: const TextStyle(fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      onChanged: (v) => setD(() => v == true
                          ? toRemove.add(t.key)
                          : toRemove.remove(t.key)),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('移除 ${toRemove.length} 项')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() {
      _localTracks.removeWhere((t) => toRemove.contains(t.key));
    });
    await _saveLocal();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已移除 ${toRemove.length} 个重复项')));
    }
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
    String tagText = t.tag;
    if (t.tag == '热门') tagColor = Colors.orange;
    final localTag = _localTags[t.key];
    if (localTag != null && localTag.isNotEmpty) {
      tagText = localTag;
      tagColor = cs.primary;
    }
    final icon = t.isLocal
        ? Icons.music_note
        : (t.bvid != null ? Icons.smart_display : Icons.cloud_outlined);
    return InkWell(
      onTap: () => _play(t),
      onSecondaryTapDown: (d) => _showRowMenu(t, d.globalPosition),
      child: Container(
        color: selected ? cs.primary.withOpacity(0.12) : null,
        padding:
            EdgeInsets.symmetric(horizontal: 20, vertical: 12 * _listDensity),
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
            if (tagColor != null && tagText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child:
                    Text(tagText, style: TextStyle(color: tagColor, fontSize: 12)),
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
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: TextButton.icon(
              onPressed: () {
                setState(() => _favorites.clear());
                _saveFavorites();
              },
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('清空'),
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _favorites.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _trackRow(cs, _favorites[i], i),
          ),
        ),
      ],
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
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: ValueListenableBuilder<String>(
            valueListenable: appNameNotifier,
            builder: (_, name, __) => Text('$name v2.39.10'),
          ),
          subtitle: const Text('媒体播放器 · 支持所有格式（基于 libmpv）'),
        ),
        ListTile(
          leading: CircleAvatar(
            radius: 20,
            backgroundColor: Colors.black12,
            backgroundImage:
                _profileAvatar != null ? FileImage(File(_profileAvatar!)) : null,
            child: _profileAvatar == null
                ? const Icon(Icons.person, color: Colors.white70)
                : null,
          ),
          title: Text(_profileName.isNotEmpty
              ? _profileName
              : (_account?['uname']?.toString() ?? '点击设置个人资料')),
          subtitle: const Text('修改显示名字 / 头像（上传到平台时用）',
              style: TextStyle(fontSize: 12)),
          onTap: _editProfile,
        ),
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: const Text('修改 B站 昵称'),
          subtitle: const Text('真改你的 B站 账号昵称（受 B站 规则/费用限制）',
              style: TextStyle(fontSize: 12)),
          onTap: _changeBiliName,
        ),
        ListTile(
          leading: const Icon(Icons.edit_note),
          title: const Text('修改 B站 签名'),
          subtitle: const Text('改你的 B站 个性签名',
              style: TextStyle(fontSize: 12)),
          onTap: _changeBiliSign,
        ),
        ListTile(
          leading: const Icon(Icons.account_box_outlined),
          title: const Text('我的 B站 资料'),
          subtitle: const Text('等级 / 硬币 / 关注 / 粉丝',
              style: TextStyle(fontSize: 12)),
          onTap: _showMyProfile,
        ),
        ListTile(
          leading: const Icon(Icons.queue_music),
          title: const Text('歌单'),
          subtitle: Text('${_playlists.length} 个歌单（右键曲目可加入）',
              style: const TextStyle(fontSize: 12)),
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _PlaylistsPage(
                    playlists: _playlists,
                    onPlay: _play,
                    onSave: _savePlaylists,
                    onCacheTrack: _enqueueCache)));
            setState(() {});
          },
        ),
        ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text('扫描文件夹导入'),
          subtitle: const Text('选文件夹，递归导入里面的音视频',
              style: TextStyle(fontSize: 12)),
          onTap: _importFolder,
        ),
        ListTile(
          leading: const Icon(Icons.cleaning_services_outlined),
          title: const Text('清理失效本地文件'),
          subtitle: const Text('移除文件已被删除/移动的曲目',
              style: TextStyle(fontSize: 12)),
          onTap: _cleanupLocal,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.volume_up_outlined),
          title: const Text('起播音量淡入'),
          subtitle: const Text('开始播放时音量从 0 渐入，护耳',
              style: TextStyle(fontSize: 12)),
          value: _fadeIn,
          onChanged: _setFadeIn,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.volume_down_outlined),
          title: const Text('结束淡出'),
          subtitle: const Text('接近结尾时音量渐弱',
              style: TextStyle(fontSize: 12)),
          value: _fadeOut,
          onChanged: _setFadeOut,
        ),
        ListTile(
          leading: const Icon(Icons.history_toggle_off),
          title: const Text('继续上次播放'),
          subtitle: Text(_history.isEmpty ? '暂无记录' : _history.first.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
          onTap: () {
            if (_history.isNotEmpty) _play(_history.first);
          },
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('主题色'),
          subtitle: const Text('换 app 强调色', style: TextStyle(fontSize: 12)),
          trailing: CircleAvatar(radius: 12, backgroundColor: accentNotifier.value),
          onTap: () async {
            await _pickAccent();
            setState(() {});
          },
        ),
        ListTile(
          leading: const Icon(Icons.brightness_6_outlined),
          title: const Text('深色模式'),
          subtitle: Text(
              const ['跟随系统', '浅色', '深色'][themeModeNotifier.value.index],
              style: const TextStyle(fontSize: 12)),
          trailing: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                  value: ThemeMode.system, icon: Icon(Icons.brightness_auto)),
              ButtonSegment(
                  value: ThemeMode.light, icon: Icon(Icons.light_mode)),
              ButtonSegment(
                  value: ThemeMode.dark, icon: Icon(Icons.dark_mode)),
            ],
            selected: {themeModeNotifier.value},
            showSelectedIcon: false,
            onSelectionChanged: (s) async {
              final m = s.first;
              setState(() => themeModeNotifier.value = m);
              final p = await SharedPreferences.getInstance();
              await p.setInt('theme_mode', m.index);
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.density_medium),
          title: const Text('列表密度'),
          subtitle: const Text('行高紧凑/标准/舒适', style: TextStyle(fontSize: 12)),
          trailing: SegmentedButton<double>(
            segments: const [
              ButtonSegment(value: 0.75, label: Text('紧')),
              ButtonSegment(value: 1.0, label: Text('标')),
              ButtonSegment(value: 1.25, label: Text('舒')),
            ],
            selected: {_listDensity},
            showSelectedIcon: false,
            onSelectionChanged: (s) async {
              setState(() => _listDensity = s.first);
              final p = await SharedPreferences.getInstance();
              await p.setDouble('list_density', s.first);
            },
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.palette),
          title: const Text('封面取色'),
          subtitle: const Text('播放时按封面主色临时改强调色，退出还原',
              style: TextStyle(fontSize: 12)),
          value: _autoPalette,
          onChanged: (v) async {
            setState(() => _autoPalette = v);
            final p = await SharedPreferences.getInstance();
            await p.setBool('auto_palette', v);
          },
        ),
        ListTile(
          leading: const Icon(Icons.auto_awesome),
          title: const Text('快速主题包'),
          subtitle: const Text('一键套用配色+深浅风格', style: TextStyle(fontSize: 12)),
          onTap: _showThemePresets,
        ),
        ListTile(
          leading: const Icon(Icons.format_size),
          title: const Text('界面文字大小'),
          subtitle: Slider(
            value: textScaleNotifier.value.clamp(0.8, 1.5),
            min: 0.8,
            max: 1.5,
            divisions: 7,
            label: '${(textScaleNotifier.value * 100).round()}%',
            onChanged: (v) async {
              setState(() => textScaleNotifier.value = v);
              final p = await SharedPreferences.getInstance();
              await p.setDouble('text_scale', v);
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.keyboard_alt_outlined),
          title: const Text('快捷键 / 手势速查'),
          subtitle: const Text('查看播放器快捷键与手势',
              style: TextStyle(fontSize: 12)),
          onTap: () => showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('快捷键 / 手势'),
              content: const SingleChildScrollView(
                child: Text(
                    '播放页手势：\n'
                    '· 单击画面：播放 / 暂停\n'
                    '· 双击画面：进全屏\n'
                    '· 长按画面：2 倍速快进\n'
                    '· 上下滑动：右半调音量 / 左半调亮度\n\n'
                    '播放页按钮：\n'
                    '· 🔖 加书签，⋮ 菜单可跳转/导出/音轨/弹幕设置等\n'
                    '· A-B 图标：复读片段\n'
                    '· 截图、倍速、全屏、迷你窗（mac）\n\n'
                    '全局（mac）：\n'
                    '· 设置里可设「唤起 / 隐藏」全局快捷键\n'
                    '· ⌘Q 退出（可设确认 / 密码 / 禁止退出）'),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('好')),
              ],
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.timelapse),
          title: const Text('累计观看时长'),
          subtitle: Text(
              '约 ${_watchSec ~/ 3600} 小时 ${(_watchSec % 3600) ~/ 60} 分钟',
              style: const TextStyle(fontSize: 12)),
        ),
        ListTile(
          leading: const Icon(Icons.backup_outlined),
          title: const Text('备份数据'),
          subtitle: const Text('导出 收藏/历史/书签/资料 到文件',
              style: TextStyle(fontSize: 12)),
          onTap: _backup,
        ),
        ListTile(
          leading: const Icon(Icons.restore),
          title: const Text('恢复备份'),
          subtitle: const Text('从备份文件导入',
              style: TextStyle(fontSize: 12)),
          onTap: _restore,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.shuffle),
          title: const Text('随机播放'),
          subtitle: const Text('上一首/下一首随机选',
              style: TextStyle(fontSize: 12)),
          value: _shuffle,
          onChanged: (v) => setState(() => _shuffle = v),
        ),
        ListTile(
          leading: const Icon(Icons.fast_forward),
          title: const Text('片头跳过'),
          subtitle: Text(
              _skipIntro > 0 ? '起播自动跳过 $_skipIntro 秒' : '关闭（点击设置）',
              style: const TextStyle(fontSize: 12)),
          onTap: _setSkipIntro,
        ),
        ListTile(
          leading: const Icon(Icons.forward_10),
          title: const Text('快进/快退步长'),
          subtitle: Text('当前 $_seekStep 秒（点击修改）',
              style: const TextStyle(fontSize: 12)),
          onTap: () async {
            final ctrl = TextEditingController(text: '$_seekStep');
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('快进/快退步长（秒）'),
                content: TextField(
                    controller: ctrl,
                    autofocus: true,
                    keyboardType: TextInputType.number),
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
            final v = int.tryParse(ctrl.text.trim()) ?? 10;
            setState(() => _seekStep = v < 1 ? 1 : v);
            final p = await SharedPreferences.getInstance();
            await p.setInt('seek_step', _seekStep);
          },
        ),
        ListTile(
          leading: const Icon(Icons.system_update),
          title: const Text('检查更新'),
          subtitle: const Text('检测并下载最新版本'),
          onTap: _checkUpdateManually,
        ),
        ListTile(
          leading: const Icon(Icons.speed),
          title: const Text('测网速'),
          subtitle: Text(_speedResult ?? '测试到平台服务器的下载速度'),
          trailing: _speedTesting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.chevron_right),
          onTap: _speedTesting ? null : _runSpeedTest,
        ),
        AnimatedBuilder(
          animation: DownloadManager.instance,
          builder: (_, __) {
            final n = DownloadManager.instance.cached.length;
            final active = DownloadManager.instance.activeCount;
            return ListTile(
              leading: const Icon(Icons.sd_storage_outlined),
              title: const Text('离线缓存'),
              subtitle: Text(active > 0
                  ? '$n 个已缓存 · $active 个下载中'
                  : (n == 0 ? '长按曲目可缓存视频，离线也能看' : '$n 个视频已缓存，可离线播放')),
              trailing: n == 0
                  ? const Icon(Icons.chevron_right)
                  : TextButton(
                      onPressed: _clearCacheConfirm,
                      child: const Text('清空'),
                    ),
              onTap: _showDownloadsPanel,
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.playlist_play),
          title: const Text('连播策略'),
          subtitle: const Text('一首播完（未开单曲循环）后的行为'),
        ),
        for (final e in const [
          ['recommend', 'B站推荐', '播完续播相关推荐视频'],
          ['queue', '队列下一首', '按当前列表顺序播下一首'],
          ['stop', '播完停止', '不自动连播'],
        ])
          RadioListTile<String>(
            value: e[0],
            groupValue: _playMode,
            title: Text(e[1]),
            subtitle: Text(e[2], style: const TextStyle(fontSize: 12)),
            onChanged: (v) {
              if (v == null) return;
              setState(() => _playMode = v);
              _savePlayMode(v);
            },
          ),
        SwitchListTile(
          secondary: const Icon(Icons.visibility_off_outlined),
          title: const Text('访客模式'),
          subtitle: const Text('开启后不记录播放历史', style: TextStyle(fontSize: 12)),
          value: _guestMode,
          onChanged: (v) async {
            setState(() => _guestMode = v);
            final p = await SharedPreferences.getInstance();
            await p.setBool('guest_mode', v);
          },
        ),
        ListTile(
          leading: const Icon(Icons.home_outlined),
          title: const Text('启动进入'),
          subtitle: const Text('打开应用时停留的页面', style: TextStyle(fontSize: 12)),
          onTap: () async {
            final p = await SharedPreferences.getInstance();
            final cur = p.getInt('startup_nav') ?? -1;
            if (!mounted) return;
            final v = await showDialog<int>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: const Text('启动进入'),
                children: [
                  for (final e in const [
                    [-1, '记住上次'],
                    [0, '媒体库'],
                    [1, '收藏'],
                    [2, '我的视频'],
                    [4, '历史'],
                  ])
                    RadioListTile<int>(
                      value: e[0] as int,
                      groupValue: cur,
                      title: Text(e[1] as String),
                      onChanged: (x) => Navigator.pop(ctx, x),
                    ),
                ],
              ),
            );
            if (v != null) await p.setInt('startup_nav', v);
          },
        ),
        ListTile(
          leading: const Icon(Icons.analytics_outlined),
          title: const Text('观看统计'),
          subtitle: const Text('累计观看时长 / 最近播放排行',
              style: TextStyle(fontSize: 12)),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => StatsScreen(
                history: _history, watchSec: _watchSec),
          )),
        ),
        if (!Platform.isAndroid)
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('检测重复文件'),
            subtitle: const Text('找出同名同大小的本地文件并清理',
                style: TextStyle(fontSize: 12)),
            onTap: _detectDuplicates,
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
        if (Platform.isMacOS)
          SwitchListTile(
            secondary: const Icon(Icons.power_settings_new),
            title: const Text('开机自动启动'),
            value: _launchAtLogin,
            onChanged: (v) =>
                _guard('launchAtLogin', () => _setLaunchAtLogin(v)),
          ),
        if (Platform.isMacOS || Platform.isWindows) ...[
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('后台运行'),
            subtitle: Text(
                Platform.isWindows ? '关窗口只最小化到任务栏，不退出' : '关窗口不退出，点 Dock 图标重新打开',
                style: const TextStyle(fontSize: 12)),
            value: _backgroundRun,
            onChanged: (v) =>
                _guard('backgroundRun', () => _setBackgroundRun(v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.block),
            title: const Text('禁止退出'),
            subtitle: Text(
                Platform.isWindows ? '开启后点关闭也退不出，需在此关闭' : '开启后 ⌘Q 也退不出，需在此关闭',
                style: const TextStyle(fontSize: 12)),
            value: _blockQuit,
            onChanged: (v) =>
                _guard('blockQuit', () => _setBlockQuit(v)),
          ),
        ],
        if (Platform.isMacOS) ...[
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
            '$_officialDownload\n'
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
              Clipboard.setData(ClipboardData(text: _officialDownload));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制下载网址')));
              }
            },
          ),
          onTap: () async {
            final uri = Uri.parse(_officialDownload);
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
  String _sortOrder = 'pubdate'; // F7 投稿/播放/评论排序

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
    final l = await widget.bili.getUserVideos(widget.mid, order: _sortOrder);
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
          PopupMenuButton<String>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            onSelected: (v) {
              setState(() {
                _sortOrder = v;
                _loading = true;
              });
              _load();
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                  value: 'pubdate',
                  checked: _sortOrder == 'pubdate',
                  child: const Text('最新投稿')),
              CheckedPopupMenuItem(
                  value: 'click',
                  checked: _sortOrder == 'click',
                  child: const Text('最多播放')),
              CheckedPopupMenuItem(
                  value: 'stow',
                  checked: _sortOrder == 'stow',
                  child: const Text('最多收藏')),
            ],
          ),
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

/// 个人中心：我的钱包、每日签到领币、我的收藏/点赞/投币。
class _PersonalCenterPage extends StatefulWidget {
  final void Function(String id, String title) onPlay;
  const _PersonalCenterPage({required this.onPlay});
  @override
  State<_PersonalCenterPage> createState() => _PersonalCenterPageState();
}

class _PersonalCenterPageState extends State<_PersonalCenterPage> {
  int _balance = 0;
  bool _loading = true;
  bool _signing = false;
  String _tab = 'faved'; // faved / liked / coined
  Map<String, List<String>> _ids = {'coined': [], 'liked': [], 'faved': []};
  final Map<String, PlatformVideo> _byId = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final bal = await PlatformService.getBalance();
    final ids = await PlatformService.myLists();
    final all = await PlatformService().list(); // 全平台视频，用 id 解析成卡片
    if (!mounted) return;
    _byId.clear();
    for (final v in all) {
      _byId[v.id] = v;
    }
    setState(() {
      _balance = bal;
      _ids = ids;
      _loading = false;
    });
  }

  Future<void> _sign() async {
    if (_signing) return;
    setState(() => _signing = true);
    final d = await PlatformService.signIn();
    if (!mounted) return;
    setState(() => _signing = false);
    if (d == null) {
      _toast('签到失败，请检查网络');
      return;
    }
    if (d['already'] == true) {
      _toast('今天已签到过啦，明天再来~');
    } else {
      _toast('签到成功！+${d['reward'] ?? 0} 小李兑换币');
    }
    if (d['balance'] != null) {
      setState(() => _balance = (d['balance'] as num).toInt());
    }
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
  }

  List<PlatformVideo> get _shown {
    final ids = _ids[_tab] ?? const [];
    final out = <PlatformVideo>[];
    for (final id in ids) {
      final v = _byId[id];
      if (v != null) out.add(v);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shown = _shown;
    return Scaffold(
      appBar: AppBar(
        title: const Text('个人中心'),
        actions: [
          IconButton(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 钱包卡片
                Card(
                  color: cs.primary.withValues(alpha: 0.10),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.account_balance_wallet,
                              color: cs.primary, size: 22),
                          const SizedBox(width: 8),
                          const Text('我的小李兑换币',
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                        ]),
                        const SizedBox(height: 8),
                        Text('$_balance',
                            style: TextStyle(
                                fontSize: 40,
                                fontWeight: FontWeight.bold,
                                color: cs.primary)),
                        const SizedBox(height: 6),
                        Text(
                            '🪙 投币 ${_ids['coined']?.length ?? 0}    👍 点赞 ${_ids['liked']?.length ?? 0}    ⭐ 收藏 ${_ids['faved']?.length ?? 0}',
                            style: const TextStyle(color: Colors.black54)),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _signing ? null : _sign,
                            icon: const Icon(Icons.redeem),
                            label: const Text('每日签到领币'),
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text('每天签到领兑换币，投币给喜欢的视频，改名也能花币。',
                            style:
                                TextStyle(color: Colors.black38, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // 三连分段
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'faved', label: Text('收藏'), icon: Icon(Icons.star)),
                    ButtonSegment(value: 'liked', label: Text('点赞'), icon: Icon(Icons.thumb_up)),
                    ButtonSegment(value: 'coined', label: Text('投币'), icon: Icon(Icons.monetization_on)),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (s) => setState(() => _tab = s.first),
                ),
                const SizedBox(height: 12),
                if (shown.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Center(
                        child: Text('这里还空空的，去给喜欢的视频点点吧~',
                            style: TextStyle(color: Colors.black38))),
                  )
                else
                  for (final v in shown)
                    ListTile(
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(v.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '▶ ${v.views}   🪙 ${v.coins}   👍 ${v.likes}   ⭐ ${v.favs}'),
                      onTap: () => widget.onPlay(v.id, v.title),
                    ),
                const SizedBox(height: 20),
              ],
            ),
    );
  }
}

/// 创作中心：上传作品、我的视频、数据统计、平台播放榜。
class _CreatorCenterPage extends StatefulWidget {
  final VoidCallback onUpload;
  final VoidCallback onMyVideos;
  final VoidCallback onStats;
  final void Function(String id, String title) onPlay;
  const _CreatorCenterPage(
      {required this.onUpload,
      required this.onMyVideos,
      required this.onStats,
      required this.onPlay});
  @override
  State<_CreatorCenterPage> createState() => _CreatorCenterPageState();
}

class _CreatorCenterPageState extends State<_CreatorCenterPage> {
  final _svc = PlatformService();
  List<PlatformVideo> _works = [];
  bool _loading = true;
  String _notice = ''; // 功能2：公告条
  String _query = ''; // 功能5：搜索
  String _sort = 'views'; // 功能6：排序
  String _creatorName = ''; // 功能9：创作者名字
  int _balance = 0; // 小李兑换币余额

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await _svc.list(sort: _sort);
    final notice = await PlatformService.getNotice();
    final bal = await PlatformService.getBalance();
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _works = v;
      _notice = notice;
      _balance = bal;
      _creatorName = p.getString('creator_name') ?? '';
      _loading = false;
    });
  }

  // 投币：视频币+1，钱包扣兑换币(后台可配，默认1)。可给自己的视频投币。
  Future<void> _coin(PlatformVideo v) async {
    final d = await PlatformService.coin(v.id);
    if (d == null) {
      _toast('投币失败');
      return;
    }
    if (d['ok'] == true) {
      _toast('投币成功！花费 ${d['cost'] ?? 1} 小李兑换币');
      if (mounted) {
        setState(() => _balance = ((d['balance'] ?? _balance) as num).toInt());
      }
      _load();
    } else {
      _toast('${d['error'] ?? '投币失败'}（余额 ${d['balance'] ?? 0}）');
    }
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  static String _fmtBytes(num b) {
    if (b >= 1073741824) return '${(b / 1073741824).toStringAsFixed(1)}G';
    if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(0)}M';
    return '${(b / 1024).toStringAsFixed(0)}K';
  }

  List<PlatformVideo> get _shown => _works
      .where((v) => _query.isEmpty || v.title.toLowerCase().contains(_query))
      .toList();

  // 功能3/4：上传文件（可多选批量），带进度
  Future<void> _upload({required bool multi}) async {
    final r = await FilePicker.platform
        .pickFiles(type: FileType.video, allowMultiple: multi);
    if (r == null || r.files.isEmpty) return;
    final paths = r.files.map((f) => f.path).whereType<String>().toList();
    final uploader = _creatorName.isEmpty ? '匿名' : _creatorName;
    for (var i = 0; i < paths.length; i++) {
      final name = paths[i].split(Platform.pathSeparator).last;
      final title =
          name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
      final progress = ValueNotifier<double>(0);
      var open = true;
      void close() {
        if (open && mounted) {
          open = false;
          Navigator.of(context).pop();
        }
      }

      if (mounted) {
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            title: Text('上传中 ${i + 1}/${paths.length}'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, v, __) => LinearProgressIndicator(value: v),
              ),
              const SizedBox(height: 10),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        );
      }
      try {
        await for (final p in _svc.uploadWithProgress(paths[i], title, uploader)) {
          progress.value = p;
        }
        close();
        _toast(_svc.lastUploadMessage);
      } catch (_) {
        close();
        _toast('上传失败：${_svc.lastUploadMessage}');
      }
    }
    _load();
  }

  // 功能7：删除作品
  Future<void> _delete(PlatformVideo v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除作品'),
        content: Text('从平台删除「${v.title}」？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    final done = await PlatformService.deleteVideo(v.id);
    _toast(done ? '已删除' : '删除失败');
    if (done) _load();
  }

  // 功能9：设置创作者名字（上传时用）
  Future<void> _editName() async {
    final ctrl = TextEditingController(text: _creatorName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('创作者名字'),
        content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: '上传作品时显示的名字')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    // 改名要花小李兑换币（后台可配，默认5）。先扣费，不足则拒绝。
    final sp = await PlatformService.spend('rename');
    if (sp == null || sp['ok'] != true) {
      _toast('兑换币不足，改名需 ${sp?['need'] ?? '?'} 个（当前 ${sp?['balance'] ?? 0}）。投币可赚币');
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('creator_name', ctrl.text.trim());
    if (mounted) {
      setState(() {
        _creatorName = ctrl.text.trim();
        _balance = ((sp['balance'] ?? _balance) as num).toInt();
      });
    }
    _toast('已改名，花费 ${sp['cost']} 兑换币');
  }

  // 功能10：导出作品列表
  void _export() {
    final b = StringBuffer('我的平台作品\n');
    for (final v in _works) {
      b.writeln(
          '${v.title}\t播放${v.views}\t${_fmtBytes(v.size)}\t${PlatformService.videoUrl(v.id)}');
    }
    Clipboard.setData(ClipboardData(text: b.toString()));
    _toast('作品列表已复制');
  }

  Widget _statCard(String label, String val, Color c) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
              color: c.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Text(val,
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: c)),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final views = _works.fold<int>(0, (s, v) => s + v.views);
    final size = _works.fold<int>(0, (s, v) => s + v.size);
    final rated = _works.where((v) => v.rcount > 0).toList();
    final avg = rated.isEmpty
        ? 0.0
        : rated.fold<double>(0, (s, v) => s + v.rating) / rated.length;
    final shown = _shown;
    return Scaffold(
      appBar: AppBar(title: const Text('创作中心'), actions: [
        IconButton(
            tooltip: '创作者名字',
            onPressed: _editName,
            icon: const Icon(Icons.badge_outlined)),
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
      ]),
      body: ListView(
        children: [
          // 功能2：公告条
          if (_notice.isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                const Icon(Icons.campaign, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(_notice, style: const TextStyle(fontSize: 13))),
              ]),
            ),
          // 头图
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [Color(0xFFFF5E8A), Color(0xFFB14CFF)]),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_creatorName.isEmpty ? '我的创作' : _creatorName,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.monetization_on,
                          color: Color(0xFFFFD54F), size: 18),
                      const SizedBox(width: 4),
                      Text('$_balance 小李兑换币',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ],
                ),
              ),
              const Icon(Icons.workspace_premium,
                  color: Colors.white70, size: 40),
            ]),
          ),
          // 功能1：数据概览
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              _statCard('作品', '${_works.length}', const Color(0xFFFF5E8A)),
              _statCard('总播放', '$views', const Color(0xFF7C5CFF)),
              _statCard('占用', _fmtBytes(size), const Color(0xFF36B37E)),
              _statCard('均分', avg == 0 ? '-' : avg.toStringAsFixed(1),
                  const Color(0xFFFFA726)),
            ]),
          ),
          const SizedBox(height: 8),
          // 功能3/4：上传 + 入口
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 8, runSpacing: 4, children: [
              FilledButton.icon(
                  onPressed: () => _upload(multi: false),
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('上传作品')),
              OutlinedButton.icon(
                  onPressed: () => _upload(multi: true),
                  icon: const Icon(Icons.drive_folder_upload, size: 18),
                  label: const Text('批量上传')),
              OutlinedButton.icon(
                  onPressed: widget.onMyVideos,
                  icon: const Icon(Icons.video_library_outlined, size: 18),
                  label: const Text('我的视频/B站')),
              OutlinedButton.icon(
                  onPressed: widget.onStats,
                  icon: const Icon(Icons.analytics_outlined, size: 18),
                  label: const Text('数据统计')),
              OutlinedButton.icon(
                  onPressed: _export,
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('导出作品')),
            ]),
          ),
          const Divider(height: 24),
          // 功能5/6：作品标题 + 搜索 + 排序
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Row(children: [
              const Text('我的作品',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Spacer(),
              SizedBox(
                width: 130,
                child: TextField(
                  decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: '搜索'),
                  onChanged: (s) =>
                      setState(() => _query = s.trim().toLowerCase()),
                ),
              ),
              DropdownButton<String>(
                value: _sort,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 'views', child: Text('播放')),
                  DropdownMenuItem(value: 'time', child: Text('最新')),
                  DropdownMenuItem(value: 'rating', child: Text('评分')),
                ],
                onChanged: (v) {
                  setState(() => _sort = v ?? 'views');
                  _load();
                },
              ),
            ]),
          ),
          if (_loading)
            const Padding(
                padding: EdgeInsets.all(30),
                child: Center(child: CircularProgressIndicator()))
          else if (shown.isEmpty)
            const Padding(
                padding: EdgeInsets.all(30),
                child: Center(
                    child: Text('还没有作品，点上面「上传作品」发布到平台',
                        style: TextStyle(color: Colors.black38))))
          else
            // 功能7/8：每条作品（评分 + 播放/分享/删除）
            for (final v in shown)
              ListTile(
                dense: true,
                leading: const Icon(Icons.movie_outlined),
                title: Text(v.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    '▶ ${v.views}   🪙 ${v.coins}${v.rcount > 0 ? '   ★ ${v.rating.toStringAsFixed(1)}' : ''}   ${_fmtBytes(v.size)}'),
                onTap: () => widget.onPlay(v.id, v.title),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: const Icon(Icons.monetization_on_outlined,
                        color: Color(0xFFFFA726)),
                    tooltip: '投币(花1兑换币)',
                    onPressed: () => _coin(v),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (a) {
                      if (a == 'play') {
                        widget.onPlay(v.id, v.title);
                      } else if (a == 'share') {
                        Clipboard.setData(ClipboardData(
                            text: PlatformService.videoUrl(v.id)));
                        _toast('分享链接已复制');
                      } else if (a == 'delete') {
                        _delete(v);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'play', child: Text('播放')),
                      PopupMenuItem(value: 'share', child: Text('复制分享链接')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ]),
              ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// 隐藏后台管理：连点设置5次进入。管理平台/云端视频 + 公网状态。
class _AdminPage extends StatefulWidget {
  const _AdminPage();
  @override
  State<_AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<_AdminPage> {
  final _svc = PlatformService();
  List<PlatformVideo> _videos = [];
  Map<String, dynamic> _stats = {};
  bool _loading = true;
  bool _healthy = false;
  bool _busy = false; // 正在执行某个管理动作
  String _query = ''; // 功能2：搜索过滤
  String _sort = 'time'; // 功能3：排序 time/size/name
  bool _selectMode = false; // 批次3：批量选择
  final Set<String> _selected = {};
  Map<String, dynamic> _flags = {}; // upload_enabled / auto_backup

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return; // 异步动作后可能已退出本页
    setState(() => _loading = true);
    final v = await PlatformService.adminList(); // 含隐藏 + 管理字段
    final h = await _svc.publicHealthy();
    final s = await PlatformService.adminGet('stats'); // 功能1：统计
    final f = await PlatformService.adminGet('flags'); // 批次3：开关状态
    if (!mounted) return;
    setState(() {
      _videos = v;
      _healthy = h;
      _stats = s ?? {};
      _flags = f ?? {};
      _loading = false;
    });
  }

  // 过滤+排序后的列表（功能2/3）。
  List<PlatformVideo> get _shown {
    var l = _videos
        .where((v) => _query.isEmpty || v.title.toLowerCase().contains(_query))
        .toList();
    if (_sort == 'size') {
      l.sort((a, b) => b.size.compareTo(a.size));
    } else if (_sort == 'name') {
      l.sort((a, b) => a.title.compareTo(b.title));
    } else if (_sort == 'views') {
      l.sort((a, b) => b.views.compareTo(a.views));
    } else {
      l.sort((a, b) => b.ts.compareTo(a.ts));
    }
    // 置顶的排最前
    l.sort((a, b) => (b.pinned ? 1 : 0).compareTo(a.pinned ? 1 : 0));
    return l;
  }

  static String _fmtBytes(num b) {
    if (b >= 1073741824) return '${(b / 1073741824).toStringAsFixed(2)} GB';
    if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(1)} MB';
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '$b B';
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _run(String label, Future<bool> Function() action) async {
    setState(() => _busy = true);
    final ok = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(ok ? '$label 完成' : '$label 失败');
  }

  Future<void> _refreshUrl() async {
    await PlatformService.loadRemoteUrl(); // 功能(刷新地址)
    await PlatformService.loadLocal();
    await _load();
    _toast('已刷新公网地址');
  }

  Future<void> _republish() => _run('重发公网地址到 GitHub', () async {
        final d = await PlatformService.adminGet('republish');
        return d?['ok'] == true;
      }); // 功能8

  Future<void> _rebackup() => _run('补全 GitHub 备份', () async {
        final d = await PlatformService.adminGet('rebackup');
        if (d?['ok'] == true) {
          _toast('已排队备份 ${d?['queued'] ?? 0} 个，稍后刷新');
          return true;
        }
        return false;
      }); // 功能9

  Future<void> _restartTunnel() async {
    final ok = await _confirm('重启隧道', '会断开当前公网地址、约1分钟后换新地址（自动发布）。继续？');
    if (ok != true) return;
    await _run('重启隧道', () async {
      final d = await PlatformService.adminGet('tunnel', params: {'action': 'restart'});
      return d?['ok'] == true;
    }); // 功能7
  }

  Future<void> _clearAll() async {
    final ok = await _confirm('清空全部视频', '将删除平台上全部 ${_videos.length} 个视频（本地文件）。不可恢复！继续？');
    if (ok != true) return;
    await _run('清空全部', () async {
      final d = await PlatformService.adminGet('clear');
      if (d?['ok'] == true) {
        await _load();
        return true;
      }
      return false;
    }); // 功能(清空全部)
  }

  Future<void> _showLog() async {
    // 功能10：查看服务器/隧道日志。future 只在切换来源时重算，不随每次 rebuild 重拉。
    var which = 'server';
    Future<Map<String, dynamic>?>? fut;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          fut ??= PlatformService.adminGet('log',
              params: {'which': which, 'n': '200'});
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.7,
            builder: (_, scroll) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(children: [
                    const SizedBox(width: 8),
                    const Text('日志',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    for (final w in const ['server', 'tunnel', 'keepalive'])
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: ChoiceChip(
                          label: Text(w, style: const TextStyle(fontSize: 12)),
                          selected: which == w,
                          onSelected: (_) => setSheet(() {
                            which = w;
                            fut = PlatformService.adminGet('log',
                                params: {'which': w, 'n': '200'});
                          }),
                        ),
                      ),
                  ]),
                ),
                Expanded(
                  child: FutureBuilder<Map<String, dynamic>?>(
                    future: fut,
                    builder: (_, snap) {
                      final log = (snap.data?['log'] ??
                              (snap.connectionState == ConnectionState.waiting
                                  ? '加载中…'
                                  : '(无)'))
                          .toString();
                      return SingleChildScrollView(
                        controller: scroll,
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(log,
                            style: const TextStyle(
                                fontSize: 11, fontFamily: 'monospace')),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<bool?> _confirm(String title, String msg) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(msg),
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

  Future<void> _rename(PlatformVideo v) async {
    // 功能6：重命名
    final ctrl = TextEditingController(text: v.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final t = ctrl.text.trim();
    if (t.isEmpty) return;
    final d =
        await PlatformService.adminGet('rename', params: {'id': v.id, 'title': t});
    _toast(d?['ok'] == true ? '已重命名' : '重命名失败');
    if (d?['ok'] == true) _load();
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    _toast('已复制$what');
  }

  Future<void> _delete(PlatformVideo v) async {
    final ok = await _confirm('删除视频', '删除「${v.title}」？平台和 GitHub 备份都会一并删除。');
    if (ok != true) return;
    final done = await PlatformService.deleteVideo(v.id);
    _toast(done ? '已删除' : '删除失败');
    if (done) _load();
  }

  // 功能11/12：在线改「更新说明」/「公告栏」（持久化到服务器 config）。
  Future<void> _editCfg(String key, String title, String cur) async {
    final ctrl = TextEditingController(text: cur);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: ctrl, autofocus: true, maxLines: 4, minLines: 1),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final d = await PlatformService.adminGet('set-$key',
        params: {'v': ctrl.text.trim()});
    _toast(d?['ok'] == true ? '$title 已保存' : '保存失败');
    if (d?['ok'] == true) _load();
  }

  // 后台直接改某视频的投币数（给自己刷币 / 纠错）。
  Future<void> _setCoins(PlatformVideo v) async {
    final ctrl = TextEditingController(text: '${v.coins}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('改投币数 · ${v.title}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: '投币数', helperText: '直接设为该数值（0 起）'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final n = int.tryParse(ctrl.text.trim());
    if (n == null || n < 0) {
      _toast('请输入 ≥0 的整数');
      return;
    }
    final d = await PlatformService.adminGet('set-coins',
        params: {'id': v.id, 'n': '$n'});
    _toast(d?['ok'] == true ? '投币数已改为 ${d?['coins'] ?? n}' : '改失败');
    if (d?['ok'] == true) _load();
  }

  // 功能价格：表单面板（改名/投币花费 + 新用户起始余额），不再手填 JSON。
  Future<void> _editPrices() async {
    // 当前价格：prices 可能是 JSON 字符串或空。
    var prices = <String, dynamic>{};
    final raw = (_stats['prices'] ?? '').toString();
    if (raw.trim().isNotEmpty) {
      try {
        final p = jsonDecode(raw);
        if (p is Map) prices = Map<String, dynamic>.from(p);
      } catch (_) {}
    }
    int cur(String k, int dft) {
      final x = prices[k];
      if (x is num) return x.toInt();
      return int.tryParse('${x ?? ''}') ?? dft;
    }

    final rename = TextEditingController(text: '${cur('rename', 5)}');
    final coin = TextEditingController(text: '${cur('coin', 1)}');
    final start = TextEditingController(
        text: '${int.tryParse('${_stats['start_balance'] ?? 100}') ?? 100}');
    Widget field(String label, String hint, TextEditingController c) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: label,
                helperText: hint,
                border: const OutlineInputBorder()),
          ),
        );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('功能价格（小李兑换币）'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            field('改创作者名 花费', '默认 5', rename),
            field('投一次币 花费', '默认 1', coin),
            field('新用户起始余额', '默认 100', start),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    int nn(TextEditingController c, int dft) {
      final x = int.tryParse(c.text.trim());
      return (x == null || x < 0) ? dft : x;
    }

    final pj = jsonEncode({'rename': nn(rename, 5), 'coin': nn(coin, 1)});
    final d1 = await PlatformService.adminGet('set-prices', params: {'v': pj});
    final d2 = await PlatformService.adminGet('set-start-balance',
        params: {'v': '${nn(start, 100)}'});
    _toast((d1?['ok'] == true && d2?['ok'] == true) ? '价格已保存' : '保存失败');
    if (d1?['ok'] == true) _load();
  }

  // 功能13：孤儿文件清理。
  Future<void> _cleanOrphans() => _run('清理孤儿文件', () async {
        final d = await PlatformService.adminGet('clean-orphans');
        if (d?['ok'] == true) {
          _toast('清理 ${d?['removed'] ?? 0} 个，释放 ${_fmtBytes((d?['freed'] ?? 0) as num)}');
          return true;
        }
        return false;
      });

  // 功能14：导出 index.json 备份（复制到剪贴板）。
  Future<void> _exportIndex() async {
    final d = await PlatformService.adminGet('export');
    if (d?['index'] == null) {
      _toast('导出失败');
      return;
    }
    _copy(jsonEncode({'index': d!['index'], 'config': d['config']}),
        'index 备份(JSON)');
  }

  // 功能15：重启服务器。
  Future<void> _restartServer() async {
    final ok = await _confirm('重启服务器', '会短暂中断，keepalive 会自动拉起。继续？');
    if (ok != true) return;
    await PlatformService.adminGet('restart-server');
    _toast('服务器重启中…几秒后刷新');
  }

  // 功能16：服务器信息。
  Future<void> _sysinfo() async {
    final d = await PlatformService.adminGet('sysinfo');
    if (d == null || !mounted) {
      _toast('取信息失败');
      return;
    }
    final up = (d['uptime_sec'] ?? 0) as num;
    final h = (up ~/ 3600), m = ((up % 3600) ~/ 60);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('服务器信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('版本', '${d['version']}'),
            _kv('运行', '${h}h ${m}m'),
            _kv('Python', '${d['python']}'),
            _kv('系统', '${d['platform']}'),
            _kv('目录', '${d['root']}'),
            _kv('视频数', '${d['video_count']}'),
            _kv('公网', '${d['public_url']}'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  // 功能17/18：隐藏/显示、置顶/取消。
  Future<void> _toggleFlag(PlatformVideo v, String flag, bool on) async {
    final d = await PlatformService.adminGet(flag,
        params: {'id': v.id, 'on': on ? '1' : '0'});
    if (d?['ok'] == true) _load();
  }

  // 功能19：视频详情。
  Future<void> _detail(PlatformVideo v) async {
    final when = v.ts > 0
        ? DateTime.fromMillisecondsSinceEpoch(v.ts * 1000).toString().substring(0, 19)
        : '未知';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('上传者', v.uploader.isEmpty ? '匿名' : v.uploader),
            _kv('分类', v.cat),
            _kv('大小', _fmtBytes(v.size)),
            _kv('播放量', '${v.views}'),
            _kv('上传时间', when),
            _kv('GitHub备份', v.ghUrl != null ? '已备份 ✓' : '未备份'),
            _kv('状态',
                '${v.hidden ? '已隐藏 ' : ''}${v.pinned ? '已置顶' : ''}'.trim().isEmpty ? '正常' : '${v.hidden ? '已隐藏 ' : ''}${v.pinned ? '已置顶' : ''}'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () {
                _copy(PlatformService.videoUrl(v.id), '直链');
                Navigator.pop(ctx);
              },
              child: const Text('复制直链')),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  // 功能21：改上传者(+标题)
  Future<void> _editUploader(PlatformVideo v) async {
    final tc = TextEditingController(text: v.title);
    final uc = TextEditingController(text: v.uploader);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: tc,
              decoration: const InputDecoration(labelText: '标题')),
          TextField(
              controller: uc,
              decoration: const InputDecoration(labelText: '上传者')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final d = await PlatformService.adminGet('edit', params: {
      'id': v.id,
      'title': tc.text.trim(),
      'uploader': uc.text.trim(),
    });
    _toast(d?['ok'] == true ? '已保存' : '保存失败');
    if (d?['ok'] == true) _load();
  }

  // 功能22：下载平台视频到本地
  Future<void> _downloadVideo(PlatformVideo v) async {
    final safe = v.title.replaceAll(RegExp(r'[^\w一-龥 .-]'), '_');
    final dest = await FilePicker.platform
        .saveFile(dialogTitle: '保存到…', fileName: '$safe.mp4');
    if (dest == null || !mounted) return;
    _toast('开始下载…');
    final err = await PlatformService().downloadVideo(v.id, dest);
    _toast(err == null ? '已保存到 $dest' : '下载失败：$err');
  }

  // 功能23：导入/恢复 index
  Future<void> _import() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入/恢复 index'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('粘贴之前「导出index」复制的 JSON（会替换当前全部记录）',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          TextField(
              controller: ctrl,
              maxLines: 5,
              decoration: const InputDecoration(border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;
    final txt = ctrl.text.trim();
    if (txt.isEmpty) return;
    final n = await PlatformService.adminImport(txt);
    _toast(n != null ? '已导入 $n 条' : '导入失败(JSON 格式?)');
    if (n != null) _load();
  }

  // 功能24/25：公网上传开关 / 云端自动备份开关
  Future<void> _setFlag(String key, bool on) async {
    setState(() => _flags[key] = on); // 乐观更新
    final d = await PlatformService.adminGet('set-flag',
        params: {'key': key, 'on': on ? '1' : '0'});
    if (d?['ok'] != true) {
      _toast('切换失败');
      _load();
    }
  }

  // 功能26：一键体检
  Future<void> _healthCheck() async {
    setState(() => _busy = true);
    final d = await PlatformService.adminGet('health-check');
    if (!mounted) return;
    setState(() => _busy = false);
    if (d == null) {
      _toast('体检失败');
      return;
    }
    Widget row(String k, bool? ok) => _kv(k, ok == true ? '正常 ✓' : '异常 ✗',
        color: ok == true ? Colors.green : Colors.red);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('一键体检'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          row('服务器', d['server'] == true),
          row('公网隧道', d['tunnel'] == true),
          row('GitHub', d['github'] == true),
          _kv('磁盘剩余', '${d['disk_free_gb'] ?? 0} GB'),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  // 功能27：最近播放记录
  Future<void> _showRecent() async {
    final d = await PlatformService.adminGet('recent');
    if (!mounted) return;
    final list = (d?['recent'] as List?) ?? [];
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text('最近播放',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          if (list.isEmpty)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                    child: Text('还没有播放记录',
                        style: TextStyle(color: Colors.black38))))
          else
            for (final e in list)
              ListTile(
                dense: true,
                leading: const Icon(Icons.play_arrow, size: 18),
                title: Text('${(e as Map)['title'] ?? ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(DateTime.fromMillisecondsSinceEpoch(
                        ((e['ts'] ?? 0) as num).toInt() * 1000)
                    .toString()
                    .substring(0, 19)),
              ),
        ],
      ),
    );
  }

  // 功能28/29：一键打开网页 / 快捷复制链接
  Future<void> _openWeb(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // 设置下一版应用文件：选平台 + 选文件上传覆盖官网下载。
  Future<void> _uploadApp() async {
    final which = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('上传哪个平台的应用文件？'),
        children: [
          for (final w in const [
            ['mac', 'macOS (.app 压缩包 zip)'],
            ['apk', 'Android (.apk)'],
            ['win', 'Windows (.zip)']
          ])
            SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, w[0]),
                child: Text(w[1])),
        ],
      ),
    );
    if (which == null) return;
    final r = await FilePicker.platform.pickFiles();
    final path = r?.files.single.path;
    if (path == null) return;
    setState(() => _busy = true);
    final ok = await PlatformService.uploadAppFile(which, path);
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(ok ? '已设为下一版 $which 应用文件' : '上传失败');
  }

  // 批次4：回收站
  Future<void> _showTrash() async {
    final d = await PlatformService.adminGet('trash');
    if (!mounted) return;
    final trash = (d?['trash'] as List?) ?? [];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          builder: (_, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  const Text('回收站',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const Spacer(),
                  if (trash.isNotEmpty)
                    TextButton(
                        onPressed: () async {
                          final ok = await _confirm('清空回收站',
                              '永久删除回收站里 ${trash.length} 个（含 GitHub 备份），不可恢复！');
                          if (ok != true) return;
                          await PlatformService.adminGet('empty-trash');
                          if (ctx.mounted) Navigator.pop(ctx);
                          _toast('回收站已清空');
                        },
                        child: const Text('清空',
                            style: TextStyle(color: Colors.red))),
                ]),
              ),
              Expanded(
                child: trash.isEmpty
                    ? const Center(
                        child: Text('回收站是空的',
                            style: TextStyle(color: Colors.black38)))
                    : ListView(
                        controller: scroll,
                        children: [
                          for (final v in trash)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.delete_outline),
                              title: Text('${(v as Map)['title'] ?? ''}',
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: TextButton(
                                child: const Text('恢复'),
                                onPressed: () async {
                                  await PlatformService.adminGet('restore',
                                      params: {'id': '${v['id']}'});
                                  if (!ctx.mounted) return;
                                  setSheet(() => trash.remove(v));
                                  _toast('已恢复');
                                  _load();
                                },
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 批次4：索引一致性检查
  Future<void> _verify() async {
    final d = await PlatformService.adminGet('verify');
    if (d == null || !mounted) {
      _toast('检查失败');
      return;
    }
    final miss = (d['missing_files'] as List?) ?? [];
    final orph = (d['orphan_files'] as List?) ?? [];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('索引一致性检查'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('条目', '${d['entries']}'),
            _kv('文件', '${d['files']}'),
            _kv('缺文件', '${miss.length}',
                color: miss.isEmpty ? Colors.green : Colors.orange),
            _kv('孤儿文件', '${orph.length}',
                color: orph.isEmpty ? Colors.green : Colors.orange),
            if (miss.isEmpty && orph.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child:
                    Text('一切正常 ✓', style: TextStyle(color: Colors.green)),
              ),
          ],
        ),
        actions: [
          if (orph.isNotEmpty)
            TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _cleanOrphans();
                },
                child: const Text('清理孤儿')),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  // 批次4：导出统计 CSV
  void _exportCsv() {
    final b = StringBuffer('标题,上传者,大小(MB),播放量,已备份,隐藏,置顶\n');
    for (final v in _videos) {
      final t = v.title.replaceAll(',', '，');
      b.writeln('$t,${v.uploader},${(v.size / 1048576).toStringAsFixed(1)},'
          '${v.views},${v.ghUrl != null ? 1 : 0},${v.hidden ? 1 : 0},${v.pinned ? 1 : 0}');
    }
    Clipboard.setData(ClipboardData(text: b.toString()));
    _toast('统计 CSV 已复制');
  }

  // 批次4：原始配置查看
  Future<void> _showConfig() async {
    final d = await PlatformService.adminGet('get-config');
    if (!mounted) return;
    final cfg = d?['config'] ?? {};
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('服务器配置 config.json'),
        content: SingleChildScrollView(
            child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(cfg),
                style:
                    const TextStyle(fontSize: 12, fontFamily: 'monospace'))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  // 批次4：单条立即备份 / 重置播放量
  Future<void> _backupOne(PlatformVideo v) async {
    final d = await PlatformService.adminGet('backup-one', params: {'id': v.id});
    _toast(d?['ok'] == true ? '已开始备份到 GitHub' : '备份失败');
  }

  Future<void> _resetViews(PlatformVideo v) async {
    await PlatformService.adminGet('reset-views', params: {'id': v.id});
    _toast('播放量已重置');
    _load();
  }

  // 批次4：批量备份选中
  Future<void> _batchBackup() async {
    if (_selected.isEmpty) return;
    setState(() => _busy = true);
    for (final id in _selected.toList()) {
      await PlatformService.adminGet('backup-one', params: {'id': id});
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selectMode = false;
      _selected.clear();
    });
    _toast('已排队备份');
  }

  // 批次5：数据看板
  Future<void> _dashboard() async {
    final d = await PlatformService.adminGet('dashboard');
    if (d == null || !mounted) {
      _toast('加载失败');
      return;
    }
    final top = (d['top'] as List?) ?? [];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('数据看板'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('作品数', '${d['videos']}'),
            _kv('总播放', '${d['total_views']}'),
            _kv('今日播放', '${d['plays_today']}'),
            _kv('占用', _fmtBytes((d['storage'] ?? 0) as num)),
            const Divider(),
            const Text('热门 Top', style: TextStyle(fontWeight: FontWeight.bold)),
            for (final t in top)
              Text('· ${(t as Map)['title']} (▶${t['views']})',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  // 批次5：访问IP统计
  Future<void> _showIps() async {
    final d = await PlatformService.adminGet('ips');
    if (!mounted) return;
    final ips = (d?['ips'] as List?) ?? [];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('访问来源（${d?['unique'] ?? 0} 个 IP）'),
        content: SizedBox(
          width: double.maxFinite,
          child: ips.isEmpty
              ? const Text('暂无')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final e in ips.take(15))
                      _kv('${(e as Map)['ip']}', '${e['hits']} 次'),
                  ],
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  // 批次5：GitHub 备份失效检测
  Future<void> _verifyBackups() async {
    setState(() => _busy = true);
    final d = await PlatformService.adminGet('verify-backups');
    if (!mounted) return;
    setState(() => _busy = false);
    final missing = (d?['missing'] as List?) ?? [];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('GitHub 备份检测'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('标记已备份', '${d?['backed'] ?? 0}'),
            _kv('资产丢失', '${missing.length}',
                color: missing.isEmpty ? Colors.green : Colors.red),
            for (final m in missing.take(8)) Text('· $m'),
          ],
        ),
        actions: [
          if (missing.isNotEmpty)
            TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _rebackup();
                },
                child: const Text('补全备份')),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  // 批次5：批量URL导入（云端缓存）
  Future<void> _batchImport() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量导入（云端缓存）'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('每行一个视频直链，服务器会逐个下载并备份',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          TextField(
              controller: ctrl,
              maxLines: 5,
              decoration: const InputDecoration(
                  hintText: 'https://...\nhttps://...',
                  border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始')),
        ],
      ),
    );
    if (ok != true) return;
    final urls = ctrl.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.startsWith('http'))
        .toList();
    if (urls.isEmpty || !mounted) return;
    setState(() => _busy = true);
    var done = 0;
    for (final url in urls) {
      final name = url.split('/').last.split('?').first;
      final err =
          await PlatformService.cloudFetch(name.isEmpty ? '导入' : name, '导入', url, const {}, 'mp4');
      if (err == null) done++;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _toast('导入完成 $done/${urls.length}');
    _load();
  }

  // 批次5：清空日志
  Future<void> _clearLogs() async {
    final ok = await _confirm('清空日志', '清空 server/tunnel/keepalive 日志？');
    if (ok != true) return;
    for (final w in ['server', 'tunnel', 'keepalive']) {
      await PlatformService.adminGet('clear-logs', params: {'which': w});
    }
    _toast('日志已清空');
  }

  // 批次5：置顶上移/下移
  Future<void> _move(PlatformVideo v, String dir) async {
    await PlatformService.adminGet('move', params: {'id': v.id, 'dir': dir});
    _load();
  }

  // 批次5：批量改上传者（选中）
  Future<void> _batchUploader() async {
    if (_selected.isEmpty) return;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('批量改上传者（${_selected.length} 个）'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    for (final id in _selected.toList()) {
      await PlatformService.adminGet('edit',
          params: {'id': id, 'uploader': ctrl.text.trim()});
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selectMode = false;
      _selected.clear();
    });
    _toast('完成');
    _load();
  }

  // 功能20(批次3)：批量删除/隐藏选中
  Future<void> _batchAct(bool delete) async {
    if (_selected.isEmpty) return;
    final ids = _selected.toList();
    final ok = await _confirm(delete ? '批量删除' : '批量隐藏',
        '对选中的 ${ids.length} 个执行${delete ? '删除(含GitHub备份)' : '隐藏'}？');
    if (ok != true) return;
    setState(() => _busy = true);
    for (final id in ids) {
      if (delete) {
        await PlatformService.deleteVideo(id);
      } else {
        await PlatformService.adminGet('hide', params: {'id': id, 'on': '1'});
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.clear();
      _selectMode = false;
    });
    _toast('完成');
    _load();
  }

  Widget _kv(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 76,
                child: Text(k,
                    style: const TextStyle(color: Colors.black54, fontSize: 13))),
            Expanded(
                child: SelectableText(v,
                    style: TextStyle(
                        fontSize: 13,
                        color: color,
                        fontWeight: FontWeight.w500))),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final backed = (_stats['backed_up'] ?? 0);
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectMode ? '已选 ${_selected.length}' : '后台管理'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          if (_selectMode) ...[
            IconButton(
                tooltip: '备份选中到 GitHub',
                onPressed: _busy ? null : _batchBackup,
                icon: const Icon(Icons.backup_outlined)),
            IconButton(
                tooltip: '批量改上传者',
                onPressed: _busy ? null : _batchUploader,
                icon: const Icon(Icons.badge_outlined)),
            IconButton(
                tooltip: '隐藏选中',
                onPressed: _busy ? null : () => _batchAct(false),
                icon: const Icon(Icons.visibility_off)),
            IconButton(
                tooltip: '删除选中(进回收站)',
                onPressed: _busy ? null : () => _batchAct(true),
                icon: const Icon(Icons.delete, color: Colors.red)),
            IconButton(
                tooltip: '退出多选',
                onPressed: () => setState(() {
                      _selectMode = false;
                      _selected.clear();
                    }),
                icon: const Icon(Icons.close)),
          ] else ...[
            IconButton(
                tooltip: '多选',
                onPressed: () => setState(() => _selectMode = true),
                icon: const Icon(Icons.checklist)),
            IconButton(
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh)),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // 功能1：平台状态 + 存储统计
                Card(
                  margin: const EdgeInsets.all(12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('平台状态 / 存储',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(height: 8),
                        _kv('公网地址', PlatformService.current),
                        _kv('局域网', PlatformService.detectedIp ?? '未探测到'),
                        _kv('公网健康', _healthy ? '正常 ✓' : '异常 ✗',
                            color: _healthy ? Colors.green : Colors.red),
                        _kv('视频数', '${_videos.length} 条'),
                        _kv('已备份', '$backed / ${_videos.length} 到 GitHub'),
                        _kv('占用空间', _fmtBytes((_stats['videos_bytes'] ?? 0) as num)),
                        _kv('磁盘剩余',
                            '${_fmtBytes((_stats['disk_free'] ?? 0) as num)} / ${_fmtBytes((_stats['disk_total'] ?? 0) as num)}'),
                        const Divider(height: 18),
                        // 功能 7/8/9/10 + 刷新/清空
                        Wrap(spacing: 8, runSpacing: 4, children: [
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _refreshUrl,
                              icon: const Icon(Icons.cloud_sync, size: 16),
                              label: const Text('刷新地址')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _republish,
                              icon: const Icon(Icons.publish, size: 16),
                              label: const Text('重发地址')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _restartTunnel,
                              icon: const Icon(Icons.restart_alt, size: 16),
                              label: const Text('重启隧道')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _rebackup,
                              icon: const Icon(Icons.backup, size: 16),
                              label: const Text('补全备份')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _showLog,
                              icon: const Icon(Icons.article_outlined, size: 16),
                              label: const Text('看日志')),
                          // 批次2 新增
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editCfg('notes', '改更新说明',
                                      (_stats['notes'] ?? '').toString()),
                              icon: const Icon(Icons.edit_note, size: 16),
                              label: const Text('改更新说明')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editCfg('notice', '改公告栏',
                                      (_stats['notice'] ?? '').toString()),
                              icon: const Icon(Icons.campaign_outlined, size: 16),
                              label: const Text('公告栏')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editCfg('disclaimer', '改免责声明',
                                      (_stats['disclaimer'] ?? '').toString()),
                              icon: const Icon(Icons.gavel_outlined, size: 16),
                              label: const Text('改免责声明')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editCfg('app-version', '改应用版本号(留空=用内置)',
                                      (_stats['app_version'] ?? '').toString()),
                              icon: const Icon(Icons.numbers, size: 16),
                              label: const Text('改版本号')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _uploadApp,
                              icon: const Icon(Icons.system_update_alt, size: 16),
                              label: const Text('上传应用文件')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _cleanOrphans,
                              icon: const Icon(Icons.cleaning_services_outlined,
                                  size: 16),
                              label: const Text('清理孤儿')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _exportIndex,
                              icon: const Icon(Icons.download_outlined, size: 16),
                              label: const Text('导出index')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _import,
                              icon: const Icon(Icons.upload_outlined, size: 16),
                              label: const Text('导入恢复')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _sysinfo,
                              icon: const Icon(Icons.info_outline, size: 16),
                              label: const Text('服务器信息')),
                          // 批次3 新增
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _healthCheck,
                              icon: const Icon(Icons.health_and_safety_outlined,
                                  size: 16),
                              label: const Text('一键体检')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _showRecent,
                              icon: const Icon(Icons.history, size: 16),
                              label: const Text('最近播放')),
                          OutlinedButton.icon(
                              onPressed: () => _openWeb(PlatformService.downloadUrl),
                              icon: const Icon(Icons.open_in_browser, size: 16),
                              label: const Text('打开下载页')),
                          OutlinedButton.icon(
                              onPressed: () =>
                                  _copy(PlatformService.current, '公网地址'),
                              icon: const Icon(Icons.copy, size: 16),
                              label: const Text('复制公网地址')),
                          // 批次4
                          OutlinedButton.icon(
                              onPressed: _showTrash,
                              icon: const Icon(Icons.delete_outline, size: 16),
                              label: const Text('回收站')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _verify,
                              icon: const Icon(Icons.fact_check_outlined, size: 16),
                              label: const Text('一致性检查')),
                          OutlinedButton.icon(
                              onPressed: _exportCsv,
                              icon: const Icon(Icons.table_chart_outlined, size: 16),
                              label: const Text('导出CSV')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _showConfig,
                              icon: const Icon(Icons.data_object, size: 16),
                              label: const Text('查看配置')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editCfg('app-name', '改应用名字(App内显示)',
                                      (_stats['app_name'] ?? '').toString()),
                              icon: const Icon(Icons.drive_file_rename_outline,
                                  size: 16),
                              label: const Text('改应用名字')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editCfg('banned', '关键词黑名单(逗号分隔，命中拒绝上传)',
                                      (_stats['banned'] ?? '').toString()),
                              icon: const Icon(Icons.block, size: 16),
                              label: const Text('黑名单')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editCfg('dl-title', '改下载页标题',
                                      (_stats['dl_title'] ?? '').toString()),
                              icon: const Icon(Icons.title, size: 16),
                              label: const Text('下载页标题')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editCfg('dl-subtitle', '改下载页副标题',
                                      (_stats['dl_subtitle'] ?? '').toString()),
                              icon: const Icon(Icons.subtitles_outlined, size: 16),
                              label: const Text('下载页副标题')),
                          // 批次5
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _dashboard,
                              icon: const Icon(Icons.dashboard_outlined, size: 16),
                              label: const Text('数据看板')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _showIps,
                              icon: const Icon(Icons.travel_explore, size: 16),
                              label: const Text('访问统计')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _verifyBackups,
                              icon: const Icon(Icons.verified_outlined, size: 16),
                              label: const Text('备份检测')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _batchImport,
                              icon: const Icon(Icons.playlist_add, size: 16),
                              label: const Text('批量导入')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _clearLogs,
                              icon: const Icon(Icons.delete_forever_outlined,
                                  size: 16),
                              label: const Text('清空日志')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editCfg('max-gb', '存储上限GB(0=无限)',
                                      (_stats['max_gb'] ?? '').toString()),
                              icon: const Icon(Icons.sd_storage, size: 16),
                              label: const Text('存储上限')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editCfg('trash-days', '回收站自动清理(天,0=不清)',
                                      (_stats['trash_days'] ?? '').toString()),
                              icon: const Icon(Icons.auto_delete_outlined, size: 16),
                              label: const Text('回收站清理')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editCfg('brand-color', '品牌色 hex(如 #ff5e8a)',
                                      (_stats['brand_color'] ?? '').toString()),
                              icon: const Icon(Icons.palette_outlined, size: 16),
                              label: const Text('品牌色')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      final cur =
                                          (_stats['download_source'] ?? 'github')
                                              .toString();
                                      final next = cur == 'github'
                                          ? 'platform'
                                          : 'github';
                                      final d = await PlatformService.adminGet(
                                          'set-download-source',
                                          params: {'v': next});
                                      _toast(d?['ok'] == true
                                          ? '下载源切到 ${next == "github" ? "GitHub" : "平台页"}'
                                          : '切换失败');
                                      if (d?['ok'] == true) _load();
                                    },
                              icon: const Icon(Icons.swap_horiz, size: 16),
                              label: Text(
                                  '下载源:${(_stats['download_source'] ?? 'github') == "github" ? "GitHub" : "平台"}')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _editPrices,
                              icon: const Icon(Icons.price_change_outlined,
                                  size: 16),
                              label: const Text('功能价格')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _restartServer,
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.orange),
                              icon: const Icon(Icons.power_settings_new, size: 16),
                              label: const Text('重启服务器')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _clearAll,
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red),
                              icon: const Icon(Icons.delete_sweep, size: 16),
                              label: const Text('清空全部')),
                        ]),
                        // 批次3：公网上传开关 / 云端自动备份开关
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('允许公网上传',
                              style: TextStyle(fontSize: 13)),
                          subtitle: const Text('关掉防陌生人乱传',
                              style: TextStyle(fontSize: 11)),
                          value: _flags['upload_enabled'] != false,
                          onChanged: (v) => _setFlag('upload_enabled', v),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('云端缓存自动备份到 GitHub',
                              style: TextStyle(fontSize: 13)),
                          value: _flags['auto_backup'] != false,
                          onChanged: (v) => _setFlag('auto_backup', v),
                        ),
                      ],
                    ),
                  ),
                ),
                // 功能2/3：搜索 + 排序
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            isDense: true,
                            prefixIcon: Icon(Icons.search, size: 20),
                            hintText: '搜索视频标题',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (s) =>
                              setState(() => _query = s.trim().toLowerCase()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<String>(
                        value: _sort,
                        items: const [
                          DropdownMenuItem(value: 'time', child: Text('最新')),
                          DropdownMenuItem(value: 'size', child: Text('大小')),
                          DropdownMenuItem(value: 'views', child: Text('播放量')),
                          DropdownMenuItem(value: 'name', child: Text('名称')),
                        ],
                        onChanged: (v) => setState(() => _sort = v ?? 'time'),
                      ),
                    ],
                  ),
                ),
                if (shown.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Center(
                        child: Text('无匹配视频',
                            style: TextStyle(color: Colors.black38))),
                  ),
                // 视频列表：备份状态图标 + 每条操作菜单（功能4/5/6 + 删除）
                for (final v in shown)
                  ListTile(
                    dense: true,
                    leading: _selectMode
                        ? Checkbox(
                            value: _selected.contains(v.id),
                            onChanged: (c) => setState(() {
                                  if (c == true) {
                                    _selected.add(v.id);
                                  } else {
                                    _selected.remove(v.id);
                                  }
                                }))
                        : Icon(
                            v.ghUrl != null
                                ? Icons.cloud_done
                                : Icons.cloud_off,
                            color:
                                v.ghUrl != null ? Colors.green : Colors.black26,
                          ),
                    title: Row(children: [
                      if (v.pinned)
                        const Icon(Icons.push_pin, size: 13, color: Colors.orange),
                      if (v.hidden)
                        const Icon(Icons.visibility_off,
                            size: 13, color: Colors.black38),
                      Flexible(
                        child: Text(v.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: v.hidden ? Colors.black45 : null)),
                      ),
                    ]),
                    subtitle: Text(
                        '${v.uploader.isEmpty ? '匿名' : v.uploader} · ${_fmtBytes(v.size)} · ▶ ${v.views}'),
                    onTap: _selectMode
                        ? () => setState(() {
                              if (_selected.contains(v.id)) {
                                _selected.remove(v.id);
                              } else {
                                _selected.add(v.id);
                              }
                            })
                        : () => _detail(v), // 功能19：详情
                    trailing: _selectMode
                        ? null
                        : PopupMenuButton<String>(
                            onSelected: (a) {
                              if (a == 'direct') {
                                _copy(PlatformService.videoUrl(v.id), '直链');
                              } else if (a == 'backup') {
                                _copy(v.ghUrl ?? '', 'GitHub 备份链接');
                              } else if (a == 'rename') {
                                _rename(v);
                              } else if (a == 'edit') {
                                _editUploader(v);
                              } else if (a == 'download') {
                                _downloadVideo(v);
                              } else if (a == 'hide') {
                                _toggleFlag(v, 'hide', !v.hidden);
                              } else if (a == 'pin') {
                                _toggleFlag(v, 'pin', !v.pinned);
                              } else if (a == 'detail') {
                                _detail(v);
                              } else if (a == 'backup1') {
                                _backupOne(v);
                              } else if (a == 'resetviews') {
                                _resetViews(v);
                              } else if (a == 'setcoins') {
                                _setCoins(v);
                              } else if (a == 'moveup') {
                                _move(v, 'up');
                              } else if (a == 'movedown') {
                                _move(v, 'down');
                              } else if (a == 'delete') {
                                _delete(v);
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: 'detail', child: Text('详情')),
                              const PopupMenuItem(
                                  value: 'download', child: Text('下载到本地')),
                              const PopupMenuItem(
                                  value: 'direct', child: Text('复制直链')),
                              if (v.ghUrl == null)
                                const PopupMenuItem(
                                    value: 'backup1',
                                    child: Text('立即备份到 GitHub')),
                              if (v.ghUrl != null)
                                const PopupMenuItem(
                                    value: 'backup',
                                    child: Text('复制 GitHub 备份链接')),
                              const PopupMenuItem(
                                  value: 'edit', child: Text('改标题/上传者')),
                              const PopupMenuItem(
                                  value: 'resetviews', child: Text('重置播放量')),
                              const PopupMenuItem(
                                  value: 'setcoins', child: Text('改投币数')),
                              PopupMenuItem(
                                  value: 'hide',
                                  child: Text(v.hidden ? '取消隐藏' : '隐藏(不公开)')),
                              PopupMenuItem(
                                  value: 'pin',
                                  child:
                                      Text(v.pinned ? '取消置顶' : '置顶/精选')),
                              if (v.pinned) ...[
                                const PopupMenuItem(
                                    value: 'moveup', child: Text('置顶内上移')),
                                const PopupMenuItem(
                                    value: 'movedown', child: Text('置顶内下移')),
                              ],
                              const PopupMenuItem(
                                  value: 'delete', child: Text('删除(进回收站)')),
                            ],
                          ),
                  ),
                const SizedBox(height: 20),
              ],
            ),
    );
  }
}

class _BiliListPage extends StatefulWidget {
  final String title;
  final Future<List<BiliTrack>> Function() fetch;
  final void Function(String bvid, String title) onPlay;
  final void Function(List<BiliTrack>)? onCacheAll; // 全部缓存(离线)
  const _BiliListPage(
      {required this.title,
      required this.fetch,
      required this.onPlay,
      this.onCacheAll});
  @override
  State<_BiliListPage> createState() => _BiliListPageState();
}

class _BiliListPageState extends State<_BiliListPage> {
  List<BiliTrack> _list = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await widget.fetch();
    if (mounted) {
      setState(() {
        _list = l;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        if (widget.onCacheAll != null && _list.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.offline_pin_outlined),
            tooltip: '全部缓存(离线可看)',
            onPressed: () => widget.onCacheAll!(_list),
          ),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _list.isEmpty
              ? const Center(
                  child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('没有内容（可能需要登录或接口受限）',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black54))))
              : ListView.separated(
                  itemCount: _list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (ctx, i) => ListTile(
                    leading: const Icon(Icons.play_circle_outline),
                    title: Text(_list[i].title,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(_list[i].author,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      widget.onPlay(_list[i].bvid, _list[i].title);
                    },
                  ),
                ),
    );
  }
}

class _PlaylistsPage extends StatefulWidget {
  final Map<String, List<Track>> playlists;
  final void Function(Track) onPlay;
  final Future<void> Function() onSave;
  final void Function(Track) onCacheTrack; // 批量缓存单曲（离线）
  const _PlaylistsPage(
      {required this.playlists,
      required this.onPlay,
      required this.onSave,
      required this.onCacheTrack});
  @override
  State<_PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<_PlaylistsPage> {
  // 把整个歌单里的在线曲目排队缓存（本地文件跳过），后台陆续下载。
  void _cacheAll(String name) {
    final tracks = widget.playlists[name] ?? [];
    final online = tracks.where((t) => !t.isLocal).toList();
    if (online.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该歌单没有可缓存的在线视频')));
      return;
    }
    for (final t in online) {
      widget.onCacheTrack(t);
    }
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已加入缓存队列：${online.length} 个，后台下载中')));
  }

  Future<void> _sharePlaylist(String name) async {
    final body = jsonEncode({
      'title': name,
      'tracks': widget.playlists[name]!.map((t) => t.toJson()).toList(),
    });
    final id = await PlatformService.uploadPlaylist(body);
    if (!mounted) return;
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('分享失败（平台不可达）')));
      return;
    }
    Clipboard.setData(ClipboardData(text: id));
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('歌单分享码'),
        content: SelectableText('$id\n\n已复制。好友在「导入分享」里输入即可导入。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  Future<void> _importShared() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入分享歌单'),
        content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: '输入分享码')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;
    final id = ctrl.text.trim();
    if (id.isEmpty) return;
    final js = await PlatformService.getPlaylistJson(id);
    if (!mounted) return;
    if (js == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导入失败（找不到或平台不可达）')));
      return;
    }
    try {
      final data = jsonDecode(js) as Map;
      final name = (data['title'] ?? '分享歌单').toString();
      final tracks = ((data['tracks'] as List?) ?? [])
          .map((e) => Track.fromJson(e as Map<String, dynamic>))
          .where((t) => t.isValid)
          .toList();
      widget.playlists[name] = tracks;
      await widget.onSave();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入「$name」（${tracks.length} 首）')));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入解析失败：$e')));
    }
  }

  Future<void> _importM3u() async {
    final res = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['m3u', 'm3u8', 'txt']);
    final path = res?.files.single.path;
    if (path == null) return;
    final raw = (await File(path).readAsString()).split('\n');
    final baseDir = File(path).parent.path;
    final name = path
        .split(Platform.pathSeparator)
        .last
        .replaceAll(RegExp(r'\.(m3u8?|txt)$'), '');
    final tracks = <Track>[];
    final extRe = RegExp(r'#EXTINF:[-\d.]+,(.*)'); // F17: 读 EXTINF 标题
    String? pendingTitle;
    String resolve(String rel) {
      // 相对路径转绝对，处理 ../ 段
      if (rel.startsWith('/') || rel.contains(':\\')) return rel;
      final parts = '$baseDir${Platform.pathSeparator}$rel'
          .split(Platform.pathSeparator);
      final out = <String>[];
      for (final seg in parts) {
        if (seg == '..') {
          if (out.isNotEmpty) out.removeLast();
        } else if (seg != '.' && seg.isNotEmpty) {
          out.add(seg);
        }
      }
      return '${Platform.pathSeparator}${out.join(Platform.pathSeparator)}';
    }

    for (var line in raw) {
      line = line.trim();
      if (line.isEmpty) continue;
      final m = extRe.firstMatch(line);
      if (m != null) {
        pendingTitle = m.group(1)?.trim();
        continue;
      }
      if (line.startsWith('#')) continue;
      if (line.startsWith('http')) {
        tracks.add(Track.online(
            pendingTitle?.isNotEmpty == true ? pendingTitle! : line.split('/').last,
            line));
      } else {
        final abs = resolve(line);
        if (File(abs).existsSync()) {
          tracks.add(Track.local(abs));
        } else if (File(line).existsSync()) {
          tracks.add(Track.local(line));
        }
      }
      pendingTitle = null;
    }
    if (tracks.isEmpty) return;
    widget.playlists[name] = tracks;
    await widget.onSave();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入歌单「$name」（${tracks.length} 首）')));
  }

  Future<void> _exportPlaylist(String name) async {
    final b = StringBuffer('#EXTM3U\n');
    for (final t in widget.playlists[name]!) {
      final src = t.localPath ?? t.url;
      if (src != null) b.writeln(src);
    }
    final path = await FilePicker.platform
        .saveFile(dialogTitle: '导出歌单', fileName: '$name.m3u');
    if (path == null) return;
    await File(path).writeAsString(b.toString());
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导出 $path')));
    }
  }

  // 批量把歌单里的本地视频抽取成 .m4a 音频，存到所选文件夹（仅桌面端有 ffmpeg）。
  Future<void> _extractAudio(String name) async {
    final ff = TranscribeService.ffmpeg;
    if (ff == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('此功能需要桌面端（ffmpeg）')));
      return;
    }
    final locals = widget.playlists[name]!
        .where((t) => t.localPath != null && File(t.localPath!).existsSync())
        .toList();
    if (locals.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('歌单里没有可提取的本地文件')));
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择保存音频的文件夹');
    if (dir == null || !mounted) return;
    var done = 0, fail = 0;
    final total = locals.length;
    final sm = ScaffoldMessenger.of(context);
    for (final t in locals) {
      final base = t.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final dest = '$dir/$base.m4a';
      try {
        final r =
            await Process.run(ff, ['-y', '-i', t.localPath!, '-vn', '-c:a', 'aac', dest]);
        final ok = r.exitCode == 0 &&
            File(dest).existsSync() &&
            File(dest).lengthSync() > 0;
        ok ? done++ : fail++;
      } catch (_) {
        fail++;
      }
      if (!mounted) return;
      sm.removeCurrentSnackBar();
      sm.showSnackBar(SnackBar(
          duration: const Duration(seconds: 30),
          content: Text('提取音频… ${done + fail}/$total')));
    }
    if (!mounted) return;
    sm.removeCurrentSnackBar();
    sm.showSnackBar(SnackBar(content: Text('提取完成：成功 $done，失败 $fail → $dir')));
  }

  // F18: 把多个歌单合并成一个新歌单，按 track.key 去重。
  Future<void> _mergePlaylists() async {
    final names = widget.playlists.keys.toList();
    if (names.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('至少要有两个歌单才能合并')));
      return;
    }
    final selected = <String>{};
    final nameCtrl = TextEditingController(text: '合并歌单');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('合并歌单'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: '新歌单名')),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final n in names)
                          CheckboxListTile(
                            dense: true,
                            value: selected.contains(n),
                            title: Text('$n（${widget.playlists[n]!.length}）'),
                            onChanged: (v) => setD(() => v == true
                                ? selected.add(n)
                                : selected.remove(n)),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('合并')),
          ],
        ),
      ),
    );
    if (ok != true || selected.length < 2) return;
    final newName = nameCtrl.text.trim().isEmpty ? '合并歌单' : nameCtrl.text.trim();
    final seen = <String>{};
    final merged = <Track>[];
    for (final n in selected) {
      for (final t in widget.playlists[n]!) {
        if (seen.add(t.key)) merged.add(t);
      }
    }
    widget.playlists[newName] = merged;
    await widget.onSave();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已合并为「$newName」（${merged.length} 首）')));
  }

  // F35: 把歌单里的平台视频导出成 aria2/wget 批量下载脚本。
  Future<void> _exportScript(String name) async {
    final ids = widget.playlists[name]!
        .where((t) => t.tag == '平台' && t.url != null)
        .map((t) => t.url!.split('/').last)
        .toList();
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该歌单没有平台视频')));
      return;
    }
    final fmt = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择脚本格式'),
        children: [
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'aria2'),
              child: const Text('aria2c（aria2 输入文件）')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'wget'),
              child: const Text('wget（bash 脚本）')),
        ],
      ),
    );
    if (fmt == null) return;
    final script = await PlatformService().exportScript(ids, fmt);
    if (script == null || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('生成失败（平台不可达）')));
      }
      return;
    }
    final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出下载脚本', fileName: '$name.$fmt.txt');
    if (path == null) return;
    await File(path).writeAsString(script);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导出 $path')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.playlists.keys.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('歌单'), actions: [
        IconButton(
            icon: const Icon(Icons.merge_type),
            tooltip: '合并歌单',
            onPressed: _mergePlaylists),
        IconButton(
            icon: const Icon(Icons.cloud_download_outlined),
            tooltip: '导入分享码',
            onPressed: _importShared),
        IconButton(
            icon: const Icon(Icons.file_open_outlined),
            tooltip: '导入 m3u',
            onPressed: _importM3u),
      ]),
      body: names.isEmpty
          ? const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('还没有歌单\n右键任意曲目 →「加入歌单」即可创建',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54))))
          : ListView(
              children: [
                for (final n in names)
                  ExpansionTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text('$n（${widget.playlists[n]!.length}）'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.share_outlined, size: 20),
                          tooltip: '分享(生成分享码)',
                          onPressed: () => _sharePlaylist(n),
                        ),
                        IconButton(
                          icon: const Icon(Icons.ios_share, size: 20),
                          tooltip: '导出 m3u',
                          onPressed: () => _exportPlaylist(n),
                        ),
                        if (!Platform.isAndroid)
                          IconButton(
                            icon: const Icon(Icons.audiotrack, size: 20),
                            tooltip: '批量提取音频(m4a)',
                            onPressed: () => _extractAudio(n),
                          ),
                        IconButton(
                          icon: const Icon(Icons.download_for_offline_outlined,
                              size: 20),
                          tooltip: '导出下载脚本(aria2/wget)',
                          onPressed: () => _exportScript(n),
                        ),
                        IconButton(
                          icon: const Icon(Icons.offline_pin_outlined, size: 20),
                          tooltip: '全部缓存(离线可看)',
                          onPressed: () => _cacheAll(n),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            widget.playlists.remove(n);
                            await widget.onSave();
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                    children: [
                      for (final t in widget.playlists[n]!)
                        ListTile(
                          leading: const Icon(Icons.play_arrow),
                          title: Text(t.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () async {
                              widget.playlists[n]!
                                  .removeWhere((x) => x.key == t.key);
                              await widget.onSave();
                              setState(() {});
                            },
                          ),
                          onTap: () => widget.onPlay(t),
                        ),
                    ],
                  ),
              ],
            ),
    );
  }
}
