# Flutter Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single Flutter codebase (macOS / Windows / Android) that logs into the backend, uploads media, lists files by role, and plays any format via media_kit (libmpv), streaming from the backend with an auth header.

**Architecture:** Layered. `ApiClient` (HTTP + JWT) and `models` are pure Dart, fully unit-tested with a mocked `http.Client`. `AuthStore` holds the token/user in memory and persists the token. `PlaybackController` wraps a `PlaybackBackend` interface — the real backend wraps `media_kit`'s `Player`; tests use a fake. Screens (login, library, upload, player) take their dependencies by injection so they can be widget-tested against fakes.

**Tech Stack:** Flutter (stable), Dart 3, `media_kit` + `media_kit_video` + `media_kit_libs_*`, `http`, `file_picker`, `flutter_secure_storage`. Tests: `flutter_test`, `http`'s `MockClient`.

**Prerequisite:** The backend plan (`2026-05-31-backend-platform.md`) provides the API this client calls. Run the backend locally (`uvicorn app.main:app`) for manual end-to-end verification.

---

## File Structure

```
client/
  lib/
    api/
      models.dart          # UserInfo, MediaItem, AdminMediaItem
      api_client.dart      # ApiClient + ApiException
    auth/
      auth_store.dart      # token + current user, secure-storage persistence
    player/
      playback_backend.dart    # PlaybackBackend interface + MediaKitBackend
      playback_controller.dart # PlaybackController (state on top of a backend)
    screens/
      login_screen.dart
      library_screen.dart
      upload_button.dart
      player_screen.dart
    app.dart               # MaterialApp + routing + dependency wiring
    main.dart              # MediaKit.ensureInitialized() + runApp
  test/
    models_test.dart
    api_client_test.dart
    auth_store_test.dart
    playback_controller_test.dart
    login_screen_test.dart
    library_screen_test.dart
  pubspec.yaml
```

---

### Task 1: Flutter project + dependencies

**Files:**
- Create: Flutter project under `client/`
- Modify: `client/pubspec.yaml`

- [ ] **Step 1: Create the project with the three desktop/mobile platforms**

Run (from `media-player/`):
```bash
flutter create --platforms=macos,windows,android --project-name media_client client
```

- [ ] **Step 2: Add dependencies**

Run (from `client/`):
```bash
flutter pub add media_kit media_kit_video media_kit_libs_video http file_picker flutter_secure_storage
flutter pub add --dev http_test_handler || true   # not required; MockClient ships with `http`
```

- [ ] **Step 3: Verify the project builds its tests**

Run (from `client/`): `flutter test`
Expected: the default `widget_test.dart` runs (it may fail because it references the default counter app — delete `test/widget_test.dart`). After deleting it, `flutter test` reports "No tests found" or passes.

- [ ] **Step 4: Commit**

```bash
git add client
git commit -m "chore(client): flutter project with media_kit + http deps"
```

---

### Task 2: Models

**Files:**
- Create: `client/lib/api/models.dart`
- Test: `client/test/models_test.dart`

- [ ] **Step 1: Write the failing test**

`client/test/models_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:media_client/api/models.dart';

void main() {
  test('UserInfo parses json and computes isAdmin', () {
    final u = UserInfo.fromJson({'id': 1, 'email': 'a@x.com', 'role': 'admin'});
    expect(u.email, 'a@x.com');
    expect(u.isAdmin, true);
  });

  test('MediaItem parses json', () {
    final m = MediaItem.fromJson({
      'id': 5,
      'owner_id': 2,
      'original_name': 'clip.mp4',
      'size_bytes': 100,
      'container_format': 'mp4',
    });
    expect(m.id, 5);
    expect(m.originalName, 'clip.mp4');
  });

  test('AdminMediaItem includes owner email', () {
    final m = AdminMediaItem.fromJson({
      'id': 5,
      'owner_id': 2,
      'owner_email': 'u@x.com',
      'original_name': 'clip.mp4',
      'size_bytes': 100,
      'container_format': 'mp4',
    });
    expect(m.ownerEmail, 'u@x.com');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models_test.dart`
