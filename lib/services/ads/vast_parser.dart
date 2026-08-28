import 'package:javp/services/ads/vast_macros.dart';
import 'package:javp/services/ads/vast_models.dart';
import 'package:xml/xml.dart';

export 'package:javp/services/ads/vast_macros.dart';

/// Parse a VAST 2/3/4.x or VMAP document into linear creatives / follow-up tags.
VastDocument parseVastXml(String xml) {
  final trimmed = xml.trim();
  if (trimmed.isEmpty) {
    return const VastDocument(empty: true);
  }
  try {
    final document = XmlDocument.parse(trimmed);
    final root = document.rootElement;
    final local = root.localName.toLowerCase();
    if (local == 'vmap') {
      return _parseVmap(root);
    }
    return _parseVast(root);
  } on XmlException {
    return const VastDocument(parseError: true);
  } on FormatException {
    return const VastDocument(parseError: true);
  }
}

/// Replace IAB VAST 4.2 macros. Values placed into URLs are percent-encoded.
String replaceVastMacros(
  String url, {
  DateTime? now,
  Duration playhead = Duration.zero,
  String? errorCode,
  String? reason,
  VastMacroContext? context,
}) {
  final at = now ?? DateTime.now().toUtc();
  final base =
      context ??
      VastMacroContext(
        cacheBuster: ((at.microsecondsSinceEpoch % 100000000)
            .toString()
            .padLeft(8, '0')),
        timestamp: at.toIso8601String(),
        contentPlayhead: playhead,
        adPlayhead: playhead,
        mediaPlayhead: playhead,
      );
  final ctx = base.copyWith(
    errorCode: errorCode,
    reason: reason,
    adPlayhead: playhead,
  );
  return VastMacros.expand(url, ctx);
}

Duration? parseVastTime(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty || text.endsWith('%')) return null;
  final parts = text.split(':');
  if (parts.length == 1) {
    final seconds = double.tryParse(parts[0]);
    if (seconds == null || seconds < 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }
  if (parts.length < 3) return null;
  final hours = int.tryParse(parts[0]);
  final minutes = int.tryParse(parts[1]);
  final secParts = parts[2].split('.');
  final seconds = int.tryParse(secParts[0]);
  if (hours == null || minutes == null || seconds == null) return null;
  var ms = 0;
  if (secParts.length > 1) {
    final frac = secParts[1].padRight(3, '0').substring(0, 3);
    ms = int.tryParse(frac) ?? 0;
  }
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: ms,
  );
}

Duration? parseVastSkipOffset(String? raw, Duration? duration) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  if (text.endsWith('%')) {
    final pct = double.tryParse(text.substring(0, text.length - 1).trim());
    if (pct == null || duration == null || duration <= Duration.zero) {
      return null;
    }
    final ms = (duration.inMilliseconds * (pct.clamp(0, 100) / 100)).round();
    return Duration(milliseconds: ms);
  }
  return parseVastTime(text);
}

String formatVastTime(Duration duration) => VastMacros.playhead(duration);

/// HTTP(S) URL, or `null` when missing / not a web URL.
String? readHttpUrl(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return text;
}

/// Catalog / item VAST tag. `null` = omitted; `''` = explicitly disabled.
String? vastUrlFromJson(Map<dynamic, dynamic> map, {bool allowEmpty = false}) {
  Object? raw;
  if (map.containsKey('vastUrl')) {
    raw = map['vastUrl'];
  } else if (map.containsKey('vast')) {
    raw = map['vast'];
  } else if (map.containsKey('prerollUrl')) {
    raw = map['prerollUrl'];
  } else if (map['ads'] is Map) {
    final ads = Map<dynamic, dynamic>.from(map['ads'] as Map);
    if (ads.containsKey('vastUrl')) {
      raw = ads['vastUrl'];
    } else if (ads.containsKey('vast')) {
      raw = ads['vast'];
    } else {
      return null;
    }
  } else {
    return null;
  }
  if (raw == false || raw == null) return allowEmpty ? '' : null;
  final url = readHttpUrl(raw);
  if (url != null) return url;
  return allowEmpty ? '' : null;
}

class VastParser {
  const VastParser();

  VastDocument parse(String xml) => parseVastXml(xml);
}

