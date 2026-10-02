// Task M8b: Mihon (manga extensions) got a 4th hub row, mirroring how
// CloudStream/Aniyomi already work — Android-gated, live-updating counts.
//
// Platform.isAndroid can't be faked in `flutter test` (it reports false on
// the host running these tests — the same observation
// `lib/core/mihon/mihon_provider.dart`'s doc comment makes about the channel
// calls), so this file never exercised the row's on-Android appearance. What it
// did pin was that a Mihon source stays invisible everywhere it shouldn't show
// up: off-Android, in the TV view, in the Zangetsu row's count, in the header
// total, and as an ACTIVE badge.
//
// Novel-only build: Mihon is never registered (its boot step in injector.dart
// returns early), so the row isn't merely hidden off-Android — it is gone, and
// so is the Zangetsu streaming row it used to be counted against. The two cases
// that asserted "a Mihon source doesn't leak into the Zangetsu row's count" and
// "…nor into the header total" died with those rows: the `showMihon ? x : 0`
// guards they pinned no longer have a row to hide a count from. What is still
// true — and what the remaining cases pin — is that a registered Mihon source
// surfaces nowhere: no row on the phone, none on TV, and no ACTIVE badge from a
// `mihon:` active id.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/mihon/mihon_provider.dart';
import 'package:watch_app/core/mihon/mihon_source_info.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/sources/providers_hub_screen.dart';

// ---------------------------------------------------------------------------
// Fakes — same shape as manga_novel_hub_entry_test.dart's (private to that
// file, so re-declared here rather than shared).
// ---------------------------------------------------------------------------

class _FakeProviderRegistry implements ProviderRegistry {
  _FakeProviderRegistry(this._entries);
  final List<ProviderRegistryEntry> _entries;

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
  String? typeOf(String sourceId) => null;

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

MihonProvider _mihonSrc(int id, String name) => MihonProvider(
      info: MihonSourceInfo(
        id: id,
        name: name,
        lang: 'en',
        baseUrl: '',
        pkg: 'p.$id',
        nsfw: false,
      ),
    );

void main() {
  final sl = GetIt.instance;

  setUp(() {
    final entries = [
      ProviderRegistryEntry(
        name: 'anime1',
        url: 'bundled://anime1',
        displayName: 'Anime One',
      ),
      ProviderRegistryEntry(
        name: 'anime2',
        url: 'bundled://anime2',
        displayName: 'Anime Two',
      ),
    ];
    sl
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<ProviderRegistry>(_FakeProviderRegistry(entries))
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

  testWidgets(
    'Mihon row stays absent off-Android, same as CloudStream/Aniyomi',
    (tester) async {
      await pump(tester);

      expect(find.text('Mihon'), findsNothing);
      expect(find.text('CloudStream'), findsNothing);
      expect(find.text('Aniyomi'), findsNothing);
    },
  );

  testWidgets(
    'the TV hub view never renders a Mihon row — the hub row is phone-only '
    'by spec, and _HubTvView was not touched by this task',
    (tester) async {
      sl.unregister<AppMode>();
      sl.registerSingleton<AppMode>(const AppMode(isTv: true));
      sl<MihonManager>().register(_mihonSrc(1, 'Manga One'));

      await pump(tester);

      expect(find.text('Mihon'), findsNothing);
      // Sanity: this really did render the TV view, not silently fall back
      // to the phone view.
      expect(find.text('Providers'), findsOneWidget);
    },
  );

  testWidgets(
    'a mihon: active id does not badge any row as ACTIVE',
    (tester) async {
      sl<MihonManager>().register(_mihonSrc(1, 'Manga One'));
      sl.unregister<ActiveSourceCubit>();
      sl.registerSingleton<ActiveSourceCubit>(
        ActiveSourceCubit(fallback: 'mihon:1'),
      );
      await pump(tester);

         // The Mihon row is gone in this build, and the Zangetsu streaming row it
         // used to be counted against is gone with it, so a `mihon:` id — which
         // `activeIsZangetsu` excludes — cannot light anything up.
         expect(find.text('ACTIVE'), findsNothing);
         // Novel-only build: it is no longer NAMED either. A `mihon:` source can
         // never be selected (the picker is novel-filtered) and Mihon is never
         // booted, so "Active: Manga One" would point at a source the user
         // cannot browse with. The header reports None instead.
         expect(find.textContaining('Active: Manga One'), findsNothing);
         expect(find.textContaining('Active: None'), findsOneWidget);
       },
     );

    testWidgets(
      'a non-novel active id is not reported as the active source',
      (tester) async {
        // The gate this replaced was prefix-only and so reported the truth for
        // a novel id while waving through every other one. What matters now is
        // the answer for a source this build cannot use, which is "none" —
        // checked against a registered Mihon source, so the "it's registered,
        // it would resolve" case is the one being excluded and not merely an
        // id that happens to be unresolvable.
        sl<MihonManager>().register(_mihonSrc(1, 'Manga One'));
        sl.unregister<ActiveSourceCubit>();
        sl.registerSingleton<ActiveSourceCubit>(
          ActiveSourceCubit(fallback: 'mihon:1'),
        );
        await pump(tester);

        expect(find.textContaining('Active: Manga One'), findsNothing);
        expect(find.textContaining('Active: None'), findsOneWidget);
      },
    );
  }

