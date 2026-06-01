import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../api/api_client.dart';

/// 返回选中的文件路径，取消则为 null。注入以便测试。
typedef PickFile = Future<String?> Function();

Future<String?> defaultPickFile() async {
  final result = await FilePicker.platform.pickFiles();
  return result?.files.single.path;
}

class UploadButton extends StatelessWidget {
  final ApiClient api;
  final VoidCallback onUploaded;
  final PickFile pickFile;

  const UploadButton({
    super.key,
    required this.api,
    required this.onUploaded,
    this.pickFile = defaultPickFile,
  });

  Future<void> _upload() async {
    final path = await pickFile();
    if (path == null) return;
    await api.uploadFile(path);
    onUploaded();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('upload'),
      icon: const Icon(Icons.upload_file),
      tooltip: '上传',
      onPressed: _upload,
    );
  }
}