VastDocument _parseVast(XmlElement root) {
  final ads = <VastLinearAd>[];
  final wrappers = <String>[];
  final impressions = <String>[];
  final clickTracking = <String>[];
  final errorUrls = _urlsIn(root, 'Error');
  final tracking = <String, List<String>>{};
  final progressCues = <VastProgressCue>[];
  var viewable = const _VastViewableBundle();
  final icons = <VastIcon>[];
  final companions = <VastCompanion>[];
  final verifications = <VastVerification>[];
  final blocked = <String>[];
  var clickThrough = '';
  var followAdditional = true;
  var allowMultiple = true;
  var fallbackOnNoAd = false;
  var noPlayableMedia = false;
  var skippedInteractive = false;

  final adNodes = _named(root, 'Ad').toList();
  adNodes.sort((a, b) {
    final sa = int.tryParse(a.getAttribute('sequence') ?? '') ?? 0;
    final sb = int.tryParse(b.getAttribute('sequence') ?? '') ?? 0;
    return sa.compareTo(sb);
  });

  if (adNodes.isEmpty) {
    return VastDocument(errorUrls: errorUrls, empty: true);
  }

  for (final ad in adNodes) {
    final sequence = int.tryParse(ad.getAttribute('sequence') ?? '') ?? 0;
    final inline = _firstNamed(ad, 'InLine');
    final wrapper = _firstNamed(ad, 'Wrapper');
    if (inline != null) {
      final linear = _linearFrom(inline, sequence: sequence);
      if (linear != null) {
        ads.add(linear);
      } else if (_firstNamed(inline, 'Linear') != null) {
        errorUrls.addAll(_urlsIn(inline, 'Error'));
        noPlayableMedia = true;
        skippedInteractive =
            skippedInteractive || _linearHadInteractive(inline);
      }
      continue;
    }
    if (wrapper != null) {
      final tag = readHttpUrl(_firstNamed(wrapper, 'VASTAdTagURI')?.innerText);
      if (tag != null) wrappers.add(tag);
      impressions.addAll(_urlsIn(wrapper, 'Impression'));
      clickTracking.addAll(_urlsIn(wrapper, 'ClickTracking'));
      errorUrls.addAll(_urlsIn(wrapper, 'Error'));
      _mergeTrackingInto(tracking, _trackingFrom(wrapper));
      progressCues.addAll(_progressFrom(wrapper));
      viewable = viewable.merge(_viewableFrom(wrapper));
      icons.addAll(_iconsFrom(wrapper));
      companions.addAll(_companionsFrom(wrapper));
      verifications.addAll(_verificationsFrom(wrapper));
      blocked.addAll(_blockedFrom(wrapper));
      final wrapperClick = readHttpUrl(
        _firstNamed(wrapper, 'ClickThrough')?.innerText,
      );
      if (clickThrough.isEmpty && wrapperClick != null) {
        clickThrough = wrapperClick;
      }
      followAdditional = _boolAttr(
        wrapper,
        'followAdditionalWrappers',
        followAdditional,
      );
      allowMultiple = _boolAttr(wrapper, 'allowMultipleAds', allowMultiple);
      fallbackOnNoAd = _boolAttr(wrapper, 'fallbackOnNoAd', fallbackOnNoAd);
    }
  }

  return VastDocument(
    ads: ads,
    wrapperTagUrls: wrappers,
    impressions: impressions,
    clickTracking: clickTracking,
    errorUrls: errorUrls,
    tracking: tracking,
    progressCues: progressCues,
    viewable: viewable.viewable,
    notViewable: viewable.notViewable,
    viewUndetermined: viewable.viewUndetermined,
    icons: icons,
    companions: companions,
    verifications: verifications,
    wrapper: VastWrapperHints(
      followAdditionalWrappers: followAdditional,
      allowMultipleAds: allowMultiple,
      fallbackOnNoAd: fallbackOnNoAd,
      blockedCategories: blocked,
      clickThroughUrl: clickThrough.isEmpty ? null : clickThrough,
    ),
    noPlayableMedia: noPlayableMedia,
    skippedInteractive: skippedInteractive,
  );
}

VastDocument _parseVmap(XmlElement root) {
  final breaks = <VastAdBreak>[];
  for (final brk in _named(root, 'AdBreak')) {
    final offset = _vmapOffset(brk.getAttribute('timeOffset') ?? '');
    final breakType = (brk.getAttribute('breakType') ?? 'linear').trim();
    final breakId = (brk.getAttribute('breakId') ?? '').trim();
    final tags = <String>[];
    final inline = <VastLinearAd>[];
    for (final source in _named(brk, 'AdSource')) {
      final tag = readHttpUrl(_firstNamed(source, 'AdTagURI')?.innerText);
      if (tag != null) tags.add(tag);
      final vastData =
          _firstNamed(source, 'VASTAdData') ??
          _firstNamed(source, 'vastAdData');
      if (vastData != null) {
        final nested = vastData.childElements
            .where((e) => e.localName.toLowerCase() == 'vast')
            .toList();
        for (final node in nested) {
          final parsed = _parseVast(node);
          inline.addAll(parsed.ads);
          tags.addAll(parsed.wrapperTagUrls);
        }
      }
    }
    if (tags.isEmpty && inline.isEmpty) continue;
    breaks.add(
      VastAdBreak(
        offset: offset,
        tagUrls: tags,
        inlineAds: inline,
        breakType: breakType,
        breakId: breakId,
      ),
    );
  }
  return VastDocument(vmapBreaks: breaks);
}

