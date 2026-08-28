import 'dart:isolate';

import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/iptv_search_query.dart';

/// Precomputed lowercase search text for VOD / library rows.
///
/// Search used to rebuild
/// `"$title $group $subtitle $channelName $streamId".toLowerCase()` on every
/// keystroke for every cached title. On ~200k Xtream rows that alone stalls
/// the UI isolate. Build once per cache revision; reuse across queries.
///
/// Native Search uses [VodCatalogDb.searchFts]. The haystack map is
/// web / test / leftover RAM cache only — do not refill `_vodStreamCache`
/// from SQLite just to build hay.
class VodSearchIndex {
  VodSearchIndex._();

  /// Above this, Search prefers an isolate scan of warm hay pairs.
  /// Shipping ~MediaItem graphs through [Isolate.run] crashed Windows; strings
  /// only are safe (same lesson as VOD JSON parse isolates).
  static const isolateFilterMinRows = 8000;

  /// Same fields as the historical [LibraryProvider.searchLocalLibrary] haystack.
  static String hayFor(MediaItem m) => IptvSearchQuery.hayForItem(m);

  /// True when every whitespace token is a substring of [hayLower].
  static bool matchesTokens(String hayLower, List<String> tokens) {
    for (final t in tokens) {
      if (!hayLower.contains(t)) return false;
    }
    return true;
  }

  /// Build id → hay for [items]. Caller owns yielding on large libraries.
  static Map<String, String> buildHayMap(Iterable<MediaItem> items) {
    final out = <String, String>{};
    for (final m in items) {
      out[m.id] = hayFor(m);
    }
    return out;
  }

  /// Pack warm hay into a flat `[id0, hay0, id1, hay1, …]` payload for isolates.
  static List<String> packFlat(Map<String, String> hayById) {
    final out = List<String>.filled(hayById.length * 2, '', growable: false);
    var i = 0;
    for (final e in hayById.entries) {
      out[i++] = e.key;
      out[i++] = e.value;
    }
    return out;
  }

  /// Filter packed hay (see [packFlat]).
  static List<String> filterFlatIds(List<String> flat, List<String> tokens) {
    final out = <String>[];
    for (var i = 0; i + 1 < flat.length; i += 2) {
      if (matchesTokens(flat[i + 1], tokens)) out.add(flat[i]);
    }
    return out;
  }
}

/// Isolate entry — must stay top-level so the closure cannot capture
/// [LibraryProvider] (streams / plugins are unsendable).
Future<List<String>> vodSearchFilterInIsolate(
  List<String> flat,
  List<String> tokens,
) {
  return Isolate.run(() => VodSearchIndex.filterFlatIds(flat, tokens));
}
