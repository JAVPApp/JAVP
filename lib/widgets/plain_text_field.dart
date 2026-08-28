import 'package:flutter/material.dart';
import 'package:javp/widgets/javp_text_field.dart';

/// A [TextField] for values the keyboard must not try to improve: URLs, hosts,
/// usernames, tokens and API keys.
///
/// Left to its defaults, a soft keyboard capitalises the first word and
/// autocorrects the rest, so `iptv-org.github.io/iptv/countries/fr.m3u` is
/// silently entered as `.../IPTV/...` and the playlist 404s with nothing on
/// screen to explain why. Password fields escape this because the platform
/// treats them specially; everything else has to ask.
class PlainTextField extends StatelessWidget {
  const PlainTextField({
    super.key,
    required this.controller,
    this.decoration,
    this.keyboardType,
    this.obscureText = false,
    this.maxLines = 1,
    this.enabled,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final InputDecoration? decoration;

  /// Pass [TextInputType.url] for addresses so the keyboard offers `/` and
  /// `.com` up front.
  final TextInputType? keyboardType;
  final bool obscureText;

  /// Long values such as magnet links wrap rather than scroll sideways.
  final int maxLines;
  final bool? enabled;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return JavpTextField(
      controller: controller,
      decoration: decoration,
      keyboardType: keyboardType,
      obscureText: obscureText,
      maxLines: maxLines,
      enabled: enabled,
      autofocus: autofocus,
      onSubmitted: onSubmitted,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.none,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
    );
  }
}