VastBreakOffset _vmapOffset(String raw) {
  final text = raw.trim().toLowerCase();
  if (text.isEmpty ||
      text == 'start' ||
      text == '0' ||
      text == '0%' ||
      text == '00:00:00' ||
      text == '00:00:00.000') {
    return const VastBreakOffset.start();
  }
  if (text == 'end' || text == '100%') {
    return const VastBreakOffset.end();
  }
  if (text.endsWith('%')) {
    final pct = double.tryParse(text.substring(0, text.length - 1).trim());
    if (pct == null || pct <= 0) return const VastBreakOffset.start();
    if (pct >= 100) return const VastBreakOffset.end();
    return VastBreakOffset.percent(pct);
  }
  final time = parseVastTime(raw);
  if (time == null || time == Duration.zero) {
    return const VastBreakOffset.start();
  }
  return VastBreakOffset.time(time);
}

VastLinearAd? _linearFrom(XmlElement inline, {int sequence = 0}) {
  final linear = _firstNamed(inline, 'Linear');
  if (linear == null) return null;
  final media = _pickMediaFile(linear);
  if (media == null) return null;
  final duration = parseVastTime(_firstNamed(linear, 'Duration')?.innerText);
  final skipOffset = parseVastSkipOffset(
    linear.getAttribute('skipoffset'),
    duration,
  );
  final clickThrough = readHttpUrl(
    _firstNamed(linear, 'ClickThrough')?.innerText,
  );
  final companions = _companionsFrom(inline);
  final requiredUnmet =
      companions.any((c) => c.required == 'all' || c.required == 'any') &&
      companions.every((c) => c.staticUrl == null || c.staticUrl!.isEmpty);
  final viewable = _viewableFrom(inline);
  return VastLinearAd(
    mediaUrl: media.url,
    mediaMime: media.mime,
    duration: duration,
    skipOffset: skipOffset,
    clickThroughUrl: clickThrough,
    impressions: _urlsIn(inline, 'Impression'),
    clickTracking: _urlsIn(linear, 'ClickTracking'),
    errorUrls: _urlsIn(inline, 'Error'),
    tracking: _trackingFrom(linear),
    progressCues: _progressFrom(linear),
    viewable: viewable.viewable,
    notViewable: viewable.notViewable,
    viewUndetermined: viewable.viewUndetermined,
    icons: _iconsFrom(linear),
    companions: companions,
    captions: _captionsFrom(linear),
    verifications: _verificationsFrom(inline),
    categories: _categoriesFrom(inline),
    sequence: sequence,
    companionRequiredUnmet: requiredUnmet,
    adServingId: _firstNamed(inline, 'AdServingId')?.innerText.trim(),
    universalAdId: _universalAdId(inline),
  );
}

({String url, String mime})? _pickMediaFile(XmlElement linear) {
  final files = _named(linear, 'MediaFile').toList();
  if (files.isEmpty) return null;
  ({String url, String mime, int score, int width, int bitrate})? best;
  for (final node in files) {
    final url = readHttpUrl(node.innerText);
    if (url == null) continue;
    final type = (node.getAttribute('type') ?? '').trim().toLowerCase();
    final api = (node.getAttribute('apiFramework') ?? '').trim().toLowerCase();
    if (_isInteractiveApi(type, api)) continue;
    final delivery = (node.getAttribute('delivery') ?? '').trim().toLowerCase();
    final width = int.tryParse(node.getAttribute('width') ?? '') ?? 0;
    final bitrate = int.tryParse(node.getAttribute('bitrate') ?? '') ?? 0;
    var score = 0;
    if (type.contains('mp4') || url.toLowerCase().contains('.mp4')) {
      score = 400;
    } else if (type.contains('webm') || url.toLowerCase().contains('.webm')) {
      score = 300;
    } else if (type.contains('mpegurl') ||
        type.contains('x-mpegurl') ||
        url.toLowerCase().contains('.m3u8')) {
      score = 200;
    } else if (type.startsWith('video/')) {
      score = 100;
    } else {
      score = 10;
    }
    if (delivery == 'progressive') score += 20;
    final mime = type.isEmpty ? 'video/mp4' : type;
    final candidate = (
      url: url,
      mime: mime,
      score: score,
      width: width,
      bitrate: bitrate,
    );
    if (best == null ||
        candidate.score > best.score ||
        (candidate.score == best.score && candidate.width > best.width) ||
        (candidate.score == best.score &&
            candidate.width == best.width &&
            candidate.bitrate > best.bitrate)) {
      best = candidate;
    }
  }
  if (best == null) return null;
  return (url: best.url, mime: best.mime);
}

