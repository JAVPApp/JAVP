import 'package:flutter/material.dart';
import 'package:javp/models/iptv_source.dart';

/// Preset swatches for source badges / filter chips.
const List<Color> kSourceColorPresets = [
  Color(0xFFE53935),
  Color(0xFFFB8C00),
  Color(0xFFFDD835),
  Color(0xFF43A047),
  Color(0xFF00ACC1),
  Color(0xFF1E88E5),
  Color(0xFF5E35B1),
  Color(0xFFD81B60),
  Color(0xFF6D4C41),
  Color(0xFF78909C),
];

/// Encode a [Color] as `#RRGGBB` for [IptvSource.color].
String encodeSourceColor(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// Parse `#RRGGBB` / `#AARRGGBB` (optional `#`) into a [Color].
Color? parseSourceColor(String? raw) {
  if (raw == null) return null;
  var hex = raw.trim();
  if (hex.isEmpty) return null;
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  final value = int.tryParse(hex, radix: 16);
  if (value == null) return null;
  return Color(value);
}

/// Dark, readable badge fill tinted with [sourceColor].
Color sourceBadgeFill(Color sourceColor) {
  return Color.alphaBlend(
    sourceColor.withValues(alpha: 0.72),
    const Color(0xFF000000),
  );
}

/// Next unused preset hex for a newly added source (`#RRGGBB`).
///
/// Prefers the first preset not already taken (case-insensitive). When every
/// preset is in use, cycles by [existingCount].
String nextDefaultSourceColor(
  Iterable<String?> existingColors, {
  int existingCount = 0,
}) {
  final used = <int>{};
  for (final raw in existingColors) {
    final parsed = parseSourceColor(raw);
    if (parsed != null) used.add(parsed.toARGB32() & 0xFFFFFF);
  }
  for (final preset in kSourceColorPresets) {
    final rgb = preset.toARGB32() & 0xFFFFFF;
    if (!used.contains(rgb)) return encodeSourceColor(preset);
  }
  final n = kSourceColorPresets.length;
  return encodeSourceColor(kSourceColorPresets[existingCount % n]);
}

/// Fill in badge colors for sources that have none (imports / pairing).
List<IptvSource> assignMissingSourceColors(List<IptvSource> list) {
  final out = <IptvSource>[];
  for (var i = 0; i < list.length; i++) {
    final source = list[i];
    final hasColor =
        source.color != null && source.color!.trim().isNotEmpty;
    if (hasColor) {
      out.add(source);
      continue;
    }
    out.add(
      source.copyWith(
        color: nextDefaultSourceColor(
          out.map((s) => s.color),
          existingCount: out.length,
        ),
      ),
    );
  }
  return out;
}
