import 'package:javp/models/media_item.dart';

/// Helpers for treating same-channel live streams as quality variants.
class ChannelQuality {
  const ChannelQuality._();

  /// Stable family key for prefs + collapsing.
  ///
  /// Prefers a display name (EPG display-name → cleaned stream title →
  /// tvg-name) so HD/FHD/SD siblings merge even when their tvg-ids differ.
  /// Falls back to `source|epg:…` only when no usable name exists.
  ///
  /// Names are passed through [baseTitle] so quality suffixes
  /// (`News One HD` vs `News One FHD`) collapse to one family.
  static String? preferenceKey(MediaItem channel, {String? officialName}) {
    final source = channel.sourceId?.trim();
    if (source == null || source.isEmpty) return null;

    // EPG display-name when the caller resolved one (not the raw tvg-name —
    // that often still includes a quality tag per stream).
    final official = officialName?.trim();
    if (official != null && official.isNotEmpty) {
      final cleaned = baseTitle(official);
      if (cleaned.isNotEmpty) {
        return '$source|name:${normalizeKey(cleaned)}';
      }
    }

    // Cleaned stream title before tvg-id: Xtream quality variants commonly
    // share a basename ("News One HD" / "News One FHD") while carrying distinct
    // epg_channel_id values. Keying on tvg-id first hid every alternate
    // quality behind "No other qualities for this EPG id".
    final fromTitle = baseTitle(channel.title);
    if (fromTitle.isNotEmpty) {
      return '$source|name:${normalizeKey(fromTitle)}';
    }

    final tvgName = channel.channelName?.trim();
    if (tvgName != null && tvgName.isNotEmpty) {
      final cleaned = baseTitle(tvgName);
      if (cleaned.isNotEmpty) {
        return '$source|name:${normalizeKey(cleaned)}';
      }
    }

    final tvg = channel.epgChannelId?.trim();
    if (tvg != null && tvg.isNotEmpty) {
      return '$source|epg:$tvg';
    }

    return null;
  }

