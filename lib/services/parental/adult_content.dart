// Shared helpers for source-marked adult / mature-only content.
// Missing flags and unknown ratings are treated as not adult so panels
// without the field never hide titles by accident.

/// Parse panel / JSON 0/1/bool/`"true"` style adult flags.
bool truthyAdultFlag(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = '$value'.trim().toLowerCase();
  if (text.isEmpty ||
      text == 'null' ||
      text == 'false' ||
      text == '0' ||
      text == 'no') {
    return false;
  }
  return text == '1' || text == 'true' || text == 'yes' || text == 'adult';
}

/// Explicit adult / pornographic content ratings (not general mature like TV-MA).
bool isAdultContentRating(String? rating) {
  final raw = rating?.trim();
  if (raw == null || raw.isEmpty) return false;
  final n = raw.toLowerCase().replaceAll(RegExp(r'[\s_\-]'), '');
  const exact = {
    'xxx',
    'xx',
    'x',
    'ao',
    'adultsonly',
    'r18',
    'r18+',
    '18+',
    '+18',
    '18',
    '18rated',
    'nc17', // theatrical adults-only; treat as adult for lock filtering
  };
  if (exact.contains(n)) return true;
  final lower = raw.toLowerCase();
  if (lower.contains('adults only')) return true;
  if (RegExp(r'\bxxx\b').hasMatch(lower)) return true;
  if (RegExp(r'\b18\s*\+').hasMatch(lower)) return true;
  return false;
}

/// Genre / tag / label tokens that mark adult shelves or titles.
bool isAdultLabelToken(String? raw) {
  final t = raw?.trim().toLowerCase();
  if (t == null || t.isEmpty) return false;
  if (t == 'adult' ||
      t == 'adults' ||
      t == 'xxx' ||
      t == 'porn' ||
      t == 'pornography' ||
      t == 'erotica' ||
      t == 'erotic' ||
      t == 'nsfw' ||
      t == '18+' ||
      t == '+18') {
    return true;
  }
  // Avoid matching "adultery" / "adulthood".
  return RegExp(
    r'(^|[\s|/_,\-])(adult|adults|xxx|porn|pornography|erotica|erotic|nsfw|18\+|(\+18))([\s|/_,\-]|$)',
  ).hasMatch(t);
}

bool anyAdultLabel(Iterable<String>? labels) {
  if (labels == null) return false;
  for (final label in labels) {
    if (isAdultLabelToken(label)) return true;
  }
  return false;
}

/// Combine explicit flag + rating + label/genre/tag signals.
bool resolveIsAdult({
  Object? flag,
  String? contentRating,
  Iterable<String>? labels,
  Iterable<String>? genres,
  Iterable<String>? tags,
}) {
  if (truthyAdultFlag(flag)) return true;
  if (isAdultContentRating(contentRating)) return true;
  if (anyAdultLabel(labels)) return true;
  if (anyAdultLabel(genres)) return true;
  if (anyAdultLabel(tags)) return true;
  return false;
}
