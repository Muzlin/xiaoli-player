import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_client/api/api_client.dart';
import 'package:media_client/auth/auth_store.dart';
import 'package:media_client/screens/login_screen.dart';

class FakeStorage implements TokenStorage {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? t) async => value = t;
}

void main() {
  testWidgets('successful login calls onSignedIn and stores token',
      (tester) async {
    final mock = MockClient((req) async =>
        http.Response(jsonEncode({'access_token': 'tok'}), 200));
    final api = ApiClient(baseUrl: 'http://h', client: mock);
    final auth = AuthStore(storage: FakeStorage());
    var signedIn = false;

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        api: api,
        auth: auth,
        onSignedIn: () => signedIn = true,
      ),
    ));

    await tester.enterText(find.byKey(const Key('email')), 'a@x.com');
    await tester.enterText(find.byKey(const Key('password')), 'pw');
    await tester.tap(find.byKey(const Key('login')));
    await tester.pumpAndSettle();

    expect(signedIn, true);
    expect(auth.token, 'tok');
  });

  testWidgets('failed login shows error', (tester) async {
    final mock = MockClient((req) async => http.Response('bad', 401));
    final api = ApiClient(baseUrl: 'http://h', client: mock);
    final auth = AuthStore(storage: FakeStorage());

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(api: api, auth: auth, onSignedIn: () {}),
    ));
    await tester.tap(find.byKey(const Key('login')));
    await tester.pumpAndSettle();

    expect(find.textContaining('登录失败'), findsOneWidget);
  });

  testWidgets('register button calls /auth/register', (tester) async {
    String? path;
    final mock = MockClient((req) async {
      path = req.url.path;
      return http.Response(jsonEncode({'access_token': 'tok'}), 200);
    });
    final api = ApiClient(baseUrl: 'http://h', client: mock);
    final auth = AuthStore(storage: FakeStorage());
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(api: api, auth: auth, onSignedIn: () {}),
    ));
    await tester.tap(find.byKey(const Key('register')));
    await tester.pumpAndSettle();
    expect(path, '/auth/register');
  });
}
