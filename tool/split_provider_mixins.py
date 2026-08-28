#!/usr/bin/env python3
"""Extract allowlisted methods into same-library extensions.

Dart cannot split one class across `part` files, and mixins-on-a-base cannot
see sibling mixin methods. Extensions in the same library keep the public
instance API (`library.queryVodCatalog`) while moving bodies out of the
god-object files. Fields and constructors stay on the class.

Static members must stay on the class; calls from extensions need
`LibraryProvider.foo` / `PlaybackProvider.foo`. `super.notifyListeners` is
illegal in extensions — use `_notifyPierceQuiet` / `_notifySession`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def member_span(text: str, name: str) -> tuple[int, int] | None:
    """Start/end offsets of a class member named `name` (indent 2)."""
    # Exactly two leading spaces so we do not match indented calls.
    patterns = [
        rf"^  (?! )(?:static\s+)?(?:[\w.<>,?]+(?:<[^>\n]+>)?\s+)?{re.escape(name)}\s*\(",
        rf"^  (?! )(?:static\s+)?[\w.<>,?]+(?:<[^>\n]+>)?\s+get\s+{re.escape(name)}\b",
        rf"^  (?! )set\s+{re.escape(name)}\s*\(",
    ]
    for pat in patterns:
        for m in re.finditer(pat, text, re.M):
            # skip if this is the constructor (Name matches class)
            start = m.start()
            # include preceding doc / annotations / blank lines at indent 0-2
            line_start = text.rfind("\n", 0, start) + 1
            prefix = line_start
            while prefix > 0:
                prev_nl = text.rfind("\n", 0, prefix - 1)
                prev = text[prev_nl + 1 : prefix]
                stripped = prev.strip()
                if stripped.startswith("///") or stripped.startswith("//") or stripped.startswith("@") or stripped == "":
                    prefix = prev_nl + 1
                    continue
                break
            end = _consume_from(text, start)
            return prefix, end
    return None


def _consume_from(text: str, start: int) -> int:
    i = start
    depth_brace = 0
    depth_paren = 0
    depth_brack = 0
    saw_brace = False
    in_str: str | None = None
    escape = False
    while i < len(text):
        ch = text[i]
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == in_str:
                in_str = None
            i += 1
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] == "/":
            nl = text.find("\n", i)
            i = len(text) if nl == -1 else nl + 1
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] == "*":
            endc = text.find("*/", i + 2)
            i = len(text) if endc == -1 else endc + 2
            continue
        if ch in ("'", '"'):
            if text[i : i + 3] in ("'''", '"""'):
                end = text.find(text[i : i + 3], i + 3)
                i = (end + 3) if end != -1 else len(text)
                continue
            in_str = ch
            i += 1
            continue
        if ch == "(":
            depth_paren += 1
        elif ch == ")":
            depth_paren -= 1
        elif ch == "[":
            depth_brack += 1
        elif ch == "]":
            depth_brack -= 1
        elif ch == "{":
            depth_brace += 1
            saw_brace = True
        elif ch == "}":
            depth_brace -= 1
            if saw_brace and depth_brace == 0 and depth_paren <= 0:
                return i + 1
        elif ch == ";" and not saw_brace and depth_paren <= 0 and depth_brack <= 0:
            return i + 1
        i += 1
    return len(text)


def extract_named(body: str, names: set[str]) -> tuple[str, str]:
    """Return (kept_body, extracted_chunk) moving `names` out of body."""
    spans: list[tuple[int, int, str]] = []
    for name in names:
        span = member_span(body, name)
        if span:
            spans.append((span[0], span[1], name))
    spans.sort()
    # drop overlaps (keep first)
    cleaned: list[tuple[int, int, str]] = []
    last = -1
    for a, b, n in spans:
        if a < last:
            continue
        cleaned.append((a, b, n))
        last = b
    chunks: list[str] = []
    kept: list[str] = []
    cursor = 0
    for a, b, _ in cleaned:
        kept.append(body[cursor:a])
        chunks.append(body[a:b].rstrip() + "\n")
        cursor = b
    kept.append(body[cursor:])
    return "".join(kept), "\n".join(chunks)


