import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_client/api/api_client.dart';
import 'package:media_client/screens/upload_button.dart';

void main() {
  testWidgets('upload picks file, posts multipart field "file", calls onUploaded',
      (tester) async {
    final tmp = File('${Directory.systemTemp.path}/xl_upload_test.bin')
      ..writeAsBytesSync([1, 2, 3]);
    var uploaded = false;
    http.Request? seen;
    final mock = MockClient((req) async {
      seen = req;
      return http.Response(
        jsonEncode({
          'id': 1,
          'owner_id': 1,
          'original_name': 'xl_upload_test.bin',
          'size_bytes': 3,
          'container_format': 'bin',
        }),
        200,
      );
    });
    final api = ApiClient(baseUrl: 'http://h', client: mock)..setToken('tok');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: [
          UploadButton(
            api: api,
            onUploaded: () => uploaded = true,
            pickFile: () async => tmp.path,
          ),
        ]),
      ),
    ));

    // 上传走真实文件 IO（MultipartFile.fromPath），需在 runAsync 中推进真实异步。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('upload')));
      for (var i = 0; i < 50 && !uploaded; i++) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    });

    expect(uploaded, true);
    expect(seen!.url.path, '/media/upload');
    expect(String.fromCharCodes(seen!.bodyBytes), contains('name="file"'));
    tmp.deleteSync();
  });

  testWidgets('cancelled pick does nothing', (tester) async {
    var uploaded = false;
    final mock = MockClient((req) async => http.Response('{}', 200));
    final api = ApiClient(baseUrl: 'http://h', client: mock);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: [
          UploadButton(
            api: api,
            onUploaded: () => uploaded = true,
            pickFile: () async => null,
          ),
        ]),
      ),
    ));
    await tester.tap(find.byKey(const Key('upload')));
    await tester.pumpAndSettle();
    expect(uploaded, false);
  });
}
