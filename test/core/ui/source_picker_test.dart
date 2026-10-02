import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/ui/source_switcher.dart';
import 'package:watch_app/features/sources/zangetsu_sources_screen.dart';

// ---------------------------------------------------------------------------
// Stubs (same shape as test/features/sources/mode_filtered_sources_test.dart)
// ---------------------------------------------------------------------------

class _FakeManager implements ProviderRuntimeLoader {
  @override
  JsProvider? get(String id) => null;
  @override
  Future<void> load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) async {}
  @override
  void setSettings(String sourceId, Map<String, dynamic> settings) {}
  @override
  void remove(String id) {}
}

class _FakeFetcher implements ProviderJsFetcher {
  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async =>
      CachedProvider(name: name, jsCode: '', url: url, fetchedAt: DateTime.now());
  @override
  Future<void> remove(String name) async {}
}

Future<void> _seedJsSource({
  required String id,
  required String type,
  String repoUrl = 'https://example.com/repo/index.json',
}) async {
  final reposBox = Hive.box<Map>(ProviderReposRegistry.boxName);
  final existingRaw = reposBox.get(repoUrl);
  final existingSources = existingRaw == null
      ? const <RepoSource>[]
      : ProviderRepo.fromJson(Map<String, dynamic>.from(existingRaw)).sources;
  final repo = ProviderRepo(
    url: repoUrl,
    name: 'Test Repo',
    description: '',
    lastSyncedAt: DateTime.now(),
    sources: [
      ...existingSources,
      RepoSource(id: id, name: id, version: '1.0.0', type: type, lang: 'en', file: '$id.js'),
    ],
  );
  await reposBox.put(repoUrl, repo.toJson());

  final regBox = Hive.box<Map>(ProviderRegistry.boxName);
  final entry = ProviderRegistryEntry(
    name: id,
    url: '$repoUrl/$id.js',
    originRepoUrl: repoUrl,
    displayName: id,
  );
  await regBox.put(ProviderRegistry.providerKey(repoUrl, id), entry.toJson());
}

void main() {
  late Directory tempDir;
  late ActiveSourceCubit activeSource;
  late ContentModeCubit modeCubit;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('source_picker_test');
    Hive.init(tempDir.path);
    await ProviderRegistry.init();
    await ProviderReposRegistry.init();
    await PlaybackPrefs.init();
    await CloudStreamManager.init();

    sl.registerSingleton<ProviderRegistry>(
      ProviderRegistry(
        downloader: _FakeFetcher(),
        manager: _FakeManager(),
        repos: ProviderReposRegistry(dio: Dio()),
      ),
    );
    sl.registerSingleton<ProviderReposRegistry>(ProviderReposRegistry(dio: Dio()));
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
    sl.registerSingleton<AniyomiManager>(AniyomiManager());
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));

    activeSource = ActiveSourceCubit();
    modeCubit = await ContentModeCubit.create(activeSource);
    sl.registerSingleton<ActiveSourceCubit>(activeSource);
    sl.registerSingleton<ContentModeCubit>(modeCubit);
  });

  tearDown(() async {
    await modeCubit.close();
    await activeSource.close();
    await sl.reset();
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpSwitcher(WidgetTester tester, {String currentId = 'js:a'}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => SourceSwitcher(
              currentId: currentId,
              onChanged: (_) {},
              onInstallSources: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ZangetsuSourcesScreen(openToRepos: true),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(SourceSwitcher));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'novel mode regression: tabs are exactly All/Novel, the novel row shows '
    'and no video rows leak in',
    (tester) async {
      // Real Hive I/O — even properly-awaited writes need runAsync under the
      // automated (pump-driven) testWidgets binding, or they never actually
      // land (same class of issue as mode_switcher_test.dart's setMode note).
      await tester.runAsync(() async {
        await _seedJsSource(id: 'js:n', type: 'novel');
        await _seedJsSource(id: 'js:a', type: 'anime');
        await _seedJsSource(id: 'js:mv', type: 'movie');
      });

      await pumpSwitcher(tester, currentId: 'js:n');

      // A reading mode gets All + its own single bucket. The video tabs
      // (Zangetsu/CloudStream/Aniyomi, NSFW) and the Manga tab are gone
      // rather than left empty, and nothing of theirs is listed under All.
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Novel'), findsOneWidget);
      expect(find.text('Anime'), findsNothing);
      expect(find.text('Movies/Series'), findsNothing);
      expect(find.text('NSFW'), findsNothing);
      expect(find.text('Manga'), findsNothing);

      // "All" tab is the default. findsWidgets (not findsOneWidget): the pill
      // itself also shows the current source's name ('js:n'), so that one
      // legitimately matches twice.
      expect(find.text('js:n'), findsWidgets);
      expect(find.text('js:a'), findsNothing);
      expect(find.text('js:mv'), findsNothing);
    },
  );

  testWidgets(
    'novel mode, nothing installed: tabs are All/Novel only, empty state '
    'shows an install CTA that opens ZangetsuSourcesScreen on Repositories',
    (tester) async {
      // No setMode() to await here: the cubit boots into Novel on its own
      // (ContentModeCubit._restore ignores the persisted mode) and refuses to
      // leave it, which is exactly the state this case is about.
      await pumpSwitcher(tester);

      expect(find.text('All'), findsOneWidget);
      expect(find.text('Novel'), findsOneWidget);
      expect(find.text('Anime'), findsNothing);
      expect(find.text('Movies/Series'), findsNothing);
      expect(find.text('NSFW'), findsNothing);
      expect(find.text('Manga'), findsNothing);

      expect(find.text('No Novel sources yet'), findsOneWidget);
      final ctaButton = find.widgetWithText(FilledButton, 'Browse repositories');
      expect(ctaButton, findsOneWidget);

      await tester.tap(ctaButton);
      await tester.pumpAndSettle();

      final screen = tester.widget<ZangetsuSourcesScreen>(find.byType(ZangetsuSourcesScreen));
      expect(screen.openToRepos, isTrue);
    },
  );

  testWidgets(
    'novel mode with a novel source installed: row shows, no install CTA',
    (tester) async {
      // Real Hive I/O — see the comment on the first test above.
      await tester.runAsync(() async {
        await _seedJsSource(id: 'js:n', type: 'novel');
      });

      await pumpSwitcher(tester, currentId: 'js:n');

      // findsWidgets: the pill itself also shows the current source's name.
      expect(find.text('js:n'), findsWidgets);
      expect(find.text('No Novel sources yet'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Browse repositories'), findsNothing);
    },
  );
}
