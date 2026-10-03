// The picker's per-row settings gear and Cloudflare action.
// Harness mirrors wrong_title_sheet_test.dart's fakes; this file only adds
// the second novel source — a plain Zangetsu JS provider that declares
// `type: 'novel'` and has no site behind it, so the row has nothing to offer
// and the site-backed row's controls can be told apart from an empty menu.
//
// Novel-only build: the "Source settings" half of this file is gone.
// source_actions.hasSourceSettings answers for `ani:`/`mihon:`/`cs:` ids only,
// and none of those ecosystems can be installed in this build, so a novel
// source can never offer a per-source settings screen — there is nothing left
// for those two cases to assert. What is still live, and what these cases now
// pin, is the Cloudflare solve: which row gets a control, and where it sits.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/picker_deps.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
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
  // Only the `lnr:` extension is site-backed here; the plain JS provider has
  // no base url, which is what hides the controls on its row.
  @override
  String baseUrlFor(String id) =>
      id.startsWith('ani:') || id.startsWith('mihon:') || id.startsWith('lnr:')
          ? 'https://example.test'
          : '';
  @override
  List<({String id, String name})> get loadedSources =>
      [for (final id in bySource.keys) (id: id, name: _name(id))];
  static String _name(String id) =>
      id == _siteBacked.id ? _siteBacked.name : _plainJs.name;
  @override
  bool hasSource(String sourceId) => bySource.containsKey(sourceId);
  @override
  String displayName(String id) => _name(id);
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async =>
      bySource[sourceId] ?? const [];
}

/// The LNReader extension row: a site, so the Cloudflare solve has a target.
const _siteBacked = (id: 'lnr:novelhub', name: 'NovelHub');

/// The app's own novel source: a repo-installed JS provider declaring
/// `type: 'novel'`, with no site of its own.
const _plainJs = (id: 'novelquill', name: 'NovelQuill');

class _FakeTitlePrefs extends TitlePrefsStore {
  @override
  String? category(String s, String u) => null;
  @override
  Future<void> setCategory(String s, String u, String c) async {}
}

/// The selector row on the Detail screen carries the same shield/gear pair for
/// the selected source, so a bare byIcon finder matches twice once the sheet is
/// open. Scope to the sheet.
Finder inSheet(Finder f) =>
    find.descendant(of: find.byType(BottomSheet), matching: f);

/// Registers [_siteBacked] as an installed LNReader plugin. The picker reads
/// its rows from the app's own registries rather than from the fake
/// repository, so the row only exists if the box behind LnReaderManager says so
/// (its [LnReaderManager.installedSources] is a plain read of stored plugin
/// meta — no runtime is built). [registerPickerDeps] does the same job for
/// Aniyomi.
Future<void> _registerLnReaderSource(({String id, String name}) s) async {
  final box = await openBoxSafely<Map>(LnReaderExtensionService.boxName);
  final pluginId = s.id.substring(4); // the box is keyed by the bare plugin id
  await box.put(pluginId, LnReaderPluginMeta(
    id: pluginId,
    name: s.name,
    site: 'https://example.test',
    lang: 'en',
    version: '1.0.0',
    url: 'https://example.test/$pluginId.js',
    iconUrl: '',
  ).toMap());
  sl.registerSingleton<LnReaderManager>(LnReaderManager(
    service: LnReaderExtensionService(httpGet: (_) async => ''),
    // No plugin is ever called, so the runtime is never asked for one.
    fetch: (_, _) => throw UnsupportedError('these tests never load a plugin'),
  ));
}

/// Installs [_plainJs] as a repo provider. Unlike an `lnr:` row this one gets
/// into the novel bucket through its repo manifest's `type`, so the manifest
/// AND the provider-registry entry both have to be written — the picker reads
/// the registry for the row and the manifest for its type.
Future<void> _registerJsNovelSource(({String id, String name}) s) async {
  const repoUrl = 'https://example.test/repo/index.json';
  final reposBox = Hive.box<Map>(ProviderReposRegistry.boxName);
  await reposBox.put(
    repoUrl,
    ProviderRepo(
      url: repoUrl,
      name: 'Test Repo',
      description: '',
      lastSyncedAt: DateTime.now(),
      sources: [
        RepoSource(
          id: s.id,
          name: s.name,
          version: '1.0.0',
          type: 'novel',
          lang: 'en',
          file: '${s.id}.js',
        ),
      ],
    ).toJson(),
  );
  final regBox = Hive.box<Map>(ProviderRegistry.boxName);
  await regBox.put(
    ProviderRegistry.providerKey(repoUrl, s.id),
    ProviderRegistryEntry(
      name: s.id,
      url: '$repoUrl/${s.id}.js',
      originRepoUrl: repoUrl,
      displayName: s.name,
    ).toJson(),
  );
}

