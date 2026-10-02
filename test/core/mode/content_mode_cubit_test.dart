import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';

/// Minimal [SourceRepository] stub — only [loadedSources] is used by
/// [ContentModeCubit], the rest just isn't called from these tests.
class _FakeSourceRepository implements SourceRepository {
  _FakeSourceRepository(List<String> ids)
      : loadedSources = [for (final id in ids) (id: id, name: id)];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  final List<({String id, String name})> loadedSources;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mode_test');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
    if (sl.isRegistered<SourceRepository>()) sl.unregister<SourceRepository>();
  });

  // Novel-only build: there is one mode, so the questions the old suite asked
  // ("which mode do we boot into?", "does a switch persist?") have one answer
  // each, and the per-mode source memory is unreachable — setMode() returns
  // before it for every mode but novel, so nothing is ever parked or restored.
  // The gate itself and the boot safety net below are what's left to pin.
  test('always restores novel, over a persisted mode from a pre-fork build',
      () async {
    await ActiveSourceCubit.init();
    final active = ActiveSourceCubit(box: Hive.box(ActiveSourceCubit.boxName));
    final cubit = await ContentModeCubit.create(active);
    expect(cubit.state, ContentMode.novel);

    // An install that last sat on Manga (or Streaming) still has that on disk.
    await Hive.box('content_mode').put('mode', 'manga');

    final reloaded = await ContentModeCubit.create(active);
    expect(reloaded.state, ContentMode.novel);
  });

  test('setMode refuses anime and manga, and parks nothing for them', () async {
    await ActiveSourceCubit.init();
    final active = ActiveSourceCubit(box: Hive.box(ActiveSourceCubit.boxName));
    final cubit = await ContentModeCubit.create(active);

    for (final m in [ContentMode.anime, ContentMode.manga]) {
      await cubit.setMode(m);
      expect(cubit.state, ContentMode.novel, reason: 'setMode($m)');
    }
    // A refused switch writes nothing: no mode, and no remembered source under
    // a key no screen can ever ask for again.
    expect(Hive.box('content_mode').get('mode'), isNull);
    expect(Hive.box('content_mode').get('src.anime'), isNull);
    expect(Hive.box('content_mode').get('src.manga'), isNull);
  });

  // ── C: mode-appropriate fallback (the "Novel shows an anime source" bug) ──
  test('ensureSourceForMode() keeps the current source when it already '
      'belongs to the mode', () async {
    await ActiveSourceCubit.init();
    final active = ActiveSourceCubit(box: Hive.box(ActiveSourceCubit.boxName));
    final cubit = await ContentModeCubit.create(active);
    active.setSource('lnr:a');
    sl.registerSingleton<SourceRepository>(
      _FakeSourceRepository(['lnr:a', 'lnr:b']),
    );

    cubit.ensureSourceForMode();
    expect(active.state, 'lnr:a'); // not swapped to lnr:b — current pick fits
  });

  test('ensureSourceForMode() self-corrects a mode stuck on a non-novel '
      'source (boot safety net)', () async {
    await ActiveSourceCubit.init();
    final active = ActiveSourceCubit(box: Hive.box(ActiveSourceCubit.boxName));
    final cubit = await ContentModeCubit.create(active);
    active.setSource('allanime'); // simulate boot restoring an anime source
    sl.registerSingleton<SourceRepository>(
      _FakeSourceRepository(['allanime', 'lnr:wbnovel']),
    );

    cubit.ensureSourceForMode();
    expect(active.state, 'lnr:wbnovel');
  });
}
