// Task E3 originally gave manga/novel sources their own "Zangetsu Manga" hub
// row and a "Manga & Novel" Settings entry. BOTH were later removed —
// (and the Sozo Read recommended-repo suggestion, tested elsewhere) was
// dropped: that Zangetsu JS reading-source row duplicated the still-live
// Settings entry, and those JS sources are search-only (no popular/latest),
// so selecting one left Home with nothing to render. The Settings entry
// itself is unaffected and still opens the same scoped Zangetsu screen.
//
// What's under test now:
//  - ProvidersHubScreen (phone view) has no "Zangetsu Manga" row / section —
//    the ACTIVE-badge exclusivity rule (a source active under the Zangetsu
//    ecosystem must not badge a row it doesn't belong to) still holds.
//  - Settings → Sources no longer has a "Manga & Novel" entry.
//  - ZangetsuSourcesScreen itself, scoped to reading providers and unscoped.
//
// Novel-only build: the Zangetsu streaming row and its whole STREAMING section
// are gone too — the hub's only ecosystem is LNReader under a "NOVEL" header,
// and the header total is the novel source count. So the cases that read the
// Zangetsu row's title or count are deleted rather than re-pointed (there is no
// row left to read), the badge rule is re-pointed at the rule that survives
// (only an `lnr:` novel extension badges a hub row), and the unscoped screen is
// pushed directly instead of through the hub row that used to open it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/torrent/torrent_prefs.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/features/sources/providers_hub_screen.dart';
import 'package:watch_app/features/sources/zangetsu_sources_screen.dart';

// ---------------------------------------------------------------------------
// Shared fakes
// ---------------------------------------------------------------------------

/// Fixed installed-entries + manifest-type lookup, so reading (manga/novel)
/// vs. video (anime/movie) counts are deterministic without wiring up a real
/// cached repo manifest.
class _FakeProviderRegistry implements ProviderRegistry {
  _FakeProviderRegistry(this._entries, this._types);
  final List<ProviderRegistryEntry> _entries;
  final Map<String, String> _types;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRegistryEntry> getAll() => _entries;

  @override
  ProviderRegistryEntry? entryFor(String sourceId) {
    for (final e in _entries) {
      if (e.name == sourceId) return e;
    }
    return null;
  }

  @override
  Set<String> nsfwSourceIds() => const {};

  @override
  String? typeOf(String sourceId) => _types[sourceId];

  // SourcesBloc (built when ZangetsuSourcesScreen is pushed) subscribes to
  // this on construction.
  @override
  Stream<BoxEvent> watch() => const Stream<BoxEvent>.empty();
}

class _FakeReposRegistry implements ProviderReposRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRepo> getAll() => const [];

  @override
  Stream<BoxEvent> watch() => const Stream<BoxEvent>.empty();
}

