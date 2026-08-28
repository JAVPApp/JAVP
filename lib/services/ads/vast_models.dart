/// VAST 4.2 linear creative plus companion/icon/viewability metadata.
class VastLinearAd {
  const VastLinearAd({
    required this.mediaUrl,
    this.mediaMime = 'video/mp4',
    this.duration,
    this.skipOffset,
    this.clickThroughUrl,
    this.impressions = const [],
    this.clickTracking = const [],
    this.errorUrls = const [],
    this.tracking = const {},
    this.progressCues = const [],
    this.viewable = const [],
    this.notViewable = const [],
    this.viewUndetermined = const [],
    this.icons = const [],
    this.companions = const [],
    this.captions = const [],
    this.verifications = const [],
    this.categories = const [],
    this.sequence = 0,
    this.conditional = false,
    this.blocked = false,
    this.companionRequiredUnmet = false,
    this.adServingId,
    this.universalAdId = '',
  });

  final String mediaUrl;
  final String mediaMime;
  final Duration? duration;

  /// When Skip may appear. `null` = not skippable.
  final Duration? skipOffset;
  final String? clickThroughUrl;
  final List<String> impressions;
  final List<String> clickTracking;
  final List<String> errorUrls;
  final Map<String, List<String>> tracking;
  final List<VastProgressCue> progressCues;
  final List<String> viewable;
  final List<String> notViewable;
  final List<String> viewUndetermined;
  final List<VastIcon> icons;
  final List<VastCompanion> companions;
  final List<VastCaption> captions;
  final List<VastVerification> verifications;
  final List<String> categories;
  final int sequence;
  final bool conditional;
  final bool blocked;
  final bool companionRequiredUnmet;
  final String? adServingId;
  final String universalAdId;

  VastLinearAd mergeWrapper({
    List<String> impressions = const [],
    List<String> clickTracking = const [],
    List<String> errorUrls = const [],
    Map<String, List<String>> tracking = const {},
    List<VastProgressCue> progressCues = const [],
    List<String> viewable = const [],
    List<String> notViewable = const [],
    List<String> viewUndetermined = const [],
    List<VastIcon> icons = const [],
    List<VastCompanion> companions = const [],
    List<VastVerification> verifications = const [],
    String? clickThroughUrl,
    List<String> blockedCategories = const [],
  }) {
    final blockedCodes = {
      for (final c in blockedCategories)
        if (c.trim().isNotEmpty) c.trim().toLowerCase(),
    };
    final categoryHit = categories.any(
      (c) => blockedCodes.contains(c.trim().toLowerCase()),
    );
    return VastLinearAd(
      mediaUrl: mediaUrl,
      mediaMime: mediaMime,
      duration: duration,
      skipOffset: skipOffset,
      clickThroughUrl: this.clickThroughUrl ?? clickThroughUrl,
      impressions: [...impressions, ...this.impressions],
      clickTracking: [...clickTracking, ...this.clickTracking],
      errorUrls: [...errorUrls, ...this.errorUrls],
      tracking: mergeVastTracking(tracking, this.tracking),
      progressCues: [...progressCues, ...this.progressCues],
      viewable: [...viewable, ...this.viewable],
      notViewable: [...notViewable, ...this.notViewable],
      viewUndetermined: [...viewUndetermined, ...this.viewUndetermined],
      icons: mergeVastIcons(inline: this.icons, wrapper: icons),
      companions: [...this.companions, ...companions],
      captions: captions,
      verifications: [...verifications, ...this.verifications],
      categories: categories,
      sequence: sequence,
      conditional: conditional,
      blocked: blocked || categoryHit,
      companionRequiredUnmet: companionRequiredUnmet,
      adServingId: adServingId,
      universalAdId: universalAdId,
    );
  }

  bool get blockedByWrapperCategories => blocked;
}

class VastProgressCue {
  const VastProgressCue({required this.urls, this.offset, this.percent});

