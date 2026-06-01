import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_client/api/api_client.dart';

void main() {
  test('login posts credentials and returns token', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/auth/login');
      final body = jsonDecode(req.body);
      expect(body['email'], 'a@x.com');
      return http.Response(jsonEncode({'access_token': 'tok'}), 200);
    });
    final api = ApiClient(baseUrl: 'http://h', client: mock);
    final token = await api.login('a@x.com', 'pw');
    expect(token, 'tok');
  });

  test('listMedia sends bearer token and parses list', () async {
    final mock = MockClient((req) async {
      expect(req.headers['authorization'], 'Bearer tok');
      return http.Response(
        jsonEncode([
          {
            'id': 1,
            'owner_id': 1,
            'original_name': 'a.mp4',
            'size_bytes': 10,
            'container_format': 'mp4',
          }
        ]),
        200,
      );
    });
    final api = ApiClient(baseUrl: 'http://h', client: mock)..setToken('tok');
    final items = await api.listMedia();
    expect(items.single.originalName, 'a.mp4');
  });

  test('non-2xx throws ApiException', () async {
    final mock = MockClient((req) async => http.Response('nope', 401));
    final api = ApiClient(baseUrl: 'http://h', client: mock);
    expect(() => api.login('a', 'b'), throwsA(isA<ApiException>()));
  });

  test('streamUrl and authHeaders expose playback inputs', () {
    final api = ApiClient(
        baseUrl: 'http://h',
        client: MockClient((_) async => http.Response('', 200)))
      ..setToken('tok');
    expect(api.streamUrl(7), 'http://h/media/7/stream');
    expect(api.authHeaders()['Authorization'], 'Bearer tok');
  });
}
