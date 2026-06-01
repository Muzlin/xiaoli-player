import 'package:flutter_test/flutter_test.dart';
import 'package:media_client/auth/auth_store.dart';

class FakeStorage implements TokenStorage {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? token) async => value = token;
}

void main() {
  test('signIn stores token and marks authenticated', () async {
    final storage = FakeStorage();
    final store = AuthStore(storage: storage);
    await store.signIn('tok');
    expect(store.isAuthenticated, true);
    expect(store.token, 'tok');
    expect(storage.value, 'tok');
  });

  test('signOut clears token', () async {
    final storage = FakeStorage()..value = 'tok';
    final store = AuthStore(storage: storage);
    await store.loadFromStorage();
    await store.signOut();
    expect(store.isAuthenticated, false);
    expect(storage.value, null);
  });
}
