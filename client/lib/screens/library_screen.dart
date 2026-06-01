import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../api/api_client.dart';
import '../api/models.dart';
import 'upload_button.dart';
import 'player_screen.dart';

class LibraryScreen extends StatefulWidget {
  final ApiClient api;
  final UserInfo user;
  final void Function(MediaItem) onPlay;

  const LibraryScreen({
    super.key,
    required this.api,
    required this.user,
    required this.onPlay,
  });

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<MediaItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.listMedia();
  }

  void _reload() => setState(() => _future = widget.api.listMedia());

  Future<void> _openLocal() async {
    final result = await FilePicker.platform.pickFiles();
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(source: PlaybackSource.local(path)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.user.isAdmin ? '媒体库（管理员）' : '我的媒体'),
        actions: [
          IconButton(
            key: const Key('open-local'),
            icon: const Icon(Icons.folder_open),
            tooltip: '打开本地文件',
            onPressed: _openLocal,
          ),
          UploadButton(api: widget.api, onUploaded: _reload),
        ],
      ),
      body: FutureBuilder<List<MediaItem>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('加载失败：${snapshot.error}'));
          }
          final items = snapshot.data!;
          if (items.isEmpty) {
            return const Center(child: Text('还没有文件，点右上角上传'));
          }
          return ListView(
            children: [
              for (final m in items)
                ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: Text(m.originalName),
                  subtitle: Text(m.containerFormat.toUpperCase()),
                  trailing: widget.user.isAdmin
                      ? IconButton(
                          icon: const Icon(Icons.download),
                          tooltip: '下载',
                          onPressed: () {},
                        )
                      : null,
                  onTap: () => widget.onPlay(m),
                ),
            ],
          );
        },
      ),
    );
  }
}
