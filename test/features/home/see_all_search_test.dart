import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/home/see_all_screen.dart';

MediaItem _item(String id) => MediaItem(
  id: id,
  title: id,
  cover: null,
  url: 'https://x.test/$id',
  type: ProviderType.anime,
  sourceId: 'ani:1',
);

Widget _wrap(Widget child) => MaterialApp(home: child);

/// Opens the field, types [query] and submits it the way the keyboard's search
/// key does — the same path a real submit takes, rather than a test-only call.
Future<void> _search(WidgetTester tester, String query) async {
  await tester.tap(find.byIcon(Icons.search_rounded));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

int _gridCount(WidgetTester tester) {
  final grid = tester.widget<GridView>(find.byType(GridView));
  return (grid.childrenDelegate as SliverChildBuilderDelegate).childCount ?? 0;
}

void main() {
  setUp(() {
    if (sl.isRegistered<AppMode>()) sl.unregister<AppMode>();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() {
    if (sl.isRegistered<AppMode>()) sl.unregister<AppMode>();
  });

  group('search affordance', () {
    testWidgets('no field at all when the caller cannot search', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SeeAllScreen(
            title: 'Popular',
            items: [_item('a'), _item('b')],
            onTap: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // A See All over a saved list or a set of search results has nothing to
      // search, and a field that searches nothing is worse than no field.
      expect(find.byIcon(Icons.search_rounded), findsNothing);
    });

    testWidgets('the field replaces the title and takes the query', (
      tester,
    ) async {
      final queries = <String>[];
      await tester.pumpWidget(
        _wrap(
          SeeAllScreen(
            title: 'Popular',
            items: [_item('a'), _item('b')],
            onTap: (_) {},
            onSearch: (q, page) async {
              queries.add(q);
              return [_item('result')];
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Popular'), findsOneWidget);

      await _search(tester, 'shadow slave');

      expect(queries, ['shadow slave']);
      // The title made way for the field — not stacked above the grid, which on
      // a phone would cost a screenful of covers.
      expect(find.text('Popular'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      // And the grid is now the results, not the row.
      expect(find.text('result'), findsOneWidget);
      expect(find.text('a'), findsNothing);
    });
  });

  group('search results', () {
    testWidgets('an empty result says so, and names the query', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SeeAllScreen(
            title: 'Popular',
            items: [_item('a')],
            onTap: (_) {},
            onSearch: (q, page) async => const [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _search(tester, 'nothing here');

      // "Found nothing" and "the source failed" look identical otherwise, and
      // they need opposite responses: try another title vs. try again.
      expect(find.textContaining('Nothing here for'), findsOneWidget);
      expect(find.byType(GridView), findsNothing);
    });

    testWidgets('a failed search is not reported as "no results"', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SeeAllScreen(
            title: 'Popular',
            items: [_item('a')],
            onTap: (_) {},
            onSearch: (q, page) async => throw StateError('source down'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _search(tester, 'anything');

      expect(find.textContaining('could not be searched'), findsOneWidget);
      expect(find.textContaining('Nothing here for'), findsNothing);
    });

    testWidgets('closing the search puts the row back as it was', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SeeAllScreen(
            title: 'Popular',
            items: [_item('a'), _item('b')],
            onTap: (_) {},
            onSearch: (q, page) async => [_item('result')],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _search(tester, 'x');
      expect(find.text('result'), findsOneWidget);

      // Back out of the field — the app bar's leading button, which means
      // "leave the search" rather than "leave the screen".
      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Popular'), findsOneWidget);
      expect(find.text('a'), findsOneWidget);
      expect(find.text('result'), findsNothing);
    });

    testWidgets('results page, and stop when a page adds nothing new', (
      tester,
    ) async {
      final pages = <int>[];
      await tester.pumpWidget(
        _wrap(
          SeeAllScreen(
            title: 'Popular',
            items: [_item('a')],
            onTap: (_) {},
            onSearch: (q, page) async {
              pages.add(page);
              // Page 1 is a full screen of results, or there is nothing to
              // scroll and the near-end listener never fires at all.
              if (page == 1) return [for (var i = 0; i < 30; i++) _item('r$i')];
              if (page == 2) {
                return [_item('r0'), for (var i = 30; i < 50; i++) _item('r$i')];
              }
              return const [];
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _search(tester, 'x');
      expect(_gridCount(tester), 30);

      await tester.fling(find.byType(GridView), const Offset(0, -6000), 6000);
      await tester.pumpAndSettle();
      expect(pages.contains(2), isTrue);
      // r0 deduped, r30..r49 appended.
      expect(_gridCount(tester), 50);

      // One more trip to the bottom: page 3 is empty, so paging ends there.
      await tester.fling(find.byType(GridView), const Offset(0, -600), 600);
      await tester.pumpAndSettle();
      final before = pages.length;
      await tester.fling(find.byType(GridView), const Offset(0, -600), 600);
      await tester.pumpAndSettle();
      expect(pages.length, before);
    });
  });

  testWidgets('a stale answer never overwrites a newer search', (tester) async {
    final gate = Completer<List<MediaItem>>();
    var call = 0;
    await tester.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Popular',
          items: [_item('a')],
          onTap: (_) {},
          onSearch: (q, page) async {
            call++;
            if (call == 1) {
              // The slow first search, still in the air.
              return gate.future;
            }
            return [_item('second')];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'first');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'second');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('second'), findsWidgets);

      // The first search finally answers, with results for a query the reader has
      // already replaced. They must not appear.
      gate.complete([_item('first-result-late')]);
      await tester.pumpAndSettle();
      expect(find.text('first-result-late'), findsNothing);
      expect(find.text('second'), findsWidgets);

  });
}
