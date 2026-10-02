import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/ui/source_icon_tile.dart';
import 'package:watch_app/features/search/browse_sources_list.dart';

import '../../support/picker_deps.dart';

// Novel-only build: this list gathers the novel bucket and nothing else, so the
// fixtures below install novel sources — LNReader plugins (`lnr:`), which carry
// a `LNReader · ` row tag, and the app's own JS novel providers, which carry
// none. The Aniyomi source registered in setUp is deliberate: it must never be
// listed, which is what makes each case a novel-only case and not just a list
// test.

/// Installs [plugins] as LNReader novel sources and registers a real
/// [LnReaderManager] over the box that holds them — the established way to get
/// a novel row (`source_switcher_lnreader_test.dart` does exactly this). No
/// network, no QuickJS runtime: only the stored metadata is ever read, which is
/// all `categorizedSources()` asks of it.
Future<void> _seedNovelPlugins(List<(String id, String name)> plugins) async {
  if (!sl.isRegistered<LnReaderManager>()) {
    final manager = LnReaderManager(
      service: LnReaderExtensionService(
        httpGet: (url) async => throw StateError('unexpected httpGet($url)'),
      ),
      fetch: (url, init) async =>
          throw StateError('fetch should not be called — the list reads meta only'),
    );
    await manager.init(); // opens the box; does not build the runtime
    sl.registerSingleton<LnReaderManager>(manager);
  }
  final box = Hive.box<Map>(LnReaderExtensionService.boxName);
  for (final (id, name) in plugins) {
    await box.put(id, {
      ...LnReaderPluginMeta(
        id: id,
        name: name,
        site: 'https://$id.test/',
        lang: 'en',
        version: '1.0.0',
        url: 'https://cdn.test/$id.js',
        iconUrl: '',
      ).toMap(),
      'js': '',
    });
  }
}

