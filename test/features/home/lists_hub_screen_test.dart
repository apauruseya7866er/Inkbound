// The hub behind Home's single card. It replaced a card per tracker plus a
// Schedule card, so the thing worth pinning is that it stops depending on the
// mode: every connected tracker is listed no matter which mode you arrived in.
//
// Novel-only build: two of the three cases this file used to hold are gone with
// the rows they described. The Schedule row is the anime airing calendar
// (AniList NEXT_EPISODES) and is no longer offered at all, so "the hub lists
// every connected tracker plus Schedule" and "Schedule stands alone when
// nothing is connected" had nothing left to assert. What survives is the
// connection filter below, which is mode-independent and still live.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/features/home/lists_hub_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

class _FakeTracker implements Tracker {
  _FakeTracker(this.displayName, {required this.supportsReading,
      this.isConnected = true});

  @override
  final String displayName;
  @override
  final bool supportsReading;
  @override
  final bool isConnected;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget harness() => const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ListsHubScreen(),
    );

void main() {
  // Three trackers with three kinds each runs past a default test viewport, and
  // a ListView does not build what it cannot show. Give it room so the finders
  // are testing the screen rather than the scroll position.
  setUp(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(400 * 3, 1600 * 3);
    v.devicePixelRatio = 3;
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first
        .resetPhysicalSize();
    await sl.reset();
  });

  testWidgets('a disconnected tracker is not offered', (t) async {
    sl.registerSingleton<TrackerHub>(TrackerHub([
      _FakeTracker('AniList', supportsReading: true),
      _FakeTracker('Simkl', supportsReading: false, isConnected: false),
    ]));

    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    expect(find.text('ANILIST'), findsOneWidget);
    expect(find.text('SIMKL'), findsNothing);
  });
}
