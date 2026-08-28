import 'package:flutter/material.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/theme/app_theme.dart';

/// Compact “what you can watch” line for a title family.
///
/// Lists available audio and caption languages plus ceiling quality.
/// Play auto-picks an encode; tracks and quality are switched in the player.
class VodAvailabilityLine extends StatelessWidget {
  const VodAvailabilityLine({
    super.key,
    required this.layout,
    this.preferredLangs = const [],
  });

  final VodFamilyLayout layout;
  final List<String> preferredLangs;

  @override
  Widget build(BuildContext context) {
    final text = layout.availabilityLabel(preferredLangs: preferredLangs);
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 13,
          height: 1.35,
        ),
      ),
    );
  }
}