def extract_class(src: str, class_name: str) -> tuple[int, int, int, str]:
    m = re.search(rf"class {class_name} extends ChangeNotifier \{{", src)
    if not m:
        raise SystemExit(f"class {class_name} not found")
    body_start = m.end()
    depth = 1
    i = body_start
    while i < len(src) and depth:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return m.start(), body_start, i, src[body_start : i - 1]


def write_extension(path: Path, part_of: str, ext: str, on: str, body: str, extras: str = "") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"part of '{part_of}';\n\n{extras}extension {ext} on {on} {{\n{body.rstrip()}\n}}\n"
    )


PLAYBACK_ENGINE = {
    "player",
    "controller",
    "_enginePlay",
    "_enginePause",
    "_mpvSetPaused",
    "_applyEnginePlaying",
    "_setPlayingOverride",
    "_onEnginePlayingChanged",
    "_engineSeek",
    "_engineStop",
    "_engineRate",
    "_engineSetRate",
    "_snapRateToRealtimeIfNeeded",
    "_clearEngineBeforeLoad",
    "_awaitEngineSetup",
    "_openMedia",
    "_configureStreamTransport",
    "buildVideoSurface",
    "engineRevision",
    "_ensureEngine",
    "_wireVideoPlayerEngine",
    "_wireMediaKitEngine",
    "_cancelEngineSubscriptions",
    "_releaseEngine",
}

PLAYBACK_VAST = {
    "isPlayingAd",
    "adDuration",
    "adRemaining",
    "canSkipAd",
    "adClickThroughUrl",
    "adIcons",
    "adCompanion",
    "skipAd",
    "openAdClickThrough",
    "openAdIcon",
    "openAdCompanion",
    "_shouldPlayAds",
    "_maybeStartVast",
    "_beginAdPod",
    "_openAdCreative",
    "_applyAdCaptions",
    "_finishCurrentAd",
    "_openPendingContent",
    "_clearAdCreative",
    "_clearAdBreak",
    "_clearVastSession",
    "_maybeStartMidroll",
    "_crossedBreak",
    "_startMidroll",
    "_fireAdProgress",
    "_fireIconViews",
    "_pingAdEvent",
    "_pingUrls",
    "_resolveViewable",
    "_vastMacros",
    "_vastMacrosForContent",
}

PLAYBACK_DVR = {
    "canLiveDvr",
    "isAtLiveEdge",
    "canStartOver",
    "liveDelay",
    "liveDvrWindow",
    "liveDvrProgress",
    "playbackWallClock",
    "_dvrPlayheadWallClock",
    "liveScrubMode",
    "usesProgramScrubber",
    "liveProgramProgress",
    "liveProgramLiveFraction",
    "_refreshProgramCache",
    "currentProgram",
    "nextProgram",
    "seekLiveDvrProgress",
    "seekLiveProgramProgress",
    "seekLiveScrubProgress",
    "seekLiveDvrTo",
    "_continuousTimeshiftDuration",
    "_resumeWallClockForCatchup",
    "_onTimeshiftCompleted",
    "switchLiveQuality",
    "seekLiveDvrBy",
    "_canSeekWithinOpenTimeshift",
    "_seekNearLiveEdge",
    "jumpToLive",
    "startOverCurrentProgram",
    "_clearLivePausedAt",
    "_armLivePauseTicker",
    "_openTimeshift",
    "_retainLiveChannelAfterTimeshift",
    "_openMediaServerTimeshift",
    "_awaitOpenOutcome",
    "_parseCatchupStart",
    "_persistDvrProgress",
    "_parseTimeshiftStart",
    "_parseStamp",
}

