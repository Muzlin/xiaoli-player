import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../player/playback_source.dart';
import '../widgets/player_bar.dart';
import 'player_screen.dart';

/// 一首曲目：本地文件或在线 URL。
class Track {
  final String name;
  final String? localPath;
  final String? url;

  Track.local(this.localPath)
      : name = localPath!.split(Platform.pathSeparator).last,
        url = null;

  Track.online(this.name, this.url) : localPath = null;

  bool get isLocal => localPath != null;

  String get ext {
    final src = localPath ?? url ?? '';
    return src.contains('.') ? src.split('.').last.split('?').first.toUpperCase() : '';
  }

  PlaybackSource toSource() => isLocal
      ? PlaybackSource.local(localPath!)
      : PlaybackSource.stream(url!, const {}, title: name);
}

/// 桌面音乐播放器风格主界面：左侧导航 + 顶部搜索 + 列表（热门+本地）+ 底部播放条。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// 内置热门歌曲（免费可在线播放的示例曲目）。
  static final List<Track> _hotTracks = [
    Track.online('钢琴轻音乐 · Demo',
        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3'),
    Track.online('电子节拍 · Demo',
        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3'),
    Track.online('吉他旋律 · Demo',
        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3'),
    Track.online('流行节奏 · Demo',
        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-5.mp3'),
    Track.online('放松音乐 · Demo',
        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-8.mp3'),
  ];

  final List<Track> _localTracks = [];
  Track? _current;
  String _query = '';
  int _navIndex = 0;

  static const _sidebarColor = Color(0xFF2B2B33);
  static const _topbarColor = Color(0xFF35353F);

  List<Track> get _allTracks => [..._hotTracks, ..._localTracks];

  static const _prefsKey = 'local_tracks_v1';

  @override
  void initState() {
    super.initState();
    _loadSaved();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showDisclaimer());
  }

  /// 启动时加载已保存的本地音乐（文件仍存在的才加入）。
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

  /// 保存本地音乐路径列表。
  Future<void> _saveLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _prefsKey, _localTracks.map((t) => t.localPath!).toList());
  }

  Future<void> _showDisclaimer() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('免责声明'),
        content: const SingleChildScrollView(
          child: Text(
            '「小李播放器」是一款本地媒体播放器，仅供学习与个人使用。\n\n'
            '内置「热门歌曲」为免费示例曲目；请勿用于任何商业或侵权用途，'
            '使用本软件产生的一切后果由使用者自行承担。\n\n'
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

  void _play(Track t) {
    setState(() => _current = t);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(source: t.toSource()),
    ));
  }

  void _prev() {
    final list = _allTracks;
    if (_current == null || list.isEmpty) return;
    final i = list.indexWhere((t) => t.name == _current!.name);
    if (i > 0) _play(list[i - 1]);
  }

  void _next() {
    final list = _allTracks;
    if (_current == null || list.isEmpty) return;
    final i = list.indexWhere((t) => t.name == _current!.name);
    if (i >= 0 && i < list.length - 1) _play(list[i + 1]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          _sidebar(cs),
          Expanded(
            child: Column(
              children: [
                _topbar(cs),
                Expanded(
                  child: _navIndex == 0 ? _libraryView(cs) : _settingsView(cs),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: PlayerBar(
        title: _current?.name,
        subtitle: _current?.ext,
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
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '搜索歌曲…',
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
    final items = q.isEmpty
        ? _allTracks
        : _allTracks.where((t) => t.name.toLowerCase().contains(q)).toList();
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 64, color: cs.primary.withOpacity(0.4)),
            const SizedBox(height: 12),
            const Text('没有匹配的歌曲', style: TextStyle(color: Colors.black54)),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = items[i];
        final selected = t.name == _current?.name;
        return InkWell(
          onTap: () => _play(t),
          child: Container(
            color: selected ? cs.primary.withOpacity(0.12) : null,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  child: Text('${i + 1}',
                      style: const TextStyle(color: Colors.black45)),
                ),
                Icon(t.isLocal ? Icons.music_note : Icons.cloud_outlined,
                    color: cs.primary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(t.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (!t.isLocal)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Text('热门',
                        style: TextStyle(color: Colors.orange, fontSize: 12)),
                  ),
                SizedBox(
                  width: 64,
                  child: Text(t.ext,
                      style: const TextStyle(color: Colors.black45)),
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
      },
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
          title: Text('小李播放器 v1'),
          subtitle: Text('本地媒体播放器 · 支持所有格式（基于 libmpv）'),
        ),
        const ListTile(
          leading: Icon(Icons.local_fire_department),
          title: Text('热门歌曲'),
          subtitle: Text('内置免费在线示例曲目，打开即可播放'),
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
