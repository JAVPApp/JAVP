/// A named on-device identity: its own history, sources, and preferences.
///
/// Profiles are also the unit of sync — one profile maps to one folder in the
/// remote sync target.
class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.createdAt,
    this.colorValue,
    this.avatarEmoji,
    this.avatarToken,
    this.avatarUpdatedAt,
  });

  /// Profile that owns the pre-profiles storage keys, so existing installs
  /// keep their data without a migration.
  static const defaultId = 'default';

  final String id;
  final String name;
  final DateTime createdAt;
  final int? colorValue;
  final String? avatarEmoji;

  /// Opaque revision for the current photo file (null = no custom photo).
  /// Used as an [Image] cache key; bytes live in [ProfileAvatarStore].
  final String? avatarToken;

  /// Last time the photo was set or cleared — drives sync last-write-wins.
  final DateTime? avatarUpdatedAt;

  bool get isDefault => id == defaultId;

  bool get hasAvatar => avatarToken != null && avatarToken!.isNotEmpty;

  Profile copyWith({
    String? name,
    int? colorValue,
    String? avatarEmoji,
    String? avatarToken,
    DateTime? avatarUpdatedAt,
    bool clearAvatar = false,
  }) {
    return Profile(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      colorValue: colorValue ?? this.colorValue,
      avatarEmoji: avatarEmoji ?? this.avatarEmoji,
      avatarToken: clearAvatar ? null : (avatarToken ?? this.avatarToken),
      avatarUpdatedAt: avatarUpdatedAt ?? this.avatarUpdatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'colorValue': colorValue,
    'avatarEmoji': avatarEmoji,
    if (avatarToken != null) 'avatarToken': avatarToken,
    if (avatarUpdatedAt != null)
      'avatarUpdatedAt': avatarUpdatedAt!.toUtc().toIso8601String(),
  };

  static Profile? tryFromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    final name = (json['name'] as String?)?.trim();
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;
    final token = (json['avatarToken'] as String?)?.trim();
    return Profile(
      id: id,
      name: name,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      colorValue: (json['colorValue'] as num?)?.toInt(),
      avatarEmoji: (json['avatarEmoji'] as String?)?.trim(),
      avatarToken: (token == null || token.isEmpty) ? null : token,
      avatarUpdatedAt: DateTime.tryParse(
        json['avatarUpdatedAt'] as String? ?? '',
      )?.toUtc(),
    );
  }
}
