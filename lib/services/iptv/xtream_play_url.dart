import 'package:javp/models/iptv_source.dart';

const _pathKinds = {'live', 'movie', 'series'};

/// Credential-free Xtream stream URL stored on [MediaItem.playUrl].
///
/// Playback reconstructs `/live/user/pass/id.ts` via [injectXtreamCredentials].
String xtreamStoredStreamUrl({
  required String base,
  required String kind,
  required String streamId,
  required String extension,
}) {
  final b = base.replaceAll(RegExp(r'/+$'), '');
  final ext = extension.replaceAll('.', '');
  return '$b/$kind/$streamId.$ext';
}

/// True when [url] looks like an Xtream live/VOD/timeshift path or php form.
bool isXtreamStreamUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.pathSegments.isEmpty) return false;
  final path = uri.path.toLowerCase();
  if (path.contains('timeshift.php') ||
      path.contains('player_api.php') ||
      path.contains('xmltv.php')) {
    return true;
  }
  final segs = uri.pathSegments.map((s) => s.toLowerCase()).toList();
  return segs.contains('live') ||
      segs.contains('movie') ||
      segs.contains('series') ||
      segs.contains('timeshift');
}

/// Drop username/password from Xtream path and query so backups / DBs
/// do not persist panel credentials inside stream URLs.
String stripXtreamCredentials(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || (!uri.hasScheme && url.trim().isEmpty)) return url;

  final q = Map<String, String>.from(uri.queryParameters);
  var queryChanged = false;
  for (final key in [...q.keys]) {
    final k = key.toLowerCase();
    if (k == 'username' ||
        k == 'password' ||
        k == 'user' ||
        k == 'pass' ||
        k == 'pwd') {
      q.remove(key);
      queryChanged = true;
    }
  }

  final segs = List<String>.from(uri.pathSegments);
  var pathChanged = false;
  for (var i = 0; i < segs.length; i++) {
    final kind = segs[i].toLowerCase();
    if (_pathKinds.contains(kind)) {
      // `/live/user/pass/id.ts` → `/live/id.ts`
      if (i + 3 < segs.length && segs[i + 3].contains('.')) {
        segs.removeRange(i + 1, i + 3);
        pathChanged = true;
      }
      break;
    }
    if (kind == 'timeshift') {
      // `/timeshift/user/pass/minutes/stamp/id.ts` → `/timeshift/minutes/stamp/id.ts`
      if (i + 5 < segs.length && segs[i + 5].contains('.')) {
        segs.removeRange(i + 1, i + 3);
        pathChanged = true;
      }
      break;
    }
  }

  if (!queryChanged && !pathChanged) return url;
  return _rebuildUri(uri, segs, q);
}

/// Put the source's current username/password back into a stored Xtream URL.
String injectXtreamCredentials(String url, IptvSource source) {
  final user = source.username ?? '';
  final pass = source.password ?? '';
  if (user.isEmpty && pass.isEmpty) return url;
  final uri = Uri.tryParse(url);
  if (uri == null) return url;

  final pathLower = uri.path.toLowerCase();
  if (pathLower.contains('timeshift.php') ||
      pathLower.contains('player_api.php') ||
      pathLower.contains('xmltv.php')) {
    final q = Map<String, String>.from(uri.queryParameters)
      ..['username'] = user
      ..['password'] = pass;
    return uri.replace(queryParameters: q).toString();
  }

  final segs = List<String>.from(uri.pathSegments);
  for (var i = 0; i < segs.length; i++) {
    final kind = segs[i].toLowerCase();
    if (_pathKinds.contains(kind)) {
      if (i + 1 >= segs.length) break;
      if (segs[i + 1].contains('.')) {
        segs.insert(i + 1, user);
        segs.insert(i + 2, pass);
      } else if (i + 3 < segs.length && segs[i + 3].contains('.')) {
        segs[i + 1] = user;
        segs[i + 2] = pass;
      }
      break;
    }
    if (kind == 'timeshift') {
      if (i + 3 < segs.length && segs[i + 3].contains('.')) {
        segs.insert(i + 1, user);
        segs.insert(i + 2, pass);
      } else if (i + 5 < segs.length && segs[i + 5].contains('.')) {
        segs[i + 1] = user;
        segs[i + 2] = pass;
      }
      break;
    }
  }
  return _rebuildUri(uri, segs, Map<String, String>.from(uri.queryParameters));
}

bool isXtreamTimeshiftUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return path.contains('timeshift');
}

String? xtreamUrlExtension(String url) {
  final uri = Uri.tryParse(url);
  final file = uri?.pathSegments.isNotEmpty == true
      ? uri!.pathSegments.last
      : url;
  final dot = file.lastIndexOf('.');
  if (dot < 0 || dot == file.length - 1) return null;
  final ext = file.substring(dot + 1);
  if (ext.contains('/') || ext.length > 8) return null;
  return ext;
}

String _rebuildUri(Uri uri, List<String> segs, Map<String, String> query) {
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    pathSegments: segs,
    queryParameters: query.isEmpty ? null : query,
  ).toString();
}