LIBRARY_GROUPS: dict[str, set[str]] = {
    "vod": {
        "queryVodCatalog",
        "queryVodCatalogAsync",
        "ensureVodVariantIndex",
        "ensureVodGroupIndex",
        "ensureVodDbWorkingSet",
        "ensureVodDiskHydrated",
        "vodVariantsFor",
        "resolveVodVariant",
        "collapseVodVariants",
        "hydrateVodFamilyFromDb",
        "loadVodCategory",
        "vodShelfSample",
        "vodShelfSampleAsync",
        "vodPreview",
        "setPreferredVodVariant",
        "hasVodDb",
        "vodCacheCount",
        "vodItems",
        "_enableVodDb",
        "_persistVodCache",
        "_maybeMigrateVodJsonToDb",
    },
    "live": {
        "liveChannels",
        "ensureLiveIndex",
        "indexedLivePage",
        "pageLiveChannels",
        "liveListingCount",
        "qualityVariantsFor",
        "qualityVariantsForAsync",
        "resolveLiveChannel",
        "resolveLiveChannelAsync",
        "resolveCatchupChannel",
        "resolveCatchupChannelAsync",
        "liveSupportsCatchup",
        "liveSupportsCatchupAsync",
        "collapseLiveQualities",
        "setPreferredLiveQuality",
        "hasPreferredLiveQuality",
        "hasPreferredLiveQualityAsync",
        "ensureLiveCategoryAvailable",
        "loadLiveCategory",
        "catchupItem",
        "catchupItemAsync",
        "liveDvrItem",
        "hasLiveDb",
        "catchupChannels",
        "_enableLiveDbFromChannels",
        "_replaceLiveSourceInDb",
        "liveOrCatchupDisplayTitle",
    },
    "epg": {
        "fetchChannelGuide",
        "fetchChannelGuides",
        "guideFor",
        "programAt",
        "nowPlayingFor",
        "onNowChannels",
        "searchEpgHits",
        "scheduleProgramReminder",
        "cancelProgramReminder",
        "isEpgEnabledForChannel",
        "resolvedEpgUrlFor",
        "nearbyPrograms",
    },
    "sources": {
        "addM3uSource",
        "addXtreamSource",
        "addStalkerSource",
        "addCustomCatalogSource",
        "addXmltvSource",
        "addMediaServerSource",
        "removeSource",
        "renameSource",
        "setSourceEnabled",
        "updateSourceDetails",
        "importSourcesDocument",
        "buildSourcesExport",
        "syncSource",
        "isSourceSyncing",
        "loadDemoCatalog",
        "rebuildCatalogFromSources",
    },
    "trackers": {
        "syncSimklActivity",
        "syncTraktWatchlist",
        "syncSerializdActivity",
        "syncBetaseriesLists",
        "syncPlexWatchlist",
        "importLetterboxdExport",
        "saveSimklCredentials",
        "saveTraktCredentials",
        "trackerSyncPhase",
        "resolveSimklWatchingTap",
        "resolveSimklWatchingTapAsync",
        "resolveSerializdTap",
    },
    "history": {
        "flushPendingWrites",
        "recordWatch",
        "recordProgress",
        "removeFromHistory",
        "removeFromContinueWatching",
        "clearHistory",
        "seedContinueWatchingNext",
        "recentHistory",
    },
    "bootstrap": {
        "bootstrap",
        "markHomeRevealSettled",
        "waitUntilHomeRevealSettled",
        "reloadAfterSync",
        "_bootstrapDeferred",
        "_loadHomeShelfSnapshotEarly",
    },
    "downloads": {
        "enqueueDownload",
        "enqueueEpisodeDownloads",
        "enqueueCatchupDownload",
        "scheduleRemoveDownloadAfterWatch",
        "removeOfflineLibraryItem",
        "offlineLibraryItems",
        "downloadedSeriesItems",
    },
}


