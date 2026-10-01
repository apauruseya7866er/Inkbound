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
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/torrent/torrent_prefs.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/locale/locale_controller.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

// ── Minimal stubs (mirrors settings_screen_tv_test.dart / AppMode wiring) ────

class _StubSearchPrefs extends SearchPrefs {
  @override
  SearchLayout get layout => SearchLayout.vertical;
}

class _StubProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRegistryEntry> getAll() => const [];

  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;

  @override
  Set<String> nsfwSourceIds() => const {};
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

void _mockPathProvider(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => '/tmp/test',
  );
}

void main() {
  late ActiveSourceCubit activeCubit;
  late Directory _hiveDir;

  setUp(() async {
    _hiveDir = await Directory.systemTemp.createTemp();
    Hive.init(_hiveDir.path);
    await Hive.openBox(DownloadPrefs.boxName);
    await Hive.openBox(TorrentPrefs.boxName);
    await Hive.openBox(ThemeController.boxName);
    await Hive.openBox(LocaleController.boxName);
    await LocaleController.init();
    await Hive.openBox(PlaybackPrefs.boxName);
    await ReaderPrefs.init();
    final sl = GetIt.instance;
    sl
      ..registerSingleton<AppMode>(AppMode(isTv: false))
      ..registerSingleton<SearchPrefs>(_StubSearchPrefs())
      ..registerSingleton<ProviderRegistry>(_StubProviderRegistry())
      ..registerSingleton<AniListService>(_StubAniList())
      ..registerSingleton<MalService>(_StubMal())
      ..registerSingleton<SimklService>(_StubSimkl())
      ..registerSingleton<PlaybackPrefs>(PlaybackPrefs())
      ..registerSingleton<DownloadPrefs>(DownloadPrefs())
      ..registerSingleton<TorrentPrefs>(TorrentPrefs())
      ..registerSingleton<ReaderPrefs>(ReaderPrefs());
    activeCubit = ActiveSourceCubit();
  });

  tearDown(() async {
    await activeCubit.close();
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (_hiveDir.existsSync()) await _hiveDir.delete(recursive: true);
  });

  Future<void> _pumpSettings(WidgetTester tester) async {
    _mockPathProvider(tester);
    await tester.binding.setSurfaceSize(const Size(1000, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      BlocProvider<ActiveSourceCubit>.value(
        value: activeCubit,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('top level shows one tappable row per section, not the tiles',
      (tester) async {
    await _pumpSettings(tester);

    // Each section is now a single drill-down row.
    for (final section in const [
      'Account & sync',
      'Sources',
      'Downloads',
      'Interface',
      'Advanced',
      'About',
    ]) {
      expect(find.text(section), findsOneWidget, reason: 'category: $section');
    }
    // Novel-only build: Playback is gone. Every row in it (quality, autoplay,
    // speed, decoder, audio/subtitle defaults, resume) drives the MPV player,
    // which this build has no route to — so the whole category is hidden rather
    // than relabelled.
    expect(find.text('Playback'), findsNothing);
    // Notifications is Android-only (its sole entry), so its category is absent
    // on the non-Android test host.
    expect(find.text('Notifications'), findsNothing);
    // The individual settings live INSIDE their section now, not up top.
    expect(find.text('Providers'), findsNothing);
    expect(find.text('Storage'), findsNothing);
    expect(find.text('Backup & Restore'), findsNothing);
  });

  testWidgets('tapping a category drills into its settings', (tester) async {
    await _pumpSettings(tester);

    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();

    // The Sources section's tiles are now on screen.
    for (final t in const ['Providers', 'Source health']) {
      expect(find.text(t), findsOneWidget, reason: 'tile: $t');
    }
    expect(find.text('Active source'), findsNothing);
    // Other sections' rows are gone (we're on the Sources sub-page).
    expect(find.text('Downloads'), findsNothing);
    expect(find.text('About'), findsNothing);
  });

  test(
    'Android Player is marked experimental in the player settings label',
    () {
      final l10n = lookupAppLocalizations(const Locale('en'));

      expect(l10n.androidPlayer, 'Android Player (Experimental)');
    },
  );

  testWidgets('Reading section has a Reader entry that opens reader defaults',
      (tester) async {
    await _pumpSettings(tester);

    await tester.tap(find.text('Reading'));
    await tester.pumpAndSettle();
    expect(find.text('Reader'), findsOneWidget);

    await tester.tap(find.text('Reader'));
    await tester.pumpAndSettle();

    // Novel-only build: the page used to open on a "MANGA" section of
    // page-image prefs. What's left is the shared pair (Keep Screen On,
    // Fullscreen) under a generic "READING" header, then the Novel section.
    // The header is "READING", not "READER" — `l10n.reader` would print
    // "READER" directly under the app bar, which already reads "Reader".
    expect(find.text('READING'), findsOneWidget);
    expect(find.text('NOVEL'), findsOneWidget);
    // The Manga section header is gone with the page-image prefs it headed.
    expect(find.text('MANGA'), findsNothing);
  });

  testWidgets('search cuts across every section (flat filtered list)',
      (tester) async {
    await _pumpSettings(tester);

    await tester.enterText(find.byType(TextField), 'backup');
    await tester.pumpAndSettle();

    // The matching tile surfaces regardless of its section…
    expect(find.text('Backup & Restore'), findsOneWidget);
    // …and non-matching tiles/categories are filtered out.
    expect(find.text('Providers'), findsNothing);
    expect(find.text('Sources'), findsNothing);
  });
}