void main() {
  final sl = GetIt.instance;

  // ── ProvidersHubScreen (phone) ──────────────────────────────────────────
  group('ProvidersHubScreen phone view', () {
    setUp(() {
      final entries = [
        ProviderRegistryEntry(
          name: 'anime1',
          url: 'bundled://anime1',
          displayName: 'Anime One',
        ),
        ProviderRegistryEntry(
          name: 'manga1',
          url: 'bundled://manga1',
          displayName: 'Manga One',
        ),
        ProviderRegistryEntry(
          name: 'novel1',
          url: 'bundled://novel1',
          displayName: 'Novel One',
        ),
      ];
      final types = {'anime1': 'anime', 'manga1': 'manga', 'novel1': 'novel'};

      sl
        ..registerSingleton<AppMode>(const AppMode(isTv: false))
        ..registerSingleton<ProviderRegistry>(
          _FakeProviderRegistry(entries, types),
        )
        ..registerSingleton<ProviderReposRegistry>(_FakeReposRegistry())
        ..registerSingleton<CloudStreamManager>(CloudStreamManager())
        ..registerSingleton<AniyomiManager>(AniyomiManager())
        ..registerSingleton<MihonManager>(MihonManager())
        ..registerSingleton<ActiveSourceCubit>(ActiveSourceCubit(fallback: ''));
    });

    tearDown(() async {
      await sl.reset();
    });

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: ProvidersHubScreen()));
      await tester.pumpAndSettle();
    }

    // The dedicated "Zangetsu Manga" hub row and its MANGA & NOVEL section
    // are gone — those JS reading sources are search-only, so selecting one
    // left Home with nothing to render. Reading sources are still reachable
    // through Settings → Manga & Novel (unaffected, tested elsewhere), just
    // not from this hub. Inverse assertion so the row can't silently
    // reappear.
    testWidgets('has no Zangetsu Manga row or MANGA & NOVEL section',
        (tester) async {
      await pump(tester);

      expect(find.text('Zangetsu Manga'), findsNothing);
      expect(find.text('MANGA & NOVEL'), findsNothing);
    });

    testWidgets(
      'CloudStream and Aniyomi rows are unaffected — still Android-gated, '
      'absent on this (non-Android) test host, same as before',
      (tester) async {
        await pump(tester);

        expect(find.text('CloudStream'), findsNothing);
        expect(find.text('Aniyomi'), findsNothing);
      },
    );

    // Novel-only build: with the Zangetsu streaming row gone, the badge
    // exclusivity rule it used to be about has no row to land on. What
    // survives is the discipline behind it — a row badges for its own prefix
    // only, and the LNReader row (the one that badges for `lnr:` ids) is
    // pinned in lnreader_hub_entry_test.dart. What belongs here is that a
    // Zangetsu JS provider, the only other source kind this build loads, is
    // never badged: it IS the active source and nothing claims it.
    testWidgets(
      'a Zangetsu JS source active badges no row (only novel extensions do)',
      (tester) async {
        sl.unregister<ActiveSourceCubit>();
        sl.registerSingleton<ActiveSourceCubit>(
          ActiveSourceCubit(fallback: 'novel1'),
        );
        await pump(tester);

        expect(find.text('ACTIVE'), findsNothing);
        expect(find.textContaining('Active: Novel One'), findsOneWidget);
      },
    );

    // scopeToReading is still live production behavior of
    // ZangetsuSourcesScreen — the JS screen itself is very much alive in this
    // build (it's where a Zangetsu novel provider is installed and picked, from
    // the detail screen's source switch, search and the home overflow). The
    // flag has no caller of its own since the Settings → Manga & Novel entry
    // went, so its filter is pinned here directly.
    testWidgets(
      'ZangetsuSourcesScreen(scopeToReading: true) scopes the Installed tab '
      'to reading providers, with a Show all escape hatch back to everything',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: ZangetsuSourcesScreen(scopeToReading: true),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Manga One'), findsOneWidget);
        expect(find.text('Novel One'), findsOneWidget);
        // Anime provider is hidden by default — this is the actual "different
        // from streaming mode" the user asked for, not just a different tile.
        expect(find.text('Anime One'), findsNothing);

        // The user can still always reach everything.
        final showAll = find.text('Show all');
        expect(showAll, findsOneWidget);
        await tester.tap(showAll);
        await tester.pumpAndSettle();

        expect(find.text('Anime One'), findsOneWidget);
        expect(find.text('Manga One'), findsOneWidget);
        expect(find.text('Novel One'), findsOneWidget);
      },
    );

    // Novel-only build: the hub no longer lists Zangetsu at all, so the
    // unscoped screen is pushed directly rather than through a row that isn't
    // there. What it shows is unchanged: every provider, no scoping UI.
    testWidgets(
      'ZangetsuSourcesScreen unscoped shows every provider, no scoping UI',
      (tester) async {
        await tester.pumpWidget(const MaterialApp(home: ZangetsuSourcesScreen()));
        await tester.pumpAndSettle();

        expect(find.text('Anime One'), findsOneWidget);
        expect(find.text('Manga One'), findsOneWidget);
        expect(find.text('Novel One'), findsOneWidget);
        expect(find.text('Show all'), findsNothing);
      },
    );
  });

  // ── Settings → Sources ──────────────────────────────────────────────────
  group('Settings Sources section', () {
    late ActiveSourceCubit activeCubit;
    late Directory hiveDir;

    setUp(() async {
      hiveDir = await Directory.systemTemp.createTemp();
      Hive.init(hiveDir.path);
      await Hive.openBox(DownloadPrefs.boxName);
      await Hive.openBox(TorrentPrefs.boxName);
      await Hive.openBox(ThemeController.boxName);
      await Hive.openBox(PlaybackPrefs.boxName);
      sl
        ..registerSingleton<AppMode>(const AppMode(isTv: false))
        ..registerSingleton<SearchPrefs>(_StubSearchPrefs())
        ..registerSingleton<ProviderRegistry>(_FakeProviderRegistry(
          [
            ProviderRegistryEntry(name: 'manga1', url: 'bundled://manga1'),
          ],
          {'manga1': 'manga'},
        ))
        ..registerSingleton<AniListService>(_StubAniList())
        ..registerSingleton<MalService>(_StubMal())
        ..registerSingleton<SimklService>(_StubSimkl())
        ..registerSingleton<PlaybackPrefs>(PlaybackPrefs())
        ..registerSingleton<DownloadPrefs>(DownloadPrefs())
        ..registerSingleton<TorrentPrefs>(TorrentPrefs());
      activeCubit = ActiveSourceCubit();
    });

    tearDown(() async {
      await activeCubit.close();
      await GetIt.instance.reset();
      await Hive.deleteFromDisk();
      if (hiveDir.existsSync()) await hiveDir.delete(recursive: true);
    });

    Future<void> pumpSettings(WidgetTester tester) async {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => '/tmp/test',
      );
      await tester.binding.setSurfaceSize(const Size(1000, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        BlocProvider<ActiveSourceCubit>.value(
          value: activeCubit,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'the Sources section keeps its entries and has NO Manga & Novel row',
      (tester) async {
        await pumpSettings(tester);

        await tester.tap(find.text('Sources'));
        await tester.pumpAndSettle();

        // The reading entry was dropped along with the providers-hub row —
        // those JS sources are search-only, so Home had nothing to render.
        // Manga lives under Providers -> Mihon. Asserting its ABSENCE stops it
        // silently returning.
        expect(find.text('Manga & Novel'), findsNothing);

        for (final t in const [
          'Providers',
          'Source health',
        ]) {
          expect(find.text(t), findsOneWidget, reason: 'tile: $t');
        }
        expect(find.text('Active source'), findsNothing);
        // Auto-update extensions is Android-only (Platform.isAndroid).
        expect(find.text('Auto-update extensions'), findsNothing);

        // The surviving entries keep their original relative order.
        final providersY = tester.getTopLeft(find.text('Providers')).dy;
        final healthY = tester.getTopLeft(find.text('Source health')).dy;
        expect(providersY, lessThan(healthY));
      },
    );

    testWidgets('searching "manga" surfaces no reading Settings entry',
        (tester) async {
      await pumpSettings(tester);

      await tester.enterText(find.byType(TextField), 'manga');
      await tester.pumpAndSettle();

      expect(find.text('Manga & Novel'), findsNothing);
    });
  });
}

class _StubSearchPrefs extends SearchPrefs {
  @override
  SearchLayout get layout => SearchLayout.vertical;
}

class _StubAniList implements AniListService {
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubMal implements MalService {
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubSimkl implements SimklService {
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
