import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/sync_worker/sync_protocol.dart';
import 'package:javp/sync_worker/sync_scheduler.dart';

IptvSource _xtream() => IptvSource(
      id: 'src-1',
      name: 'IPTV',
      type: IptvSourceType.xtream,
      createdAt: DateTime.utc(2024, 1, 1),
      serverUrl: 'http://example.test:8080',
      username: 'u',
      password: 'p',
    );

void main() {
  group('SyncJob / SyncEvent protocol', () {
    test('round-trips xtreamVod job JSON', () {
      final job = SyncJob(
        op: SyncOp.xtreamVod,
        reason: SyncReason.manual,
        profileId: 'default',
        source: _xtream(),
      );
      final again = SyncJob.fromJson(job.toJson());
      expect(again.op, SyncOp.xtreamVod);
      expect(again.reason, SyncReason.manual);
      expect(again.profileId, 'default');
      expect(again.source.id, 'src-1');
      expect(again.source.password, 'p');
    });

    test('round-trips xtreamLive job with categories', () {
      final job = SyncJob(
        op: SyncOp.xtreamLive,
        reason: SyncReason.soft,
        profileId: 'p1',
        source: _xtream(),
        epgDisplayNames: const {'1': 'News'},
        preferredLiveQualities: const {'fam': 'HD'},
        liveCategories: [
          IptvCategory(
            id: '10',
            name: 'Sports',
            kind: IptvCategoryKind.live,
            sourceId: 'src-1',
          ),
        ],
      );
      final again = SyncJob.fromJson(job.toJson());
      expect(again.op, SyncOp.xtreamLive);
      expect(again.liveCategories, hasLength(1));
      expect(again.liveCategories.first.name, 'Sports');
      expect(again.epgDisplayNames['1'], 'News');
      expect(again.preferredLiveQualities['fam'], 'HD');
    });

    test('progress and done events round-trip', () {
      final progress = SyncEvent.progress(
        phase: 'vod',
        status: 'saving',
        committed: 40,
        total: 100,
      );
      final p2 = SyncEvent.fromJson(progress.toJson());
      expect(p2.type, 'progress');
      expect(p2.committed, 40);
      expect(p2.total, 100);

      final done = SyncEvent.done(
        skipped: true,
        sqlCount: 200,
        fingerprint: 'abc',
        written: false,
      );
      final d2 = SyncEvent.fromJson(done.toJson());
      expect(d2.skipped, isTrue);
      expect(d2.sqlCount, 200);
      expect(d2.fingerprint, 'abc');
    });
  });

  group('SyncScheduler', () {
    setUp(SyncScheduler.instance.debugReset);
    tearDown(SyncScheduler.instance.debugReset);

    test('runs jobs serially', () async {
      final order = <int>[];
      final a = SyncScheduler.instance.enqueue(() async {
        order.add(1);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        order.add(2);
        return 'a';
      }, label: 'a');
      final b = SyncScheduler.instance.enqueue(() async {
        order.add(3);
        return 'b';
      }, label: 'b');
      expect(SyncScheduler.instance.isBusy, isTrue);
      expect(await a, 'a');
      expect(await b, 'b');
      expect(order, [1, 2, 3]);
      expect(SyncScheduler.instance.isBusy, isFalse);
    });

    test('failed job does not block the next', () async {
      final first = SyncScheduler.instance.enqueue(() async {
        throw StateError('boom');
      }, label: 'fail');
      final second = SyncScheduler.instance.enqueue(() async => 42, label: 'ok');
      await expectLater(first, throwsStateError);
      expect(await second, 42);
      expect(SyncScheduler.instance.isBusy, isFalse);
    });
  });
}