  final List<String> urls;
  final Duration? offset;
  final double? percent;
}

class VastIcon {
  const VastIcon({
    required this.staticUrl,
    this.program,
    this.width,
    this.height,
    this.xPosition = 'right',
    this.yPosition = 'top',
    this.offset,
    this.duration,
    this.clickThroughUrl,
    this.clickTracking = const [],
    this.viewTracking = const [],
  });

  final String staticUrl;
  final String? program;
  final int? width;
  final int? height;
  final String xPosition;
  final String yPosition;
  final Duration? offset;
  final Duration? duration;
  final String? clickThroughUrl;
  final List<String> clickTracking;
  final List<String> viewTracking;
}

class VastCompanion {
  const VastCompanion({
    this.staticUrl,
    this.width,
    this.height,
    this.clickThroughUrl,
    this.clickTracking = const [],
    this.creativeView = const [],
    this.required = 'none',
  });

  final String? staticUrl;
  final int? width;
  final int? height;
  final String? clickThroughUrl;
  final List<String> clickTracking;
  final List<String> creativeView;
  final String required;
}

class VastCaption {
  const VastCaption({required this.url, this.language, this.type});

  final String url;
  final String? language;
  final String? type;
}

class VastVerification {
  const VastVerification({
    this.vendor,
    this.javaScriptResource,
    this.apiFramework,
    this.notExecuted = const [],
  });

  final String? vendor;
  final String? javaScriptResource;
  final String? apiFramework;
  final List<String> notExecuted;
}

class VastNonLinear {
  const VastNonLinear({
    this.staticUrl,
    this.clickThroughUrl,
    this.clickTracking = const [],
    this.minSuggestedDuration,
    this.width,
    this.height,
  });

  final String? staticUrl;
  final String? clickThroughUrl;
  final List<String> clickTracking;
  final Duration? minSuggestedDuration;
  final int? width;
  final int? height;
}

enum VastBreakKind { start, end, linear, nonlinear }

class VastBreakOffset {
  const VastBreakOffset.start()
    : kind = VastBreakKind.start,
      time = null,
      percent = null;
  const VastBreakOffset.end()
    : kind = VastBreakKind.end,
      time = null,
      percent = null;
  const VastBreakOffset.time(this.time)
    : kind = VastBreakKind.linear,
      percent = null;
  const VastBreakOffset.percent(this.percent)
    : kind = VastBreakKind.linear,
      time = null;

  final VastBreakKind kind;
  final Duration? time;
  final double? percent;

  bool get isPreroll => kind == VastBreakKind.start;
  bool get isPostroll => kind == VastBreakKind.end;
  bool get isMidroll =>
      (kind == VastBreakKind.linear && time != null) || percent != null;
}

class VastAdBreak {
  const VastAdBreak({
    required this.offset,
    this.tagUrls = const [],
    this.inlineAds = const [],
    this.nonlinear = const [],
    this.breakType = 'linear',
    this.breakId = '',
  });

  final VastBreakOffset offset;
  final List<String> tagUrls;
  final List<VastLinearAd> inlineAds;
  final List<VastNonLinear> nonlinear;
  final String breakType;
  final String breakId;
}

class VastWrapperHints {
  const VastWrapperHints({
    this.followAdditionalWrappers = true,
    this.allowMultipleAds = true,
    this.fallbackOnNoAd = false,
    this.blockedCategories = const [],
    this.clickThroughUrl,
  });

  final bool followAdditionalWrappers;
  final bool allowMultipleAds;
  final bool fallbackOnNoAd;
  final List<String> blockedCategories;
  final String? clickThroughUrl;
}

