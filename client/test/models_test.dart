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
