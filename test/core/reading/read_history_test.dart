import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/reading/read_history.dart';

/// Reading history is local-only: one Hive box is the whole truth, so these
/// cover the box behaviour (one row per title, the finished rules, the
/// per-kind filter) and the read/modify/clear operations behind the History
/// screen.
void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('read_history');
    Hive.init(dir.path);
    await ReadHistory.init();
  });
  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  ReadEntry entry(
    String show, {
    int pos = 0,
    int total = 20,
    int ts = 0,
    ProviderType type = ProviderType.novel,
  }) => ReadEntry(
    sourceId: 'js:m', showId: show, title: show, cover: null,
    chapterId: 'ch1', chapterNumber: 1, chapterUrl: 'u',
    pos: pos, total: total, updatedMs: ts, type: type,
  );

  test('save keeps one row per title (latest chapter wins)', () async {
    final h = ReadHistory();
    await h.save(entry('a', pos: 1, ts: 1));
    await h.save(entry('a', pos: 5, ts: 2));
    expect(h.recent(), hasLength(1));
    expect(h.recent().single.pos, 5);
  });

  test('recent() excludes finished and sorts newest-first', () async {
    final h = ReadHistory();
    await h.save(entry('done', pos: 19, total: 20, ts: 1)); // finished
    await h.save(entry('old', pos: 2, ts: 10));
    await h.save(entry('new', pos: 2, ts: 20));
    expect(h.recent().map((e) => e.showId).toList(), ['new', 'old']);
  });

  test('recent() applies the novel permille finished rule (total == 1000)',
      () async {
    final h = ReadHistory();
    await h.save(entry('almostDone', pos: 950, total: 1000, ts: 1));
    await h.save(entry('reading', pos: 500, total: 1000, ts: 2));
    expect(h.recent().map((e) => e.showId).toList(), ['reading']);
  });

  test('recent(type:) returns only that kind — the box mixes manga and novel',
      () async {
    final h = ReadHistory();
    await h.save(entry('m1', ts: 3, type: ProviderType.manga));
    await h.save(entry('n1', ts: 2, type: ProviderType.novel));
    await h.save(entry('m2', ts: 1, type: ProviderType.manga));
    expect(h.recent(type: ProviderType.manga).map((e) => e.showId).toList(),
        ['m1', 'm2']);
    expect(h.recent(type: ProviderType.novel).map((e) => e.showId).toList(),
        ['n1']);
    expect(h.recent().length, 3); // no type → both (backward compatible)
  });

  test('readEntryTypeFromName: manga round-trips, everything else '
      '(including null — a pre-existing row) defaults to novel', () {
    expect(readEntryTypeFromName('manga'), ProviderType.manga);
    expect(readEntryTypeFromName('novel'), ProviderType.novel);
    expect(readEntryTypeFromName(null), ProviderType.novel);
    expect(readEntryTypeFromName('anime'), ProviderType.novel);
    expect(readEntryTypeFromName('garbage'), ProviderType.novel);
  });

  test('toJson/fromJson round-trips a manga entry\'s type', () {
    final e = entry('m', type: ProviderType.manga);
    final back = ReadEntry.fromJson(e.toJson());
    expect(back.type, ProviderType.manga);
  });

  test('fromJson defaults to novel when the stored map has no type key '
      'at all (a row saved before this field existed)', () {
    final legacy = entry('legacy').toJson()..remove('type');
    expect(ReadEntry.fromJson(legacy).type, ProviderType.novel);
  });

  test('save() then reading back from the box preserves a manga entry\'s '
      'type (Hive round trip, not just toJson/fromJson in memory)',
      () async {
    final h = ReadHistory();
    await h.save(entry('m', type: ProviderType.manga));
    expect(h.recent().single.type, ProviderType.manga);
  });

  // ── History screen: all() / get() / remove() / clearType() ───────────────

  test('all() returns every row (finished included) newest-first', () async {
    final h = ReadHistory();
    await h.save(
      entry('finishedManga', pos: 19, total: 20, ts: 1, type: ProviderType.manga),
    );
    await h.save(entry('novelA', pos: 2, ts: 5));
    final all = h.all();
    // newest-first, and unlike recent() the finished row is NOT dropped.
    expect(all.map((e) => e.showId).toList(), ['novelA', 'finishedManga']);
  });

  test('get() returns the saved entry for a title, or null when there is '
      'none', () async {
    final h = ReadHistory();
    expect(h.get('js:m', 'a'), isNull);

    await h.save(entry('a', pos: 4, ts: 1));
    final got = h.get('js:m', 'a');
    expect(got?.showId, 'a');
    expect(got?.pos, 4);
    expect(h.get('js:m', 'other'), isNull); // different show, no entry
  });

  test('remove() deletes the row', () async {
    final h = ReadHistory();
    await h.save(entry('a', pos: 1, ts: 1));
    expect(h.all(), hasLength(1));

    await h.remove('js:m', 'a');

    expect(h.all(), isEmpty);
  });

  test('clearType(manga) wipes only manga rows, leaving novel history '
      'untouched', () async {
    final h = ReadHistory();
    await h.save(entry('m1', ts: 1, type: ProviderType.manga));
    await h.save(entry('n1', ts: 2, type: ProviderType.novel));

    await h.clearType(ProviderType.manga);

    expect(h.all().map((e) => e.showId).toList(), ['n1']);
  });

  test('clearLocal() drops every row', () async {
    final h = ReadHistory();
    await h.save(entry('m1', ts: 1, type: ProviderType.manga));
    await h.save(entry('n1', ts: 2, type: ProviderType.novel));
    expect(h.all(), hasLength(2));

    await h.clearLocal();

    expect(h.all(), isEmpty);
  });
}