bool _linearHadInteractive(XmlElement inline) {
  final linear = _firstNamed(inline, 'Linear');
  if (linear == null) return false;
  for (final node in _named(linear, 'MediaFile')) {
    final type = (node.getAttribute('type') ?? '').trim().toLowerCase();
    final api = (node.getAttribute('apiFramework') ?? '').trim().toLowerCase();
    if (_isInteractiveApi(type, api)) return true;
  }
  return _named(inline, 'InteractiveCreativeFile').isNotEmpty;
}

bool _isInteractiveApi(String type, String api) {
  return type.contains('javascript') ||
      type.contains('vpaid') ||
      api == 'vpaid' ||
      api == 'omid' ||
      api == 'simid';
}

Map<String, List<String>> _trackingFrom(XmlElement node) {
  final out = <String, List<String>>{};
  for (final tracking in _named(node, 'Tracking')) {
    final event = (tracking.getAttribute('event') ?? '').trim().toLowerCase();
    if (event.isEmpty || event == 'progress') continue;
    final url = readHttpUrl(tracking.innerText);
    if (url == null) continue;
    out.update(event, (v) => [...v, url], ifAbsent: () => [url]);
  }
  return out;
}

List<VastProgressCue> _progressFrom(XmlElement node) {
  final byOffset = <String, List<String>>{};
  for (final tracking in _named(node, 'Tracking')) {
    final event = (tracking.getAttribute('event') ?? '').trim().toLowerCase();
    if (event != 'progress') continue;
    final url = readHttpUrl(tracking.innerText);
    if (url == null) continue;
    final offset = (tracking.getAttribute('offset') ?? '').trim();
    byOffset.update(offset, (v) => [...v, url], ifAbsent: () => [url]);
  }
  return [
    for (final e in byOffset.entries)
      VastProgressCue(
        urls: e.value,
        offset: e.key.endsWith('%') ? null : parseVastTime(e.key),
        percent: e.key.endsWith('%')
            ? double.tryParse(e.key.substring(0, e.key.length - 1).trim())
            : null,
      ),
  ];
}

List<VastIcon> _iconsFrom(XmlElement node) {
  final out = <VastIcon>[];
  for (final icon in _named(node, 'Icon')) {
    final staticUrl = readHttpUrl(
      _firstNamed(icon, 'StaticResource')?.innerText,
    );
    if (staticUrl == null) continue;
    final program = (icon.getAttribute('program') ?? '').trim();
    out.add(
      VastIcon(
        staticUrl: staticUrl,
        program: program.isEmpty ? null : program,
        width: int.tryParse(icon.getAttribute('width') ?? ''),
        height: int.tryParse(icon.getAttribute('height') ?? ''),
        xPosition: icon.getAttribute('xPosition') ?? 'right',
        yPosition: icon.getAttribute('yPosition') ?? 'top',
        offset: parseVastTime(icon.getAttribute('offset')),
        duration: parseVastTime(icon.getAttribute('duration')),
        clickThroughUrl: readHttpUrl(
          _firstNamed(icon, 'IconClickThrough')?.innerText,
        ),
        clickTracking: _urlsIn(icon, 'IconClickTracking'),
        viewTracking: _urlsIn(icon, 'IconViewTracking'),
      ),
    );
  }
  return out;
}

List<VastCompanion> _companionsFrom(XmlElement node) {
  final out = <VastCompanion>[];
  for (final ads in _named(node, 'CompanionAds')) {
    final required = (ads.getAttribute('required') ?? 'none')
        .trim()
        .toLowerCase();
    for (final c in _named(ads, 'Companion')) {
      final tracking = _trackingFrom(c);
      out.add(
        VastCompanion(
          staticUrl: readHttpUrl(_firstNamed(c, 'StaticResource')?.innerText),
          width: int.tryParse(c.getAttribute('width') ?? ''),
          height: int.tryParse(c.getAttribute('height') ?? ''),
          clickThroughUrl: readHttpUrl(
            _firstNamed(c, 'CompanionClickThrough')?.innerText,
          ),
          clickTracking: _urlsIn(c, 'CompanionClickTracking'),
          creativeView: tracking['creativeview'] ?? const [],
          required: required,
        ),
      );
    }
  }
  return out;
}