  static String normalizeKey(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Strip quality / region noise so "UK: News One FHD" → "News One".
  static String baseTitle(String title) {
    var t = title.trim();
    if (t.isEmpty) return t;

    t = t.replaceAll(
      RegExp(
        r'[\[\(][^\]\)]*(?:UHD|4K|FHD|HD|SD|HEVC|H\.?265|1080P?|720P?|2160P?|AUTO|STANDARD|BAS\s*D[EÉ]BIT)[^\]\)]*[\]\)]',
        caseSensitive: false,
      ),
      ' ',
    );
    // Numbered list rows: "2 - Channel Two (HD)" → "Channel Two"
    t = t.replaceFirst(RegExp(r'^\d+\s*[-–—]\s*'), '');
    // Leading country / region markers: "UK:", "US |", "DE -", "FR-CAR|"
    // (compound codes like FR-CAR must strip before the separator, otherwise
    // "FR-" alone leaves "CAR| ChannelA" and breaks family grouping / labels).
    t = t.replaceFirst(
      RegExp(
        r'^[A-Z]{2,3}(?:-[A-Z0-9]{2,12})*\s*[:|\-–—]\s*',
        caseSensitive: false,
      ),
      '',
    );
    t = t.replaceAll(
      RegExp(
        r'\b(UHD|4K|2160P?|FHD|FULL\s*HD|1080P?|HD|720P?|SD|480P?|360P?|HEVC|H\.?265|HQ|LQ|AUTO|STANDARD)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    t = t.replaceAll(RegExp(r'[\|\-–—:/]+$'), '');
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return t.isEmpty ? title.trim() : t;
  }

  /// Shared family label: majority cleaned base across variants (ties → shortest).
  ///
  /// Used for collapsed rows / quality-picker headings so an outlier like
  /// `FR-CAR| ChannelA` does not become the family title when siblings are `FR| ChannelA …`.
  /// Votes use EPG display-name when provided, otherwise the stream title
  /// (not raw tvg-name — that is often a shared regional outlier).
  static String familyBaseTitle(
    Iterable<MediaItem> variants, {
    String? Function(MediaItem channel)? officialNameOf,
  }) {
    final counts = <String, int>{};
    for (final v in variants) {
      final official = officialNameOf?.call(v)?.trim();
      final String voted;
      if (official != null && official.isNotEmpty) {
        voted = baseTitle(official);
      } else {
        voted = baseTitle(v.title);
      }
      if (voted.isEmpty) continue;
      counts[voted] = (counts[voted] ?? 0) + 1;
    }
    if (counts.isEmpty) return '';
    final ranked = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        final byLen = a.key.length.compareTo(b.key.length);
        if (byLen != 0) return byLen;
        return a.key.toLowerCase().compareTo(b.key.toLowerCase());
      });
    return ranked.first.key;
  }

  /// Family heading: shared cleaned base (no quality tag).
  ///
  /// List rows must not imply a stream quality — Auto, a remembered pref, or
  /// HLS adaptive may load a different sibling than the collapsed row.
  static String familyDisplayTitle(
    MediaItem preferred,
    Iterable<MediaItem> variants, {
    String? Function(MediaItem channel)? officialNameOf,
  }) {
    final base = familyBaseTitle(variants, officialNameOf: officialNameOf);
    if (base.isEmpty) {
      return displayTitle(
        preferred,
        epgDisplayName: officialNameOf?.call(preferred),
      );
    }
    return base;
  }

  /// Best label for a collapsed channel row.
  ///
  /// Official / tvg-name values are passed through [baseTitle] so regional
  /// prefixes (`FR|`, `FR-CAR|`) and quality suffixes never leak into the
  /// family heading. Quality stays in the picker / player, not the list.
  static String displayTitle(MediaItem channel, {String? epgDisplayName}) {
    final official = (epgDisplayName ?? channel.channelName)?.trim();
    final raw = (official != null && official.isNotEmpty)
        ? official
        : channel.title;
    final base = baseTitle(raw);
    return base.isNotEmpty ? base : raw.trim();
  }

  /// `Channel Two` + HD → `Channel Two (HD)`. No-ops when already present or unknown.
  ///
  /// For quality pickers / player chrome — live list titles stay untagged.
  static String withQualityParentheses(String title, MediaItem channel) {
    final base = title.trim();
    if (base.isEmpty) return base;
    final label = labelFor(channel);
    if (label == null || label.isEmpty) return base;
    final upper = base.toUpperCase();
    // Already has a quality cue — don't double up.
    if (RegExp(
      r'[\[\(]\s*(?:UHD|4K|FHD|HD|SD|LD|AUTO|HEVC|H\.?265|STANDARD|BAS)',
      caseSensitive: false,
    ).hasMatch(base)) {
      return base;
    }
    if (upper.contains(label.toUpperCase())) return base;
    return '$base ($label)';
  }

  /// Best-effort quality tag parsed from the stream name.
  /// Returns null when there is no useful tag (avoids a redundant "Stream").
  static String? labelFor(MediaItem channel) {
    final name = channel.title.toUpperCase();
    if (RegExp(r'\b(UHD|4K|2160P?)\b').hasMatch(name)) return 'UHD / 4K';
    if (RegExp(r'\b(FHD|1080P?|FULL\s*HD)\b').hasMatch(name)) return 'FHD';
    if (RegExp(r'\b(HD|720P?)\b').hasMatch(name)) return 'HD';
    if (RegExp(r'\b(SD|480P?|360P?|STANDARD)\b').hasMatch(name)) return 'SD';
    if (RegExp(r'\bBAS\s*D').hasMatch(name)) return 'LD';
    if (RegExp(r'\bAUTO\b').hasMatch(name)) return 'Auto';
    if (RegExp(r'\bHEVC\b').hasMatch(name)) return 'HEVC';
    if (RegExp(r'\bH\.?265\b').hasMatch(name)) return 'H.265';
    return null;
  }

  /// Higher = better for live Auto / picker ordering.
  static int rankFor(MediaItem channel) {
    final name = channel.title.toUpperCase();
    if (RegExp(r'\b(UHD|4K|2160P?)\b').hasMatch(name)) return 400;
    if (RegExp(r'\b(FHD|1080P?|FULL\s*HD)\b').hasMatch(name)) return 300;
    if (RegExp(r'\b(HD|720P?)\b').hasMatch(name)) return 200;
    if (RegExp(r'\bAUTO\b').hasMatch(name)) return 190;
    if (RegExp(r'\bHEVC\b|\bH\.?265\b').hasMatch(name)) return 180;
    if (RegExp(r'\b(SD|480P?|360P?|STANDARD)\b').hasMatch(name)) return 100;
    if (RegExp(r'\bBAS\s*D').hasMatch(name)) return 80;
    return 150;
  }

  static bool isUhd(MediaItem channel) => rankFor(channel) >= 400;

  /// Sort variants for live lists / Auto: quality only (UHD → FHD → HD → …).
  ///
  /// Catchup is not a live-rank signal — DVR/timeshift can fall back to a
  /// catchup-capable [pickCatchupSibling] without forcing live onto SD.
  static int compareVariants(MediaItem a, MediaItem b) {
    final quality = rankFor(b).compareTo(rankFor(a));
    if (quality != 0) return quality;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }

  /// Catchup sibling order: highest quality, then longest archive window.
  static int compareCatchupSiblings(MediaItem a, MediaItem b) {
    final quality = rankFor(b).compareTo(rankFor(a));
    if (quality != 0) return quality;
    final days = b.catchupDays.compareTo(a.catchupDays);
    if (days != 0) return days;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }

  /// Best catchup-capable sibling in [variants], or null if none.
  ///
  /// Rule: prefer highest quality among streams with `catchupDays > 0`;
  /// break ties with longest archive days, then title.
  static MediaItem? pickCatchupSibling(Iterable<MediaItem> variants) {
    final catchup = variants
        .where((v) => v.supportsCatchup && (v.streamId ?? '').isNotEmpty)
        .toList();
    if (catchup.isEmpty) return null;
    catchup.sort(compareCatchupSiblings);
    return catchup.first;
  }

  /// Next live sibling after [triedStreamIds], in [compareVariants] order
  /// (best first). Used when the preferred/Auto feed fails to open.
  static MediaItem? nextVariantAfter(
    List<MediaItem> variants, {
    required Set<String> triedStreamIds,
  }) {
    if (variants.isEmpty) return null;
    for (final variant in variants) {
      final streamId = variant.streamId?.trim() ?? '';
      final key = streamId.isNotEmpty ? streamId : variant.id;
      if (triedStreamIds.contains(key)) continue;
      if (streamId.isNotEmpty && triedStreamIds.contains(variant.id)) {
        continue;
      }
      return variant;
    }
    return null;
  }

  /// Pick a variant for playback: session override → explicit channel pref →
  /// Auto best (caller should sort with [compareVariants]).
  ///
  /// When [allowUhd] is false, Auto skips UHD/4K and falls through to FHD→….
  /// Session / remembered prefs still honor an explicit UHD pick.
  static MediaItem pickVariant(
    List<MediaItem> variants, {
    String? sessionStreamId,
    String? preferredStreamId,
    bool allowUhd = true,
  }) {
    if (variants.isEmpty) {
      throw ArgumentError.value(variants, 'variants', 'must not be empty');
    }
    if (variants.length == 1) return variants.first;
    MediaItem? match(String? streamId) {
      if (streamId == null || streamId.isEmpty) return null;
      for (final variant in variants) {
        if (variant.streamId == streamId) return variant;
      }
      return null;
    }

    return match(sessionStreamId) ??
        match(preferredStreamId) ??
        _autoBest(variants, allowUhd: allowUhd);
  }

  static MediaItem _autoBest(
    List<MediaItem> variants, {
    required bool allowUhd,
  }) {
    if (allowUhd) return variants.first;
    for (final variant in variants) {
      if (!isUhd(variant)) return variant;
    }
    // Family is UHD-only — still play something.
    return variants.first;
  }

  static String detailLine(MediaItem channel, {String? sourceLabel}) {
    final source = sourceLabel?.trim();
    return [
      if (source != null && source.isNotEmpty) source,
      if (channel.streamId != null) 'ID ${channel.streamId}',
      ?labelFor(channel),
      if (channel.supportsCatchup) '${channel.catchupDays}d catchup',
      if (channel.group != null && channel.group!.trim().isNotEmpty)
        channel.group!,
    ].join(' · ');
  }
}
