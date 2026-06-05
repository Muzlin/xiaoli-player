import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../player/playback_source.dart';
import '../widgets/player_bar.dart';
import 'player_screen.dart';

/// 一首本地曲目。
class LocalTrack {
  final String path;
  final String name;
  final String ext;
  LocalTrack(this.path)
      : name = path.split(Platform.pathSeparator).last,
        ext = path.contains('.') ? path.split('.').last.toUpperCase() : '';
}

/// 桌面音乐播放器风格主界面：左侧导航 + 顶部搜索 + 本地媒体列表 + 底部播放条。
/// 纯本地，无账号、无服务器。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final List<LocalTrack> _tracks = [];
  LocalTrack? _current;
  String _query = '';
  int _navIndex = 0;

  static const _sidebarColor = Color(0xFF2B2B33);
  static const _topbarColor = Color(0xFF35353F);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showDisclaimer());
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
            '请勿用于任何商业或侵权用途；使用本软件产生的一切后果由使用者自行承担。\n\n'
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
        if (f.path != null && !_tracks.any((t) => t.path == f.path)) {
          _tracks.add(LocalTrack(f.path!));
        }
      }
    });
  }

  void _play(LocalTrack t) {
    setState(() => _current = t);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          PlayerScreen(source: PlaybackSource.local(t.path)),
    ));
  }

  void _prev() {
    if (_current == null || _tracks.isEmpty) return;
    final i = _tracks.indexOf(_current!);
    if (i > 0) _play(_tracks[i - 1]);
  }

  void _next() {
    if (_current == null || _tracks.isEmpty) return;
    final i = _tracks.indexOf(_current!);
    if (i >= 0 && i < _tracks.length - 1) _play(_tracks[i + 1]);
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
            '我的音乐',
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
                  hintText: '搜索…',
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
    final items = _query.isEmpty
        ? _tracks
        : _tracks
            .where(
                (t) => t.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_music, size: 64, color: cs.primary.withOpacity(0.4)),
            const SizedBox(height: 12),
            const Text('还没有音乐，点右上角「添加文件」',
                style: TextStyle(color: Colors.black54)),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = items[i];
        final selected = t.path == _current?.path;
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
                Icon(Icons.music_note, color: cs.primary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(t.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                SizedBox(
                  width: 70,
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
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('免责声明'),
          onTap: _showDisclaimer,
        ),
        const ListTile(
          leading: Icon(Icons.folder_open),
          title: Text('添加音乐'),
          subtitle: Text('在「我的音乐」右上角点「添加文件」选择本地媒体'),
        ),
      ],
    );
  }
}
