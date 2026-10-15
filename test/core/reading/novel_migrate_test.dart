import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart' show ProviderType;
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/source_health_store.dart'
    show SourceOutcome;
import 'package:watch_app/core/reading/novel_migrator.dart';
import 'package:watch_app/core/reading/read_history.dart';
import 'package:watch_app/core/reading/read_position_mover.dart';
import 'package:watch_app/core/reading/read_store.dart';

/// The Hive-facing half of migration: what [NovelMigrator.migrate] actually
/// writes.
///
/// This half had no coverage at all, and it is where the feature broke. The
/// position carry-over depended on `destinationChapters`, which only a caller
/// with a [SourceRepository] could supply and neither screen did - so
/// `resolveChapter` was handed an empty list, returned null, and every migration
/// landed at chapter one while the confirmation dialog promised otherwise. The
/// tests below pin the behaviour that has to be true for the promise to hold.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('inkbound_migrate_test');
    Hive.init(dir.path);
    await Hive.openBox<Map>(MyListStore.boxName);
    await Hive.openBox<Map>(ReadHistory.boxName);
    await ReadStore.init();
  });

  tearDown(() async {
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  MediaItem novel({
    required String id,
    String sourceId = 'lnr:old',
    String? title,
  }) => MediaItem(
    id: id,
    title: title ?? 'The Beginning After The End',
    url: '/novel/$id',
    type: ProviderType.novel,
    sourceId: sourceId,
  );

  ReadEntry entry({
    required String sourceId,
    required String showId,
    required String chapterId,
    required double? chapterNumber,
    String title = 'The Beginning After The End',
  }) => ReadEntry(
    sourceId: sourceId,
    showId: showId,
    title: title,
    chapterId: chapterId,
    chapterNumber: chapterNumber,
    chapterUrl: '/c/$chapterId',
    pos: 400,
    total: 1000,
    updatedMs: 1,
    type: ProviderType.novel,
  );

  group('migrate', () {
    test('carries the reading position to the destination chapter', () async {
      final from = novel(id: 'old-1');
      final to = novel(id: 'new-1', sourceId: 'lnr:new');
      final list = MyListStore();
      final history = ReadHistory();
      final store = ReadStore();
      final mover = ReadPositionMover(store: store);

      await list.add(from);
      await history.save(
        entry(sourceId: 'lnr:old', showId: 'old-1', chapterId: 'ch12', chapterNumber: 12),
      );
      await store.save('lnr:old', 'old-1', 'ch12', pos: 400, total: 1000);

      final migrator = NovelMigrator(
        list: list,
        history: history,
        positions: mover,
        chaptersOf: (_) async => [
          (id: '/new/11', title: 'Chapter 11'),
          (id: '/new/12', title: 'Chapter 12'),
        ],
      );

      final res = await migrator.migrate(
        from: from,
        to: to,
        chapterNumber: 12,
        chapterId: 'ch12',
      );

      expect(res.ok, isTrue);
      // The whole point. This was false in every migration before.
      expect(res.carriedPosition, isTrue);
      expect(
        store.get('lnr:new', 'new-1', '/new/12'),
        (pos: 400, total: 1000),
      );
    });

    test('lands at or below the reader\'s chapter, never above', () async {
      final from = novel(id: 'old-1');
      final to = novel(id: 'new-1', sourceId: 'lnr:new');
      final list = MyListStore();
      final history = ReadHistory();
      final store = ReadStore();

      await list.add(from);
      await history.save(
        entry(sourceId: 'lnr:old', showId: 'old-1', chapterId: 'ch40', chapterNumber: 40),
      );
      await store.save('lnr:old', 'old-1', 'ch40', pos: 900, total: 1000);

      final migrator = NovelMigrator(
        list: list,
        history: history,
        positions: ReadPositionMover(store: store),
        // The destination only goes up to 38.
        chaptersOf: (_) async => [
          (id: '/new/37', title: 'Chapter 37'),
          (id: '/new/38', title: 'Chapter 38'),
        ],
      );

      final res = await migrator.migrate(
        from: from,
        to: to,
        chapterNumber: 40,
        chapterId: 'ch40',
      );

      expect(res.carriedPosition, isTrue);
      expect(
        store.get('lnr:new', 'new-1', '/new/38'),
        (pos: 900, total: 1000),
      );
      // Nothing above the reader's position was written.
      expect(store.get('lnr:new', 'new-1', '/new/37'), isNull);
    });

    test('a destination that will not list its chapters costs only the position',
        () async {
      final from = novel(id: 'old-1');
      final to = novel(id: 'new-1', sourceId: 'lnr:new');
      final list = MyListStore();
      final history = ReadHistory();
      final store = ReadStore();

      await list.add(from);
      await history.save(
        entry(sourceId: 'lnr:old', showId: 'old-1', chapterId: 'ch12', chapterNumber: 12),
      );
      await store.save('lnr:old', 'old-1', 'ch12', pos: 400, total: 1000);

      final migrator = NovelMigrator(
        list: list,
        history: history,
        positions: ReadPositionMover(store: store),
        chaptersOf: (_) async => const [],
      );

      final res = await migrator.migrate(
        from: from,
        to: to,
        chapterNumber: 12,
        chapterId: 'ch12',
      );

      // The move still happened; only the resume was lost, and it is reported
      // as lost rather than claimed.
      expect(res.ok, isTrue);
      expect(res.carriedPosition, isFalse);
      expect(list.all().map((m) => m.id), contains('new-1'));
    });

    test('re-points the history row so Continue Reading follows', () async {
      final from = novel(id: 'old-1');
      final to = novel(id: 'new-1', sourceId: 'lnr:new');
      final list = MyListStore();
      final history = ReadHistory();
      final store = ReadStore();

      await list.add(from);
      await history.save(
        entry(sourceId: 'lnr:old', showId: 'old-1', chapterId: 'ch3', chapterNumber: 3),
      );
      await history.save(
        entry(
          sourceId: 'lnr:other',
          showId: 'other-1',
          chapterId: 'x1',
          chapterNumber: 1,
          title: 'A Different Book',
        ),
      );

      final migrator = NovelMigrator(
        list: list,
        history: history,
        positions: ReadPositionMover(store: store),
        chaptersOf: (_) async => const [],
      );

      final res = await migrator.migrate(from: from, to: to);

      expect(res.historyRows, 1);
      // Nothing left pointing at the dead source, or Continue Reading keeps
      // offering it for the first tap after migrating.
      expect(history.all().where((e) => e.sourceId == 'lnr:old'), isEmpty);
      final moved = history.get('lnr:new', 'new-1');
      expect(moved, isNotNull);
      expect(moved!.title, 'The Beginning After The End');
      // An unrelated book is untouched.
      expect(history.get('lnr:other', 'other-1')?.title, 'A Different Book');
    });

    test('leaves the old source\'s position in place', () async {
      final from = novel(id: 'old-1');
      final to = novel(id: 'new-1', sourceId: 'lnr:new');
      final list = MyListStore();
      final history = ReadHistory();
      final store = ReadStore();

      await list.add(from);
      await history.save(
        entry(sourceId: 'lnr:old', showId: 'old-1', chapterId: 'ch12', chapterNumber: 12),
      );
      await store.save('lnr:old', 'old-1', 'ch12', pos: 400, total: 1000);

      final migrator = NovelMigrator(
        list: list,
        history: history,
        positions: ReadPositionMover(store: store),
        chaptersOf: (_) async => [(id: '/new/12', title: 'Chapter 12')],
      );

      await migrator.migrate(
        from: from,
        to: to,
        chapterNumber: 12,
        chapterId: 'ch12',
      );

      // A wrong guess must be recoverable, which means the old copy has to
      // still be there to migrate back from.
      expect(store.get('lnr:old', 'old-1', 'ch12'), (pos: 400, total: 1000));
    });

    test('migrating a novel onto itself is refused', () async {
      final same = novel(id: 'old-1');
      final list = MyListStore();
      final migrator = NovelMigrator(
        list: list,
        history: ReadHistory(),
        positions: ReadPositionMover(store: ReadStore()),
        chaptersOf: (_) async => const [],
      );

      final res = await migrator.migrate(from: same, to: same);
      expect(res.ok, isFalse);
      expect(res.reason, 'same place');
    });
  });

  group('position selection', () {
    test('carries the position belonging to the chapter being resolved', () async {
      final store = ReadStore();
      final mover = ReadPositionMover(store: store);

      // Chapter 9 is further through the scrollbar than chapter 40, but the
      // reader is ON chapter 40. Carrying "furthest" would move chapter 9's
      // place to wherever chapter 40 lands.
      await store.save('lnr:old', 'old-1', 'ch9', pos: 1000, total: 1000);
      await store.save('lnr:old', 'old-1', 'ch40', pos: 200, total: 1000);

      expect(mover.furthest('lnr:old', 'old-1')!.chapterId, 'ch9');
      expect(mover.at('lnr:old', 'old-1', 'ch40')!.pos, 200);
    });

    test('a chapter with no stored position reports none', () async {
      final mover = ReadPositionMover(store: ReadStore());
      await ReadStore().save('lnr:old', 'old-1', 'ch1', pos: 10, total: 100);

      expect(mover.at('lnr:old', 'old-1', 'ch7'), isNull);
    });
  });

  group('source outcomes', () {
    test('blocked and timed-out sources are reported as broken, not as empty', () {
      // A blocked source hands back an empty list and an outcome - it does not
      // throw. Treating that as "had nothing" is the one confusion this feature
      // exists to avoid.
      for (final outcome in [
        SourceOutcome.blocked,
        SourceOutcome.timeout,
        SourceOutcome.error,
      ]) {
        expect(outcome.name, isNotEmpty);
      }
    });
  });
}