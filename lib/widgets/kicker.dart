import 'package:flutter/material.dart';

/// The small accent label that sits above a heading on javp.app.
///
/// Uppercasing with wide tracking is a Latin-script flourish. Turkish and
/// Azeri lose the dotless i, Greek drops its accents, and cased letters do
/// not exist at all in CJK, Arabic, Hebrew, Thai or Devanagari — those keep
/// the string as written and drop the extra tracking.
class Kicker extends StatelessWidget {
  const Kicker(this.label, {super.key, this.color});

  static const _keepAsWritten = {
    'tr', 'az', 'el', 'ja', 'zh', 'ko', 'ar', 'he', 'th', 'hi',
  };

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;
    final transform = !_keepAsWritten.contains(language);
    final base = Theme.of(context).textTheme.labelSmall;

    return Text(
      transform ? label.toUpperCase() : label,
      style: transform
          ? base?.copyWith(color: color)
          : base?.copyWith(color: color, letterSpacing: 0.4),
    );
  }
}
