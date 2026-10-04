import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/home_row.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/ui/home_rows_prefs.dart';
import 'package:watch_app/core/zmode/metadata_provider_prefs.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/cubit/home_cubit.dart';

// The cubit-level promises of the home rows: the tracker library is fetched
// alongside the provider's sections, the DEFAULT arrangement hides every
// tracker row (so today's home survives the feature), an enabled row renders
// where the user put it, and a tracker that fails or goes away degrades to
// provider-only rows without breaking the load.
//
// Novel-only build: the layout under composition is the Novel one
// (`anilist::novel`, or `mal::novel` behind the MAL provider pref), so the
// fixtures carry novel rows and novel-typed items. A reading layout has no
// new-episodes row to begin with (`trackerRowIdsFor`), which is why the saved
// arrangements below never name one.

/// Z Mode home sections — `more.sourceId == 'zm'`, so the first section
/// repeats as a row on the phone exactly like the metadata catalogues.
HomeSection _zmSection(String title) => HomeSection(
  title: title,
  items: [_item(title)],
  more: const BrowseMore(sourceId: 'zm', kind: 'zm_home'),
);

/// CloudStream-style sections — the phone drops a non-repeating first one.
HomeSection _csSection(String title) => HomeSection(
  title: title,
  items: [_item(title)],
  more: const BrowseMore(sourceId: 'cs:Example', kind: 'cs_mainpage'),
);

MediaItem _item(String t) => MediaItem(
  id: t,
  title: t,
  cover: null,
  url: 'zm://novel/mal:1',
  type: ProviderType.novel,
  sourceId: 'zm',
);

class _StubRepo implements CatalogueRepository {
  _StubRepo(this._sections, {this.homeForSource});

  final List<HomeSection> _sections;
  final List<HomeSection> Function(String? sourceId)? homeForSource;

  /// How many times the provider was actually asked for its home.
  int homeCount = 0;
  final sourceIds = <String?>[];

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async {
    homeCount++;
    sourceIds.add(sourceId);
    return homeForSource?.call(sourceId) ?? _sections;
  }

