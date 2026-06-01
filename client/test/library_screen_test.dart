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
}
