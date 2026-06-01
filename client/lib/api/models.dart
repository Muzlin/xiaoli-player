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
