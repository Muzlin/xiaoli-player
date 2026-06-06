import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import '../player/playback_source.dart';
import '../services/bilibili_service.dart';
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
  final UpdateService _update = UpdateService();
  Track? _current;
  String _query = '';
  int _navIndex = 0;
  Timer? _searchDebounce;
  bool _searchingOnline = false;
  bool _biliLoggedIn = false;

  // 外观：自定义背景（图片或纯色）+ 透明度。背景图会复制进 app 容器，重启不丢。
  String? _bgImagePath;
  int? _bgColorValue;
  double _bgOpacity = 0.6;

  static const _prefsKey = 'local_tracks_v1';
  static const _biliCookieKey = 'bili_cookie';
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

  List<Track> get _allTracks => [..._hotTracks, ..._localTracks];
  List<Track> get _playQueue =>
      [..._hotTracks, ..._localTracks, ..._onlineTracks];

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _loadBiliCookie();
    _loadAppearance();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showDisclaimer();
      _silentCheckUpdate();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
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
    final view = _navIndex == 0 ? _libraryView(cs) : _settingsView(cs);
    if (!_hasCustomBg) return view;
    return ColoredBox(
      color: _baseBg.withValues(alpha: (1 - _bgOpacity).clamp(0.0, 1.0)),
      child: view,
    );
  }

  Future<void> _loadBiliCookie() async {
    final prefs = await SharedPreferences.getInstance();
    final c = prefs.getString(_biliCookieKey) ?? '';
    if (c.isNotEmpty) _bili.setUserCookie(c);
    if (mounted) setState(() => _biliLoggedIn = c.isNotEmpty);
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
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('登录'),
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
    setState(() => _biliLoggedIn = cookie.isNotEmpty);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(cookie.isNotEmpty ? '已登录 B站，搜索更稳定了' : '已退出登录')),
    );
    if (cookie.isNotEmpty && _query.trim().isNotEmpty) _searchOnline(_query);
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
    if (!mounted) return;
    setState(() {
      _searchingOnline = false;
      _onlineTracks
        ..clear()
        ..addAll(results.map((b) => Track.bili(
              b.author.isEmpty ? b.title : '${b.title} - ${b.author}',
              b.bvid,
            )));
    });
  }

  Future<void> _play(Track t) async {
    setState(() => _current = t);
    PlaybackSource src;
    if (t.bvid != null) {
      // B站：先弹 loading，异步取音频流
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
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
          title: t.name, isVideo: true);
    } else {
      src = t.toSource();
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerScreen(source: src)),
    );
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
          _navIcon(Icons.settings, 1, cs),
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
                onChanged: _onSearchChanged,
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
    final base = q.isEmpty
        ? _allTracks
        : _allTracks.where((t) => t.name.toLowerCase().contains(q)).toList();
    final items = [...base, ..._onlineTracks];
    return Column(
      children: [
        if (_searchingOnline) const LinearProgressIndicator(minHeight: 2),
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

  Widget _trackRow(ColorScheme cs, Track t, int i) {
    final selected = t.name == _current?.name;
    Color? tagColor;
    if (t.tag == '热门') tagColor = Colors.orange;
    final icon = t.isLocal
        ? Icons.music_note
        : (t.bvid != null ? Icons.smart_display : Icons.cloud_outlined);
    return InkWell(
      onTap: () => _play(t),
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
              icon: const Icon(Icons.play_circle_outline),
              color: cs.primary,
              onPressed: () => _play(t),
            ),
          ],
        ),
      ),
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
          title: Text('小李播放器 v2.2.1'),
          subtitle: Text('媒体播放器 · 支持所有格式（基于 libmpv）'),
        ),
        ListTile(
          leading: const Icon(Icons.system_update),
          title: const Text('检查更新'),
          subtitle: const Text('检测并下载最新版本'),
          onTap: _checkUpdateManually,
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
          leading: Icon(_biliLoggedIn ? Icons.verified_user : Icons.login,
              color: _biliLoggedIn ? Colors.green : null),
          title: const Text('B站登录'),
          subtitle: Text(_biliLoggedIn
              ? '已登录 · 搜索不受限流（点此可退出）'
              : '未登录 · 点此粘贴 Cookie 登录，搜索更稳定'),
          onTap: _showBiliLogin,
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
