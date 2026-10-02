import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/picker_deps.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/detail/cubit/detail_cubit.dart';
import 'package:watch_app/features/detail/wrong_title_sheet.dart';

class _Src implements SourceRepository {
  _Src(this.bySource);
  final Map<String, List<MediaItem>> bySource;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  String baseUrlFor(String id) =>
      id.startsWith('ani:') || id.startsWith('mihon:') || id.startsWith('lnr:')
          ? 'https://example.test'
          : '';
  @override
  List<({String id, String name})> get loadedSources =>
      [for (final id in bySource.keys) (id: id, name: _name(id))];
  static String _name(String id) =>
      id == _novelA.id ? _novelA.name : _novelB.name;
  @override
  bool hasSource(String sourceId) => bySource.containsKey(sourceId);
  @override
  String displayName(String id) => _name(id);
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async =>
      bySource[sourceId] ?? const [];
}

/// The novel sources every fixture in this file is built from. `lnr:`-prefixed
/// because that is the one ecosystem this build can still have: the picker's
/// rows are built from the app's own registries, not from [_Src], so the same
/// pair of ids has to be seeded into the LNReader box by
/// [_registerNovelSources] for a row to appear in the sheet.
const _novelA = (id: 'lnr:novelhub', name: 'NovelHub');
const _novelB = (id: 'lnr:novelverse', name: 'NovelVerse');

/// Registers the novel sources the picker will offer.
///
/// [registerPickerDeps] covers the app-wide registries and the Aniyomi rows;
/// LNReader is registered separately because the picker reads it through
/// `sl.isRegistered<LnReaderManager>()` rather than a locator it always has.
/// Nothing here builds the QuickJS runtime — [LnReaderManager.installedSources]
/// is a plain read of the stored plugin meta, which is what the picker needs.
///
/// Must run inside `runAsync` (or a plain `test`), like every other Hive write
/// in a pump-driven test.
Future<void> _registerNovelSources(
  List<({String id, String name})> sources,
) async {
  final box = await openBoxSafely<Map>(LnReaderExtensionService.boxName);
  await box.clear();
  for (final s in sources) {
    // The box is keyed by the BARE plugin id; the manager adds the `lnr:`
    // prefix itself when it builds the source id.
    final pluginId = s.id.substring(4);
    await box.put(pluginId, LnReaderPluginMeta(
      id: pluginId,
      name: s.name,
      site: 'https://example.test',
      lang: 'en',
      version: '1.0.0',
      url: 'https://example.test/$pluginId.js',
      iconUrl: '',
    ).toMap());
  }
  sl.registerSingleton<LnReaderManager>(LnReaderManager(
    service: LnReaderExtensionService(httpGet: (_) async => ''),
    // No plugin is ever called, so the runtime is never asked for one.
    fetch: (_, _) => throw UnsupportedError('these tests never load a plugin'),
  ));
}

class _None implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  List<({String id, String name})> get loadedSources => const [];
}

/// A minimal [CatalogueRepository] so [MatchLine]'s reading-kind reload path
/// (`context.read<DetailCubit>().refresh()`) has a real DetailCubit to call
/// into. Counts `detail()` calls so a test can prove that path actually fired.
class _Repo implements CatalogueRepository {
  int detailCalls = 0;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  Future<void> clearHttpCache() async {}
  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
    bool Function()? abandoned,
  }) async {
    detailCalls++;
    return const MediaDetail(
        id: 'x', title: 'x', url: 'zm://novel/mal:777', type: ProviderType.novel, sourceId: 'zm');
  }
}

/// [TitlePrefsStore] touches Hive on construction-adjacent calls; DetailCubit
/// reads `category()` synchronously in its constructor, so a real store isn't
/// needed here. Mirrors detail_cubit_test.dart's identical fake.
class _FakeTitlePrefs extends TitlePrefsStore {
  @override
  String? category(String s, String u) => null;
  @override
  Future<void> setCategory(String s, String u, String c) async {}
}

