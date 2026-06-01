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

  /// 下载文件字节（带鉴权头），属主或管理员可用。
  Future<List<int>> downloadBytes(int mediaId) async {
    final r = await _http.get(_uri('/media/$mediaId/download'),
        headers: authHeaders());
    _ensureOk(r);
    return r.bodyBytes;
  }

  String streamUrl(int mediaId) => '$baseUrl/media/$mediaId/stream';
  String downloadUrl(int mediaId) => '$baseUrl/media/$mediaId/download';
}
