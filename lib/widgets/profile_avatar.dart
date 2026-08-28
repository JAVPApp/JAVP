import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:provider/provider.dart';

/// Circular profile photo, or the name initial when none is set.
class ProfileAvatar extends StatefulWidget {
  const ProfileAvatar({
    super.key,
    required this.profile,
    this.radius = 20,
    this.highlighted = false,
  });

  final Profile profile;
  final double radius;
  final bool highlighted;

  @override
  State<ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<ProfileAvatar> {
  Future<Uint8List?>? _photo;
  String? _loadedProfileId;
  String? _loadedToken;
  int? _loadedRevision;

  @override
  Widget build(BuildContext context) {
    final revision = context.select<ProfileProvider, int>(
      (provider) => provider.avatarRevision(widget.profile.id),
    );
    if (_photo == null ||
        _loadedProfileId != widget.profile.id ||
        _loadedToken != widget.profile.avatarToken ||
        _loadedRevision != revision) {
      _loadedProfileId = widget.profile.id;
      _loadedToken = widget.profile.avatarToken;
      _loadedRevision = revision;
      _photo = context.read<ProfileProvider>().avatars.load(widget.profile.id);
    }

    final bg = widget.highlighted
        ? AppColors.accent
        : AppColors.accent.withValues(alpha: .2);
    final fg = widget.highlighted ? Colors.black : AppColors.text;
    final initial = widget.profile.name.trim().isEmpty
        ? '?'
        : widget.profile.name.characters.first.toUpperCase();

    if (!widget.profile.hasAvatar) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundColor: bg,
        child: Text(
          initial,
          style: TextStyle(
            color: fg,
            fontWeight: FontWeight.bold,
            fontSize: widget.radius * 0.9,
          ),
        ),
      );
    }

    return FutureBuilder<Uint8List?>(
      future: _photo,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return CircleAvatar(
            radius: widget.radius,
            backgroundColor: bg,
            child: Text(
              initial,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.bold,
                fontSize: widget.radius * 0.9,
              ),
            ),
          );
        }
        return CircleAvatar(
          radius: widget.radius,
          backgroundColor: bg,
          backgroundImage: MemoryImage(bytes),
        );
      },
    );
  }
}

/// Rail brand mark: active profile photo when set, else the play icon.
class ActiveProfileAvatar extends StatelessWidget {
  const ActiveProfileAvatar({super.key, this.radius = 13});

  final double radius;

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileProvider>().activeProfile;
    if (profile == null || !profile.hasAvatar) {
      return Icon(
        Icons.play_circle_fill_rounded,
        color: AppColors.accent,
        size: radius * 2,
      );
    }
    return ProfileAvatar(profile: profile, radius: radius, highlighted: true);
  }
}