def split_playback() -> None:
    path = ROOT / "lib/providers/playback_provider.dart"
    src = path.read_text()
    class_start, body_start, class_end, body = extract_class(src, "PlaybackProvider")

    remaining = body
    extracted: dict[str, str] = {}
    for key, names in (
        ("engine", PLAYBACK_ENGINE),
        ("vast", PLAYBACK_VAST),
        ("dvr", PLAYBACK_DVR),
    ):
        remaining, chunk = extract_named(remaining, names)
        extracted[key] = chunk
        print(f"  playback {key}: {len(chunk.splitlines())} lines, {chunk.count(chr(10)+'  ')} members-ish")

    pending = ""
    pm = re.search(r"\nclass _PendingAfterAds \{.*?\n\}\n?\Z", src[class_end:], re.S)
    tail = src[class_end:]
    if pm:
        pending = pm.group(0).lstrip("\n")
        tail = tail[: pm.start()] + tail[pm.end() :]

    header = src[:class_start]
    if "part 'playback/" not in header:
        header = header.replace(
            "export 'package:javp/services/playback/player_loading_overlay.dart'\n    show playerLoadingOverlayVisible;\n\n",
            "export 'package:javp/services/playback/player_loading_overlay.dart'\n"
            "    show playerLoadingOverlayVisible;\n\n"
            "part 'playback/playback_engine.dart';\n"
            "part 'playback/playback_vast.dart';\n"
            "part 'playback/playback_dvr.dart';\n\n",
        )

    path.write_text(header + src[class_start:body_start] + remaining + "\n}" + tail)

    write_extension(
        ROOT / "lib/providers/playback/playback_engine.dart",
        "../playback_provider.dart",
        "PlaybackEngine",
        "PlaybackProvider",
        extracted["engine"],
    )
    write_extension(
        ROOT / "lib/providers/playback/playback_vast.dart",
        "../playback_provider.dart",
        "PlaybackVast",
        "PlaybackProvider",
        extracted["vast"],
        extras=pending + ("\n" if pending else ""),
    )
    write_extension(
        ROOT / "lib/providers/playback/playback_dvr.dart",
        "../playback_provider.dart",
        "PlaybackDvr",
        "PlaybackProvider",
        extracted["dvr"],
    )


def split_library() -> None:
    path = ROOT / "lib/providers/library_provider.dart"
    src = path.read_text()
    class_start, body_start, class_end, body = extract_class(src, "LibraryProvider")
    remaining = body
    extracted: dict[str, str] = {}
    for key, names in LIBRARY_GROUPS.items():
        remaining, chunk = extract_named(remaining, names)
        extracted[key] = chunk
        print(f"  library {key}: {len(chunk.splitlines())} lines")

    parts = "\n".join(
        f"part 'library/library_{k}.dart';" for k in LIBRARY_GROUPS
    )
    header = src[:class_start]
    if "part 'library/" not in header:
        doc = header.rfind("\n///")
        # Insert parts immediately before `class`, not before the last `///`
        # (that splits the class doc).
        cls = header.rfind("\nclass ")
        if cls != -1:
            header = header[:cls] + "\n" + parts + "\n" + header[cls:]
        elif doc != -1:
            header = header[:doc] + "\n" + parts + "\n" + header[doc:]
        else:
            header = header + parts + "\n\n"
    tail = src[class_end:]
    path.write_text(header + src[class_start:body_start] + remaining + "\n}" + tail)
    names = {
        "vod": "LibraryVod",
        "live": "LibraryLive",
        "epg": "LibraryEpg",
        "sources": "LibrarySources",
        "trackers": "LibraryTrackers",
        "history": "LibraryHistory",
        "bootstrap": "LibraryBootstrap",
        "downloads": "LibraryDownloads",
    }
    for key, ext in names.items():
        write_extension(
            ROOT / f"lib/providers/library/library_{key}.dart",
            "../library_provider.dart",
            ext,
            "LibraryProvider",
            extracted[key] or "  // no members matched\n",
        )


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in {"playback", "library", "all"}:
        print("usage: split_provider_mixins.py playback|library|all")
        sys.exit(2)
    target = sys.argv[1]
    if target in {"playback", "all"}:
        split_playback()
    if target in {"library", "all"}:
        split_library()


if __name__ == "__main__":
    main()
