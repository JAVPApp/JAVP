import 'package:flutter/material.dart';
import 'package:javp/widgets/parental_controls_settings.dart';

/// PIN, lock-on-resume, hidden Live groups / sources, adult filter.
class SettingsParentalTab extends StatelessWidget {
  const SettingsParentalTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: const [ParentalControlsSettingsSection(showTitle: false)],
    );
  }
}
