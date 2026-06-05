import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../player/playback_source.dart';
import '../services/audius_service.dart';
import '../widgets/player_bar.dart';
import 'player_screen.dart';

/// 一首曲目：本地文件、内置热门、或联网搜索到的在线歌曲。
class Track {
  final String name;
  final String? localPath;
  final String? url;
  final String tag; // '' | '热门' | '在线'

  Track.local(this.localPath)
      : name = localPath!.split(Platform.pathSeparator).last,
        url = null,
        tag = '';

  Track.online(this.name, this.url, {this.tag = ''}) : localPath = null;

  bool get isLocal => localPath != null;

  String get ext {
    final src = localPath ?? '';
    return src.contains('.') ? src.split('.').last.toUpperCase() : '';
  }

  PlaybackSource toSource() => isLocal
      ? PlaybackSource.local(localPath!)
      : PlaybackSource.stream(url!, const {}, title: name);
}

/// 桌面音乐播放器风格主界面：侧栏 + 顶部搜索（联网） + 列表 + 底部播放条。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// 内置热门歌曲（免费可在线播放的示例曲目）。
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
    Track.online('流行节奏 · Demo',
        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-5.mp3',
        tag: '热门'),
    Track.online('放松音乐 · Demo',
        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-8.mp3',
        tag: '热门'),
  ];

  final List<Track> _localTracks = [];
  final List<Track> _onlineTracks = [];
  final AudiusService _audius = AudiusService();
  Track? _current;
  String _query = '';
  int _navIndex = 0;
  Timer? _searchDebounce;
  bool _searchingOnline = false;

  static const _prefsKey = 'local_tracks_v1';
  static const _sidebarColor = Color(0xFF2B2B33);
  static const _topbarColor = Color(0xFF35353F);

  List<Track> get _allTracks => [..._hotTracks, ..._localTracks];
  List<Track> get _playQueue =>
      [..._hotTracks, ..._localTracks, ..._onlineTracks];

  @override
  void initState() {
    super.initState();
    _loadSaved();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showDisclaimer());
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

  Future<void> _showDisclaimer() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('免责声明'),
        content: const SingleChildScrollView(
          child: Text(
            '「小李播放器」是一款媒体播放器，仅供学习与个人使用。\n\n'
            '在线搜索内容来自第三方免费音乐平台（李土豆）；请勿用于任何商业或'
            '侵权用途，使用本软件产生的一切后果由使用者自行承担。\n\n'
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
    final results = await _audius.search(q);
    if (!mounted) return;
    setState(() {
      _searchingOnline = false;
      _onlineTracks
        ..clear()
        ..addAll(results.map((o) => Track.online(
              o.artist.isEmpty ? o.title : '${o.title} - ${o.artist}',
              o.streamUrl,
              tag: '在线',
            )));
    });
  }

  void _play(Track t) {
    setState(() => _current = t);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(source: t.toSource()),
    ));
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
        subtitle: _current?.tag.isNotEmpty == true ? _current!.tag : _current?.ext,
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
                  hintText: '搜索歌曲（联网搜全网音乐）…',
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
                            ? '还没有歌曲，点右上角「添加文件」或搜索联网音乐'
                            : (_searchingOnline ? '联网搜索中…' : '没有找到「$_query」'),
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
    if (t.tag == '在线') tagColor = Colors.blueAccent;
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
            Icon(t.isLocal ? Icons.music_note : Icons.cloud_outlined,
                color: cs.primary, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child:
                  Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (tagColor != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(t.tag,
                    style: TextStyle(color: tagColor, fontSize: 12)),
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
          title: Text('小李播放器 v2.1.3'),
          subtitle: Text('媒体播放器 · 支持所有格式（基于 libmpv）'),
        ),
        const ListTile(
          leading: Icon(Icons.travel_explore),
          title: Text('联网搜索'),
          subtitle: Text('搜索框输入歌名，联网搜索在线音乐（李土豆 免费平台）'),
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
