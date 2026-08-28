import 'dart:io';

/// Best-effort public tracker list (same source the old libtorrent wrapper used).
const kPublicTrackersUrl =
    'https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt';

/// Append `&tr=` entries that are not already on [magnetUri].
String injectTrackers(String magnetUri, Iterable<String> trackers) {
  var uri = magnetUri;
  for (final tr in trackers) {
    final t = tr.trim();
    if (t.isEmpty) continue;
    final encoded = Uri.encodeComponent(t);
    if (uri.contains(encoded) || uri.contains(t)) continue;
    uri += '&tr=$encoded';
  }
  return uri;
}

/// Fetch [kPublicTrackersUrl]. Empty list on any failure.
Future<List<String>> fetchPublicTrackers({
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    final req = await client.getUrl(Uri.parse(kPublicTrackersUrl));
    final res = await req.close();
    if (res.statusCode != 200) {
      client.close(force: true);
      return const [];
    }
    final body = await res.transform(const SystemEncoding().decoder).join();
    client.close(force: true);
    return body
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}