void main() {
  late ZSourcePrefs prefs;
  late Directory dir;
  const fma = ZCanonical(ZKind.novel, 'mal:5114');

  Widget harness(Widget child, {CatalogueRepository? repo, String? url}) => MaterialApp(
    home: Scaffold(
      body: BlocProvider(
        create: (_) => DetailCubit(
          repo: repo ?? _Repo(),
          url: url ?? 'zm://novel/mal:5114',
          prefs: _FakeTitlePrefs(),
        ),
        child: child,
      ),
    ),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wrongshow');
    Hive.init(dir.path);
    await registerPickerDeps();
    // The picker's rows come from the registries registerPickerDeps sets up,
    // so the two novel sources have to exist there too — a fake
    // SourceRepository alone puts nothing in the sheet.
    await _registerNovelSources([_novelA, _novelB]);
    // Picker rows probe the native side for per-source settings. These tests
    // are about matching, not settings, so answer "none" rather than let an
    // unimplemented channel throw mid-build.
    for (final ch in const ['zangetsu/aniyomi', 'zangetsu/mihon']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        MethodChannel(ch),
        (call) async => call.method == 'hasSourceSettings' ? false : null,
      );
    }
    final src = _Src({
      _novelA.id: [MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2003', type: ProviderType.novel, sourceId: _novelA.id)],
      _novelB.id: [
        MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
            url: 'https://h/2003', type: ProviderType.novel, sourceId: _novelB.id),
        MediaItem(id: 'fmab', title: 'Fullmetal Alchemist: Brotherhood',
            url: 'https://h/fmab', type: ProviderType.novel, sourceId: _novelB.id),
      ],
    });
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, prefs: prefs, candidates: (_) => src.loadedSources));
  });
  tearDown(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('shows the source Auto Resolve settled on, and Wrong title?',
      (t) async {
    // MatchLine resolves on first build via a real Hive write, which never
    // drains under the pump-driven testWidgets binding without runAsync —
    // same class of issue as mode_switcher_test.dart's setMode. Pre-resolving
    // here means the write happens inside runAsync, and MatchLine's own
    // build-time resolve() just hits the already-saved fast path.
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();
    expect(find.textContaining(_novelA.name), findsOneWidget);
    expect(find.text('Wrong title?'), findsOneWidget);
  });

  // The row is 52 tall but its InkWell used to shrink to the text's own ~20px,
  // so a tap 4px from the row's top edge — well inside what looks like a
  // button — did nothing. Tapping the text always worked, which is why every
  // other test here missed it.
  testWidgets('the whole 52px row opens the picker, not just the text line',
      (t) async {
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();

    // The grey pill itself, not its label.
    final row = find.ancestor(
      of: find.textContaining(_novelA.name),
      matching: find.byType(InkWell),
    );
    final box = t.getRect(row.first);
    expect(box.height, 52, reason: 'the tap target must be the whole row');

    // 4px in from the top edge — above the text, inside the pill.
    await t.tapAt(Offset(box.left + 20, box.top + 4));
    await t.pumpAndSettle();
    expect(find.text('All'), findsOneWidget);
  });

  testWidgets('switching source in the picker updates the line', (t) async {
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();
    expect(find.textContaining(_novelA.name), findsOneWidget);

    await t.tap(find.textContaining(_novelA.name));
    await t.pumpAndSettle();
    // The shared picker has no title row — its tabs identify it, and in this
    // build that is the All tab plus the mode's own single bucket.
    expect(find.text('All'), findsOneWidget);
    expect(find.textContaining(_novelB.name), findsOneWidget);

    await t.runAsync(() async {
      await t.tap(find.textContaining(_novelB.name));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    expect(find.textContaining(_novelB.name), findsOneWidget);
    // Picking pins THIS title to the second novel source. The kind default is
    // deliberately left alone now — one title's correction no longer reassigns
    // every other title of that kind.
    expect(sl<MatchStore>().get(fma, _novelB.id)?.pinned, isTrue);
    expect(prefs.get(fma.kind), isNull);
    // The first source's own match is untouched by the switch.
    expect(sl<MatchStore>().get(fma, _novelA.id)?.sourceId, _novelA.id);
  });

  testWidgets('Wrong title? corrects the match for the selected source only', (t) async {
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();
    // Selected source is the first novel source (the first candidate to
    // genuinely match).
    await t.tap(find.text('Wrong title?'));
    await t.pumpAndSettle();
    // The sheet only ever searches the selected source — its one result is
    // the (2003) title already resolved above.
    expect(find.text('Fullmetal Alchemist (2003)'), findsWidgets);
    expect(find.text('Fullmetal Alchemist: Brotherhood'), findsNothing);

    await t.runAsync(() async {
      await t.tap(find.text('Fullmetal Alchemist (2003)').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    expect(sl<MatchStore>().get(fma, _novelA.id)?.pinned, isTrue);
    // The other source was never touched by this correction.
    expect(sl<MatchStore>().get(fma, _novelB.id), isNull);

    // Confirming a match toasts, and a toast is a two-second timer. Left
    // running, it outlives the widget tree and the binding fails the test on
    // a pending timer — nothing to do with the correction itself.
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('Wrong title? correction on a novel title refreshes the Detail screen', (t) async {
    // A correction always re-fetches Detail, whichever kind it was on: the
    // matched source owns the chapter list, so the old one is stale the moment
    // the pin moves (see MatchLine._refreshAfterMatchChange).
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    final repo = _Repo();
    await t.pumpWidget(harness(
      const MatchLine(canonical: fma, title: 'Fullmetal Alchemist (2003)'),
      repo: repo,
    ));
    await t.pumpAndSettle();
    expect(repo.detailCalls, 0); // nothing corrected yet — no reload

    await t.tap(find.text('Wrong title?'));
    await t.pumpAndSettle();
    // The sheet only ever searches the selected source — its one result is
    // the (2003) title already resolved above.
    expect(find.text('Fullmetal Alchemist (2003)'), findsWidgets);

    await t.runAsync(() async {
      await t.tap(find.text('Fullmetal Alchemist (2003)').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    expect(sl<MatchStore>().get(fma, _novelA.id)?.pinned, isTrue);
    expect(repo.detailCalls, greaterThan(0));

    // Drain the confirmation toast's timer — see the note in the test above.
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('the row names the title it matched, so a wrong one is visible',
      (t) async {
    // The case this control exists for: the source matched confidently, but to
    // the wrong title. Same source name, a full chapter list — indistinguishable
    // from a correct match unless the matched TITLE is on screen.
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    final src = _Src({
      _novelA.id: [MediaItem(id: 'brother', title: 'Fullmetal Alchemist Brotherhood',
          url: 'https://a/bro', type: ProviderType.novel, sourceId: _novelA.id)],
    });
    await t.runAsync(() async {
      await registerPickerDeps();
      await _registerNovelSources([_novelA]);
    });
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, prefs: prefs, candidates: (_) => src.loadedSources));

    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist Brotherhood'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist Brotherhood')));
    await t.pumpAndSettle();

    // The source, and what it landed on, both on screen without opening a thing.
    expect(find.textContaining(_novelA.name), findsOneWidget);
    expect(find.text('Fullmetal Alchemist Brotherhood'), findsOneWidget);
    expect(find.text('Wrong title?'), findsOneWidget);
  });

  testWidgets('a source with no match still appears in the picker; choosing it shows the honest empty state',
      (t) async {
    // The second source is installed but genuinely has nothing matching this
    // title — its own catalogue is a different book entirely.
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    final src = _Src({
      _novelA.id: [MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2003', type: ProviderType.novel, sourceId: _novelA.id)],
      _novelB.id: [MediaItem(id: 'op', title: 'One Piece',
          url: 'https://h/op', type: ProviderType.novel, sourceId: _novelB.id)],
    });
    // sl.reset() above dropped the picker's own singletons; the sheet needs
    // them back before it can be opened. runAsync: seeding the LNReader box is
    // real Hive I/O, which never drains under the pump-driven binding.
    await t.runAsync(() async {
      await registerPickerDeps();
      await _registerNovelSources([_novelA, _novelB]);
    });
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, prefs: prefs, candidates: (_) => src.loadedSources));

    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();
    expect(find.textContaining(_novelA.name), findsOneWidget); // auto-picked

    await t.tap(find.textContaining(_novelA.name));
    await t.pumpAndSettle();
    // The other source is offered even though it can't possibly match — not
    // filtered out of the picker for lacking one.
    expect(find.textContaining(_novelB.name), findsOneWidget);

    await t.runAsync(() async {
      await t.tap(find.textContaining(_novelB.name));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    // It is now selected, honestly with no match — not silently left on the
    // first source, and not crashed/hidden.
    expect(find.textContaining(_novelB.name), findsOneWidget);
    // "Selected but nothing behind it" is said in words, not just signalled by
    // dimming the name: a picked source keeps its normal label (you need to
    // read WHICH source is selected in order to change it) and the pill
    // carries an explicit line underneath saying it has nothing.
    final name = t.widget<Text>(find.textContaining(_novelB.name));
    expect(name.style?.color, AppColors.textPrimary);
    expect(find.text('No episodes available from this source'), findsOneWidget);
    // The choice is recorded even though there's nothing behind it. It used
    // to write nothing at all, which left the PREVIOUS source pinned — so the
    // picker named the new source while the old one went on serving the
    // chapter list, the reader and the downloads.
    final picked = sl<MatchStore>().get(fma, _novelB.id);
    expect(picked?.pinned, isTrue);
    expect(picked?.showUrl, isEmpty, reason: 'a choice, not a match');
    expect(sl<MatchStore>().get(fma, _novelA.id)?.pinned, isNot(true));
  });

  testWidgets('switching source on a novel title refreshes the Detail screen chapters', (t) async {
    await sl.reset();
    Hive.init(dir.path);
    // runAsync: seeding the registries writes to Hive, and a real write never
    // drains under the pump-driven binding.
    await t.runAsync(() async {
      await registerPickerDeps();
      await _registerNovelSources([_novelA, _novelB]);
    });
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    final src = _Src({
      _novelA.id: [MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2003', type: ProviderType.novel, sourceId: _novelA.id)],
      _novelB.id: [MediaItem(id: 'fmab', title: 'Fullmetal Alchemist: Brotherhood',
          url: 'https://h/fmab', type: ProviderType.novel, sourceId: _novelB.id)],
    });
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, prefs: prefs, candidates: (_) => src.loadedSources));

    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    final repo = _Repo();
    await t.pumpWidget(harness(
      const MatchLine(canonical: fma, title: 'Fullmetal Alchemist (2003)'),
      repo: repo,
    ));
    await t.pumpAndSettle();
    expect(repo.detailCalls, 0); // nothing switched yet — no reload
    await t.tap(find.textContaining(_novelA.name));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      await t.tap(find.textContaining(_novelB.name));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    expect(repo.detailCalls, greaterThan(0));
  });

  testWidgets(
      'nothing anywhere leaves Auto Resolve unnamed, with the picker still there',
      (t) async {
    // Neither source has anything resembling this title.
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    final src = _Src({_novelA.id: [], _novelB.id: []});
    // sl.reset() above dropped the picker's own singletons; the sheet needs
    // them back before it can be opened.
    await t.runAsync(() async {
      await registerPickerDeps();
      await _registerNovelSources([_novelA, _novelB]);
    });
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, prefs: prefs, candidates: (_) => src.loadedSources));

    // runAsync: nothing matches, so the matcher records a miss per candidate
    // (MatchStore.rememberMiss) — real Hive writes, which never drain under
    // the pump-driven binding.
    await t.runAsync(() async {
      await t.pumpWidget(
          harness(const MatchLine(canonical: fma, title: 'nothing like it')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();

    // Nothing matched anywhere, so Auto Resolve has no source to name — and
    // no line under it either, because "Wrong title?" corrects a source's
    // match and there is no source yet. "No source has this yet" would be
    // wrong too: nothing has been pinned, so nothing has been ruled out.
    expect(find.text('Auto Resolve'), findsOneWidget);
    expect(find.text('No source has this yet'), findsNothing);
    expect(find.text('Wrong title?'), findsNothing);

    await t.tap(find.text('Auto Resolve'));
    await t.pumpAndSettle();
    // The shared picker has no title row — its tabs identify it. Both sources
    // are offered, so a correction is still two taps away.
    expect(find.text('All'), findsOneWidget);
    expect(find.textContaining(_novelA.name), findsOneWidget);
    expect(find.textContaining(_novelB.name), findsOneWidget);
  });

  testWidgets('no installed source at all says so, with nothing to switch or fix', (t) async {
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    final none = _None();
    sl.registerSingleton<SourceRepository>(none);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: none, store: store, prefs: prefs, candidates: (_) => const []));
    await t.pumpWidget(harness(const MatchLine(canonical: fma, title: 'x')));
    await t.pumpAndSettle();
    // "No sources installed", NOT "no source has this yet": nothing is
    // installed, and blaming the title for that is the same mistake as
    // blaming a source for an episode that hasn't aired.
    expect(find.text('No sources installed'), findsOneWidget);
    expect(find.text('No source has this yet'), findsNothing);
    expect(find.text('Wrong title?'), findsNothing);
  });
}