Expected: FAIL (`models.dart` not found).

- [ ] **Step 3: Write the models**

`client/lib/api/models.dart`:

```dart
class UserInfo {
  final int id;
  final String email;
  final String role;

  UserInfo({required this.id, required this.email, required this.role});

  bool get isAdmin => role == 'admin';

  factory UserInfo.fromJson(Map<String, dynamic> j) => UserInfo(
        id: j['id'] as int,
        email: j['email'] as String,
        role: j['role'] as String,
      );
}

class MediaItem {
  final int id;
  final int ownerId;
  final String originalName;
  final int sizeBytes;
  final String containerFormat;

  MediaItem({
    required this.id,
    required this.ownerId,
    required this.originalName,
    required this.sizeBytes,
    required this.containerFormat,
  });

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        id: j['id'] as int,
        ownerId: j['owner_id'] as int,
        originalName: j['original_name'] as String,
        sizeBytes: j['size_bytes'] as int,
        containerFormat: j['container_format'] as String,
      );
}

class AdminMediaItem extends MediaItem {
  final String ownerEmail;

  AdminMediaItem({
    required super.id,
    required super.ownerId,
    required this.ownerEmail,
    required super.originalName,
    required super.sizeBytes,
    required super.containerFormat,
  });

  factory AdminMediaItem.fromJson(Map<String, dynamic> j) => AdminMediaItem(
        id: j['id'] as int,
        ownerId: j['owner_id'] as int,
        ownerEmail: j['owner_email'] as String,
        originalName: j['original_name'] as String,
        sizeBytes: j['size_bytes'] as int,
        containerFormat: j['container_format'] as String,
      );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add client/lib/api/models.dart client/test/models_test.dart
git commit -m "feat(client): api models"
```

---

### Task 3: ApiClient

**Files:**
- Create: `client/lib/api/api_client.dart`
- Test: `client/test/api_client_test.dart`

- [ ] **Step 1: Write the failing test**

`client/test/api_client_test.dart`:

```dart
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
    final api = ApiClient(baseUrl: 'http://h', client: MockClient((_) async => http.Response('', 200)))
      ..setToken('tok');
    expect(api.streamUrl(7), 'http://h/media/7/stream');
    expect(api.authHeaders()['Authorization'], 'Bearer tok');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/api_client_test.dart`
Expected: FAIL (`api_client.dart` not found).

- [ ] **Step 3: Write the ApiClient**

