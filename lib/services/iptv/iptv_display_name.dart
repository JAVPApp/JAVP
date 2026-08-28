/// Strip decorative wrappers IPTV panels put on category / group names.
///
/// Keeps the raw string in the DB; only the UI should call this.
/// `### FRANCE ###` → `FRANCE`, `--- SPORTS ---` → `SPORTS`.
///
/// Region tags like `[FR] FAMILLE` are left intact — only a *matching*
/// bracket pair that wraps the whole name (`[FRANCE]`) is peeled.
String cleanIptvDisplayName(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return raw;

  // Peel matching wrapper runs (`### … ###`, `*** … ***`, `--- … ---`).
  final wrapped = RegExp(r'^([=#*_~\-\.]{2,})\s*(.+?)\s*\1$');
  for (var i = 0; i < 3; i++) {
    final m = wrapped.firstMatch(s);
    if (m == null) break;
    s = m.group(2)!.trim();
  }

  // Unmatched leading / trailing rune decoration (not brackets — those are
  // handled below so `[FR] Movies` is not turned into `FR] Movies`).
  s = s.replaceFirst(RegExp(r'^[-=*_#~.]{2,}\s*'), '');
  s = s.replaceFirst(RegExp(r'\s*[-=*_#~.]{2,}$'), '');

  // Peel whole-string bracket wraps only: `[FRANCE]` / `{SPORTS}` / `(FOO)`.
  for (var i = 0; i < 3; i++) {
    if (s.length < 2) break;
    final open = s[0];
    final close = s[s.length - 1];
    final matched =
        (open == '[' && close == ']') ||
        (open == '{' && close == '}') ||
        (open == '(' && close == ')');
    if (!matched) break;
    final inner = s.substring(1, s.length - 1).trim();
    if (inner.isEmpty) break;
    s = inner;
  }

  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.isEmpty ? raw.trim() : s;
}