/// Installs the app's OWN novel sources: JS providers whose repo manifest
/// declares `type: 'novel'`. These are the one novel ecosystem whose row label
/// carries NO ecosystem tag, which is what makes them the other half of the
/// "orders by name, not by tag" cases.
Future<void> _seedJsNovelSources(List<(String id, String name)> sources) async {
  const repoUrl = 'https://example.test/repo/index.json';
  await Hive.box<Map>(ProviderReposRegistry.boxName).put(
    repoUrl,
    ProviderRepo(
      url: repoUrl,
      name: 'Test Repo',
      description: '',
      lastSyncedAt: DateTime.now(),
      sources: [
        for (final (id, name) in sources)
          RepoSource(
            id: id,
            name: name,
            version: '1.0.0',
            type: 'novel',
            lang: 'en',
            file: '$id.js',
          ),
      ],
    ).toJson(),
  );
  final regBox = Hive.box<Map>(ProviderRegistry.boxName);
  for (final (id, name) in sources) {
    await regBox.put(
      ProviderRegistry.providerKey(repoUrl, id),
      ProviderRegistryEntry(
        name: id,
        url: '$repoUrl/$id.js',
        originRepoUrl: repoUrl,
        displayName: name,
      ).toJson(),
    );
  }
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('browse_list');
    Hive.init(dir.path);
    await registerPickerDeps(
      aniyomi: [aniSource(id: 1, name: 'HiAnime')],
    );
  });

  tearDown(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('lists installed sources and reports the one tapped', (t) async {
    await t.runAsync(() => _seedNovelPlugins([('hi-novel', 'HiNovel')]));

    String? tappedId;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BrowseSourcesList(onBrowse: (id, _) => tappedId = id),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiNovel'), findsOneWidget);
    expect(
      find.textContaining('HiAnime'),
      findsNothing,
      reason: 'an installed anime source is not a novel source',
    );

    await t.tap(find.textContaining('HiNovel'));
    await t.pumpAndSettle();
    expect(tappedId, 'lnr:hi-novel');
  });

  // This list is the Sources TAB, so the shell's floating dock is drawn over
  // it and its height reaches the list as a bottom inset. A ListView with an
  // explicit padding opts out of absorbing that, so the padding has to add it
  // back — otherwise the last source sits under the dock with no way to
  // scroll it clear.
  testWidgets('the list clears the dock inset', (t) async {
    await t.runAsync(() => _seedNovelPlugins([('only-novel', 'OnlyNovel')]));

    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(padding: const EdgeInsets.only(bottom: 104)),
            child: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final list = t.widget<ListView>(find.byType(ListView).first);
    expect(
      (list.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(104.0),
      reason: 'the last source must scroll clear of the dock',
    );
  });

  testWidgets('says so when nothing is installed', (t) async {
    await sl.reset();
    await registerPickerDeps(aniyomi: [aniSource(id: 1, name: 'HiAnime')]);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    expect(
      find.textContaining('HiAnime'),
      findsNothing,
      reason: 'an anime source installed is still not a novel source installed',
    );
    // Not the old bare "No sources installed": on a fresh install this is the
    // first screen a user reaches, and a dead-end message there is unreachable
    // content — there is no other way to install anything.
    expect(find.text('No sources installed'), findsNothing);
    expect(find.text('No novel sources installed'), findsOneWidget);
    expect(find.text('Add novel sources'), findsOneWidget);
  });

  testWidgets('query narrows the rows by source name', (t) async {
    await sl.reset();
    await registerPickerDeps();
    await t.runAsync(
      () => _seedNovelPlugins([
        ('hi-novel', 'HiNovel'),
        ('all-novel', 'AllNovel'),
      ]),
    );
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {}, query: 'hi')),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiNovel'), findsOneWidget);
    expect(find.textContaining('AllNovel'), findsNothing);
  });

  testWidgets('a query nothing matches shows the no-matches state, not '
      'the nothing-installed one', (t) async {
    await t.runAsync(() => _seedNovelPlugins([('hi-novel', 'HiNovel')]));
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BrowseSourcesList(onBrowse: (_, _) {}, query: 'zzz-nope'),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiNovel'), findsNothing);
    expect(find.text('No matches found'), findsOneWidget);
    expect(find.text('No sources installed'), findsNothing);
  });

  testWidgets('every row carries a source icon tile', (t) async {
    await t.runAsync(() => _seedNovelPlugins([('hi-novel', 'HiNovel')]));
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    // This list and the picker show the same sources; a row here without a
    // logo while the picker has one is exactly the drift the shared tile
    // exists to stop.
    expect(find.byType(SourceIconTile), findsWidgets);
  });

  testWidgets('rows are alphabetical by the source name, not the tag', (t) async {
    await t.runAsync(() async {
      await _seedNovelPlugins([('alpha-lnr', 'Alpha')]);
      await _seedJsNovelSources([('js:beta', 'Beta')]);
    });

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    // Two DIFFERENT tags on purpose. With one ecosystem the two orderings
    // agree and the test proves nothing: "LNReader · Alpha" sorts before
    // "LNReader · Beta" either way. Across the two novel ecosystems they
    // disagree — by raw label "Beta" beats "LNReader · Alpha", by name Alpha
    // beats Beta.
    final alpha = t.getTopLeft(find.text('LNReader · Alpha')).dy;
    final beta = t.getTopLeft(find.text('Beta')).dy;
    expect(alpha, lessThan(beta));
  });

  testWidgets('no A-Z rail on a short list', (t) async {
    await t.runAsync(() => _seedNovelPlugins([('only-one', 'Only One')]));

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    // A rail over a handful of rows is clutter; the whole list is already on
    // screen.
    expect(find.byKey(alphabetRailKey), findsNothing);
  });

  testWidgets('a long list gets the A-Z rail, and tapping it scrolls', (t) async {
    await t.runAsync(
      () => _seedNovelPlugins([
        for (var i = 0; i < 20; i++)
          ('novel-${String.fromCharCode(65 + i)}', String.fromCharCode(65 + i)),
      ]),
    );

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    expect(find.byKey(alphabetRailKey), findsOneWidget);

    final list = find.byType(Scrollable).first;
    expect(t.widget<Scrollable>(list).controller!.offset, 0);

    // Press near the bottom of the rail — that is a late letter, so the list
    // must move. This is the whole point of the rail.
    final rail = t.getRect(find.byKey(alphabetRailKey));
    await t.tapAt(Offset(rail.center.dx, rail.bottom - 4));
    await t.pumpAndSettle();

    expect(t.widget<Scrollable>(list).controller!.offset, greaterThan(0));
  });

  testWidgets('a name starting with an emoji buckets under # at the TOP',
      (t) async {
    await t.runAsync(() async {
      await _seedNovelPlugins([('sportzx', '⚡SportzX')]);
      await _seedJsNovelSources([('js:beta', 'Beta')]);
    });

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    // U+26A1 sorts ABOVE 'z', so a plain name-sort dropped this row at the
    // very bottom while the rail still bucketed it as '#' near the top —
    // '#' in two places, and the rail could only reach the first.
    final emoji = t.getTopLeft(find.text('LNReader · ⚡SportzX')).dy;
    final beta = t.getTopLeft(find.text('Beta')).dy;
    expect(emoji, lessThan(beta));
  });

  test('sourceInitial buckets by the source name, not the tag', () {
    expect(sourceInitial('LNReader · Vidsrc'), 'V');
    expect(sourceInitial('AnimePahe'), 'A');
    expect(sourceInitial('4K HDHub'), '#');
    expect(sourceInitial('LNReader · ⚡SportzX'), '#');
    expect(sourceInitial(''), '#');
  });

  testWidgets('rail letters get equal slots, not gaps stretched to fill',
      (t) async {
    await t.runAsync(
      () => _seedNovelPlugins([
        for (var i = 0; i < 20; i++)
          ('novel-${String.fromCharCode(65 + i)}', String.fromCharCode(65 + i)),
      ]),
    );

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    final railH = t.getSize(find.byKey(alphabetRailKey)).height;
    final listH = t.getSize(find.byType(BrowseSourcesList)).height;

    // 20 letters at a fixed slot each — NOT spread over the whole list, which
    // made the gaps depend on how many letters there happened to be.
    expect(railH, 20 * railSlotHeight);
    expect(railH, lessThan(listH));

    // And centred in the list, not pinned to the top.
    final rail = t.getRect(find.byKey(alphabetRailKey));
    final list = t.getRect(find.byType(BrowseSourcesList));
    expect((rail.center.dy - list.center.dy).abs(), lessThan(24));
  });

  testWidgets('a finger on the rail shows a small letter preview beside it',
      (t) async {
    await t.runAsync(
      () => _seedNovelPlugins([
        for (var i = 0; i < 20; i++)
          ('novel-${String.fromCharCode(65 + i)}', String.fromCharCode(65 + i)),
      ]),
    );

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    expect(find.byKey(railPreviewKey), findsNothing);

    // Hold, don't tap: the preview only exists while a finger is down.
    final rail = t.getRect(find.byKey(alphabetRailKey));
    final g = await t.startGesture(Offset(rail.center.dx, rail.top + 4));
    await t.pump(const Duration(milliseconds: 250));

    expect(find.byKey(railPreviewKey), findsOneWidget);
    final preview = t.getRect(find.byKey(railPreviewKey));
    final listRect = t.getRect(find.byType(BrowseSourcesList));
    // Beside the rail on the right, not floating in the middle of the list.
    expect(preview.center.dx, greaterThan(listRect.center.dx));
    expect(preview.right, lessThanOrEqualTo(rail.left + 1));
    // And it rides the letter: near the top of the rail, so near the top row.
    expect(preview.center.dy, lessThan(listRect.center.dy));
    // Small — the slider letters carry the motion, not this.
    expect(preview.width, lessThanOrEqualTo(48));

    await g.up();
    await t.pumpAndSettle();
    expect(find.byKey(railPreviewKey), findsNothing);
  });
}
