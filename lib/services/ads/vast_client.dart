import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:javp/services/ads/vast_models.dart';
import 'package:javp/services/ads/vast_parser.dart';
import 'package:javp/services/diagnostics/javp_log.dart';

/// Fetches VAST / VMAP tags and resolves wrappers into a playable 4.x schedule.
class VastClient {
  VastClient({http.Client? httpClient, this.maxWrapperDepth = 5})
    : _injectedHttp = httpClient;

  static const _timeout = Duration(seconds: 5);
  static const _headers = {
    'User-Agent': 'JAVP',
    'Accept': 'application/xml, application/vast+xml, text/xml, */*',
  };

  final http.Client? _injectedHttp;
  http.Client? _ownedHttp;
  final int maxWrapperDepth;

  http.Client get _http => _injectedHttp ?? (_ownedHttp ??= http.Client());

  /// Resolve [tagUrl] to linear prerolls. Empty on timeout / parse failure.
  Future<List<VastLinearAd>> fetchPrerolls(String tagUrl) async {
    final schedule = await fetchSchedule(tagUrl);
    return schedule.prerolls;
  }

  /// Resolve a VAST or VMAP tag into preroll / midroll / postroll creatives.
  Future<VastSchedule> fetchSchedule(
    String tagUrl, {
    VastMacroContext? macros,
  }) async {
    final ctx = macros ?? VastMacroContext.now(userAgent: 'JAVP');
    try {
      return await _resolveTag(
        tagUrl,
        depth: 0,
        inherited: const VastDocument(),
        ctx: ctx,
        followWrappers: true,
        allowMultiple: true,
      );
    } catch (e) {
      JavpLog.w('vast', 'fetch failed url=$tagUrl', error: e);
      return const VastSchedule();
    }
  }

  /// Fire-and-forget tracking / impression GET. Failures are ignored.
  void ping(
    String url, {
    Duration playhead = Duration.zero,
    String? errorCode,
    String? reason,
    VastMacroContext? macros,
  }) {
    final resolved = replaceVastMacros(
      url,
      playhead: playhead,
      errorCode: errorCode,
      reason: reason,
      context: macros,
    );
    final uri = Uri.tryParse(resolved);
    if (uri == null) return;
    () async {
      try {
        await _http.get(uri, headers: _headers).timeout(_timeout);
      } catch (_) {}
    }();
  }

  void pingAll(
    Iterable<String> urls, {
    Duration playhead = Duration.zero,
    String? errorCode,
    String? reason,
    VastMacroContext? macros,
  }) {
    for (final url in urls) {
      ping(
        url,
        playhead: playhead,
        errorCode: errorCode,
        reason: reason,
        macros: macros,
      );
    }
  }

  void pingErrors(
    Iterable<String> urls,
    String code, {
    VastMacroContext? macros,
  }) {
    pingAll(urls, errorCode: code, macros: macros);
  }

  Future<VastSchedule> _resolveTag(
    String tagUrl, {
    required int depth,
    required VastDocument inherited,
    required VastMacroContext ctx,
    required bool followWrappers,
    required bool allowMultiple,
  }) async {
    if (depth > maxWrapperDepth) {
      pingErrors(inherited.errorUrls, '302', macros: ctx);
      return const VastSchedule();
    }
    final uri = Uri.tryParse(tagUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      if (depth > 0) pingErrors(inherited.errorUrls, '300', macros: ctx);
      return const VastSchedule();
    }

    http.Response response;
    try {
      response = await _http.get(uri, headers: _headers).timeout(_timeout);
    } on TimeoutException {
      pingErrors(inherited.errorUrls, depth == 0 ? '301' : '301', macros: ctx);
      return const VastSchedule();
    } catch (e) {
      if (depth > 0) pingErrors(inherited.errorUrls, '300', macros: ctx);
      return const VastSchedule();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (depth > 0) pingErrors(inherited.errorUrls, '300', macros: ctx);
      return const VastSchedule();
    }

    final doc = parseVastXml(response.body);
    if (doc.parseError) {
      pingErrors(
        [...inherited.errorUrls, ...doc.errorUrls],
        '100',
        macros: ctx,
      );
      return const VastSchedule();
    }

    final merged = _mergeDocs(inherited, doc);

    if (doc.empty &&
        doc.wrapperTagUrls.isEmpty &&
        doc.vmapBreaks.isEmpty &&
        doc.ads.isEmpty) {
      pingErrors(merged.errorUrls, '303', macros: ctx);
      return const VastSchedule();
    }

    if (doc.vmapBreaks.isNotEmpty) {
      return _resolveVmap(doc, ctx: ctx, inherited: merged);
    }

    if (doc.wrapperTagUrls.isNotEmpty) {
      if (!followWrappers && depth > 0) {
        pingErrors(merged.errorUrls, '302', macros: ctx);
        return const VastSchedule();
      }
      final out = <VastLinearAd>[];
      final overlays = <VastNonLinear>[];
      for (final nested in doc.wrapperTagUrls) {
        final child = await _resolveTag(
          nested,
          depth: depth + 1,
          inherited: merged,
          ctx: ctx,
          followWrappers: doc.wrapper.followAdditionalWrappers,
          allowMultiple: doc.wrapper.allowMultipleAds,
        );
        out.addAll(child.prerolls);
        overlays.addAll(child.overlays);
        if (!doc.wrapper.allowMultipleAds && out.isNotEmpty) break;
      }
      if (out.isEmpty && doc.noPlayableMedia) {
        pingErrors(merged.errorUrls, '403', macros: ctx);
        if (doc.skippedInteractive) {
          pingErrors(merged.errorUrls, '409', macros: ctx);
        }
      }
      final ads = allowMultiple || out.isEmpty ? out : out.take(1).toList();
      return VastSchedule(prerolls: ads, overlays: overlays);
    }

    if (doc.noPlayableMedia && doc.ads.isEmpty) {
      pingErrors(merged.errorUrls, '403', macros: ctx);
      if (doc.skippedInteractive) {
        pingErrors(merged.errorUrls, '409', macros: ctx);
      }
      return const VastSchedule();
    }

    final ads = <VastLinearAd>[];
    for (final ad in doc.ads) {
      final resolved = merged.applyWrapper(ad);
      _noteUnsupportedApis(resolved, ctx);
      if (resolved.blockedByWrapperCategories) {
        pingErrors(resolved.errorUrls, '205', macros: ctx);
        continue;
      }
      if (resolved.companionRequiredUnmet) {
        pingErrors(resolved.errorUrls, '604', macros: ctx);
      }
      ads.add(resolved);
      if (!allowMultiple) break;
    }
    return VastSchedule(prerolls: ads, overlays: doc.nonlinear);
  }

