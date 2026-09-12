import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_client/services/update_service.dart';
import 'package:media_client/services/platform_service.dart';

/// UTF-8 JSON 响应（http.Response 无 charset 时默认 latin1，中文 body 会抛异常）
http.Response _json(String body, int code) => http.Response(
    body, code,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PlatformService.useLan = false;

  testWidgets('平台返回新版 → 发现更新', (tester) async {
    await tester.runAsync(() async {
      final mock = MockClient((req) async {
        if (req.url.path == '/version') {
          return _json(
              '{"version":"2.55.0","notes":"测试新版","download_url":"https://dl.example/app.zip"}',
              200);
        }
        return _json('{}', 404);
      });
      final info = await UpdateService(mock).check();
      expect(info, isNotNull);
      expect(info!.version, '2.55.0');
    });
  });

  testWidgets('平台数据过期(2.40.0) + raw公网2.55.0 → 走公网发现更新', (tester) async {
    await tester.runAsync(() async {
      final mock = MockClient((req) async {
        if (req.url.path == '/version') {
          return _json('{"version":"2.40.0","notes":"过期"}', 200);
        }
        if (req.url.host.contains('raw.githubusercontent.com')) {
          return _json('{"version":"2.55.0","notes":"公网新版"}', 200);
        }
        return _json('{}', 404);
      });
      final info = await UpdateService(mock).check();
      expect(info, isNotNull);
      expect(info!.version, '2.55.0');
    });
  });

  testWidgets('全源都是当前版本 → 无更新', (tester) async {
    await tester.runAsync(() async {
      final mock = MockClient((req) async {
        if (req.url.path == '/version') return _json('{"version":"2.41.0"}', 200);
        if (req.url.host.contains('raw.githubusercontent.com')) {
          return _json('{"version":"2.41.0"}', 200);
        }
        return _json('{"tag_name":"v2.41.0"}', 200);
      });
      final info = await UpdateService(mock).check();
      expect(info, isNull);
    });
  });

  testWidgets('全部源失败 → 无更新(不抛异常)', (tester) async {
    await tester.runAsync(() async {
      final mock = MockClient((req) async => throw Exception('网络错误'));
      final info = await UpdateService(mock).check();
      expect(info, isNull);
    });
  });
}