List<VastCaption> _captionsFrom(XmlElement linear) {
  return [
    for (final f in _named(linear, 'ClosedCaptionFile'))
      if (readHttpUrl(f.innerText) != null)
        VastCaption(
          url: readHttpUrl(f.innerText)!,
          language: f.getAttribute('language'),
          type: f.getAttribute('type'),
        ),
  ];
}

_VastViewableBundle _viewableFrom(XmlElement node) {
  final el = _firstNamed(node, 'ViewableImpression');
  if (el == null) return const _VastViewableBundle();
  return _VastViewableBundle(
    viewable: _urlsIn(el, 'Viewable'),
    notViewable: _urlsIn(el, 'NotViewable'),
    viewUndetermined: _urlsIn(el, 'ViewUndetermined'),
  );
}

List<VastVerification> _verificationsFrom(XmlElement node) {
  final out = <VastVerification>[];
  for (final v in _named(node, 'Verification')) {
    final js = _firstNamed(v, 'JavaScriptResource');
    final notExec = <String>[];
    for (final t in _named(v, 'Tracking')) {
      final event = (t.getAttribute('event') ?? '').trim().toLowerCase();
      if (event == 'verificationnotexecuted') {
        final url = readHttpUrl(t.innerText);
        if (url != null) notExec.add(url);
      }
    }
    out.add(
      VastVerification(
        vendor: v.getAttribute('vendor'),
        javaScriptResource: js?.innerText.trim(),
        apiFramework: js?.getAttribute('apiFramework'),
        notExecuted: notExec,
      ),
    );
  }
  return out;
}

List<String> _categoriesFrom(XmlElement node) {
  return [
    for (final c in _named(node, 'Category'))
      if (c.innerText.trim().isNotEmpty) c.innerText.trim(),
  ];
}

List<String> _blockedFrom(XmlElement node) {
  return [
    for (final c in _named(node, 'BlockedAdCategories'))
      if (c.innerText.trim().isNotEmpty) c.innerText.trim(),
  ];
}

String _universalAdId(XmlElement node) {
  final el = _firstNamed(node, 'UniversalAdId');
  if (el == null) return '';
  final registry = (el.getAttribute('idRegistry') ?? '').trim();
  final value = el.innerText.trim();
  if (registry.isEmpty) return value;
  return '$registry $value';
}

void _mergeTrackingInto(
  Map<String, List<String>> target,
  Map<String, List<String>> extra,
) {
  for (final e in extra.entries) {
    target.update(
      e.key,
      (v) => [...v, ...e.value],
      ifAbsent: () => [...e.value],
    );
  }
}

List<String> _urlsIn(XmlElement node, String localName) {
  return _named(
    node,
    localName,
  ).map((e) => readHttpUrl(e.innerText)).whereType<String>().toList();
}

Iterable<XmlElement> _named(XmlNode node, String localName) {
  final want = localName.toLowerCase();
  return node.descendantElements.where(
    (e) => e.localName.toLowerCase() == want,
  );
}

XmlElement? _firstNamed(XmlNode node, String localName) {
  final matches = _named(node, localName);
  return matches.isEmpty ? null : matches.first;
}

bool _boolAttr(XmlElement el, String name, bool fallback) {
  final v = el.getAttribute(name);
  if (v == null) return fallback;
  final s = v.trim().toLowerCase();
  if (s == 'true' || s == '1') return true;
  if (s == 'false' || s == '0') return false;
  return fallback;
}

class _VastViewableBundle {
  const _VastViewableBundle({
    this.viewable = const [],
    this.notViewable = const [],
    this.viewUndetermined = const [],
  });

  final List<String> viewable;
  final List<String> notViewable;
  final List<String> viewUndetermined;

  _VastViewableBundle merge(_VastViewableBundle other) {
    if (other.viewable.isEmpty &&
        other.notViewable.isEmpty &&
        other.viewUndetermined.isEmpty) {
      return this;
    }
    return _VastViewableBundle(
      viewable: [...viewable, ...other.viewable],
      notViewable: [...notViewable, ...other.notViewable],
      viewUndetermined: [...viewUndetermined, ...other.viewUndetermined],
    );
  }
}
