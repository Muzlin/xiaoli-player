import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class TokenStorage {
  Future<String?> read();
  Future<void> write(String? token);
}

class SecureTokenStorage implements TokenStorage {
  static const _key = 'jwt';
  final FlutterSecureStorage _s;
  SecureTokenStorage([FlutterSecureStorage? s])
      : _s = s ?? const FlutterSecureStorage();

  @override
  Future<String?> read() => _s.read(key: _key);

  @override
  Future<void> write(String? token) =>
      token == null ? _s.delete(key: _key) : _s.write(key: _key, value: token);
}

class AuthStore extends ChangeNotifier {
  final TokenStorage _storage;
  String? _token;

  AuthStore({required TokenStorage storage}) : _storage = storage;

  String? get token => _token;
  bool get isAuthenticated => _token != null;

  Future<void> loadFromStorage() async {
    _token = await _storage.read();
    notifyListeners();
  }

  Future<void> signIn(String token) async {
    _token = token;
    await _storage.write(token);
    notifyListeners();
  }

  Future<void> signOut() async {
    _token = null;
    await _storage.write(null);
    notifyListeners();
  }
}