void main() {
  late ZSourcePrefs prefs;
  late Directory dir;
  const fma = ZCanonical(ZKind.novel, 'mal:5114');

  Widget harness(Widget child) => MaterialApp(
    home: Scaffold(
      body: BlocProvider(
        create: (_) => DetailCubit(
          repo: _NoopRepo(),
          url: 'zm://novel/mal:5114',
          prefs: _FakeTitlePrefs(),
        ),
        child: child,
      ),
    ),
  );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    dir = await Directory.systemTemp.createTemp('wrongshow_picker');
    Hive.init(dir.path);
    await registerPickerDeps();
    // Both novel sources are installed, so the sheet has a site-backed row and
    // a row with nothing to offer.
    await _registerLnReaderSource(_siteBacked);
    await _registerJsNovelSource(_plainJs);
    final src = _Src({
      _siteBacked.id: [MediaItem(id: 'a', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/1', type: ProviderType.novel, sourceId: _siteBacked.id)],
      _plainJs.id: [MediaItem(id: 'b', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2', type: ProviderType.novel, sourceId: _plainJs.id)],
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

  // The per-source controls live behind one overflow (three icons on a row that
  // also has to show a name was too many for actions used about twice per
  // source), so every assertion here opens the menu first.
  //
  // Home already routes Mihon, Aniyomi and LNReader challenges through the one
  // solver, so scoping the picker's solve to `mihon:` hid a control that
  // works. The gate is the source's base url: site-backed ecosystems have one,
  // CloudStream/JS items are absolute and have none.
  testWidgets('the Cloudflare entry follows the base url, not the ecosystem',
      (t) async {
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();

    await t.tap(find.textContaining(_siteBacked.name));
    await t.pumpAndSettle();
    // The shared picker has no title row — its tabs identify it, and in this
    // build that is the All tab plus the mode's own single bucket.
    expect(find.text('All'), findsOneWidget);

    // The lnr: row is site-backed and gets the overflow; the JS provider has
    // no base url and must not — "nothing to solve against" is the only thing
    // that hides it, not "not currently blocked".
    expect(inSheet(find.byIcon(Icons.more_vert_rounded)), findsOneWidget);
    // The shared picker builds its own row widget, not a ListTile.
    final actionRow = find.ancestor(
      of: inSheet(find.byIcon(Icons.more_vert_rounded)),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(
          of: actionRow, matching: find.textContaining(_siteBacked.name)),
      findsOneWidget,
      reason: 'the actions must sit on the site-backed row, not the JS one',
    );
    // Unflagged: nothing on the row but the overflow, and no badge — the
    // badge means a challenge was actually seen.
    expect(inSheet(find.byIcon(Icons.shield_rounded)), findsNothing);
    expect(inSheet(find.byType(Badge)), findsNothing);

    await t.tap(inSheet(find.byIcon(Icons.more_vert_rounded)));
    await t.pumpAndSettle();
    expect(find.text('Solve Cloudflare'), findsOneWidget);
  });

  // Task 20: a source CfSolveNeeded flagged gets a visually distinct control —
  // otherwise there's nothing telling the user THIS one actually needs a
  // solve. It also comes back OUT of the overflow: solving is the one action
  // here you may do repeatedly, and only a flagged source is about to need it.
  testWidgets(
      'a source flagged by CfSolveNeeded gets a distinct badged overflow',
      (t) async {
    CfSolveNeeded.needsSolve(
      'example.test',
      'https://example.test/s?q=x',
      sourceId: _siteBacked.id,
    );
    addTearDown(() => CfSolveNeeded.clear('example.test'));

    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();

    await t.tap(find.textContaining(_siteBacked.name));
    await t.pumpAndSettle();

    // The shield is back on the row, badged, one tap from a solve.
    expect(inSheet(find.byIcon(Icons.shield_rounded)), findsOneWidget);
    expect(inSheet(find.byType(Badge)), findsOneWidget);
    // The overflow stays (this source still has its site to sign in to) but is
    // plain, and must not offer the same solve a second time.
    expect(inSheet(find.byIcon(Icons.more_vert_rounded)), findsOneWidget);
    await t.tap(inSheet(find.byIcon(Icons.more_vert_rounded)));
    await t.pumpAndSettle();
    expect(find.text('Solve Cloudflare'), findsNothing);
    expect(find.text('Sign in'), findsOneWidget);
  });
}

class _NoopRepo implements CatalogueRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
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
  }) async =>
      const MediaDetail(
          id: 'x', title: 'x', url: 'zm://novel/mal:5114', type: ProviderType.novel, sourceId: 'zm');
}