  @override
  String get sourceId => 'test';

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeTracker implements Tracker {
  _FakeTracker({
    this.name = 'AniList',
    this.connected = true,
    List<TrackerListItem>? library,
    this.error,
  }) : library = library ?? const [];

  final String name;
  bool connected;
  final bool reading = true;
  List<TrackerListItem> library;
  Object? error;
  int fetchCount = 0;

  final _listeners = <VoidCallback>[];

  @override
  String get displayName => name;
  @override
  bool get isConnected => connected;
  @override
  bool get supportsReading => reading;
  @override
  Future<List<TrackerListItem>> fetchList() async {
    fetchCount++;
    if (error != null) throw error!;
    return library;
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
  void notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

TrackerListItem _entry(
  String title, {
  WatchStatus status = WatchStatus.watching,
  int? progress,
  int? totalEpisodes,
  int? nextAiringEpisode,
  DateTime? updatedAt,
}) => TrackerListItem(
  item: _item(title),
  status: status,
  progress: progress,
  totalEpisodes: totalEpisodes,
  nextAiringEpisode: nextAiringEpisode,
  updatedAt: updatedAt,
);

void main() {
  late Directory dir;
  const sourceMeta = LnReaderPluginMeta(
    id: 'test-source',
    name: 'Test Source',
    site: 'https://example.com',
    lang: 'en',
    version: '1.0.0',
    url: 'https://example.com/source.js',
    iconUrl: '',
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('home_cubit_rows_test');
    Hive.init(dir.path);
    await ZModePrefs.init(); // on + novel (the only mode) → 'anilist::novel'
    await HomeRowsPrefs.init();
    await Hive.openBox<Map>(LnReaderExtensionService.boxName);
    await Hive.box<Map>(
      LnReaderExtensionService.boxName,
    ).put(sourceMeta.id, {...sourceMeta.toMap(), 'js': ''});
    sl.registerSingleton<LnReaderManager>(
      LnReaderManager(
        service: LnReaderExtensionService(httpGet: (_) async => ''),
        fetch: (_, _) async => throw StateError('unexpected network call'),
      ),
    );
  });

  tearDown(() async {
    HomeRowsPrefs.revision.value = 0;
    if (sl.isRegistered<LnReaderManager>()) {
      await sl.unregister<LnReaderManager>();
    }
    await Hive.close();
    await dir.delete(recursive: true);
  });

  HomeCubit cubitWith(_FakeTracker t, {List<HomeSection> sections = const []}) =>
      HomeCubit(_StubRepo(sections), trackerHub: TrackerHub([t]));

  test('relayout re-merges a saved arrangement without refetching', () async {
    final t = _FakeTracker(library: [_entry('One Piece', progress: 100)]);
    final repo = _StubRepo([_zmSection('Trending'), _zmSection('Popular')]);
    final cubit = HomeCubit(repo, trackerHub: TrackerHub([t]));
    addTearDown(cubit.close);

    await cubit.load();
    expect(repo.homeCount, 1);
    expect(cubit.state.rows?.map((r) => r.id), [
      'local:continue',
      'section:Test Source · Trending',
      'section:Test Source · Popular',
    ]);

    // What the editor does: save an arrangement, then let the revision bump
    // land. Hiding a section and surfacing a tracker row must both show up.
    await HomeRowsPrefs.save('anilist::novel', [
      'tracker:watching',
      'local:continue',
      '!section:Test Source · Trending',
      'section:Test Source · Popular',
    ]);
    cubit.relayout();

    expect(cubit.state.rows?.map((r) => r.id), [
      'tracker:watching',
      'local:continue',
      'section:Test Source · Popular',
    ]);
    // The point of relayout: no second provider round trip, and the cached
    // library serves the tracker row rather than a second list read.
    expect(repo.homeCount, 1);
    expect(t.fetchCount, 1);
  });

  test('relayout before the first load is a no-op, not a crash', () {
    final t = _FakeTracker();
    final repo = _StubRepo([_zmSection('Trending')]);
    final cubit = HomeCubit(repo, trackerHub: TrackerHub([t]));
    addTearDown(cubit.close);

    cubit.relayout();

    expect(cubit.state.rows, isNull);
    expect(repo.homeCount, 0);
  });

  test('loads every installed novel source and each non-empty feed', () async {
    const secondSource = LnReaderPluginMeta(
      id: 'second-source',
      name: 'Second Source',
      site: 'https://second.example.com',
      lang: 'en',
      version: '1.0.0',
      url: 'https://second.example.com/source.js',
      iconUrl: '',
    );
    await Hive.box<Map>(
      LnReaderExtensionService.boxName,
    ).put(secondSource.id, {...secondSource.toMap(), 'js': ''});
    final repo = _StubRepo(
      const [],
      homeForSource: (sourceId) => [
        HomeSection(
          title: 'Popular',
          items: [_item('Popular')],
          more: BrowseMore(sourceId: sourceId!, kind: 'popular'),
        ),
        HomeSection(
          title: 'Latest',
          items: [_item('Latest')],
          more: BrowseMore(sourceId: sourceId, kind: 'latest'),
        ),
      ],
    );
    final cubit = HomeCubit(repo);
    addTearDown(cubit.close);

    await cubit.load();

    expect(repo.sourceIds, ['lnr:second-source', 'lnr:test-source']);
    expect(cubit.state.sections?.map((section) => section.title), [
      'Second Source · Popular',
      'Second Source · Latest',
      'Test Source · Popular',
      'Test Source · Latest',
    ]);
    expect(cubit.state.sections!.map((section) => section.more!.sourceId), [
      'lnr:second-source',
      'lnr:second-source',
      'lnr:test-source',
      'lnr:test-source',
    ]);
  });

  test('no installed novel sources never fetch the AniList catalogue', () async {
    await Hive.box<Map>(LnReaderExtensionService.boxName).clear();
    final repo = _StubRepo([_zmSection('Trending')]);
    final cubit = HomeCubit(repo);
    addTearDown(cubit.close);

    await cubit.load();

    expect(repo.homeCount, 0);
    expect(cubit.state.sections, isEmpty);
    expect(cubit.state.heroItems, isEmpty);
  });

  test('refreshes Home when a novel source is installed', () async {
    final repo = _StubRepo([_zmSection('Popular')]);
    final cubit = HomeCubit(repo)..bindInstalledNovelSources();
    addTearDown(cubit.close);

    await cubit.load();
    expect(repo.homeCount, 1);

    await Hive.box<Map>(LnReaderExtensionService.boxName).put('new-source', {
      'id': 'new-source',
      'name': 'New Source',
      'site': 'https://new.example.com',
      'lang': 'en',
      'version': '1.0.0',
      'url': 'https://new.example.com/source.js',
      'iconUrl': '',
      'js': '',
    });
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(repo.homeCount, 3);
    expect(cubit.state.sections?.map((section) => section.title), [
      'New Source · Popular',
      'Test Source · Popular',
    ]);
  });

  test('DEFAULT: tracker data fetched but no tracker row renders', () async {
    final t = _FakeTracker(library: [_entry('One Piece', progress: 100)]);
    final cubit = cubitWith(t, sections: [_zmSection('Trending'), _zmSection('Popular')]);
    addTearDown(cubit.close);

    await cubit.load();

    expect(t.fetchCount, 1); // the library WAS read…
    expect(cubit.state.rows?.map((r) => r.id), [
      'local:continue', // …but the default arrangement hides every tracker row
      'section:Test Source · Trending',
      'section:Test Source · Popular',
    ]);
    expect(cubit.state.rows!.any((r) => isTrackerRowId(r.id)), isFalse);
  });

  test('enabled rows render at the saved spot with the tracker bucketed', () async {
    final t = _FakeTracker(
      library: [
        _entry('One Piece', progress: 100, updatedAt: DateTime(2026, 9, 1)),
        _entry('Bleach', progress: 3, updatedAt: DateTime(2026, 8, 1)),
        _entry('Naruto', status: WatchStatus.planning),
        _entry('Cowboy Bebop', status: WatchStatus.paused, progress: 5),
      ],
    );
    await HomeRowsPrefs.save('anilist::novel', [
      'tracker:continue',
      'tracker:watching',
      'local:continue',
      'section:Test Source · Trending',
      'section:Test Source · Popular',
    ]);
    final cubit = cubitWith(t, sections: [_zmSection('Trending'), _zmSection('Popular')]);
    addTearDown(cubit.close);

    await cubit.load();

    expect(cubit.state.rows?.map((r) => r.id), [
      'tracker:continue',
      'tracker:watching',
      'local:continue',
      'section:Test Source · Trending',
      'section:Test Source · Popular',
    ]);
    final continueRow = cubit.state.rows![0] as TrackerContinueHomeRow;
    expect(continueRow.trackerName, 'AniList');
    // Most recently updated first, and only the entries actually in progress.
    expect(continueRow.items.map((e) => e.item.title), ['One Piece', 'Bleach']);
    final watching = cubit.state.rows![1] as TrackerListHomeRow;
    expect(watching.items.length, 2);
    // A reading layout has no new-episodes row at all — `trackerRowIdsFor`
    // leaves it out of both the available ids and the default arrangement, so
    // it can never be built, enabled or saved.
    expect(cubit.state.rows!.any((r) => r.id == 'tracker:new-episodes'), isFalse);
  });

  test('a tracker that throws degrades to provider-only rows', () async {
    final t = _FakeTracker(error: Exception('offline'));
    final cubit = cubitWith(t, sections: [_zmSection('Trending')]);
    addTearDown(cubit.close);

    await cubit.load();

    expect(cubit.state.rows?.map((r) => r.id), [
      'local:continue',
      'section:Test Source · Trending',
    ]);
    expect(cubit.state.sections?.length, 1); // the provider load itself lived
  });

  test('a reset load re-reads the library, not the cached parse', () async {
    // The cache holds PARSED items — titles included — so a reset (source,
    // provider, or title-language change) has to drop it or the rows keep the
    // old spelling.
    final t = _FakeTracker(library: [_entry('One Piece', progress: 1)]);
    await HomeRowsPrefs.save('anilist::novel', [
      'tracker:continue',
      'local:continue',
      'section:Test Source · Trending',
    ]);
    final cubit = cubitWith(t, sections: [_zmSection('Trending')]);
    addTearDown(cubit.close);

    await cubit.load();
    expect(t.fetchCount, 1);

    await cubit.load(); // ordinary revisit still uses the cache
    expect(t.fetchCount, 1);

    await cubit.load(reset: true);
    expect(t.fetchCount, 2);
  });

  test('the library is cached: a second load does not re-fetch', () async {
    final t = _FakeTracker(library: [_entry('One Piece', progress: 1)]);
    final cubit = cubitWith(t, sections: [_zmSection('Trending')]);
    addTearDown(cubit.close);

    await cubit.load();
    final firstRows = cubit.state.rows;
    await cubit.load();

    expect(t.fetchCount, 1);
    expect(cubit.state.rows?.map((r) => r.id), firstRows?.map((r) => r.id));
  });

  test('a source-backed home keeps the phone first-drop rule and never asks a tracker', () async {
    await ZModePrefs.setEnabled(false);
    final t = _FakeTracker(library: [_entry('One Piece', progress: 1)]);
    final cubit = cubitWith(t, sections: [
      _csSection('Featured'),
      _csSection('Latest'),
      _csSection('Popular'),
    ]);
    addTearDown(cubit.close);

    await cubit.load();

    expect(t.fetchCount, 0); // no Z Mode kind → no tracker read at all
    expect(cubit.state.rows?.map((r) => r.id), [
      'local:continue',
      'section:Test Source · Latest', // Featured fed the banner and was dropped.
      'section:Test Source · Popular',
    ]);
  });

  test('the FIRST connected tracker in hub order answers', () async {
    final anilist = _FakeTracker(name: 'AniList', library: [
      _entry('One Piece', progress: 1),
    ]);
    final mal = _FakeTracker(name: 'MyAnimeList', library: [
      _entry('Naruto', progress: 1),
    ]);
    await HomeRowsPrefs.save('anilist::novel', [
      'tracker:continue',
      'local:continue',
      'section:Test Source · Trending',
    ]);
    final cubit = HomeCubit(
      _StubRepo([_zmSection('Trending')]),
      trackerHub: TrackerHub([anilist, mal]),
    );
    addTearDown(cubit.close);

    await cubit.load();

    expect(anilist.fetchCount, 1);
    expect(mal.fetchCount, 0);
    final row = cubit.state.rows!.first as TrackerContinueHomeRow;
    expect(row.trackerName, 'AniList');
    expect(row.items.single.item.title, 'One Piece');
  });

  test('the layout provider decides which tracker answers', () async {
    final anilist = _FakeTracker(name: 'AniList', library: [
      _entry('One Piece', progress: 1),
    ]);
    final mal = _FakeTracker(name: 'MyAnimeList', library: [
      _entry('Naruto', progress: 1),
    ]);
    // The MAL metadata provider makes the novel layout 'mal::novel' (the
    // provider pref is still the anime/manga/novel one), and a layout's
    // provider is the tracker behind its list rows — one choice, not a
    // separate account setting to keep in sync.
    final prefs = await MetadataProviderPrefs.open();
    await prefs.setAnime(AnimeProvider.mal);
    sl.registerSingleton<MetadataProviderPrefs>(prefs);
    addTearDown(() => sl.unregister<MetadataProviderPrefs>());

    await HomeRowsPrefs.save('mal::novel', [
      'tracker:continue',
      'local:continue',
      'section:Test Source · Trending',
    ]);
    final cubit = HomeCubit(
      _StubRepo([_zmSection('Trending')]),
      trackerHub: TrackerHub([anilist, mal]),
    );
    addTearDown(cubit.close);

    await cubit.load();

    // AniList is first in hub order and never even read.
    expect(anilist.fetchCount, 0);
    expect(mal.fetchCount, 1);
    final row = cubit.state.rows!.first as TrackerContinueHomeRow;
    expect(row.trackerName, 'MyAnimeList');
    expect(row.items.single.item.title, 'Naruto');
  });

  test('a provider you are not signed into yields no tracker rows', () async {
    // The layout is AniList's and AniList isn't connected. MAL's library is
    // not a substitute — the row would carry the wrong account's name.
    final anilist = _FakeTracker(name: 'AniList', connected: false);
    final mal = _FakeTracker(name: 'MyAnimeList', library: [
      _entry('Naruto', progress: 1),
    ]);
    await HomeRowsPrefs.save('anilist::novel', [
      'tracker:continue',
      'local:continue',
      'section:Test Source · Trending',
    ]);
    final cubit = HomeCubit(
      _StubRepo([_zmSection('Trending')]),
      trackerHub: TrackerHub([anilist, mal]),
    );
    addTearDown(cubit.close);

    await cubit.load();

    expect(mal.fetchCount, 0);
    expect(cubit.state.rows!.any((r) => isTrackerRowId(r.id)), isFalse);
    expect(cubit.state.rows?.map((r) => r.id), [
      'local:continue',
      'section:Test Source · Trending',
    ]);
  });

  test('a tracker disconnecting re-merges without its rows', () async {
    final t = _FakeTracker(library: [_entry('One Piece', progress: 1)]);
    await HomeRowsPrefs.save('anilist::novel', [
      'tracker:continue',
      'local:continue',
      'section:Test Source · Trending',
    ]);
    final cubit = cubitWith(t, sections: [_zmSection('Trending')]);
    addTearDown(cubit.close);

    await cubit.load();
    expect(cubit.state.rows!.first, isA<TrackerContinueHomeRow>());

    t.connected = false;
    t.notify();
    await pumpEventQueue();

    expect(cubit.state.rows?.map((r) => r.id), [
      'local:continue',
      'section:Test Source · Trending',
    ]);
  });
}
