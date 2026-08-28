import 'package:flutter/material.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';

class GuideStep extends StatelessWidget {
  const GuideStep({super.key, required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$number.',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AppColors.textMuted, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class OpenLinkButton extends StatelessWidget {
  const OpenLinkButton({super.key, required this.label, required this.url});

  final String label;
  final String url;

  Future<void> _open() async {
    final uri = Uri.parse(url);
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _open,
      icon: const Icon(Icons.open_in_new_rounded, size: 18),
      label: Text(label),
    );
  }
}

class SettingsInfoTile extends StatelessWidget {
  const SettingsInfoTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: AppColors.accent),
      title: Text(title, style: const TextStyle(color: AppColors.text)),
      subtitle: Text(subtitle),
    );
  }
}
