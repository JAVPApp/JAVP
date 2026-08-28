import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_details.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/services/parental/adult_content.dart';
import 'package:javp/services/metadata/external_ids.dart';
import 'package:javp/services/iptv/vod_ingest_plan.dart';
import 'package:javp/services/iptv/vod_variant_index.dart';
import 'package:javp/services/iptv/live_ingest_plan.dart';
import 'package:javp/services/iptv/xtream_play_url.dart';
import 'package:javp/services/storage/vod_catalog_db.dart';
import 'package:javp/services/diagnostics/hwnd_sync_trace.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

class XtreamSyncResult {
  const XtreamSyncResult({
    required this.live,
    required this.vod,
    required this.series,
    required this.liveCategories,
    required this.vodCategories,
    required this.seriesCategories,
    this.epgUrl,
    this.activeServerUrl,
  });

  final List<MediaItem> live;
  final List<MediaItem> vod;
  final List<MediaItem> series;
  final List<IptvCategory> liveCategories;
  final List<IptvCategory> vodCategories;
  final List<IptvCategory> seriesCategories;
  final String? epgUrl;
  final String? activeServerUrl;

  List<MediaItem> get all => [...live, ...vod, ...series];
}

/// Streamed VOD/series dump. SQL rows are never concatenated on the UI isolate.
class XtreamPackedIngest {
  const XtreamPackedIngest({
    required this.fingerprint,
    required this.sqlCount,
    this.families = const {},
    this.canonical = const {},
    this.indexFingerprint = '',
    this.skipped = false,
    this.bodyFingerprint = '',
  });

  final String fingerprint;
  final int sqlCount;
  final Map<String, List<String>> families;
  final Map<String, String> canonical;
  final String indexFingerprint;
  final bool skipped;
  /// Raw VOD|series body hashes — stored so the next Sync can skip jsonDecode.
  final String bodyFingerprint;
}

/// Xtream Codes API client for Live, VOD, series, EPG, and catchup.
class XtreamClient {
  XtreamClient({http.Client? httpClient})
    : _http = httpClient ?? http.Client(),
      _httpInjected = httpClient != null;

  final http.Client _http;

  /// Tests inject [http.Client]; production dumps fetch inside the JSON worker
  /// so the UI isolate never copies the body (that froze the Windows HWND).
  final bool _httpInjected;

  static String _normalizeBase(String url) =>
      url.replaceAll(RegExp(r'/+$'), '');

  List<String> _candidateBases(IptvSource source) {
    final bases = <String>[];
    void add(String? raw) {
      if (raw == null || raw.trim().isEmpty) return;
      final normalized = _normalizeBase(raw.trim());
      if (!bases.contains(normalized)) bases.add(normalized);
    }

    add(source.serverUrl);
    add(source.alternateServerUrl);
    return bases;
  }

  Uri _playerApi(
    String base, {
    required String username,
    required String password,
    Map<String, String>? query,
  }) {
    return Uri.parse('$base/player_api.php').replace(
      queryParameters: {'username': username, 'password': password, ...?query},
    );
  }

  /// XMLTV guide URL for this Xtream account.
  String xmltvUrl(IptvSource source, {String? serverUrl}) {
    final base = _normalizeBase(serverUrl ?? source.serverUrl!);
    final uri = Uri.parse('$base/xmltv.php').replace(
      queryParameters: {
        'username': source.username!,
        'password': source.password!,
      },
    );
    return uri.toString();
  }