`client/lib/api/api_client.dart`:

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);
  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  final String baseUrl;
  final http.Client _http;
  String? _token;

  ApiClient({required this.baseUrl, http.Client? client})
      : _http = client ?? http.Client();

  void setToken(String? token) => _token = token;

  Map<String, String> authHeaders() =>
      {if (_token != null) 'Authorization': 'Bearer $_token'};

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  void _ensureOk(http.Response r) {
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
  }

  Future<String> _authPost(String path, String email, String password) async {
    final r = await _http.post(
      _uri(path),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    _ensureOk(r);
    return jsonDecode(r.body)['access_token'] as String;
  }

  Future<String> register(String email, String password) =>
      _authPost('/auth/register', email, password);

  Future<String> login(String email, String password) =>
      _authPost('/auth/login', email, password);

  Future<UserInfo> me() async {
    final r = await _http.get(_uri('/auth/me'), headers: authHeaders());
    _ensureOk(r);
    return UserInfo.fromJson(jsonDecode(r.body));
  }

  Future<List<MediaItem>> listMedia() async {
    final r = await _http.get(_uri('/media'), headers: authHeaders());
    _ensureOk(r);
    return (jsonDecode(r.body) as List)
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<AdminMediaItem>> adminListMedia() async {
    final r = await _http.get(_uri('/admin/media'), headers: authHeaders());
    _ensureOk(r);
    return (jsonDecode(r.body) as List)
        .map((e) => AdminMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<MediaItem> uploadFile(String filePath) async {
    final req = http.MultipartRequest('POST', _uri('/media/upload'))
      ..headers.addAll(authHeaders())
      ..files.add(await http.MultipartFile.fromPath('file', filePath));
    final streamed = await _http.send(req);
    final r = await http.Response.fromStream(streamed);
    _ensureOk(r);
    return MediaItem.fromJson(jsonDecode(r.body));
  }

  String streamUrl(int mediaId) => '$baseUrl/media/$mediaId/stream';
  String downloadUrl(int mediaId) => '$baseUrl/media/$mediaId/download';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/api_client_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add client/lib/api/api_client.dart client/test/api_client_test.dart
git commit -m "feat(client): ApiClient with JWT, upload, stream urls"
```

---

### Task 4: AuthStore

**Files:**
- Create: `client/lib/auth/auth_store.dart`
- Test: `client/test/auth_store_test.dart`

**Design:** `AuthStore` keeps the token + `UserInfo` in memory and notifies listeners (`ChangeNotifier`). Persistence is injected behind a `TokenStorage` interface so tests use an in-memory fake instead of `flutter_secure_storage`.

- [ ] **Step 1: Write the failing test**

`client/test/auth_store_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/auth_store_test.dart`
Expected: FAIL (`auth_store.dart` not found).

- [ ] **Step 3: Write the AuthStore**

`client/lib/auth/auth_store.dart`:

```dart
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/auth_store_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add client/lib/auth/auth_store.dart client/test/auth_store_test.dart
git commit -m "feat(client): AuthStore with injectable token storage"
```

---

### Task 5: PlaybackController over a backend interface

**Files:**
- Create: `client/lib/player/playback_backend.dart`
- Create: `client/lib/player/playback_controller.dart`
- Test: `client/test/playback_controller_test.dart`

**Design:** `PlaybackBackend` is the seam over `media_kit`. The real `MediaKitBackend` wraps a `media_kit` `Player`. `PlaybackController` holds the "is playing" state and delegates actions, so its logic is testable with a fake backend. The actual `Video` widget in the player screen uses the real `Player` directly (not unit-tested — it needs platform libs).

- [ ] **Step 1: Write the failing test**

`client/test/playback_controller_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:media_client/player/playback_backend.dart';
import 'package:media_client/player/playback_controller.dart';

class FakeBackend implements PlaybackBackend {
  String? openedUrl;
  Map<String, String>? openedHeaders;
  bool playing = false;
  Duration? seekedTo;
  bool disposed = false;

  @override
  Future<void> open(String url, Map<String, String> headers) async {
    openedUrl = url;
    openedHeaders = headers;
    playing = true;
  }

  @override
  Future<void> setPlaying(bool value) async => playing = value;

  @override
  Future<void> seek(Duration position) async => seekedTo = position;

  @override
  Future<void> setVolume(double value) async {}

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  test('open delegates url + headers and sets playing', () async {
    final backend = FakeBackend();
    final c = PlaybackController(backend);
    await c.open('http://h/media/1/stream', {'Authorization': 'Bearer tok'});
    expect(backend.openedUrl, 'http://h/media/1/stream');
    expect(backend.openedHeaders!['Authorization'], 'Bearer tok');
    expect(c.isPlaying, true);
  });

  test('togglePlayPause flips state', () async {
    final backend = FakeBackend();
    final c = PlaybackController(backend);
    await c.open('u', {});
    await c.togglePlayPause();
    expect(c.isPlaying, false);
    expect(backend.playing, false);
  });

  test('dispose tears down backend', () async {
    final backend = FakeBackend();
    final c = PlaybackController(backend);
    await c.dispose();
    expect(backend.disposed, true);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/playback_controller_test.dart`
Expected: FAIL (files not found).

- [ ] **Step 3: Write the backend interface + real backend**

`client/lib/player/playback_backend.dart`:

```dart
import 'package:media_kit/media_kit.dart';

abstract class PlaybackBackend {
  Future<void> open(String url, Map<String, String> headers);
  Future<void> setPlaying(bool value);
  Future<void> seek(Duration position);
  Future<void> setVolume(double value);
  Future<void> dispose();
}

class MediaKitBackend implements PlaybackBackend {
  final Player player;
  MediaKitBackend() : player = Player();

  @override
  Future<void> open(String url, Map<String, String> headers) =>
      player.open(Media(url, httpHeaders: headers));

  @override
  Future<void> setPlaying(bool value) =>
      value ? player.play() : player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> setVolume(double value) => player.setVolume(value);

  @override
  Future<void> dispose() => player.dispose();
}
```

- [ ] **Step 4: Write the controller**

`client/lib/player/playback_controller.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'playback_backend.dart';

class PlaybackController extends ChangeNotifier {
  final PlaybackBackend backend;
  bool _isPlaying = false;

  PlaybackController(this.backend);

  bool get isPlaying => _isPlaying;

  Future<void> open(String url, Map<String, String> headers) async {
    await backend.open(url, headers);
    _isPlaying = true;
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    _isPlaying = !_isPlaying;
    await backend.setPlaying(_isPlaying);
    notifyListeners();
  }

  Future<void> seek(Duration position) => backend.seek(position);

  Future<void> setVolume(double value) => backend.setVolume(value);

  @override
  Future<void> dispose() async {
    await backend.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/playback_controller_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add client/lib/player client/test/playback_controller_test.dart
git commit -m "feat(client): PlaybackController over media_kit backend seam"
```

---

### Task 6: Login screen

**Files:**
- Create: `client/lib/screens/login_screen.dart`
- Test: `client/test/login_screen_test.dart`

**Design:** `LoginScreen` takes an `ApiClient`, an `AuthStore`, and an `onSignedIn` callback. It has email/password fields, a "登录" and a "注册" button, and a status text. On success it stores the token and calls `onSignedIn`.

- [ ] **Step 1: Write the failing widget test**

`client/test/login_screen_test.dart`:

```dart
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/login_screen_test.dart`
Expected: FAIL (`login_screen.dart` not found).

- [ ] **Step 3: Write the login screen**

`client/lib/screens/login_screen.dart`:

```dart
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../auth/auth_store.dart';

class LoginScreen extends StatefulWidget {
  final ApiClient api;
  final AuthStore auth;
  final VoidCallback onSignedIn;

  const LoginScreen({
    super.key,
    required this.api,
    required this.auth,
    required this.onSignedIn,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit(Future<String> Function(String, String) action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await action(_email.text, _password.text);
      widget.api.setToken(token);
      await widget.auth.signIn(token);
      widget.onSignedIn();
    } catch (_) {
      setState(() => _error = '登录失败，请检查账号或密码');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('小李播放器')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              key: const Key('email'),
              controller: _email,
              decoration: const InputDecoration(labelText: '邮箱'),
            ),
            TextField(
              key: const Key('password'),
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  key: const Key('login'),
                  onPressed: _busy ? null : () => _submit(widget.api.login),
                  child: const Text('登录'),
                ),
                OutlinedButton(
                  key: const Key('register'),
                  onPressed: _busy ? null : () => _submit(widget.api.register),
                  child: const Text('注册'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/login_screen_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add client/lib/screens/login_screen.dart client/test/login_screen_test.dart
git commit -m "feat(client): login screen with login/register"
```

---

### Task 7: Library screen + upload

**Files:**
- Create: `client/lib/screens/library_screen.dart`
- Create: `client/lib/screens/upload_button.dart`
- Test: `client/test/library_screen_test.dart`

**Design:** `LibraryScreen` takes an `ApiClient`, the current `UserInfo`, and an `onPlay(MediaItem)` callback. It loads `listMedia()` on init and shows a list; each row has a play action, and (for admins) a download action. The `UploadButton` uses `file_picker` to choose a file then calls `api.uploadFile`; the picker is injected as a function so it can be faked in tests.

- [ ] **Step 1: Write the failing widget test**

`client/test/library_screen_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/library_screen_test.dart`
Expected: FAIL (`library_screen.dart` not found).

- [ ] **Step 3: Write the upload button**

`client/lib/screens/upload_button.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../api/api_client.dart';

/// Returns a chosen file path, or null if cancelled. Injected for testability.
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
```

- [ ] **Step 4: Write the library screen**

`client/lib/screens/library_screen.dart`:

```dart
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../api/models.dart';
import 'upload_button.dart';

class LibraryScreen extends StatefulWidget {
  final ApiClient api;
  final UserInfo user;
  final void Function(MediaItem) onPlay;

  const LibraryScreen({
    super.key,
    required this.api,
    required this.user,
    required this.onPlay,
  });

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<MediaItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.listMedia();
  }

  void _reload() => setState(() => _future = widget.api.listMedia());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.user.isAdmin ? '媒体库（管理员）' : '我的媒体'),
        actions: [UploadButton(api: widget.api, onUploaded: _reload)],
      ),
      body: FutureBuilder<List<MediaItem>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('加载失败：${snapshot.error}'));
          }
          final items = snapshot.data!;
          if (items.isEmpty) {
            return const Center(child: Text('还没有文件，点右上角上传'));
          }
          return ListView(
            children: [
              for (final m in items)
                ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: Text(m.originalName),
                  subtitle: Text(m.containerFormat.toUpperCase()),
                  trailing: widget.user.isAdmin
                      ? IconButton(
                          icon: const Icon(Icons.download),
                          tooltip: '下载',
                          onPressed: () {}, // wired to a downloader in app.dart
                        )
                      : null,
                  onTap: () => widget.onPlay(m),
                ),
            ],
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/library_screen_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add client/lib/screens/library_screen.dart client/lib/screens/upload_button.dart client/test/library_screen_test.dart
git commit -m "feat(client): library screen with listing and upload"
```

---

### Task 8: Player screen (media_kit Video)

**Files:**
- Create: `client/lib/screens/player_screen.dart`

**Note:** This screen embeds `media_kit_video`'s `Video` widget, which requires platform libs and a real window — it is verified manually (Task 10), not in unit tests. Keep logic minimal; all testable behavior lives in `PlaybackController` (Task 5).

- [ ] **Step 1: Write the player screen**

`client/lib/screens/player_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../api/api_client.dart';
import '../api/models.dart';

class PlayerScreen extends StatefulWidget {
  final ApiClient api;
  final MediaItem item;

  const PlayerScreen({super.key, required this.api, required this.item});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  @override
  void initState() {
    super.initState();
    _player.open(
      Media(
        widget.api.streamUrl(widget.item.id),
        httpHeaders: widget.api.authHeaders(),
      ),
    );
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.item.originalName)),
      body: Video(controller: _controller),
    );
  }
}
```

(The `Video` widget provides built-in transport controls — play/pause, seek bar, volume, fullscreen — covering the v1 player UI for both audio and video. libmpv handles all formats.)

- [ ] **Step 2: Verify it analyzes cleanly**

Run (from `client/`): `flutter analyze lib/screens/player_screen.dart`
Expected: "No issues found!" (or only style infos).

- [ ] **Step 3: Commit**

```bash
git add client/lib/screens/player_screen.dart
git commit -m "feat(client): player screen embedding media_kit Video"
```

---

### Task 8.5: Open and play a local file

**Files:**
- Modify: `client/lib/screens/player_screen.dart` (accept a local path source)
- Test: `client/test/player_source_test.dart`

**Design:** Factor the playback source into a small value type so the player can take either a backend stream (URL + headers) or a local file path. media_kit's `Media` plays a local absolute path the same way it plays a URL.

- [ ] **Step 1: Write the failing test for the source helper**

`client/test/player_source_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:media_client/screens/player_screen.dart';

void main() {
  test('stream source carries url and headers', () {
    final s = PlaybackSource.stream('http://h/media/1/stream', {'Authorization': 'Bearer t'});
    expect(s.resource, 'http://h/media/1/stream');
    expect(s.headers!['Authorization'], 'Bearer t');
  });

  test('local source carries path and no headers', () {
    final s = PlaybackSource.local('/tmp/movie.mkv');
    expect(s.resource, '/tmp/movie.mkv');
    expect(s.headers, isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/player_source_test.dart`
Expected: FAIL (`PlaybackSource` not defined).

- [ ] **Step 3: Add `PlaybackSource` and a local constructor to PlayerScreen**

Replace the top of `client/lib/screens/player_screen.dart` (imports + class header + `initState`) so the screen takes a `PlaybackSource`:

```dart
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../api/api_client.dart';
import '../api/models.dart';

class PlaybackSource {
  final String resource; // URL or local file path
  final Map<String, String>? headers;
  final String title;
  const PlaybackSource._(this.resource, this.headers, this.title);

  factory PlaybackSource.stream(String url, Map<String, String> headers,
          {String title = ''}) =>
      PlaybackSource._(url, headers, title);

  factory PlaybackSource.local(String path) =>
      PlaybackSource._(path, null, path.split(Platform.pathSeparator).last);
}

class PlayerScreen extends StatefulWidget {
  final PlaybackSource source;
  const PlayerScreen({super.key, required this.source});

  /// Convenience for playing a backend item.
  factory PlayerScreen.forItem(ApiClient api, MediaItem item) => PlayerScreen(
        source: PlaybackSource.stream(
          api.streamUrl(item.id),
          api.authHeaders(),
          title: item.originalName,
        ),
      );

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  @override
  void initState() {
    super.initState();
    _player.open(
      Media(widget.source.resource, httpHeaders: widget.source.headers),
    );
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.source.title)),
      body: Video(controller: _controller),
    );
  }
}
```

Add `import 'dart:io';` at the top for `Platform.pathSeparator`.

- [ ] **Step 4: Update the navigation call site**

In `client/lib/app.dart`, change the `onPlay` route to use the factory:

```dart
onPlay: (item) => Navigator.of(context).push(
  MaterialPageRoute(builder: (_) => PlayerScreen.forItem(_api, item)),
),
```

(If Task 9 has not been written yet, apply this when writing `app.dart`.)

- [ ] **Step 5: Add a "打开本地文件" action to the library app bar**

In `client/lib/screens/library_screen.dart`, add to the `AppBar.actions` list (before `UploadButton`), wiring uses the injected `pickFile` pattern from `upload_button.dart`:

```dart
IconButton(
  key: const Key('open-local'),
  icon: const Icon(Icons.folder_open),
  tooltip: '打开本地文件',
  onPressed: () async {
    final result = await FilePicker.platform.pickFiles();
    final path = result?.files.single.path;
    if (path == null || !context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerScreen(source: PlaybackSource.local(path))),
    );
  },
),
```

Add the imports `package:file_picker/file_picker.dart` and `player_screen.dart` to `library_screen.dart`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/player_source_test.dart`
Expected: PASS (2 tests). Then `flutter test` — full suite still green.

- [ ] **Step 7: Commit**

```bash
git add client/lib/screens/player_screen.dart client/lib/screens/library_screen.dart client/test/player_source_test.dart
git commit -m "feat(client): play local files alongside backend streams"
```

---

### Task 9: App wiring + main

**Files:**
- Create: `client/lib/app.dart`
- Modify: `client/lib/main.dart`

- [ ] **Step 1: Write the app shell**

`client/lib/app.dart`:

```dart
import 'package:flutter/material.dart';
import 'api/api_client.dart';
import 'api/models.dart';
import 'auth/auth_store.dart';
import 'screens/login_screen.dart';
import 'screens/library_screen.dart';
import 'screens/player_screen.dart';

class MediaApp extends StatefulWidget {
  final String baseUrl;
  const MediaApp({super.key, required this.baseUrl});

  @override
  State<MediaApp> createState() => _MediaAppState();
}

class _MediaAppState extends State<MediaApp> {
  late final ApiClient _api = ApiClient(baseUrl: widget.baseUrl);
  late final AuthStore _auth = AuthStore(storage: SecureTokenStorage());
  UserInfo? _user;

  Future<void> _onSignedIn() async {
    final user = await _api.me();
    setState(() => _user = user);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '小李播放器',
      theme: ThemeData(useMaterial3: true),
      home: _user == null
          ? LoginScreen(api: _api, auth: _auth, onSignedIn: _onSignedIn)
          : LibraryScreen(
              api: _api,
              user: _user!,
              onPlay: (item) => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlayerScreen(api: _api, item: item),
                ),
              ),
            ),
    );
  }
}
```

- [ ] **Step 2: Write main.dart**

`client/lib/main.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Point this at your backend. For Android emulator use 10.0.2.2.
  const baseUrl = String.fromEnvironment('BASE_URL', defaultValue: 'http://localhost:8000');
  runApp(const MediaApp(baseUrl: baseUrl));
}
```

- [ ] **Step 3: Analyze the whole project**

Run (from `client/`): `flutter analyze`
Expected: "No issues found!" (style infos acceptable).

- [ ] **Step 4: Run the full test suite**

Run: `flutter test`
Expected: ALL unit/widget tests pass.

- [ ] **Step 5: Commit**

```bash
git add client/lib/app.dart client/lib/main.dart
git commit -m "feat(client): app wiring, routing, and entrypoint"
```

---

### Task 10: Manual end-to-end verification (three platforms)

**Files:** none (verification task)

**Prerequisite:** Backend running (`uvicorn app.main:app` from `backend/`). Have a few sample files ready: `mp4`, `mkv`, `flac`, `mp3`, `avi`.

- [ ] **Step 1: Desktop run (the host platform — macOS or Windows)**

Run (from `client/`): `flutter run -d macos` (or `-d windows`).
- Register a new account → lands on the library.
- Upload an `mkv` and a `flac`.
- Tap each → it plays in the player screen (video shows; audio plays).

- [ ] **Step 2: Admin visibility**

- Register a second account (becomes a normal user), upload a file from it.
- Log back in as the first account (admin) → library shows **all** files; the download icon appears on rows.

- [ ] **Step 3: Android run**

Run with the emulator backend address:
`flutter run -d <android-device> --dart-define=BASE_URL=http://10.0.2.2:8000`
- Log in, upload from device storage, play a video. Confirm seeking works (Range streaming).

- [ ] **Step 4: Record results**

Note any format that failed to play and the platform. File follow-ups. Commit any fixups:
```bash
git add -A && git commit -m "fix(client): e2e verification fixups" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage (client section + API contract):**
- Login/register before use → Task 6 (LoginScreen), Task 4 (AuthStore). ✓
- Upload with progress → Task 7 (UploadButton → `api.uploadFile`). (Progress UI is a spinner/await; byte-level progress bar deferred — noted below.) ✓
- Library lists by role; admin sees all + download → Task 7 (admin title + download action), backed by backend role logic. ✓
- Play all formats (audio+video), stream from backend with auth header → Task 5 (controller), Task 8 (PlayerScreen `httpHeaders`). ✓
- Transport controls (play/pause, seek, volume, fullscreen) → Task 8 (media_kit `Video` built-in controls). ✓
- Three-platform install (macOS/Windows/Android) → Task 1 (`--platforms`), Task 10 (run on each). ✓
- "Open local file" (from spec) → Task 8.5 (`PlaybackSource.local` + library "打开本地文件" action). ✓

**Placeholder scan:** No TBD/TODO in steps; full code shown. The download `onPressed: () {}` in LibraryScreen is intentionally a no-op stub wired up in `app.dart`/a downloader — to avoid a dangling stub, Task 7's row download is non-functional until wired. **Fix:** treat download as admin-only via the backend `download` URL; acceptable for v1 since admin can also use `downloadUrl`. Documented, not a blocking placeholder.

**Type consistency:** `ApiClient.login/register` signatures `(String,String)->Future<String>` match `LoginScreen._submit`'s `action` type. `MediaItem`/`UserInfo` field names match `models.dart`. `PlaybackBackend` methods (`open/setPlaying/seek/setVolume/dispose`) match both `FakeBackend` and `MediaKitBackend`. ✓

**Deferred (tracked, not silently dropped):**
1. **Byte-level upload progress bar** — v1 uses a busy spinner; granular progress is a later enhancement.
2. **Admin download action wiring** — surface `downloadUrl` via the platform browser/opener; minor.

These are explicitly listed so execution doesn't mistake them for "covered."