  Future<VastSchedule> _resolveVmap(
    VastDocument doc, {
    required VastMacroContext ctx,
    required VastDocument inherited,
  }) async {
    final prerolls = <VastLinearAd>[];
    final midrolls = <VastTimedBreak>[];
    final postrolls = <VastLinearAd>[];
    final overlays = <VastNonLinear>[...doc.nonlinear];

    for (final brk in doc.vmapBreaks) {
      final ads = [...brk.inlineAds];
      for (final tag in brk.tagUrls) {
        final child = await _resolveTag(
          tag,
          depth: 1,
          inherited: inherited,
          ctx: ctx,
          followWrappers: true,
          allowMultiple: true,
        );
        ads.addAll(child.prerolls);
        overlays.addAll(child.overlays);
      }
      if (ads.isEmpty) continue;
      if (brk.offset.isPreroll) {
        prerolls.addAll(ads);
      } else if (brk.offset.isPostroll) {
        postrolls.addAll(ads);
      } else {
        midrolls.add(VastTimedBreak(offset: brk.offset, ads: ads));
      }
    }
    return VastSchedule(
      prerolls: prerolls,
      midrolls: midrolls,
      postrolls: postrolls,
      overlays: overlays,
    );
  }

  VastDocument _mergeDocs(VastDocument parent, VastDocument child) {
    if (parent.ads.isEmpty &&
        parent.wrapperTagUrls.isEmpty &&
        parent.impressions.isEmpty &&
        parent.errorUrls.isEmpty &&
        parent.tracking.isEmpty) {
      return child;
    }
    return VastDocument(
      ads: child.ads,
      wrapperTagUrls: child.wrapperTagUrls,
      vmapBreaks: child.vmapBreaks,
      impressions: [...parent.impressions, ...child.impressions],
      clickTracking: [...parent.clickTracking, ...child.clickTracking],
      errorUrls: [...parent.errorUrls, ...child.errorUrls],
      tracking: mergeVastTracking(parent.tracking, child.tracking),
      progressCues: [...parent.progressCues, ...child.progressCues],
      viewable: [...parent.viewable, ...child.viewable],
      notViewable: [...parent.notViewable, ...child.notViewable],
      viewUndetermined: [...parent.viewUndetermined, ...child.viewUndetermined],
      icons: mergeVastIcons(inline: child.icons, wrapper: parent.icons),
      companions: [...child.companions, ...parent.companions],
      verifications: [...parent.verifications, ...child.verifications],
      nonlinear: [...child.nonlinear, ...parent.nonlinear],
      wrapper: VastWrapperHints(
        followAdditionalWrappers: child.wrapper.followAdditionalWrappers,
        allowMultipleAds: child.wrapper.allowMultipleAds,
        fallbackOnNoAd: child.wrapper.fallbackOnNoAd,
        blockedCategories: [
          ...parent.wrapper.blockedCategories,
          ...child.wrapper.blockedCategories,
        ],
        clickThroughUrl:
            child.wrapper.clickThroughUrl ?? parent.wrapper.clickThroughUrl,
      ),
      empty: child.empty,
      parseError: child.parseError,
      noPlayableMedia: child.noPlayableMedia,
      skippedInteractive: child.skippedInteractive,
    );
  }

  /// Player does not execute OMID / SIMID. Ping verificationNotExecuted (410).
  void _noteUnsupportedApis(VastLinearAd ad, VastMacroContext ctx) {
    for (final v in ad.verifications) {
      if (v.notExecuted.isEmpty) continue;
      pingAll(v.notExecuted, reason: '2', errorCode: '410', macros: ctx);
    }
  }
}
