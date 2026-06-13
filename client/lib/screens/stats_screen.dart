import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'home_shell.dart' show Track;

/// F50: 观看统计看板。展示累计观看时长、最近播放排行，支持导出 CSV。
class StatsScreen extends StatelessWidget {
  final List<Track> history; // 最近播放（去重，最新在前）
  final int watchSec; // 累计观看秒数
  const StatsScreen({super.key, required this.history, required this.watchSec});

  String _fmtDuration(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    if (h > 0) return '$h 小时 $m 分';
    return '$m 分钟';
  }

  Future<void> _exportCsv(BuildContext context) async {
    final b = StringBuffer('序号,名称,来源\n');
    for (var i = 0; i < history.length; i++) {
      final t = history[i];
      final src = t.bvid != null
          ? 'B站'
          : (t.isLocal ? '本地' : (t.tag.isEmpty ? '在线' : t.tag));
      final name = t.name.replaceAll(',', '，').replaceAll('\n', ' ');
      b.writeln('${i + 1},$name,$src');
    }
    final path = await FilePicker.platform
        .saveFile(dialogTitle: '导出统计 CSV', fileName: '观看统计.csv');
    if (path == null) return;
    await File(path).writeAsString(b.toString());
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导出 $path')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final biliCount = history.where((t) => t.bvid != null).length;
    final localCount = history.where((t) => t.isLocal).length;
    return Scaffold(
      appBar: AppBar(title: const Text('观看统计'), actions: [
        IconButton(
          icon: const Icon(Icons.ios_share),
          tooltip: '导出 CSV',
          onPressed: () => _exportCsv(context),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              _statCard(cs, '累计观看', _fmtDuration(watchSec), Icons.timer),
              const SizedBox(width: 12),
              _statCard(cs, '最近曲目', '${history.length}', Icons.queue_music),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _statCard(cs, 'B站', '$biliCount', Icons.smart_display),
              const SizedBox(width: 12),
              _statCard(cs, '本地', '$localCount', Icons.folder),
            ],
          ),
          const SizedBox(height: 24),
          Text('最近播放',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: cs.primary)),
          const SizedBox(height: 8),
          if (history.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                  child: Text('还没有播放记录',
                      style: TextStyle(color: Colors.black54))),
            ),
          for (var i = 0; i < history.length; i++)
            ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 14,
                backgroundColor: cs.primary.withValues(alpha: 0.15),
                child: Text('${i + 1}',
                    style: TextStyle(fontSize: 12, color: cs.primary)),
              ),
              title: Text(history[i].name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
  }

  Widget _statCard(ColorScheme cs, String label, String value, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: cs.primary, size: 22),
            const SizedBox(height: 8),
            Text(value,
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.bold)),
            Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
      ),
    );
  }
}
