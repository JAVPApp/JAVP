import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/iptv_category.dart';

/// Why a catalog sync job was scheduled.
enum SyncReason {
  manual,
  soft,
  idle,
  rebuild,
  deep,
}

/// Catalog writer operations owned by [SyncEngine].
enum SyncOp {
  /// Xtream VOD + series dump → `vod_catalog.db`.
  xtreamVod,

  /// Xtream live dump → `live_channels.db`.
  xtreamLive,

  /// Merged XMLTV feeds → `epg_programs.db`.
  xmltvEpg,
}

/// One catalog write job (desktop: child process; mobile: in-process).
class SyncJob {
  const SyncJob({
    required this.op,
    required this.reason,
    required this.profileId,
    required this.source,
    this.epgDisplayNames = const {},
    this.preferredLiveQualities = const {},
    this.liveCategories = const [],
    this.epgUrls = const [],
    this.warmEpgUrls = const [],
    this.trigger = '',
  });

  final SyncOp op;
  final SyncReason reason;
  final String profileId;
  final IptvSource source;

  /// Optional log label (e.g. EPG `manual-sync:xmltv`).
  final String trigger;

  /// Live-only: XMLTV display names for EPG id matching during pack.
  final Map<String, String> epgDisplayNames;

  /// Live-only: preferred quality per family.
  final Map<String, String> preferredLiveQualities;

  /// Live-only: categories already fetched by the UI (skip worker re-fetch).
  final List<IptvCategory> liveCategories;

  /// [SyncOp.xmltvEpg]: feed URLs to download / keep.
  final List<String> epgUrls;

  /// [SyncOp.xmltvEpg]: feeds already warm — skip HTTP when SQLite has them.
  final List<String> warmEpgUrls;

  Map<String, Object?> toJson() => {
        'v': 1,
        't': 'job',
        'op': op.name,
        'reason': reason.name,
        'profileId': profileId,
        'source': source.toJson(),
        if (epgDisplayNames.isNotEmpty) 'epgDisplayNames': epgDisplayNames,
        if (preferredLiveQualities.isNotEmpty)
          'preferredLiveQualities': preferredLiveQualities,
        if (liveCategories.isNotEmpty)
          'liveCategories': [
            for (final c in liveCategories) c.toJson(),
          ],
        if (epgUrls.isNotEmpty) 'epgUrls': epgUrls,
        if (warmEpgUrls.isNotEmpty) 'warmEpgUrls': warmEpgUrls,
        if (trigger.isNotEmpty) 'trigger': trigger,
      };

  factory SyncJob.fromJson(Map<String, Object?> json) {
    final opName = '${json['op'] ?? ''}';
    final reasonName = '${json['reason'] ?? 'manual'}';
    final sourceRaw = json['source'];
    if (sourceRaw is! Map) {
      throw FormatException('SyncJob missing source');
    }
    final op = SyncOp.values.asNameMap()[opName];
    if (op == null) {
      throw FormatException('Unknown SyncOp: $opName');
    }
    final reason =
        SyncReason.values.asNameMap()[reasonName] ?? SyncReason.manual;
    final catsRaw = json['liveCategories'];
    final cats = <IptvCategory>[];
    if (catsRaw is List) {
      for (final raw in catsRaw) {
        if (raw is Map) {
          cats.add(IptvCategory.fromJson(Map<String, dynamic>.from(raw)));
        }
      }
    }
    return SyncJob(
      op: op,
      reason: reason,
      profileId: '${json['profileId'] ?? ''}',
      source: IptvSource.fromJson(Map<String, dynamic>.from(sourceRaw)),
      epgDisplayNames: _stringMap(json['epgDisplayNames']),
      preferredLiveQualities: _stringMap(json['preferredLiveQualities']),
      liveCategories: cats,
      epgUrls: _stringList(json['epgUrls']),
      warmEpgUrls: _stringList(json['warmEpgUrls']),
      trigger: '${json['trigger'] ?? ''}',
    );
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries) '${e.key}': '${e.value}',
    };
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if ('$e'.trim().isNotEmpty) '$e'.trim(),
    ];
  }
}

/// NDJSON event from engine → UI / stdout.
class SyncEvent {
  const SyncEvent._({
    required this.type,
    this.phase,
    this.status,
    this.committed,
    this.total,
    this.finalized,
    this.skipped,
    this.sqlCount,
    this.fingerprint,
    this.indexFingerprint,
    this.written,
    this.error,
  });

  factory SyncEvent.progress({
    required String phase,
    String? status,
    int? committed,
    int? total,
    bool finalized = false,
  }) =>
      SyncEvent._(
        type: 'progress',
        phase: phase,
        status: status,
        committed: committed,
        total: total,
        finalized: finalized,
      );

  factory SyncEvent.done({
    required bool skipped,
    required int sqlCount,
    String fingerprint = '',
    String indexFingerprint = '',
    bool written = false,
  }) =>
      SyncEvent._(
        type: 'done',
        skipped: skipped,
        sqlCount: sqlCount,
        fingerprint: fingerprint,
        indexFingerprint: indexFingerprint,
        written: written,
      );

  factory SyncEvent.error(String message) => SyncEvent._(
        type: 'error',
        error: message,
      );

  factory SyncEvent.hello() => const SyncEvent._(type: 'hello');

  final String type;
  final String? phase;
  final String? status;
  final int? committed;
  final int? total;
  final bool? finalized;
  final bool? skipped;
  final int? sqlCount;
  final String? fingerprint;
  final String? indexFingerprint;
  final bool? written;
  final String? error;

  Map<String, Object?> toJson() => {
        'v': 1,
        't': type,
        if (phase != null) 'phase': phase,
        if (status != null) 'status': status,
        if (committed != null) 'committed': committed,
        if (total != null) 'total': total,
        if (finalized != null) 'finalized': finalized,
        if (skipped != null) 'skipped': skipped,
        if (sqlCount != null) 'sqlCount': sqlCount,
        if (fingerprint != null && fingerprint!.isNotEmpty)
          'fingerprint': fingerprint,
        if (indexFingerprint != null && indexFingerprint!.isNotEmpty)
          'indexFingerprint': indexFingerprint,
        if (written != null) 'written': written,
        if (error != null) 'error': error,
      };

  factory SyncEvent.fromJson(Map<String, Object?> json) {
    final t = '${json['t'] ?? ''}';
    return SyncEvent._(
      type: t,
      phase: json['phase'] as String?,
      status: json['status'] as String?,
      committed: (json['committed'] as num?)?.toInt(),
      total: (json['total'] as num?)?.toInt(),
      finalized: json['finalized'] as bool?,
      skipped: json['skipped'] as bool?,
      sqlCount: (json['sqlCount'] as num?)?.toInt(),
      fingerprint: json['fingerprint'] as String?,
      indexFingerprint: json['indexFingerprint'] as String?,
      written: json['written'] as bool?,
      error: json['error'] as String?,
    );
  }
}

/// Final result for SyncClient callers.
class SyncJobResult {
  const SyncJobResult({
    required this.skipped,
    required this.sqlCount,
    this.fingerprint = '',
    this.indexFingerprint = '',
    this.written = false,
  });

  final bool skipped;
  final int sqlCount;
  final String fingerprint;
  final String indexFingerprint;
  final bool written;
}