  Future<Map<String, dynamic>> authenticate(IptvSource source) async {
    Object? lastError;
    for (final base in _candidateBases(source)) {
      try {
        final response = await _http.get(
          _playerApi(
            base,
            username: source.username!,
            password: source.password!,
          ),
        );
        if (response.statusCode >= 400) {
          lastError = Exception('Xtream auth failed (${response.statusCode})');
          continue;
        }
        final body = jsonDecode(response.body);
        if (body is! Map<String, dynamic>) {
          lastError = Exception('Unexpected Xtream auth payload');
          continue;
        }
        final user = body['user_info'];
        if (user is Map && '${user['auth']}' == '0') {
          lastError = Exception('Xtream credentials rejected');
          continue;
        }
        return {...body, '_resolved_server_url': base};
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Xtream auth failed: $lastError');
  }

  Future<XtreamSyncResult> syncCatalog(
    IptvSource source, {
    bool includeVod = false,
    bool includeSeries = false,

    /// When false, skip the full `get_live_streams` dump — categories only.
    /// TV fills groups via [loadCategoryStreams] (same idea as Catalog VOD).
    bool includeLiveStreams = true,
  }) async {
    final hwnd = HwndSyncTrace.of(source.id);
    hwnd?.mark('syncCatalog-auth-start');
    final auth = await authenticate(source);
    hwnd?.mark('syncCatalog-auth-done');
    final activeBase = '${auth['_resolved_server_url'] ?? source.serverUrl}'
        .trim();
    final active = source.copyWith(serverUrl: activeBase);

    hwnd?.mark('syncCatalog-cats-start');
    final liveCatsFuture = getCategories(active, IptvCategoryKind.live);
    final vodCatsFuture = getCategories(active, IptvCategoryKind.vod);
    final seriesCatsFuture = getCategories(active, IptvCategoryKind.series);

    final cats = await Future.wait([
      liveCatsFuture,
      vodCatsFuture,
      seriesCatsFuture,
    ]);
    final liveCats = cats[0];
    final vodCats = cats[1];
    final seriesCats = cats[2];
    hwnd?.mark(
      'syncCatalog-cats-done',
      'live=${liveCats.length} vod=${vodCats.length} series=${seriesCats.length}',
    );

    var live = <MediaItem>[];
    if (includeLiveStreams) {
      hwnd?.mark('syncCatalog-live-streams-start');
      final liveRows = await getStreams(active, kind: IptvCategoryKind.live);
      final liveNameById = {for (final c in liveCats) c.id: c.name};
      final liveAdultIds = {
        for (final c in liveCats)
          if (c.isAdult) c.id,
      };
      // Panels routinely return 20k–40k live rows; mapping them in one pass
      // froze the UI for seconds mid-sync.
      live = await _mapChunked(
        liveRows,
        (row) => _mapLive(active, row, liveNameById, liveAdultIds),
      );
      hwnd?.mark('syncCatalog-live-streams-done', 'n=${live.length}');
    }

    var vod = <MediaItem>[];
    if (includeVod) {
      final vodNameById = {for (final c in vodCats) c.id: c.name};
      final vodAdultIds = {
        for (final c in vodCats)
          if (c.isAdult) c.id,
      };
      final vodRows = await getStreams(active, kind: IptvCategoryKind.vod);
      vod = await _mapChunked(
        vodRows,
        (row) => _mapVod(active, row, vodNameById, vodAdultIds),
      );
    }

    var series = <MediaItem>[];
    if (includeSeries) {
      final seriesNameById = {for (final c in seriesCats) c.id: c.name};
      final seriesAdultIds = {
        for (final c in seriesCats)
          if (c.isAdult) c.id,
      };
      final seriesRows = await getStreams(
        active,
        kind: IptvCategoryKind.series,
      );
      series = await _mapChunked(
        seriesRows,
        (row) => _mapSeries(active, row, seriesNameById, seriesAdultIds),
      );
    }

    hwnd?.mark('syncCatalog-done');
    return XtreamSyncResult(
      live: live,
      vod: vod,
      series: series,
      liveCategories: liveCats,
      vodCategories: vodCats,
      seriesCategories: seriesCats,
      epgUrl: xmltvUrl(active),
      activeServerUrl: activeBase,
    );
  }

  /// Candidate guide URLs for Xtream auto-discovery (zip first, then xmltv).
  /// Library probes in order and persists the first URL that returns a guide.
  List<String> epgCandidateUrls(IptvSource source, {String? serverUrl}) {
    final base = _normalizeBase(serverUrl ?? source.serverUrl!);
    return ['$base/epgZip.xml', xmltvUrl(source, serverUrl: base)];
  }

  /// Full movies + series packed for SQLite — no `List<MediaItem>` kept.
  ///
  /// Library prefetch **replaces** this source. An empty plan must not wipe
  /// a warm cache — that skip lives in [LibraryProvider], not here.
  /// Per-category [loadCategoryStreams] still returns a page of items.
  Future<VodIngestPlan> fetchOnDemandCatalogPlan(IptvSource source) async {
    final sqlRows = <Map<String, Object?>>[];
    final dumped = await streamOnDemandCatalog(
      source,
      onSqlChunk: (chunk) async => sqlRows.addAll(chunk),
    );
    return VodIngestPlan(
      rows: sqlRows,
      families: dumped.families,
      canonical: dumped.canonical,
    );
  }

  /// Same dump as [fetchOnDemandCatalogPlan] but SQL rows are handed to
  /// [onSqlChunk] 400 at a time and dropped. Use this on the first-sync path
  /// so Windows can keep pumping the HWND.
  Future<XtreamPackedIngest> streamOnDemandCatalog(
    IptvSource source, {
    HwndSyncTrace? hwnd,
    Future<bool> Function(String fingerprint, int sqlCount)? skipIf,
    /// Raw dump body hash — skip without jsonDecode when unchanged.
    Future<bool> Function(String bodyFingerprint)? skipIfBody,
    Future<void> Function(String bodyFingerprint)? rememberBody,
    required Future<void> Function(List<Map<String, Object?>> chunk) onSqlChunk,
    SendPort? sqlSink,
    Future<SendPort?> Function()? openSqlSink,
  }) async {
    final trace = hwnd ??
        HwndSyncTrace.of(source.id) ??
        HwndSyncTrace.begin('vod-stream', sourceId: source.id);
    trace.mark('vod-auth-start');
    final auth = await authenticate(source);
    trace.mark('vod-auth-done');
    final activeBase = '${auth['_resolved_server_url'] ?? source.serverUrl}'
        .trim();
    final active = source.copyWith(serverUrl: activeBase);

    trace.mark('vod-cats-start');
    final vodCats = await getCategories(active, IptvCategoryKind.vod);
    final seriesCats = await getCategories(active, IptvCategoryKind.series);
    trace.mark(
      'vod-cats-done',
      'vodCats=${vodCats.length} seriesCats=${seriesCats.length}',
    );
    final vodNameById = {for (final c in vodCats) c.id: c.name};
    final seriesNameById = {for (final c in seriesCats) c.id: c.name};
    final vodAdultIds = {
      for (final c in vodCats)
        if (c.isAdult) c.id,
    };
    final seriesAdultIds = {
      for (final c in seriesCats)
        if (c.isAdult) c.id,
    };
    return ingestOnDemandCatalog(
      active,
      hwnd: trace,
      vodCategoryNames: vodNameById,
      seriesCategoryNames: seriesNameById,
      vodAdultIds: vodAdultIds,
      seriesAdultIds: seriesAdultIds,
      skipIf: skipIf,
      skipIfBody: skipIfBody,
      rememberBody: rememberBody,
      onSqlChunk: onSqlChunk,
      sqlSink: sqlSink,
      openSqlSink: openSqlSink,
    );
  }

  /// Stream packed VOD + series dumps into [onSqlChunk] without holding the
  /// combined SQL list on the UI isolate. Variant families stay on the worker
  /// (never copied back) — the library rebuilds Versions from disk after ingest.
  /// Both dumps pause after fingerprint so an unchanged catalog can skip the
  /// isolate copy entirely.
  Future<XtreamPackedIngest> ingestOnDemandCatalog(
    IptvSource source, {
    HwndSyncTrace? hwnd,
    required Map<String, String> vodCategoryNames,
    required Map<String, String> seriesCategoryNames,
    required Set<String> vodAdultIds,
    required Set<String> seriesAdultIds,
    Future<bool> Function(String fingerprint, int sqlCount)? skipIf,
    Future<bool> Function(String bodyFingerprint)? skipIfBody,
    Future<void> Function(String bodyFingerprint)? rememberBody,
    required Future<void> Function(List<Map<String, Object?>> chunk) onSqlChunk,
    /// When set, SQL maps go worker → this port (never UI isolate).
    SendPort? sqlSink,
    /// Lazily open the sink after fingerprint skip fails (avoid writer on no-op).
    Future<SendPort?> Function()? openSqlSink,
  }) async {
    final trace = hwnd ?? HwndSyncTrace.of(source.id);
    // Stream-hash bodies first (no jsonDecode, bytes discarded). When this
    // matches the stored body fp, Synchroniser never builds map heaps — that
    // was the HWND freeze during "Récupération du catalogue VOD".
    var bodyFingerprint = '';
    if (!kIsWeb &&
        (skipIfBody != null || skipIf != null || rememberBody != null)) {
      trace?.mark('vod-body-hash-start');
      final vodBody = await _streamDumpBodyFingerprint(
        source,
        kind: IptvCategoryKind.vod,
        hwnd: trace,
      );
      await pumpUi(label: 'vod-body-hash-vod');
      final seriesBody = await _streamDumpBodyFingerprint(
        source,
        kind: IptvCategoryKind.series,
        hwnd: trace,
      );
      await pumpUi(label: 'vod-body-hash-series');
      bodyFingerprint = '$vodBody|$seriesBody';
      trace?.mark('vod-body-meta', 'fp=$bodyFingerprint');
      if (skipIfBody != null && await skipIfBody(bodyFingerprint)) {
        trace?.mark('vod-skip-body', 'fp=$bodyFingerprint');
        return XtreamPackedIngest(
          fingerprint: bodyFingerprint,
          sqlCount: 0,
          skipped: true,
          bodyFingerprint: bodyFingerprint,
        );
      }
    }

    // Body changed or first seed: decode ONE dump at a time, free it, then the
    // next — never hold vod+series map heaps together.
    trace?.mark('vod-jobs-spawn');
    final vodJob = await _XtreamPackedJob.start(
      this,
      source,
      kind: IptvCategoryKind.vod,
      categoryNames: vodCategoryNames,
      adultIds: vodAdultIds,
      sqlOnly: true,
    );
    await vodJob.advanceToIdsMeta(hwnd: trace);
    final vodFp = vodJob.fingerprint;
    final vodN = vodJob.sqlCount;
    await vodJob.cancel();
    await pumpUi(label: 'vod-ids-freed-vod');

    final seriesJob = await _XtreamPackedJob.start(
      this,
      source,
      kind: IptvCategoryKind.series,
      categoryNames: seriesCategoryNames,
      adultIds: seriesAdultIds,
      sqlOnly: true,
    );
    await seriesJob.advanceToIdsMeta(hwnd: trace);
    final seriesFp = seriesJob.fingerprint;
    final seriesN = seriesJob.sqlCount;
    final sqlCount = vodN + seriesN;
    final fingerprint = '$vodFp|$seriesFp';
    if (bodyFingerprint.isEmpty) {
      bodyFingerprint =
          '${vodJob.bodyFingerprint}|${seriesJob.bodyFingerprint}';
    }
    trace?.mark(
      'vod-jobs-meta',
      'n=$sqlCount vodN=$vodN seriesN=$seriesN',
    );
    if (skipIf != null && await skipIf(fingerprint, sqlCount)) {
      await rememberBody?.call(bodyFingerprint);
      await seriesJob.cancel();
      trace?.mark('vod-skip-fingerprint', 'n=$sqlCount');
      return XtreamPackedIngest(
        fingerprint: fingerprint,
        sqlCount: sqlCount,
        skipped: true,
        bodyFingerprint: bodyFingerprint,
      );
    }
    await seriesJob.cancel();
    await pumpUi(label: 'vod-ids-miss-restart');

    // Rewrite: fresh sequential jobs (ids path already freed the probes).
    final sink = sqlSink ?? (openSqlSink != null ? await openSqlSink() : null);
    final vodWrite = await _XtreamPackedJob.start(
      this,
      source,
      kind: IptvCategoryKind.vod,
      categoryNames: vodCategoryNames,
      adultIds: vodAdultIds,
      sqlOnly: true,
    );
    await vodWrite.advanceToIdsMeta(hwnd: trace);
    try {
      trace?.mark(
        'vod-drain-movies-start',
        'n=${vodWrite.sqlCount} sink=${sink != null}',
      );
      await vodWrite.drain(
        onSqlChunk: onSqlChunk,
        hwnd: trace,
        sqlSink: sink,
      );
    } catch (_) {
      await vodWrite.cancel();
      rethrow;
    }
    final seriesWrite = await _XtreamPackedJob.start(
      this,
      source,
      kind: IptvCategoryKind.series,
      categoryNames: seriesCategoryNames,
      adultIds: seriesAdultIds,
      sqlOnly: true,
    );
    await seriesWrite.advanceToIdsMeta(hwnd: trace);
    try {
      trace?.mark('vod-drain-series-start', 'n=${seriesWrite.sqlCount}');
      await seriesWrite.drain(
        onSqlChunk: onSqlChunk,
        hwnd: trace,
        sqlSink: sink,
      );
      trace?.mark('vod-drain-done', 'n=$sqlCount');
    } catch (_) {
      await seriesWrite.cancel();
      rethrow;
    }
    await rememberBody?.call(bodyFingerprint);
    return XtreamPackedIngest(
      fingerprint: fingerprint,
      sqlCount: sqlCount,
      bodyFingerprint: bodyFingerprint,
    );
  }

  /// Download a list dump and SHA-1 the bytes without jsonDecode (HWND-safe).
  Future<String> _streamDumpBodyFingerprint(
    IptvSource source, {
    required IptvCategoryKind kind,
    HwndSyncTrace? hwnd,
  }) async {
    final action = switch (kind) {
      IptvCategoryKind.live => 'get_live_streams',
      IptvCategoryKind.vod => 'get_vod_streams',
      IptvCategoryKind.series => 'get_series',
    };
    final uri = _playerApi(
      _normalizeBase(source.serverUrl!),
      username: source.username!,
      password: source.password!,
      query: {'action': action},
    );
    hwnd?.mark('vod-body-hash-wait', 'kind=${kind.name}');
    final hb = Timer.periodic(const Duration(milliseconds: 250), (_) {
      unawaited(pumpUi(label: 'vod-body-hash'));
    });
    try {
      final fp = await Isolate.run(() => _xtreamStreamBodySha1(uri.toString()));
      hwnd?.mark('vod-body-hash-done', 'kind=${kind.name}');
      return fp;
    } finally {
      hb.cancel();
    }
  }

  /// Decodes off the UI isolate once a payload is big enough to be worth the
  /// spawn cost — series info for a long-running show can run to megabytes.
  static Future<Object?> _decodeJson(String body) {
    if (body.length < 64 * 1024) return Future.value(jsonDecode(body));
    return Isolate.run(() => jsonDecode(body));
  }

  /// Yield while mapping tens of thousands of rows so the UI isolate can paint.
  static Future<List<MediaItem>> _mapChunked(
    List<Map<String, dynamic>> rows,
    MediaItem? Function(Map<String, dynamic>) mapRow,
  ) async {
    final out = <MediaItem>[];
    final slice = Stopwatch()..start();
    for (var i = 0; i < rows.length; i++) {
      final item = mapRow(rows[i]);
      if (item != null) out.add(item);
      await yieldUiIfDue(slice, label: 'xtream-map-rows');
    }
    return out;
  }

  Future<List<IptvCategory>> getCategories(
    IptvSource source,
    IptvCategoryKind kind,
  ) async {
    final action = switch (kind) {
      IptvCategoryKind.live => 'get_live_categories',
      IptvCategoryKind.vod => 'get_vod_categories',
      IptvCategoryKind.series => 'get_series_categories',
    };
    final rows = await _getList(source, action);
    return rows
        .map((row) {
          final id = '${row['category_id'] ?? ''}';
          if (id.isEmpty) return null;
          return IptvCategory(
            id: id,
            name: '${row['category_name'] ?? 'Category'}',
            kind: kind,
            parentId: row['parent_id']?.toString(),
            sourceId: source.id,
            isAdult: truthyAdultFlag(row['is_adult']),
          );
        })
        .whereType<IptvCategory>()
        .toList();
  }

  Future<List<Map<String, dynamic>>> getStreams(
    IptvSource source, {
    required IptvCategoryKind kind,
    String? categoryId,
  }) async {
    final action = switch (kind) {
      IptvCategoryKind.live => 'get_live_streams',
      IptvCategoryKind.vod => 'get_vod_streams',
      IptvCategoryKind.series => 'get_series',
    };
    final extra = <String, String>{};
    if (categoryId != null && categoryId.isNotEmpty) {
      extra['category_id'] = categoryId;
    }
    return _getList(source, action, extraQuery: extra);
  }

  Future<List<MediaItem>> loadCategoryStreams(
    IptvSource source, {
    required IptvCategory category,
  }) async {
    final rows = await getStreams(
      source,
      kind: category.kind,
      categoryId: category.id,
    );
    final nameById = {category.id: category.name};
    final adultIds = {if (category.isAdult) category.id};
    // Category dumps are 1k–15k rows; a tight .map().toList() freezes TV /
    // Catalog while the group is opening.
    return _mapChunked(rows, (row) {
      return switch (category.kind) {
        IptvCategoryKind.live => _mapLive(source, row, nameById, adultIds),
        IptvCategoryKind.vod => _mapVod(source, row, nameById, adultIds),
        IptvCategoryKind.series => _mapSeries(source, row, nameById, adultIds),
      };
    });
  }

  /// Live group as packed SQL maps — UI never hydrates [MediaItem] graphs.
  Future<List<Map<String, Object?>>> loadCategoryLivePacked(
    IptvSource source, {
    required IptvCategory category,
  }) async {
    final rows = await getStreams(
      source,
      kind: IptvCategoryKind.live,
      categoryId: category.id,
    );
    final nameById = {category.id: category.name};
    final adultIds = {if (category.isAdult) category.id};
    final out = <Map<String, Object?>>[];
    final slice = Stopwatch()..start();
    for (var i = 0; i < rows.length; i++) {
      final packed = packLiveSqlRow(source, rows[i], nameById, adultIds);
      if (packed != null) out.add(packed);
      await yieldUiIfDue(slice, label: 'xtream-live-pack');
    }
    return out;
  }

  /// Full `get_live_streams` dump as packed SQL maps — background sync path.
  ///
  /// TV still demand-loads one group via [loadCategoryLivePacked]. This call
  /// skips [MediaItem] graphs so a 20k–40k panel does not freeze the UI.
  Future<List<Map<String, Object?>>> fetchAllLivePacked(
    IptvSource source, {
    List<IptvCategory>? liveCategories,
  }) async {
    final cats =
        liveCategories ?? await getCategories(source, IptvCategoryKind.live);
    final nameById = {for (final c in cats) c.id: c.name};
    final adultIds = {
      for (final c in cats)
        if (c.isAdult) c.id,
    };
    final packed = await _getPackedDump(
      source,
      kind: IptvCategoryKind.live,
      categoryNames: nameById,
      adultIds: adultIds,
    );
    return packed.sql;
  }

  /// Full `get_live_streams` dump streamed as SQL / listing / variant chunks.
  ///
  /// The JSON worker builds the quality index. The UI isolate never holds the
  /// unscoped channel list (that copy froze Windows during Sources Sync).
  Future<XtreamPackedIngest> streamLiveCatalog(
    IptvSource source, {
    List<IptvCategory>? liveCategories,
    Map<String, String> epgDisplayNames = const {},
    Map<String, String> preferredLiveQualities = const {},
    Future<bool> Function(String fingerprint, int sqlCount)? skipIf,
    required Future<void> Function(List<Map<String, Object?>> chunk) onSqlChunk,
    Future<void> Function(List<Map<String, Object?>> chunk)? onListingChunk,
    Future<void> Function(List<Map<String, Object?>> chunk)? onVariantChunk,
  }) async {
    final trace = HwndSyncTrace.of(source.id) ??
        HwndSyncTrace.begin('live-stream', sourceId: source.id);
    trace.mark('live-cats-start');
    final cats =
        liveCategories ?? await getCategories(source, IptvCategoryKind.live);
    final nameById = {for (final c in cats) c.id: c.name};
    final adultIds = {
      for (final c in cats)
        if (c.isAdult) c.id,
    };
    trace.mark('live-job-spawn', 'cats=${cats.length}');
    final job = await _XtreamPackedJob.start(
      this,
      source,
      kind: IptvCategoryKind.live,
      categoryNames: nameById,
      adultIds: adultIds,
      livePlan: true,
      epgDisplayNames: epgDisplayNames,
      preferredLiveQualities: preferredLiveQualities,
    );
    await job.advanceToIdsMeta(hwnd: trace);
    trace.mark('live-job-meta', 'n=${job.sqlCount}');
    if (job.sqlCount == 0) {
      await job.cancel();
      return XtreamPackedIngest(
        fingerprint: job.fingerprint,
        sqlCount: 0,
      );
    }
    if (skipIf != null && await skipIf(job.fingerprint, job.sqlCount)) {
      await job.cancel();
      trace.mark('live-skip-fingerprint', 'n=${job.sqlCount}');
      return XtreamPackedIngest(
        fingerprint: job.fingerprint,
        sqlCount: job.sqlCount,
        skipped: true,
      );
    }
    try {
      trace.mark('live-drain-start', 'n=${job.sqlCount}');
      await job.drain(
        onSqlChunk: onSqlChunk,
        onListingChunk: onListingChunk,
        onVariantChunk: onVariantChunk,
        hwnd: trace,
      );
      trace.mark('live-drain-done', 'n=${job.sqlCount}');
    } catch (_) {
      await job.cancel();
      rethrow;
    }
    return XtreamPackedIngest(
      fingerprint: job.fingerprint,
      sqlCount: job.sqlCount,
      indexFingerprint: job.indexFingerprint,
    );
  }

  /// Per-channel guide. Prefers `get_short_epg` (current window) then
  /// `get_simple_data_table` (longer archive) as fallback.
  ///
  /// When [preferArchive] is true (catchup channels), always also loads the
  /// simple data table and merges it so past programmes are not dropped just
  /// because the short EPG returned a near-now window.
  Future<List<EpgProgram>> fetchChannelEpg(
    IptvSource source, {
    required String streamId,
    bool preferArchive = false,
  }) async {
    Future<List<EpgProgram>> load(Map<String, String> query) async {
      final response = await _http.get(
        _playerApi(
          _normalizeBase(source.serverUrl!),
          username: source.username!,
          password: source.password!,
          query: query,
        ),
      );
      if (response.statusCode >= 400) return const [];
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return const [];
      final listings = decoded['epg_listings'];
      if (listings is! List) return const [];

      final programs = <EpgProgram>[];
      for (final raw in listings.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);
        final channelId = '${row['channel_id'] ?? ''}'.trim();
        final start = _parseEpgTime(row['start_timestamp'] ?? row['start']);
        final end = _parseEpgTime(row['stop_timestamp'] ?? row['end']);
        if (start == null || end == null) continue;

        final hasArchive = _truthy(row['has_archive']);
        final imageUrl = _firstNonEmptyString([
          row['stream_icon'],
          row['cover'],
          row['image'],
          row['movie_image'],
        ]);
        programs.add(
          EpgProgram(
            channelId: channelId.isEmpty ? streamId : channelId,
            title: _decodeXtreamText('${row['title'] ?? 'Program'}'),
            start: start.toUtc(),
            end: end.toUtc(),
            description: _decodeXtreamText('${row['description'] ?? ''}'),
            imageUrl: imageUrl,
            catchupId: row['id']?.toString(),
            hasArchive: hasArchive,
          ),
        );
      }
      programs.sort((a, b) => a.start.compareTo(b.start));
      return programs;
    }

    final short = await load({
      'action': 'get_short_epg',
      'stream_id': streamId,
      'limit': '24',
    });

    if (!preferArchive) {
      if (short.isNotEmpty) return short;
      return load({'action': 'get_simple_data_table', 'stream_id': streamId});
    }

    final full = await load({
      'action': 'get_simple_data_table',
      'stream_id': streamId,
    });
    if (full.isEmpty) return short;
    if (short.isEmpty) return full;
    return mergeEpgPrograms(short, full);
  }

  /// Union short + archive listings by start+title; keep the richer row.
  static List<EpgProgram> mergeEpgPrograms(
    List<EpgProgram> primary,
    List<EpgProgram> secondary,
  ) {
    final byKey = <String, EpgProgram>{};

    void add(EpgProgram p) {
      final key =
          '${p.start.toUtc().millisecondsSinceEpoch}|${p.title.toLowerCase()}';
      final existing = byKey[key];
      byKey[key] = existing == null ? p : _richerEpgProgram(existing, p);
    }

    for (final p in secondary) {
      add(p);
    }
    for (final p in primary) {
      add(p);
    }
    final out = byKey.values.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  static EpgProgram _richerEpgProgram(EpgProgram a, EpgProgram b) {
    int score(EpgProgram p) =>
        (p.hasArchive ? 4 : 0) +
        ((p.description != null && p.description!.trim().isNotEmpty) ? 2 : 0) +
        ((p.imageUrl != null && p.imageUrl!.isNotEmpty) ? 1 : 0);
    return score(b) > score(a) ? b : a;
  }

  Future<List<Map<String, dynamic>>> _getList(
    IptvSource source,
    String action, {
    Map<String, String>? extraQuery,
  }) async {
    final query = <String, String>{'action': action, ...?extraQuery};
    final uri = _playerApi(
      _normalizeBase(source.serverUrl!),
      username: source.username!,
      password: source.password!,
      query: query,
    );
    if (kIsWeb) {
      final response = await _http.get(uri);
      if (response.statusCode >= 400) {
        throw Exception('Xtream $action failed (${response.statusCode})');
      }
      return _mapsFromDecodedList(jsonDecode(response.body));
    }
    final request = http.Request('GET', uri);
    final streamed = await _http.send(request);
    if (streamed.statusCode >= 400) {
      unawaited(
        streamed.stream.drain<void>().then<void>((_) {}, onError: (_) {}),
      );
      throw Exception('Xtream $action failed (${streamed.statusCode})');
    }
    // Stream bytes to the worker. Isolating jsonDecode of a 20MB live dump
    // used to copy the whole String onto the UI isolate (Windows Not Responding).
    return _decodeListMapsFromByteStream(streamed.stream);
  }

  Future<
    ({List<Map<String, Object?>> sql, List<Map<String, Object?>> variants})
  >
  _getPackedDump(
    IptvSource source, {
    required IptvCategoryKind kind,
    required Map<String, String> categoryNames,
    required Set<String> adultIds,
  }) async {
    final job = await _XtreamPackedJob.start(
      this,
      source,
      kind: kind,
      categoryNames: categoryNames,
      adultIds: adultIds,
    );
    final sql = <Map<String, Object?>>[];
    await job.drain(onSqlChunk: (chunk) async => sql.addAll(chunk));
    return (sql: sql, variants: const <Map<String, Object?>>[]);
  }

  static Future<
    ({List<Map<String, Object?>> sql, List<Map<String, Object?>> variants})
  >
  _packRowsOnThisIsolate(
    IptvSource source,
    List<Map<String, dynamic>> rows, {
    required IptvCategoryKind kind,
    required Map<String, String> categoryNames,
    required Set<String> adultIds,
  }) async {
    final sql = <Map<String, Object?>>[];
    final variants = <Map<String, Object?>>[];
    final slice = Stopwatch()..start();
    for (var i = 0; i < rows.length; i++) {
      _packDecodedRow(
        source,
        rows[i],
        kind: kind,
        categoryNames: categoryNames,
        adultIds: adultIds,
        sql: sql,
        variants: variants,
      );
      await yieldUiIfDue(slice, label: 'xtream-pack');
    }
    return (sql: sql, variants: variants);
  }

  static void _packDecodedRow(
    IptvSource source,
    Map<String, dynamic> row, {
    required IptvCategoryKind kind,
    required Map<String, String> categoryNames,
    required Set<String> adultIds,
    required List<Map<String, Object?>> sql,
    List<Map<String, Object?>>? variants,
  }) {
    if (kind == IptvCategoryKind.live) {
      final packed = packLiveSqlRow(source, row, categoryNames, adultIds);
      if (packed != null) sql.add(packed);
      return;
    }
    final item = kind == IptvCategoryKind.series
        ? _mapSeries(source, row, categoryNames, adultIds)
        : _mapVod(source, row, categoryNames, adultIds);
    if (item == null) return;
    sql.add(VodCatalogDb.packItem(item));
    if (variants != null && !item.isEpisode && !item.isLive) {
      variants.add(VodVariantIndex.packRow(item));
    }
  }

  static const _jsonListChunkSize = 400;

  /// Cap isolate copies of HTTP bytes. A single `SendPort.send` of a multi-MB
  /// chunk holds the UI isolate long enough for Windows to mark the HWND hung.
  static Future<void> _forwardBytesToJsonWorker(
    SendPort workerPort,
    Stream<List<int>> bytes,
  ) async {
    await for (final chunk in bytes) {
      final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      var offset = 0;
      while (offset < data.length) {
        final end = offset + kIsolateByteChunk > data.length
            ? data.length
            : offset + kIsolateByteChunk;
        workerPort.send(data.sublist(offset, end));
        offset = end;
        await pumpUi();
      }
    }
    workerPort.send(null);
  }

  static List<Map<String, dynamic>> _mapsFromDecodedList(Object? decoded) {
    if (decoded is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final entry in decoded) {
      if (entry is Map<String, dynamic>) {
        out.add(entry);
      } else if (entry is Map) {
        out.add(Map<String, dynamic>.from(entry));
      }
    }
    return out;
  }

  static Future<List<Map<String, dynamic>>> _decodeListMapsFromByteStream(
    Stream<List<int>> bytes,
  ) async {
    final receive = ReceivePort();
    final errors = ReceivePort();
    late final Isolate worker;
    try {
      worker = await Isolate.spawn(
        _decodeListMapsIsolateMain,
        receive.sendPort,
        onError: errors.sendPort,
        errorsAreFatal: true,
      );
    } catch (_) {
      receive.close();
      errors.close();
      rethrow;
    }

    Object? isolateError;
    final errorSub = errors.listen((msg) {
      isolateError ??= msg;
    });
    final iter = StreamIterator(receive);
    try {
      if (!await iter.moveNext()) {
        throw StateError('xtream json isolate exited before handshake');
      }
      if (isolateError != null) throw isolateError!;
      final workerPort = iter.current as SendPort;
      workerPort.send(const <String, Object?>{});
      await _forwardBytesToJsonWorker(workerPort, bytes);

      final out = <Map<String, dynamic>>[];
      while (await iter.moveNext()) {
        if (isolateError != null) throw isolateError!;
        final message = iter.current;
        if (message == null) break;
        if (message is List) {
          for (final entry in message) {
            if (entry is Map<String, dynamic>) {
              out.add(entry);
            } else if (entry is Map) {
              out.add(Map<String, dynamic>.from(entry));
            }
          }
          await yieldAfterIsolateChunk();
        }
      }
      if (isolateError != null) throw isolateError!;
      return out;
    } finally {
      await errorSub.cancel();
      await iter.cancel();
      receive.close();
      errors.close();
      worker.kill(priority: Isolate.immediate);
    }
  }

  static MediaItem? _mapLive(
    IptvSource source,
    Map<String, dynamic> row,
    Map<String, String> categoryNames, [
    Set<String> adultCategoryIds = const {},
  ]) {
    final streamId = '${row['stream_id'] ?? ''}';
    if (streamId.isEmpty) return null;
    final name = '${row['name'] ?? 'Channel'}';
    final ext = '${row['container_extension'] ?? 'ts'}';
    final base = _normalizeBase(source.serverUrl!);
    final url = xtreamStoredStreamUrl(
      base: base,
      kind: 'live',
      streamId: streamId,
      extension: ext,
    );

    final categoryId = '${row['category_id'] ?? ''}';
    final group =
        categoryNames[categoryId] ?? '${row['category_name'] ?? 'Live'}';

    final archiveFlag = _truthy(row['tv_archive']);
    var catchupDays = int.tryParse('${row['tv_archive_duration'] ?? 0}') ?? 0;
    if (archiveFlag && catchupDays <= 0) catchupDays = 1;

    final epgRaw = row['epg_channel_id'];
    final epgChannelId = epgRaw == null || '$epgRaw'.trim().isEmpty
        ? null
        : '$epgRaw'.trim();

    final isAdult =
        truthyAdultFlag(row['is_adult']) ||
        adultCategoryIds.contains(categoryId);
    return MediaItem(
      id: 'xtream-live-${source.id}-$streamId',
      title: name,
      playUrl: url,
      kind: MediaKind.live,
      origin: MediaOrigin.iptvXtream,
      subtitle: group,
      thumbnailUrl: row['stream_icon'] as String?,
      group: group,
      channelId: streamId,
      streamId: streamId,
      epgChannelId: epgChannelId,
      catchupDays: catchupDays,
      sourceId: source.id,
      isAdult: isAdult,
    );
  }

  /// Packed live SQL row — same columns as [packLiveChannelRow] without a
  /// [MediaItem] allocate (20k-row groups used to hitch Windows focus).
  static Map<String, Object?>? packLiveSqlRow(
    IptvSource source,
    Map<String, dynamic> row,
    Map<String, String> categoryNames, [
    Set<String> adultCategoryIds = const {},
  ]) {
    final streamId = '${row['stream_id'] ?? ''}';
    if (streamId.isEmpty) return null;
    final name = '${row['name'] ?? 'Channel'}';
    final ext = '${row['container_extension'] ?? 'ts'}';
    final base = _normalizeBase(source.serverUrl!);
    final url = xtreamStoredStreamUrl(
      base: base,
      kind: 'live',
      streamId: streamId,
      extension: ext,
    );

    final categoryId = '${row['category_id'] ?? ''}';
    final group =
        categoryNames[categoryId] ?? '${row['category_name'] ?? 'Live'}';

    final archiveFlag = _truthy(row['tv_archive']);
    var catchupDays = int.tryParse('${row['tv_archive_duration'] ?? 0}') ?? 0;
    if (archiveFlag && catchupDays <= 0) catchupDays = 1;

    final epgRaw = row['epg_channel_id'];
    final epgChannelId = epgRaw == null || '$epgRaw'.trim().isEmpty
        ? null
        : '$epgRaw'.trim();

    final isAdult =
        truthyAdultFlag(row['is_adult']) ||
        adultCategoryIds.contains(categoryId);
    return {
      'id': 'xtream-live-${source.id}-$streamId',
      'source_id': source.id,
      'title': name,
      'play_url': url,
      'origin': MediaOrigin.iptvXtream.name,
      'thumbnail_url': row['stream_icon'] as String?,
      'group_name': group,
      'channel_id': streamId,
      'channel_name': null,
      'stream_id': streamId,
      'epg_channel_id': epgChannelId,
      'server_item_id': null,
      'catchup_days': catchupDays,
      'http_headers_json': null,
      'is_adult': isAdult ? 1 : 0,
    };
  }

  static MediaItem? _mapVod(
    IptvSource source,
    Map<String, dynamic> row,
    Map<String, String> categoryNames, [
    Set<String> adultCategoryIds = const {},
  ]) {
    final streamId = '${row['stream_id'] ?? ''}';
    if (streamId.isEmpty) return null;
    final name = '${row['name'] ?? 'Movie'}';
    final ext = '${row['container_extension'] ?? 'mp4'}';
    final base = _normalizeBase(source.serverUrl!);
    final url = xtreamStoredStreamUrl(
      base: base,
      kind: 'movie',
      streamId: streamId,
      extension: ext,
    );
    final categoryId = '${row['category_id'] ?? ''}';
    final group =
        categoryNames[categoryId] ?? '${row['category_name'] ?? 'Movies'}';

    final isAdult =
        truthyAdultFlag(row['is_adult']) ||
        adultCategoryIds.contains(categoryId);
    return MediaItem(
      id: 'xtream-vod-${source.id}-$streamId',
      title: name,
      playUrl: url,
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvXtream,
      subtitle: group,
      thumbnailUrl: row['stream_icon'] as String? ?? row['cover'] as String?,
      posterUrl: row['stream_icon'] as String? ?? row['cover'] as String?,
      group: group,
      streamId: streamId,
      sourceId: source.id,
      rating: double.tryParse('${row['rating'] ?? ''}'),
      year: int.tryParse('${row['year'] ?? ''}'),
      tmdbId: _tmdbIdFromRow(row, title: name),
      imdbId: ExternalIds.imdbFromMap(row, title: name),
      originalTitle: _originalTitleFromRow(row),
      isAdult: isAdult,
    );
  }

  static int? _yearFromRow(Object? raw) {
    final s = '$raw'.trim();
    if (s.isEmpty || s == 'null') return null;
    if (s.length >= 4) return int.tryParse(s.substring(0, 4));
    return int.tryParse(s);
  }

  static int? _tmdbIdFromRow(Map<dynamic, dynamic> row, {String? title}) {
    final direct = ExternalIds.tmdbFromMap(row, title: title);
    if (direct != null) return direct;
    final nested = row['info'] ?? row['movie_data'];
    if (nested is Map) {
      return ExternalIds.tmdbFromMap(
        Map<dynamic, dynamic>.from(nested),
        title: title,
      );
    }
    return null;
  }

  static String? _originalTitleFromRow(Map<dynamic, dynamic> row) {
    for (final key in const [
      'o_name',
      'original_name',
      'original_title',
      'originalTitle',
    ]) {
      final v = row[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    final nested = row['info'];
    if (nested is Map) {
      return _originalTitleFromRow(Map<dynamic, dynamic>.from(nested));
    }
    return null;
  }

  /// Rich VOD metadata via `get_vod_info` (includes panel `tmdb_id`).
  Future<XtreamVodInfo?> fetchVodInfo(
    IptvSource source, {
    required String vodId,
  }) async {
    final response = await _http.get(
      _playerApi(
        _normalizeBase(source.serverUrl!),
        username: source.username!,
        password: source.password!,
        query: {'action': 'get_vod_info', 'vod_id': vodId},
      ),
    );
    if (response.statusCode >= 400) return null;
    final decoded = await _decodeJson(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final info = decoded['info'];
    final infoMap = info is Map
        ? Map<String, dynamic>.from(info)
        : <String, dynamic>{};
    final movieData = decoded['movie_data'];
    final movieMap = movieData is Map
        ? Map<String, dynamic>.from(movieData)
        : const <String, dynamic>{};
    final tmdb = _tmdbIdFromRow(infoMap) ?? _tmdbIdFromRow(movieMap);
    final plot =
        (infoMap['plot'] as String?) ?? (infoMap['description'] as String?);
    final genresRaw = '${infoMap['genre'] ?? ''}';
    final genres = genresRaw
        .split(RegExp(r'[,|/]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final year =
        int.tryParse(
          '${infoMap['releasedate'] ?? infoMap['releaseDate'] ?? ''}'
              .split('-')
              .first,
        ) ??
        int.tryParse('${infoMap['year'] ?? ''}');
    final rating = double.tryParse('${infoMap['rating'] ?? ''}');
    final poster =
        (infoMap['movie_image'] as String?) ??
        (infoMap['cover_big'] as String?);
    final backdrops = infoMap['backdrop_path'];
    final backdrop = backdrops is List && backdrops.isNotEmpty
        ? '${backdrops.first}'
        : null;
    final trailer = infoMap['youtube_trailer'] as String?;
    final runtimeSecs = int.tryParse('${infoMap['duration_secs'] ?? ''}');
    final cast = '${infoMap['cast'] ?? infoMap['actors'] ?? ''}'
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(20)
        .map((name) => CastMember(name: name))
        .toList();

    return XtreamVodInfo(
      tmdbId: tmdb,
      plot: plot,
      genres: genres,
      year: year,
      rating: rating,
      posterUrl: poster,
      backdropUrl: backdrop,
      trailerKey: trailer,
      runtime: runtimeSecs == null ? null : Duration(seconds: runtimeSecs),
      cast: cast,
      name: infoMap['name'] as String?,
    );
  }

  /// Merge [fetchVodInfo] onto an existing list row.
  MediaItem applyVodInfo(MediaItem item, XtreamVodInfo info) {
    return item.copyWith(
      tmdbId: info.tmdbId ?? item.tmdbId,
      plot: info.plot ?? item.plot,
      genres: info.genres.isNotEmpty ? info.genres : item.genres,
      year: info.year ?? item.year,
      rating: info.rating ?? item.rating,
      posterUrl: info.posterUrl ?? item.posterUrl,
      backdropUrl: info.backdropUrl ?? item.backdropUrl,
      thumbnailUrl: info.posterUrl ?? item.thumbnailUrl,
      duration: info.runtime ?? item.duration,
      detailsId: info.tmdbId != null
          ? 'tmdb-movie-${info.tmdbId}'
          : item.detailsId,
    );
  }

  static MediaItem? _mapSeries(
    IptvSource source,
    Map<String, dynamic> row,
    Map<String, String> categoryNames, [
    Set<String> adultCategoryIds = const {},
  ]) {
    final seriesId = '${row['series_id'] ?? ''}';
    if (seriesId.isEmpty) return null;
    final name = '${row['name'] ?? 'Series'}';
    final categoryId = '${row['category_id'] ?? ''}';
    final group =
        categoryNames[categoryId] ?? '${row['category_name'] ?? 'Series'}';
    final seasons = row['seasons'];
    final seasonCount = seasons is List ? seasons.length : 0;
    final genre = row['genre'] as String?;

    final isAdult =
        truthyAdultFlag(row['is_adult']) ||
        adultCategoryIds.contains(categoryId);
    return MediaItem(
      id: 'xtream-series-${source.id}-$seriesId',
      title: name,
      // Series containers are not directly playable — open the detail screen.
      playUrl: '',
      kind: MediaKind.series,
      origin: MediaOrigin.iptvXtream,
      subtitle: [
        'Series',
        if (seasonCount > 0)
          '$seasonCount season${seasonCount == 1 ? '' : 's'}',
        if (genre != null && genre.trim().isNotEmpty) genre.trim(),
        group,
      ].join(' · '),
      thumbnailUrl: row['cover'] as String?,
      group: group,
      streamId: seriesId,
      sourceId: source.id,
      tmdbId: _tmdbIdFromRow(row, title: name),
      year: _yearFromRow(
        row['year'] ?? row['releaseDate'] ?? row['releasedate'],
      ),
      originalTitle: _originalTitleFromRow(row),
      isAdult: isAdult,
    );
  }

  /// Full series metadata + seasons/episodes via `get_series_info`.
  Future<SeriesInfo> fetchSeriesInfo(
    IptvSource source, {
    required String seriesId,
  }) async {
    final response = await _http.get(
      _playerApi(
        _normalizeBase(source.serverUrl!),
        username: source.username!,
        password: source.password!,
        query: {'action': 'get_series_info', 'series_id': seriesId},
      ),
    );
    if (response.statusCode >= 400) {
      throw Exception('Xtream series info failed (${response.statusCode})');
    }
    final decoded = await _decodeJson(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unexpected series info payload');
    }

    final info = decoded['info'];
    final infoMap = info is Map
        ? Map<String, dynamic>.from(info)
        : <String, dynamic>{};
    final title = '${infoMap['name'] ?? 'Series'}';
    final plot = infoMap['plot'] as String?;
    final cover = infoMap['cover'] as String?;
    final genre = infoMap['genre'] as String?;
    final releaseDate =
        '${infoMap['releaseDate'] ?? infoMap['releasedate'] ?? ''}'.trim();
    final rating = double.tryParse('${infoMap['rating'] ?? ''}');
    final backdrops = infoMap['backdrop_path'];
    final backdrop = backdrops is List && backdrops.isNotEmpty
        ? '${backdrops.first}'
        : null;

    final episodesRaw = decoded['episodes'];
    final seasonsMeta = decoded['seasons'];
    final seasonNameByNumber = <int, String>{};
    final seasonCoverByNumber = <int, String?>{};
    if (seasonsMeta is List) {
      for (final row in seasonsMeta.whereType<Map>()) {
        final map = Map<String, dynamic>.from(row);
        final num = int.tryParse('${map['season_number'] ?? ''}') ?? 0;
        seasonNameByNumber[num] = '${map['name'] ?? 'Season $num'}';
        seasonCoverByNumber[num] =
            map['cover'] as String? ?? map['cover_big'] as String?;
      }
    }

    final seasons = <SeriesSeason>[];
    if (episodesRaw is Map) {
      final keys = episodesRaw.keys.map((k) => '$k').toList()
        ..sort((a, b) {
          final ai = int.tryParse(a) ?? 0;
          final bi = int.tryParse(b) ?? 0;
          return ai.compareTo(bi);
        });
      for (final key in keys) {
        final seasonNumber = int.tryParse(key) ?? 0;
        final list = episodesRaw[key];
        if (list is! List) continue;
        final episodes = <SeriesEpisode>[];
        for (final raw in list.whereType<Map>()) {
          final row = Map<String, dynamic>.from(raw);
          final id = '${row['id'] ?? ''}';
          if (id.isEmpty) continue;
          final epInfo = row['info'];
          final epInfoMap = epInfo is Map
              ? Map<String, dynamic>.from(epInfo)
              : <String, dynamic>{};
          final durationSecs =
              int.tryParse('${epInfoMap['duration_secs'] ?? 0}') ?? 0;
          final airDate = SeriesEpisode.parseAirDate(
            epInfoMap['releasedate'] ??
                epInfoMap['releaseDate'] ??
                epInfoMap['release_date'] ??
                epInfoMap['air_date'] ??
                epInfoMap['airdate'] ??
                row['added'],
          );
          episodes.add(
            SeriesEpisode(
              id: id,
              episodeNum: int.tryParse('${row['episode_num'] ?? 0}') ?? 0,
              seasonNumber: seasonNumber,
              title: '${row['title'] ?? 'Episode'}',
              containerExtension: '${row['container_extension'] ?? 'mp4'}',
              plot: epInfoMap['plot'] as String?,
              thumbnailUrl: epInfoMap['movie_image'] as String?,
              duration: durationSecs > 0
                  ? Duration(seconds: durationSecs)
                  : null,
              airDate: airDate,
            ),
          );
        }
        episodes.sort((a, b) => a.episodeNum.compareTo(b.episodeNum));
        seasons.add(
          SeriesSeason(
            seasonNumber: seasonNumber,
            name: seasonNameByNumber[seasonNumber] ?? 'Season $seasonNumber',
            coverUrl: seasonCoverByNumber[seasonNumber],
            episodes: episodes,
          ),
        );
      }
    }

    return SeriesInfo(
      seriesId: seriesId,
      title: title,
      plot: plot,
      coverUrl: cover,
      genre: genre,
      releaseDate: releaseDate.isEmpty ? null : releaseDate,
      rating: rating,
      backdropUrl: backdrop,
      seasons: seasons,
    );
  }

  /// Xtream series episode stream URL.
  String seriesEpisodeUrl({
    required IptvSource source,
    required String episodeId,
    String extension = 'mp4',
  }) {
    final base = _normalizeBase(source.serverUrl!);
    final ext = extension.replaceAll('.', '');
    return '$base/series/${source.username}/${source.password}/$episodeId.$ext';
  }

  /// Build an Xtream timeshift/catchup URL for a program window.
  ///
  /// Verified against Xtream panels (incl. this project's test DNS):
  /// - `/timeshift/user/pass/{minutes}/{stamp}/{streamId}.m3u8` (VOD HLS)
  /// - `/streaming/timeshift.php?username&password&stream&start&duration`
  /// - `/timeshift/user/pass/{minutes}/{YYYY-MM-DD:HH-MM}/{streamId}.ts`
  /// Start stamps use the **UTC wall clock** (EPG `start_timestamp` / server
  /// `timezone: UTC`).
  ///
  /// Returns a **progressive** URL (php / `.ts`) so downloads and history rows
  /// stay eligible. Playback should use [catchupUrlCandidates], which prefers
  /// `.m3u8` VOD when the panel serves it (better scrubbing).
  String catchupUrl({
    required IptvSource source,
    required String streamId,
    required DateTime start,
    required Duration duration,
    String extension = 'ts',
  }) {
    final urls = catchupUrlCandidates(
      source: source,
      streamId: streamId,
      start: start,
      duration: duration,
      extension: extension,
    );
    return urls.firstWhere(
      (u) => !u.toLowerCase().contains('.m3u8'),
      orElse: () => urls.first,
    );
  }

  /// Ordered URL candidates — panels disagree on path vs php and stamp format.
  ///
  /// Prefers HLS VOD timeshift (`.m3u8`) for scrubbing, then progressive
  /// MPEG-TS. Some panels 401 segment URLs if the player does not follow the
  /// playlist redirect; callers should fall through to `.ts` / php.
  List<String> catchupUrlCandidates({
    required IptvSource source,
    required String streamId,
    required DateTime start,
    required Duration duration,
    String extension = 'ts',
  }) {
    final bases = <String>[_normalizeBase(source.serverUrl!)];
    final alt = source.alternateServerUrl?.trim();
    if (alt != null && alt.isNotEmpty) {
      final normalizedAlt = _normalizeBase(alt);
      if (!bases.contains(normalizedAlt)) bases.add(normalizedAlt);
    }

    // Match live URL style — panels expect raw credentials in the path.
    final user = source.username ?? '';
    final pass = source.password ?? '';
    final ext = extension.replaceAll('.', '');
    // Many panels reject multi-hour requests; keep a usable scrub window.
    final minutes = duration.inMinutes.clamp(1, 4 * 60);

    String pad2(int n) => n.toString().padLeft(2, '0');

    /// `YYYY-MM-DD:HH-MM` (most common Xtream timeshift stamp).
    String dashed(DateTime dt) {
      final t = dt;
      return '${t.year}-${pad2(t.month)}-${pad2(t.day)}:'
          '${pad2(t.hour)}-${pad2(t.minute)}';
    }

    /// `YYYY-MM-DD:HH:MM` (also accepted by this panel).
    String dashedColonTime(DateTime dt) {
      final t = dt;
      return '${t.year}-${pad2(t.month)}-${pad2(t.day)}:'
          '${pad2(t.hour)}:${pad2(t.minute)}';
    }

    /// EPG wall-clock form `YYYY-MM-DD HH:MM:SS`.
    String epgWall(DateTime dt) {
      final t = dt;
      return '${t.year}-${pad2(t.month)}-${pad2(t.day)} '
          '${pad2(t.hour)}:${pad2(t.minute)}:${pad2(t.second)}';
    }

    // EPG listings + server_info.timezone are UTC on the test panel.
    // Device-local stamps shift the window and break catchup in +N zones.
    final utc = start.toUtc();
    final local = start.toLocal();
    final stamps = <String>[
      dashed(utc),
      dashedColonTime(utc),
      epgWall(utc),
      if (dashed(local) != dashed(utc)) dashed(local),
      if (epgWall(local) != epgWall(utc)) epgWall(local),
    ];

    final urls = <String>[];
    void add(String url) {
      if (!urls.contains(url)) urls.add(url);
    }

    for (final base in bases) {
      for (final stamp in stamps) {
        final enc = Uri.encodeComponent(stamp);
        // HLS VOD first — known duration + segment seeks when the CDN allows it.
        add('$base/timeshift/$user/$pass/$minutes/$enc/$streamId.m3u8');
        // Query form — avoids libmpv choking on `:` in path segments.
        add(
          Uri.parse('$base/streaming/timeshift.php')
              .replace(
                queryParameters: {
                  'username': user,
                  'password': pass,
                  'stream': streamId,
                  'start': stamp,
                  'duration': '$minutes',
                },
              )
              .toString(),
        );
        // Progressive MPEG-TS fallback.
        add('$base/timeshift/$user/$pass/$minutes/$enc/$streamId.$ext');
      }
    }
    return urls;
  }

  /// Live stream URL for an Xtream channel (`/live/user/pass/{id}.ts`).
  static String liveStreamUrl({
    required IptvSource source,
    required String streamId,
    String extension = 'ts',
  }) {
    final base = source.serverUrl!.replaceAll(RegExp(r'/+$'), '');
    final user = source.username ?? '';
    final pass = source.password ?? '';
    final ext = extension.replaceAll('.', '');
    return '$base/live/$user/$pass/$streamId.$ext';
  }

  /// Convert a timeshift/catchup URL back to the live stream URL.
  ///
  /// Supports panel forms:
  /// - `/streaming/timeshift.php?username&password&stream&start&duration`
  /// - `/timeshift/user/pass/{minutes}/{stamp}/{streamId}.ts`
  /// - `/timeshift/user/pass/{minutes}/{stamp}/{streamId}.m3u8`
  static String? liveUrlFromTimeshift(String timeshiftUrl) {
    final uri = Uri.tryParse(timeshiftUrl);
    if (uri == null) return null;

    final segments = uri.pathSegments;
    final phpIdx = segments.indexWhere(
      (s) => s.toLowerCase() == 'timeshift.php',
    );
    if (phpIdx >= 0) {
      final user = uri.queryParameters['username'];
      final pass = uri.queryParameters['password'];
      final stream = uri.queryParameters['stream']?.trim();
      if (stream == null || stream.isEmpty) {
        return null;
      }
      // Drop trailing `streaming` + `timeshift.php` (or just the php file).
      var cutIdx = phpIdx;
      if (cutIdx > 0 && segments[cutIdx - 1].toLowerCase() == 'streaming') {
        cutIdx -= 1;
      }
      final liveParts = [
        ...segments.take(cutIdx),
        'live',
        if (user != null && pass != null) ...[user, pass],
        '$stream.ts',
      ];
      return Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        pathSegments: liveParts,
      ).toString();
    }

    final idx = segments.indexOf('timeshift');
    if (idx < 0) return null;
    late final String file;
    String? user;
    String? pass;
    if (segments.length > idx + 5 && segments[idx + 5].contains('.')) {
      user = segments[idx + 1];
      pass = segments[idx + 2];
      file = segments[idx + 5];
    } else if (segments.length > idx + 3 && segments[idx + 3].contains('.')) {
      file = segments[idx + 3];
    } else {
      return null;
    }
    final streamId = file.split('.').first;
    if (streamId.isEmpty) return null;
    final ext = file.contains('.') ? file.split('.').last : 'ts';
    final liveParts = [
      ...segments.take(idx),
      'live',
      if (user != null && pass != null) ...[user, pass],
      '$streamId.$ext',
    ];
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      pathSegments: liveParts,
    ).toString();
  }

  DateTime? _parseEpgTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) {
      final value = raw.toInt();
      // Heuristic: seconds vs milliseconds.
      if (value > 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
      }
      return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
    }
    final text = '$raw'.trim();
    if (text.isEmpty) return null;
    final asInt = int.tryParse(text);
    if (asInt != null) return _parseEpgTime(asInt);
    // "2026-08-03 21:00:00" (server local / UTC depending on panel)
    final normalized = text.contains('T') ? text : text.replaceFirst(' ', 'T');
    return DateTime.tryParse('${normalized}Z') ?? DateTime.tryParse(normalized);
  }

  String _decodeXtreamText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return trimmed;
    try {
      return utf8.decode(base64.decode(trimmed)).trim();
    } catch (_) {
      return trimmed;
    }
  }

  String? _firstNonEmptyString(Iterable<dynamic> values) {
    for (final value in values) {
      if (value == null) continue;
      final text = '$value'.trim();
      if (text.isNotEmpty && text.toLowerCase() != 'null') return text;
    }
    return null;
  }

  static bool _truthy(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = '$value'.trim().toLowerCase();
    return text == '1' || text == 'true' || text == 'yes';
  }

  void close() => _http.close();
}

@pragma('vm:entry-point')
Future<String> _xtreamStreamBodySha1(String url) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', Uri.parse(url));
    final streamed = await client.send(request);
    if (streamed.statusCode >= 400) {
      unawaited(
        streamed.stream.drain<void>().then<void>((_) {}, onError: (_) {}),
      );
      throw Exception('Xtream dump failed (${streamed.statusCode})');
    }
    final out = _XtreamBodyDigestSink();
    final input = sha1.startChunkedConversion(out);
    await for (final chunk in streamed.stream) {
      input.add(chunk);
    }
    input.close();
    final digest = out.value;
    if (digest == null) {
      throw StateError('xtream body sha1 missing digest');
    }
    return 'body:$digest';
  } finally {
    client.close();
  }
}