/// Parsed VAST / VMAP before wrapper follow-up.
class VastDocument {
  const VastDocument({
    this.ads = const [],
    this.wrapperTagUrls = const [],
    this.vmapBreaks = const [],
    this.impressions = const [],
    this.clickTracking = const [],
    this.errorUrls = const [],
    this.tracking = const {},
    this.progressCues = const [],
    this.viewable = const [],
    this.notViewable = const [],
    this.viewUndetermined = const [],
    this.icons = const [],
    this.companions = const [],
    this.verifications = const [],
    this.nonlinear = const [],
    this.wrapper = const VastWrapperHints(),
    this.empty = false,
    this.parseError = false,
    this.noPlayableMedia = false,
    this.skippedInteractive = false,
  });

  final List<VastLinearAd> ads;
  final List<String> wrapperTagUrls;
  final List<VastAdBreak> vmapBreaks;
  final List<String> impressions;
  final List<String> clickTracking;
  final List<String> errorUrls;
  final Map<String, List<String>> tracking;
  final List<VastProgressCue> progressCues;
  final List<String> viewable;
  final List<String> notViewable;
  final List<String> viewUndetermined;
  final List<VastIcon> icons;
  final List<VastCompanion> companions;
  final List<VastVerification> verifications;
  final List<VastNonLinear> nonlinear;
  final VastWrapperHints wrapper;
  final bool empty;
  final bool parseError;
  final bool noPlayableMedia;
  final bool skippedInteractive;

  bool get isEmpty =>
      ads.isEmpty &&
      wrapperTagUrls.isEmpty &&
      vmapBreaks.isEmpty &&
      !empty &&
      !parseError;

  /// Legacy accessor used by older preroll-only tests.
  List<String> get vmapPrerollTagUrls => [
    for (final b in vmapBreaks)
      if (b.offset.isPreroll) ...b.tagUrls,
  ];

  VastLinearAd applyWrapper(VastLinearAd ad) {
    return ad.mergeWrapper(
      impressions: impressions,
      clickTracking: clickTracking,
      errorUrls: errorUrls,
      tracking: tracking,
      progressCues: progressCues,
      viewable: viewable,
      notViewable: notViewable,
      viewUndetermined: viewUndetermined,
      icons: icons,
      companions: companions,
      verifications: verifications,
      clickThroughUrl: wrapper.clickThroughUrl,
      blockedCategories: wrapper.blockedCategories,
    );
  }
}

class VastTimedBreak {
  const VastTimedBreak({required this.offset, required this.ads});

  final VastBreakOffset offset;
  final List<VastLinearAd> ads;
}

/// Resolved VAST 4.x schedule for one content play.
class VastSchedule {
  const VastSchedule({
    this.prerolls = const [],
    this.midrolls = const [],
    this.postrolls = const [],
    this.overlays = const [],
  });

  final List<VastLinearAd> prerolls;
  final List<VastTimedBreak> midrolls;
  final List<VastLinearAd> postrolls;
  final List<VastNonLinear> overlays;

  bool get isEmpty =>
      prerolls.isEmpty &&
      midrolls.isEmpty &&
      postrolls.isEmpty &&
      overlays.isEmpty;
}

Map<String, List<String>> mergeVastTracking(
  Map<String, List<String>> a,
  Map<String, List<String>> b,
) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final out = <String, List<String>>{
    for (final e in a.entries) e.key: [...e.value],
  };
  for (final e in b.entries) {
    out.update(e.key, (v) => [...v, ...e.value], ifAbsent: () => [...e.value]);
  }
  return out;
}

/// InLine icons win per [VastIcon.program]; otherwise keep wrapper icons.
List<VastIcon> mergeVastIcons({
  required List<VastIcon> inline,
  required List<VastIcon> wrapper,
}) {
  if (wrapper.isEmpty) return inline;
  if (inline.isEmpty) return wrapper;
  final programs = {
    for (final i in inline)
      if ((i.program ?? '').isNotEmpty) i.program!.toLowerCase(),
  };
  return [
    ...inline,
    for (final w in wrapper)
      if (w.program == null ||
          w.program!.isEmpty ||
          !programs.contains(w.program!.toLowerCase()))
        w,
  ];
}
