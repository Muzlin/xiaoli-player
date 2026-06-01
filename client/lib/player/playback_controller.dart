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