class _XtreamBodyDigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

@pragma('vm:entry-point')
void _decodeListMapsIsolateMain(SendPort reply) {
  unawaited(_decodeListMapsIsolateBody(reply));
}

Future<void> _decodeListMapsIsolateBody(SendPort reply) async {
  final inbound = ReceivePort();
  reply.send(inbound.sendPort);
  final buffer = BytesBuilder(copy: false);
  Map<String, dynamic> header = const {};
  final bytesDone = Completer<void>();
  Completer<Object?>? pendingAck;
  final earlyAcks = <Object?>[];
  inbound.listen((message) {
    if (!bytesDone.isCompleted) {
      if (message == null) {
        bytesDone.complete();
        return;
      }
      if (message is Map) {
        header = Map<String, dynamic>.from(message);
        final fetchUrl = header['fetchUrl'];
        if (fetchUrl is String && fetchUrl.isNotEmpty) {
          bytesDone.complete();
        }
        return;
      }
      if (message is List<int>) buffer.add(message);
      return;
    }
    final waiter = pendingAck;
    if (waiter != null && !waiter.isCompleted) {
      pendingAck = null;
      waiter.complete(message);
    } else {
      earlyAcks.add(message);
    }
  });
  Future<bool> waitGo() async {
    final Object? message;
    if (earlyAcks.isNotEmpty) {
      message = earlyAcks.removeAt(0);
    } else {
      final c = Completer<Object?>();
      pendingAck = c;
      message = await c.future;
    }
    if (message is Map) {
      final sink = message['sqlSink'];
      if (sink is SendPort) {
        header['sqlSink'] = sink;
      }
      return message['go'] == true;
    }
    return message == true;
  }

  try {
    await bytesDone.future;
    final fetchUrl = header['fetchUrl'];
    if (fetchUrl is String && fetchUrl.isNotEmpty) {
      final response = await http.get(Uri.parse(fetchUrl));
      if (response.statusCode >= 400) {
        throw Exception('Xtream dump failed (${response.statusCode})');
      }
      buffer.add(response.bodyBytes);
    }
    final bodyBytes = buffer.takeBytes();
    final kindName = '${header['kind'] ?? ''}';
    final kind = IptvCategoryKind.values.asNameMap()[kindName];
    // Plain list decode (getCategories / _getList) has no fingerprint UI —
    // do not send body meta / waitGo or Synchroniser deadlocks on
    // "Synchronisation des catégories live…".
    if (kind == null) {
      final maps = XtreamClient._mapsFromDecodedList(
        jsonDecode(utf8.decode(bodyBytes)),
      );
      const chunk = XtreamClient._jsonListChunkSize;
      for (var i = 0; i < maps.length; i += chunk) {
        final end = (i + chunk > maps.length) ? maps.length : i + chunk;
        reply.send(List<Map<String, dynamic>>.from(maps.getRange(i, end)));
      }
      return;
    }

    // Body hash BEFORE jsonDecode — UI can cancel an unchanged dump without
    // allocating ~100k maps (that GC freezes Windows input while timers still
    // fire and status text keeps updating).
    final bodyDigest = sha1.convert(bodyBytes).toString();
    final bodyFp = 'body:$bodyDigest';
    reply.send({
      't': 'meta',
      'phase': 'body',
      'fp': bodyFp,
      'bodyFp': bodyFp,
      'n': -1,
    });
    if (!await waitGo()) return;

    final maps = XtreamClient._mapsFromDecodedList(
      jsonDecode(utf8.decode(bodyBytes)),
    );
    const chunk = XtreamClient._jsonListChunkSize;
    final idKey = kind == IptvCategoryKind.series ? 'series_id' : 'stream_id';
    final ids = <String>[
      for (final m in maps)
        if ('${m[idKey] ?? ''}'.trim().isNotEmpty) '${m[idKey]}'.trim(),
    ]..sort();
    final idsFp = sha1.convert(utf8.encode(ids.join('\n'))).toString();
    // Ids meta: stable across panel key/row reorder; used when body changed.
    reply.send({
      't': 'meta',
      'phase': 'ids',
      'fp': 'ids:$idsFp',
      'bodyFp': bodyFp,
      'n': maps.length,
    });
    // Fingerprint-only probe: free maps immediately.
    if (header['metaOnly'] == true) {
      maps.clear();
      return;
    }
    if (!await waitGo()) return;

    final source = IptvSource(
      id: '${header['sourceId'] ?? ''}',
      name: 'xtream',
      type: IptvSourceType.xtream,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      serverUrl: '${header['serverUrl'] ?? ''}',
    );
    final rawNames = header['names'];
    final names = <String, String>{
      if (rawNames is Map)
        for (final e in rawNames.entries) '${e.key}': '${e.value}',
    };
    final adult = <String>{
      for (final id in (header['adult'] is List ? header['adult'] as List : []))
        '$id',
    };
    final sqlOnly = header['sqlOnly'] == true;
    final sink = header['sqlSink'];

    /// Off-UI SQLite writer — maps never touch the UI isolate (Windows HWND).
    Future<void> flushBatchToSink(
      SendPort dest,
      List<Map<String, Object?>> batch,
    ) async {
      if (batch.isEmpty) return;
      final ack = ReceivePort();
      dest.send({
        't': 'sql',
        'v': List<Map<String, Object?>>.from(batch),
        'ack': ack.sendPort,
      });
      batch.clear();
      await ack.first;
      ack.close();
    }

    // sqlOnly + sink: pack→flush in 400-row waves. Building a 150k+ map list
    // first causes isolate-group GC pauses that freeze the Windows HWND even
    // though SQL never lands on the UI isolate.
    if (sqlOnly && sink is SendPort) {
      final batch = <Map<String, Object?>>[];
      for (var i = 0; i < maps.length; i++) {
        final raw = maps[i];
        // Drop the decoded JSON row ASAP — doubles peak RAM otherwise.
        maps[i] = const <String, dynamic>{};
        XtreamClient._packDecodedRow(
          source,
          raw,
          kind: kind,
          categoryNames: names,
          adultIds: adult,
          sql: batch,
          variants: null,
        );
        if (batch.length >= chunk) {
          await flushBatchToSink(sink, batch);
        }
        // Let the writer + GC breathe; tight pack loops starve the UI isolate
        // group on fat panels.
        if ((i & 1023) == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      await flushBatchToSink(sink, batch);
      maps.clear();
      return;
    }

    final sql = <Map<String, Object?>>[];
    final variants = <Map<String, Object?>>[];
    for (var i = 0; i < maps.length; i++) {
      XtreamClient._packDecodedRow(
        source,
        maps[i],
        kind: kind,
        categoryNames: names,
        adultIds: adult,
        sql: sql,
        variants: sqlOnly ? null : variants,
      );
    }
    maps.clear();
    Map<String, List<String>> families = const {};
    Map<String, String> canonical = const {};
    if (!sqlOnly && kind != IptvCategoryKind.live && variants.isNotEmpty) {
      final packed = VodVariantIndex.buildPacked(variants);
      variants.clear();
      final rawFamilies = packed['families'] as Map? ?? const {};
      final rawCanonical = packed['canonical'] as Map? ?? const {};
      families = {
        for (final e in rawFamilies.entries)
          '${e.key}': [for (final id in (e.value as List)) '$id'],
      };
      canonical = {
        for (final e in rawCanonical.entries) '${e.key}': '${e.value}',
      };
    }

    Future<bool> sendRowChunks(
      String type,
      List<Map<String, Object?>> rows,
    ) async {
      for (var i = 0; i < rows.length; i += chunk) {
        final end = i + chunk > rows.length ? rows.length : i + chunk;
        reply.send({
          't': type,
          'v': List<Map<String, Object?>>.from(rows.getRange(i, end)),
        });
        if (!await waitGo()) return false;
      }
      return true;
    }

    if (kind == IptvCategoryKind.live && header['livePlan'] == true) {
      final rawEpg = header['epgNames'];
      final epgNames = <String, String>{
        if (rawEpg is Map)
          for (final e in rawEpg.entries) '${e.key}': '${e.value}',
      };
      final rawPref = header['preferred'];
      final preferred = <String, String>{
        if (rawPref is Map)
          for (final e in rawPref.entries) '${e.key}': '${e.value}',
      };
      final plan = buildLiveIngestPlan(
        sourceId: source.id,
        channels: sql,
        epgDisplayNames: epgNames,
        preferredLiveQualities: preferred,
      );
      reply.send({'t': 'idx', 'v': plan.indexFingerprint});
      if (!await waitGo()) return;
      if (!await sendRowChunks('sql', sql)) return;
      if (!await sendRowChunks('lst', plan.listingRows)) return;
      if (!await sendRowChunks('lvar', plan.variantRows)) return;
      return;
    }

    if (sqlOnly) {
      await sendRowChunks('sql', sql);
      return;
    }

    Future<bool> sendMapChunks(
      String type,
      Map<String, Object?> entries,
    ) async {
      final keys = entries.keys.toList(growable: false);
      for (var i = 0; i < keys.length; i += chunk) {
        final end = i + chunk > keys.length ? keys.length : i + chunk;
        reply.send({
          't': type,
          'v': [
            for (var j = i; j < end; j++) [keys[j], entries[keys[j]]],
          ],
        });
        if (!await waitGo()) return false;
      }
      return true;
    }

    if (families.isNotEmpty) {
      if (!await sendMapChunks('fam', {
        for (final e in families.entries) e.key: e.value,
      })) {
        return;
      }
    }
    if (canonical.isNotEmpty) {
      if (!await sendMapChunks('can', {
        for (final e in canonical.entries) e.key: e.value,
      })) {
        return;
      }
    }
    await sendRowChunks('sql', sql);
  } finally {
    inbound.close();
    reply.send(null);
  }
}

/// One Xtream list dump paused after the worker fingerprint so the UI isolate
/// can skip copying SQL maps when the catalog has not changed.
class _XtreamPackedJob {
  _XtreamPackedJob._({
    required this.fingerprint,
    required this.sqlCount,
    required this.bodyFingerprint,
    required bool idsReady,
    required SendPort? workerPort,
    required StreamIterator<dynamic>? iter,
    required ReceivePort? receive,
    required ReceivePort? errors,
    required Isolate? worker,
    required StreamSubscription<dynamic>? errorSub,
    required List<Map<String, Object?>>? webSql,
    required this._webFamilies,
    required this._webCanonical,
    required Object? Function() isolateError,
  }) : _idsReady = idsReady,
       _workerPort = workerPort,
       _iter = iter,
       _receive = receive,
       _errors = errors,
       _worker = worker,
       _errorSub = errorSub,
       _webSql = webSql,
       _isolateError = isolateError;

  String fingerprint;
  int sqlCount;
  String bodyFingerprint;
  String indexFingerprint = '';
  final Map<String, List<String>> families = {};
  final Map<String, String> canonical = {};

  final SendPort? _workerPort;
  final StreamIterator<dynamic>? _iter;
  final ReceivePort? _receive;
  final ReceivePort? _errors;
  final Isolate? _worker;
  final StreamSubscription<dynamic>? _errorSub;
  final List<Map<String, Object?>>? _webSql;
  final Map<String, List<String>> _webFamilies;
  final Map<String, String> _webCanonical;
  final Object? Function() _isolateError;
  var _idsReady = false;
  var _closed = false;

  static Future<_XtreamPackedJob> start(
    XtreamClient client,
    IptvSource source, {
    required IptvCategoryKind kind,
    required Map<String, String> categoryNames,
    required Set<String> adultIds,
    bool livePlan = false,
    bool sqlOnly = false,
    /// Download + id fingerprint, then exit (no pack / no waitGo).
    bool metaOnly = false,
    Map<String, String> epgDisplayNames = const {},
    Map<String, String> preferredLiveQualities = const {},
  }) async {
    final action = switch (kind) {
      IptvCategoryKind.live => 'get_live_streams',
      IptvCategoryKind.vod => 'get_vod_streams',
      IptvCategoryKind.series => 'get_series',
    };
    final uri = client._playerApi(
      XtreamClient._normalizeBase(source.serverUrl!),
      username: source.username!,
      password: source.password!,
      query: {'action': action},
    );
    if (kIsWeb) {
      final response = await client._http.get(uri);
      if (response.statusCode >= 400) {
        throw Exception('Xtream $action failed (${response.statusCode})');
      }
      final bodyFp = 'body:${sha1.convert(utf8.encode(response.body))}';
      final rows = XtreamClient._mapsFromDecodedList(jsonDecode(response.body));
      final packed = await XtreamClient._packRowsOnThisIsolate(
        source,
        rows,
        kind: kind,
        categoryNames: categoryNames,
        adultIds: adultIds,
      );
      final fp = kind == IptvCategoryKind.live
          ? liveContentFingerprint(packed.sql)
          : VodCatalogDb.vodContentFingerprint(packed.sql);
      var families = <String, List<String>>{};
      var canonical = <String, String>{};
      if (kind != IptvCategoryKind.live && packed.variants.isNotEmpty) {
        final built = VodVariantIndex.buildPacked(packed.variants);
        final rawFamilies = built['families'] as Map? ?? const {};
        final rawCanonical = built['canonical'] as Map? ?? const {};
        families = {
          for (final e in rawFamilies.entries)
            '${e.key}': [for (final id in (e.value as List)) '$id'],
        };
        canonical = {
          for (final e in rawCanonical.entries) '${e.key}': '${e.value}',
        };
      }
      return _XtreamPackedJob._(
        fingerprint: fp,
        sqlCount: packed.sql.length,
        bodyFingerprint: bodyFp,
        idsReady: true,
        workerPort: null,
        iter: null,
        receive: null,
        errors: null,
        worker: null,
        errorSub: null,
        webSql: packed.sql,
        webFamilies: families,
        webCanonical: canonical,
        isolateError: () => null,
      );
    }

    final receive = ReceivePort();
    final errors = ReceivePort();
    late final Isolate worker;
    try {
      worker = await Isolate.spawn(
        _decodeListMapsIsolateMain,
        receive.sendPort,
        onError: errors.sendPort,
        errorsAreFatal: true,
      );
    } catch (_) {
      receive.close();
      errors.close();
      rethrow;
    }
    Object? isolateError;
    final errorSub = errors.listen((msg) {
      isolateError ??= msg;
    });
    final iter = StreamIterator(receive);
    try {
      if (!await iter.moveNext()) {
        throw StateError('xtream json isolate exited before handshake');
      }
      if (isolateError != null) throw isolateError!;
      final workerPort = iter.current as SendPort;
      // Fat list dumps must fetch inside the worker. Production always injects
      // an HTTP client (proxy/DNS), which used to force every byte through the
      // UI isolate via [_forwardBytesToJsonWorker] — that is "Récupération du
      // catalogue VOD" HWND death on Windows. Auth / categories still use the
      // injected client; only these multi‑MB panels go direct on the worker.
      final workerFetchesDump = !kIsWeb;
      workerPort.send(<String, Object?>{
        'kind': kind.name,
        'sourceId': source.id,
        'serverUrl': XtreamClient._normalizeBase(source.serverUrl!),
        'names': categoryNames,
        'adult': adultIds.toList(growable: false),
        if (workerFetchesDump || !client._httpInjected) 'fetchUrl': uri.toString(),
        if (livePlan) 'livePlan': true,
        if (sqlOnly) 'sqlOnly': true,
        if (metaOnly) 'metaOnly': true,
        if (livePlan) 'epgNames': epgDisplayNames,
        if (livePlan) 'preferred': preferredLiveQualities,
      });
      if (!workerFetchesDump && client._httpInjected) {
        final request = http.Request('GET', uri);
        final streamed = await client._http.send(request);
        if (streamed.statusCode >= 400) {
          unawaited(
            streamed.stream.drain<void>().then<void>((_) {}, onError: (_) {}),
          );
          throw Exception('Xtream $action failed (${streamed.statusCode})');
        }
        await XtreamClient._forwardBytesToJsonWorker(
          workerPort,
          streamed.stream,
        );
      }

      // Worker HTTP + body hash (no jsonDecode yet). Heartbeat keeps HWND alive.
      final hwnd = HwndSyncTrace.of(source.id);
      final metaWait = Stopwatch()..start();
      var heartbeats = 0;
      final hb = Timer.periodic(const Duration(milliseconds: 250), (_) {
        heartbeats++;
        if (heartbeats == 1 || heartbeats % 8 == 0) {
          hwnd?.mark(
            'job-meta-wait',
            'kind=${kind.name} phase=body '
                'waited=${metaWait.elapsedMilliseconds}ms hb=$heartbeats',
          );
        }
        unawaited(pumpUi(label: 'job-meta-wait'));
      });
      final bool gotMeta;
      try {
        gotMeta = await iter.moveNext();
      } finally {
        hb.cancel();
      }
      if (!gotMeta) {
        throw StateError('xtream json isolate exited before body fingerprint');
      }
      if (isolateError != null) throw isolateError!;
      final meta = iter.current;
      if (meta is! Map || '${meta['t'] ?? ''}' != 'meta') {
        throw StateError('xtream json isolate missing body fingerprint meta');
      }
      final bodyFp = '${meta['bodyFp'] ?? meta['fp'] ?? '0'}';
      hwnd?.mark(
        'job-body-meta',
        'kind=${kind.name} waited=${metaWait.elapsedMilliseconds}ms',
      );
      return _XtreamPackedJob._(
        fingerprint: bodyFp,
        sqlCount: 0,
        bodyFingerprint: bodyFp,
        idsReady: false,
        workerPort: workerPort,
        iter: iter,
        receive: receive,
        errors: errors,
        worker: worker,
        errorSub: errorSub,
        webSql: null,
        webFamilies: const {},
        webCanonical: const {},
        isolateError: () => isolateError,
      );
    } catch (e) {
      await errorSub.cancel();
      await iter.cancel();
      receive.close();
      errors.close();
      worker.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  /// Resume past body hash so the worker jsonDecodes and sends ids meta.
  Future<void> advanceToIdsMeta({HwndSyncTrace? hwnd}) async {
    if (_closed || _idsReady) return;
    if (_webSql != null) {
      _idsReady = true;
      return;
    }
    final kindHint = fingerprint;
    _workerPort!.send(true);
    final iter = _iter!;
    final metaWait = Stopwatch()..start();
    var heartbeats = 0;
    final hb = Timer.periodic(const Duration(milliseconds: 250), (_) {
      heartbeats++;
      if (heartbeats == 1 || heartbeats % 8 == 0) {
        hwnd?.mark(
          'job-meta-wait',
          'phase=ids waited=${metaWait.elapsedMilliseconds}ms '
              'hb=$heartbeats body=$kindHint',
        );
      }
      unawaited(pumpUi(label: 'job-ids-meta-wait'));
    });
    final bool gotMeta;
    try {
      gotMeta = await iter.moveNext();
    } finally {
      hb.cancel();
    }
    if (!gotMeta) {
      throw StateError('xtream json isolate exited before ids fingerprint');
    }
    final err = _isolateError();
    if (err != null) throw err;
    final meta = iter.current;
    if (meta is! Map || '${meta['t'] ?? ''}' != 'meta') {
      throw StateError('xtream json isolate missing ids fingerprint meta');
    }
    fingerprint = '${meta['fp'] ?? '0'}';
    sqlCount = (meta['n'] as num?)?.toInt() ?? 0;
    final bf = '${meta['bodyFp'] ?? ''}';
    if (bf.isNotEmpty) bodyFingerprint = bf;
    _idsReady = true;
    hwnd?.mark(
      'job-meta',
      'n=$sqlCount waited=${metaWait.elapsedMilliseconds}ms',
    );
  }

  Future<void> drain({
    required Future<void> Function(List<Map<String, Object?>> chunk) onSqlChunk,
    Future<void> Function(List<Map<String, Object?>> chunk)? onListingChunk,
    Future<void> Function(List<Map<String, Object?>> chunk)? onVariantChunk,
    HwndSyncTrace? hwnd,
    SendPort? sqlSink,
  }) async {
    if (_closed) return;
    if (!_idsReady) await advanceToIdsMeta(hwnd: hwnd);
    final webSql = _webSql;
    if (webSql != null) {
      families.addAll(_webFamilies);
      canonical.addAll(_webCanonical);
      const chunk = XtreamClient._jsonListChunkSize;
      for (var i = 0; i < webSql.length; i += chunk) {
        final end = i + chunk > webSql.length ? webSql.length : i + chunk;
        final slice = webSql.sublist(i, end);
        final writeSw = Stopwatch()..start();
        await onSqlChunk(slice);
        final writeMs = writeSw.elapsedMilliseconds;
        final pumpSw = Stopwatch()..start();
        await pumpUi(label: 'xtream-web-sql');
        hwnd?.noteSqlChunk(
          rows: slice.length,
          decodeMs: 0,
          writeMs: writeMs,
          pumpMs: pumpSw.elapsedMilliseconds,
        );
      }
      await _close();
      return;
    }
    // Off-UI writer: go message carries the sink; this isolate only waits for
    // the worker to finish (null). No SQL maps land here — but we must still
    // pumpUi or Windows stops delivering title-bar / click messages.
    if (sqlSink != null) {
      _workerPort!.send(<String, Object?>{'go': true, 'sqlSink': sqlSink});
      final iter = _iter!;
      final hb = Timer.periodic(const Duration(milliseconds: 50), (_) {
        unawaited(pumpUi(label: 'sql-sink-drain'));
      });
      try {
        while (await iter.moveNext()) {
          final err = _isolateError();
          if (err != null) throw err;
          if (iter.current == null) break;
        }
      } finally {
        hb.cancel();
      }
      hwnd?.mark('sql-sink-drain-done', 'n=$sqlCount');
      await _close();
      return;
    }
    _workerPort!.send(true);
    final iter = _iter!;
    while (await iter.moveNext()) {
      final err = _isolateError();
      if (err != null) throw err;
      final message = iter.current;
      if (message == null) break;
      if (message is! Map) {
        _workerPort!.send(true);
        continue;
      }
      final type = '${message['t'] ?? ''}';
      final raw = message['v'];
      if (type == 'fam' && raw is List) {
        for (final entry in raw) {
          if (entry is List && entry.length >= 2) {
            families['${entry[0]}'] = [
              for (final id in (entry[1] as List? ?? const [])) '$id',
            ];
          }
        }
      } else if (type == 'can' && raw is List) {
        for (final entry in raw) {
          if (entry is List && entry.length >= 2) {
            canonical['${entry[0]}'] = '${entry[1]}';
          }
        }
      } else if (type == 'idx') {
        indexFingerprint = '$raw';
      } else if (type == 'sql' && raw is List) {
        final decodeSw = Stopwatch()..start();
        final chunk = <Map<String, Object?>>[];
        for (final entry in raw) {
          if (entry is Map<String, Object?>) {
            chunk.add(entry);
          } else if (entry is Map) {
            chunk.add(Map<String, Object?>.from(entry));
          }
        }
        final decodeMs = decodeSw.elapsedMilliseconds;
        var writeMs = 0;
        if (chunk.isNotEmpty) {
          final writeSw = Stopwatch()..start();
          await onSqlChunk(chunk);
          writeMs = writeSw.elapsedMilliseconds;
        }
        final pumpSw = Stopwatch()..start();
        await pumpUi(label: 'xtream-sql-chunk');
        hwnd?.noteSqlChunk(
          rows: chunk.length,
          decodeMs: decodeMs,
          writeMs: writeMs,
          pumpMs: pumpSw.elapsedMilliseconds,
        );
        _workerPort!.send(true);
        continue;
      } else if (type == 'lst' && raw is List) {
        final chunk = <Map<String, Object?>>[];
        for (final entry in raw) {
          if (entry is Map<String, Object?>) {
            chunk.add(entry);
          } else if (entry is Map) {
            chunk.add(Map<String, Object?>.from(entry));
          }
        }
        if (chunk.isNotEmpty) await onListingChunk?.call(chunk);
      } else if (type == 'lvar' && raw is List) {
        final chunk = <Map<String, Object?>>[];
        for (final entry in raw) {
          if (entry is Map<String, Object?>) {
            chunk.add(entry);
          } else if (entry is Map) {
            chunk.add(Map<String, Object?>.from(entry));
          }
        }
        if (chunk.isNotEmpty) await onVariantChunk?.call(chunk);
      }
      await pumpUi(label: 'xtream-drain');
      // Backpressure: worker waits for this before the next chunk so the
      // ReceivePort cannot flood the UI isolate with 20k+ maps.
      _workerPort!.send(true);
    }
    await _close();
  }

  Future<void> cancel() async {
    if (_closed) return;
    if (_webSql != null) {
      await _close();
      return;
    }
    _workerPort?.send(false);
    final iter = _iter;
    if (iter != null) {
      while (await iter.moveNext()) {
        if (iter.current == null) break;
      }
    }
    await _close();
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await _errorSub?.cancel();
    await _iter?.cancel();
    _receive?.close();
    _errors?.close();
    _worker?.kill(priority: Isolate.immediate);
  }
}

class XtreamVodInfo {
  const XtreamVodInfo({
    this.tmdbId,
    this.plot,
    this.genres = const [],
    this.year,
    this.rating,
    this.posterUrl,
    this.backdropUrl,
    this.trailerKey,
    this.runtime,
    this.cast = const [],
    this.name,
  });

  final int? tmdbId;
  final String? plot;
  final List<String> genres;
  final int? year;
  final double? rating;
  final String? posterUrl;
  final String? backdropUrl;
  final String? trailerKey;
  final Duration? runtime;
  final List<CastMember> cast;
  final String? name;
}
