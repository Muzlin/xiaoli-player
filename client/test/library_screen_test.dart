import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_client/api/api_client.dart';
import 'package:media_client/api/models.dart';
import 'package:media_client/screens/library_screen.dart';

void main() {
  testWidgets('library lists media from api', (tester) async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/media');
      return http.Response(
        jsonEncode([
          {
            'id': 1,
            'owner_id': 1,
            'original_name': 'song.flac',
            'size_bytes': 10,
            'container_format': 'flac',
          }
        ]),
        200,
      );
    });
    final api = ApiClient(baseUrl: 'http://h', client: mock)..setToken('tok');
    final user = UserInfo(id: 1, email: 'a@x.com', role: 'user');

    await tester.pumpWidget(MaterialApp(
      home: LibraryScreen(api: api, user: user, onPlay: (_) {}),
    ));
    await tester.pumpAndSettle();

    expect(find.text('song.flac'), findsOneWidget);
  });

  testWidgets('tapping a row triggers onPlay', (tester) async {
    final mock = MockClient((req) async => http.Response(
          jsonEncode([
            {
              'id': 9,
              'owner_id': 1,
              'original_name': 'clip.mp4',
              'size_bytes': 10,
              'container_format': 'mp4',
            }
          ]),
          200,
        ));
    final api = ApiClient(baseUrl: 'http://h', client: mock)..setToken('tok');
    final user = UserInfo(id: 1, email: 'a@x.com', role: 'user');
    MediaItem? played;

    await tester.pumpWidget(MaterialApp(
      home: LibraryScreen(api: api, user: user, onPlay: (m) => played = m),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('clip.mp4'));
    expect(played!.id, 9);
  });

  testWidgets('admin sees admin title and download triggers onDownload',
      (tester) async {
    final mock = MockClient((req) async => http.Response(
          jsonEncode([
            {
              'id': 3,
              'owner_id': 2,
              'original_name': 'm.mkv',
              'size_bytes': 5,
              'container_format': 'mkv',
            }
          ]),
          200,
        ));
    final api = ApiClient(baseUrl: 'http://h', client: mock)..setToken('tok');
    final admin = UserInfo(id: 1, email: 'admin@x.com', role: 'admin');
    MediaItem? downloaded;
    await tester.pumpWidget(MaterialApp(
      home: LibraryScreen(
        api: api,
        user: admin,
        onPlay: (_) {},
        onDownload: (m) => downloaded = m,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('媒体库（管理员）'), findsOneWidget);
    expect(find.byIcon(Icons.download), findsOneWidget);
    await tester.tap(find.byIcon(Icons.download));
    expect(downloaded!.id, 3);
  });

  testWidgets('regular user has no download button', (tester) async {
    final mock = MockClient((req) async => http.Response(
          jsonEncode([
            {
              'id': 1,
              'owner_id': 1,
              'original_name': 'a.mp4',
              'size_bytes': 5,
              'container_format': 'mp4',
            }
          ]),
          200,
        ));
    final api = ApiClient(baseUrl: 'http://h', client: mock)..setToken('tok');
    final user = UserInfo(id: 1, email: 'u@x.com', role: 'user');
    await tester.pumpWidget(MaterialApp(
      home: LibraryScreen(api: api, user: user, onPlay: (_) {}),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.download), findsNothing);
  });

  testWidgets('401 on load triggers onSessionExpired', (tester) async {
    final mock = MockClient((req) async => http.Response('unauthorized', 401));
    final api = ApiClient(baseUrl: 'http://h', client: mock)..setToken('tok');
    final user = UserInfo(id: 1, email: 'u@x.com', role: 'user');
    var expired = false;
    await tester.pumpWidget(MaterialApp(
      home: LibraryScreen(
        api: api,
        user: user,
        onPlay: (_) {},
        onSessionExpired: () => expired = true,
      ),
    ));
    await tester.pumpAndSettle();
    expect(expired, true);
  });
}
