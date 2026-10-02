// A source that answers with nothing used to be a dead end: the screen said
// "no titles" and stopped there, while the two things that actually fix it — a
// retry, or solving the Cloudflare challenge that suppressed the request —
// were buried in an overflow menu with no reason to open it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/lnreader/novel_cloudflare.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/search/browse_source_screen.dart';

class _EmptyRepo implements SourceRepository {
  int homeCalls = 0;

  /// Per-id base urls, so a test can give one source a different host from
  /// another. Defaults to [defaultBase] for anything not named here.
  final Map<String, String> baseUrls = {};
  static const defaultBase = 'https://dead.example';

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;


  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) async {
    homeCalls++;
    return const [];
  }

  @override
  String baseUrlFor(String sourceId) =>
      baseUrls[sourceId] ?? defaultBase;

  @override
  String displayName(String sourceId) => sourceId;

  @override
  String? languageFor(String sourceId) => null;
}

class _FakeCloudStreamManager extends ChangeNotifier
    implements CloudStreamManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  BaseProvider? get(String sourceId) => null;
  @override
  String? repoNameForSourceId(String sourceId) => null;
}

void main() {
  late _EmptyRepo repo;

  Widget harness(Widget child) => MaterialApp(home: child);

  setUp(() {
    repo = _EmptyRepo();
    sl.registerSingleton<ActiveSourceCubit>(ActiveSourceCubit(fallback: 'cs:1'));
    sl.registerSingleton<CloudStreamManager>(_FakeCloudStreamManager());
    sl.registerSingleton<SourceRepository>(repo);
  });

  tearDown(() async {
    CfSolveNeeded.clear('dead.example');
    NovelCloudflare.clear();
    await sl<ActiveSourceCubit>().close();
    await sl.reset();
  });

  testWidgets('an empty source offers a retry, and it reloads', (t) async {
    await t.pumpWidget(harness(
      const BrowseSourceScreen(sourceId: 'cs:Dead', title: 'Dead'),
    ));
    await t.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    final before = repo.homeCalls;

    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();

    expect(repo.homeCalls, greaterThan(before));
  });

  testWidgets('a Cloudflare-blocked source offers the solve instead',
      (t) async {
    // Retrying a suppressed request just fails again; the challenge is the
    // thing standing in the way, so that is the action to offer.
    CfSolveNeeded.needsSolve(
      'dead.example',
      'https://dead.example',
      sourceId: 'cs:Dead',
    );

    await t.pumpWidget(harness(
      const BrowseSourceScreen(sourceId: 'cs:Dead', title: 'Dead'),
    ));
    await t.pumpAndSettle();

    expect(find.text('Solve Cloudflare'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  // A novel (LNReader) source behind Cloudflare latches into NovelCloudflare,
  // not CfSolveNeeded - the plugin catches its own fetch failures in JS, so the
  // challenge reaches the UI as an empty list and nothing was flagging it. That
  // left "Retry" as the only action offered, which cannot fix anything.
  group('a novel source latches Cloudflare separately', () {
    testWidgets('offers the solve when the latch is on this source\'s host',
        (t) async {
      repo.baseUrls['lnr:novelupdates'] = 'https://www.novelupdates.com/';
      NovelCloudflare.needsSolve(
        'https://www.novelupdates.com/series-ranking/?rank=popmonth',
      );

      await t.pumpWidget(harness(
        const BrowseSourceScreen(
          sourceId: 'lnr:novelupdates',
          title: 'Novel Updates',
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('Solve Cloudflare'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a latch on a different host is not blamed on this source',
        (t) async {
      // NovelCloudflare holds ONE pending url, not a per-source flag. Without
      // a host check, a challenge pending against one novel site would put a
      // "Solve Cloudflare" button on every other empty novel source.
      repo.baseUrls['lnr:novelupdates'] = 'https://www.novelupdates.com/';
      NovelCloudflare.needsSolve('https://webnovel.com/some-page');

      await t.pumpWidget(harness(
        const BrowseSourceScreen(
          sourceId: 'lnr:novelupdates',
          title: 'Novel Updates',
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Solve Cloudflare'), findsNothing);
    });

    testWidgets('the novel latch does not hijack a JS provider', (t) async {
      // The two ecosystems must not bleed into each other: CfSolveNeeded is
      // authoritative for cs:/Zangetsu sources and NovelCloudflare for lnr:.
      NovelCloudflare.needsSolve('https://dead.example');

      await t.pumpWidget(harness(
        const BrowseSourceScreen(sourceId: 'cs:Dead', title: 'Dead'),
      ));
      await t.pumpAndSettle();

      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Solve Cloudflare'), findsNothing);
    });
  });
}
