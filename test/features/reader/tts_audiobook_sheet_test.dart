import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tts/tts_cubit.dart';
import 'package:watch_app/core/reading/tts/tts_state.dart';
import 'package:watch_app/features/reader/tts_audiobook_sheet.dart';
import 'package:watch_app/features/reader/tts_player_bar.dart';

List<TtsSentenceView> _sentences(int n) => List<TtsSentenceView>.generate(
  n,
  (i) => TtsSentenceView(
    index: i,
    text: 'Sentence number $i of the chapter goes here.',
    blockIndex: i,
    pauseAfterMs: 0,
  ),
);

/// A cubit stand-in that records what the sheet asked it to do. The sheet only
/// needs seek/skip/toggle/setRate/setSleepTimer and a TtsState to render.
class _FakeTtsCubit extends Cubit<TtsState> implements TtsCubit {
  _FakeTtsCubit({int total = 12, int current = 3})
    : super(
        TtsState(
          status: TtsStatus.speaking,
          available: true,
          bookId: 'book',
          chapterId: 'chapter',
          totalSentences: total,
          sentences: _sentences(total),
          currentIndex: current,
        ),
      );

  final List<int> seeks = [];
  int toggles = 0;
  double? rate;

  @override
  Future<void> seek(int index) async {
    seeks.add(index);
    emit(state.copyWith(currentIndex: index));
  }

  @override
  Future<void> skip(int delta) => seek(state.currentIndex + delta);

  @override
  Future<void> toggle() async => toggles++;

  @override
  Future<void> setRate(double value) async {
    rate = value;
    emit(state.copyWith(rate: value));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _bar(_FakeTtsCubit cubit, {required VoidCallback onOpenPlayer}) =>
    MaterialApp(
      home: Scaffold(
        body: TtsPlayerBar(
          cubit: cubit,
          onOpenSettings: () {},
          onOpenPlayer: onOpenPlayer,
          onClose: () {},
        ),
      ),
    );

void main() {
  group('compact bar progress track', () {
    testWidgets('a tap on the track opens the audiobook player', (tester) async {
      final cubit = _FakeTtsCubit();
      var opened = 0;
      await tester.pumpWidget(_bar(cubit, onOpenPlayer: () => opened++));

      await tester.tap(find.byKey(const ValueKey('compact-tts-progress')));
      await tester.pump();

      expect(opened, 1);
      expect(cubit.seeks, isEmpty, reason: 'a tap must not also seek');
      await cubit.close();
    });

    testWidgets('the expand button next to settings opens the player too', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit();
      var opened = 0;
      await tester.pumpWidget(_bar(cubit, onOpenPlayer: () => opened++));

      final button = find.byIcon(Icons.open_in_full_rounded);
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pump();

      expect(opened, 1);
      await cubit.close();
    });

    testWidgets('a drag scrubs instead of opening the player', (tester) async {
      final cubit = _FakeTtsCubit();
      var opened = 0;
      await tester.pumpWidget(_bar(cubit, onOpenPlayer: () => opened++));

      final track = find.byKey(const ValueKey('compact-tts-progress'));
      final box = tester.renderObject<RenderBox>(track);
      final start = box.localToGlobal(Offset(box.size.width * 0.1, 12));
      final end = box.localToGlobal(Offset(box.size.width * 0.9, 12));

      final gesture = await tester.startGesture(start);
      await gesture.moveTo(end);
      await gesture.up();
      await tester.pump();

      expect(opened, 0, reason: 'a drag must not also open the player');
      expect(cubit.seeks, hasLength(1), reason: 'the drag commits one seek');
      await cubit.close();
    });
  });

group('audiobook sheet', () {
    testWidgets('opens with the player, and the header toggles to lyrics', (
      tester,
    ) async {
      // Six sentences so the transcript fully builds inside the 800x600 test
      // surface. A longer chapter only builds the lines near the viewport, and
      // a find that misses is then a fixture problem, not a real one.
      final cubit = _FakeTtsCubit(total: 6);
      final chapters = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: TtsAudiobookSheet(
            cubit: cubit,
            bookTitle: 'A Wizard of Earthsea',
            chapterTitle: () => 'Chapter 8',
            canPreviousChapter: () => true,
            canNextChapter: () => true,
            onPreviousChapter: () => chapters.add(-1),
            onNextChapter: () => chapters.add(1),
            cover: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('READING NOW'), findsOneWidget);
      expect(find.text('Chapter 8'), findsOneWidget);
      expect(find.text('A Wizard of Earthsea'), findsOneWidget);
      // Player: transport present, header offers the way to lyrics.
      expect(find.byKey(const ValueKey('audiobook-play')), findsOneWidget);
      expect(find.byIcon(Icons.lyrics_rounded), findsOneWidget);
      expect(find.text('Sentence number 3 of the chapter goes here.'),
          findsNothing);

      await tester.tap(find.byKey(const ValueKey('audiobook-sheet-toggle')));
      await tester.pumpAndSettle();

      // Lyrics: the header now offers the way back, and the transcript replaces
      // the transport row's neighbour content. Index 0 is asserted because it is
      // inside the lazily-built window whatever the surface size; the active
      // sentence may sit below it on a short test surface.
      expect(find.byIcon(Icons.list_rounded), findsOneWidget);
      // The view opens on the spoken sentence (index 3), not at the top.
      expect(
        find.text('Sentence number 3 of the chapter goes here.'),
        findsOneWidget,
      );
      // The transport is shared by both views - player and lyrics differ only
      // in the upper half, the controls stay put.
      expect(find.byKey(const ValueKey('audiobook-play')), findsOneWidget);
      await cubit.close();
    });

    testWidgets('the chapter buttons follow the chapter while it stays open', (
        tester,
      ) async {
        // The bug, without a reader in the way: the sheet is a stateful route
        // that outlives the chapter it was opened on, so Previous/Next have to
        // be re-asked every time they are drawn. Captured once, they are wrong
        // for every chapter after the first - Previous dead at the start of a
        // book, Next live at the end and doing nothing when tapped.
        var index = 0;
        const last = 2;
        final cubit = _FakeTtsCubit(total: 6);

        Future<void> open() async {
          await tester.pumpWidget(
            MaterialApp(
              home: TtsAudiobookSheet(
                cubit: cubit,
                bookTitle: 'Book',
                chapterTitle: () => 'Chapter ${index + 1}',
                canPreviousChapter: () => index > 0,
                canNextChapter: () => index < last,
                onPreviousChapter: () => index--,
                onNextChapter: () => index++,
                cover: null,
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        IconButton button(String key) => tester.widget<IconButton>(
              find.byKey(ValueKey(key)),
            );

        await open();
        expect(button('audiobook-prev-chapter').onPressed, isNull);
        expect(button('audiobook-next-chapter').onPressed, isNotNull);

        // Same sheet instance, new chapter - the case a tap in the reader causes
        // by loading the next one underneath this route.
        index = 1;
        await open();
        expect(
          button('audiobook-prev-chapter').onPressed,
          isNotNull,
          reason: 'a previous chapter exists now',
        );
        expect(button('audiobook-next-chapter').onPressed, isNotNull);

        index = last;
        await open();
        expect(button('audiobook-prev-chapter').onPressed, isNotNull);
        expect(
          button('audiobook-next-chapter').onPressed,
          isNull,
          reason: 'this is the last chapter',
        );

        // And the label followed it, rather than staying on the chapter the
        // page was opened with.
        expect(find.text('Chapter 3'), findsOneWidget);
        await cubit.close();
      });

    testWidgets('lyrics names the chapter being read', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      var chapter = 'Chapter 4';
      await tester.pumpWidget(
        MaterialApp(
          home: TtsAudiobookSheet(
            cubit: cubit,
            bookTitle: 'Book',
            chapterTitle: () => chapter,
            canPreviousChapter: () => true,
            canNextChapter: () => true,
            onPreviousChapter: () {},
            onNextChapter: () {},
            cover: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-sheet-toggle')));
      await tester.pumpAndSettle();

      // The transcript has to say which chapter it is a transcript *of*.
      expect(find.text('Chapter 4'), findsOneWidget);

      chapter = 'Chapter 5';
      // The rebuild trigger is the cubit, exactly as in the real flow: loading a
      // chapter adopts it, which emits, which rebuilds the transcript. Without
      // that the label would only ever change if something unrelated forced a
      // frame - which is why this goes through seek rather than a bare pump.
      await cubit.seek(1);
      await tester.pumpAndSettle();
      expect(
        find.text('Chapter 5'),
        findsOneWidget,
        reason: 'a skip must relabel the transcript in place',
      );
      await cubit.close();
    });

    testWidgets('tapping a lyric line seeks to that sentence', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      final chapters = <int>[];
      const canPrev = true;
      const canNext = true;
      await tester.pumpWidget(
        MaterialApp(
          home: TtsAudiobookSheet(
            cubit: cubit,
            bookTitle: 'Book',
            chapterTitle: () => 'Chapter 1',
            canPreviousChapter: () => canPrev,
            canNextChapter: () => canNext,
            onPreviousChapter: () => chapters.add(-1),
            onNextChapter: () => chapters.add(1),
            cover: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-sheet-toggle')));
      await tester.pumpAndSettle();

      // The spoken sentence is the one guaranteed to be on screen, since the
      // view centres itself on it.
      final target = find.text('Sentence number 3 of the chapter goes here.');
      expect(target, findsOneWidget);
      await tester.tap(target);
      await tester.pumpAndSettle();

      expect(cubit.seeks, contains(3));
      await cubit.close();
    });

    testWidgets('tapping the waveform seeks to the sentence under the finger', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit(total: 20);
      final chapters = <int>[];
      const canPrev = true;
      const canNext = true;
      await tester.pumpWidget(
        MaterialApp(
          home: TtsAudiobookSheet(
            cubit: cubit,
            bookTitle: 'Book',
            chapterTitle: () => 'Chapter 1',
            canPreviousChapter: () => canPrev,
            canNextChapter: () => canNext,
            onPreviousChapter: () => chapters.add(-1),
            onNextChapter: () => chapters.add(1),
            cover: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final wave = find.byKey(const ValueKey('audiobook-waveform'));
      expect(wave, findsOneWidget);
      final box = tester.renderObject<RenderBox>(wave);
      // Three quarters along a 20-sentence chapter.
      final at = box.localToGlobal(Offset(box.size.width * 0.75, 22));

      await tester.tapAt(at);
      await tester.pumpAndSettle();

      expect(
        cubit.seeks,
        isNotEmpty,
        reason: 'a tap on the waveform must commit a seek',
      );
      final index = cubit.seeks.last;
      expect(index, greaterThan(10), reason: 'three quarters in, not the start');
      expect(index, lessThan(20), reason: 'and not clamped past the chapter');
      await cubit.close();
    });

    testWidgets('dragging the waveform seeks once, on release', (tester) async {
      final cubit = _FakeTtsCubit(total: 20);
      final chapters = <int>[];
      const canPrev = true;
      const canNext = true;
      await tester.pumpWidget(
        MaterialApp(
          home: TtsAudiobookSheet(
            cubit: cubit,
            bookTitle: 'Book',
            chapterTitle: () => 'Chapter 1',
            canPreviousChapter: () => canPrev,
            canNextChapter: () => canNext,
            onPreviousChapter: () => chapters.add(-1),
            onNextChapter: () => chapters.add(1),
            cover: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final box = tester.renderObject<RenderBox>(
        find.byKey(const ValueKey('audiobook-waveform')),
      );
      final gesture = await tester.startGesture(
        box.localToGlobal(Offset(box.size.width * 0.2, 22)),
      );
      await gesture.moveTo(box.localToGlobal(Offset(box.size.width * 0.6, 22)));
      await tester.pump();
      // Mid-drag: nothing committed yet, or the engine restarts per frame.
      expect(cubit.seeks, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(cubit.seeks, hasLength(1), reason: 'one seek, committed on release');
      expect(cubit.seeks.last, greaterThan(6));
      await cubit.close();
    });

    testWidgets('lyrics opens already showing the sentence being read', (
      tester,
    ) async {
      // Deep into a long chapter on purpose: the transcript is lazily built, so
      // a spoken sentence near the end has no context until the list is scrolled
      // there. Opening at the top and making the reader scroll to find the line
      // is the bug this pins.
      final cubit = _FakeTtsCubit(total: 120, current: 90);
      final chapters = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: TtsAudiobookSheet(
            cubit: cubit,
            bookTitle: 'Book',
            chapterTitle: () => 'Chapter 1',
            canPreviousChapter: () => true,
            canNextChapter: () => true,
            onPreviousChapter: () => chapters.add(-1),
            onNextChapter: () => chapters.add(1),
            cover: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-sheet-toggle')));
      await tester.pumpAndSettle();
      // The scroll needs a frame to land and a second to measure.
      await tester.pumpAndSettle();

      expect(
        find.text('Sentence number 90 of the chapter goes here.'),
        findsOneWidget,
        reason: 'the spoken sentence must be on screen without scrolling',
      );
      expect(
        find.text('Sentence number 0 of the chapter goes here.'),
        findsNothing,
        reason: 'and the view must not still be parked at the top',
      );
      await cubit.close();
    });

    testWidgets('the cover grows to fill the space it is given', (tester) async {
      // The sheet hands the player body whatever the header, waveform,
      // transport and quick actions leave over. Sized against the window instead
      // of that, the cover capped out early and the slack showed as a gap above
      // the waveform.
      Future<double> sideOn(double height) async {
        tester.view.physicalSize = Size(800, height);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final cubit = _FakeTtsCubit(total: 6);
        await tester.pumpWidget(
          MaterialApp(
            home: TtsAudiobookSheet(
              cubit: cubit,
              bookTitle: 'Book',
              chapterTitle: () => 'Chapter 1',
              canPreviousChapter: () => true,
              canNextChapter: () => true,
              onPreviousChapter: () {},
              onNextChapter: () {},
              cover: null,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final box = tester.renderObject<RenderBox>(
          find.byKey(const ValueKey('audiobook-cover')),
        );
        final size = box.size;
        await cubit.close();
        return size.width;
      }

      final short = await sideOn(700);
      final tall = await sideOn(1500);

      expect(
        tall,
        greaterThan(short),
        reason: 'a taller sheet must give the cover more room',
      );
      // Square, and never wider than the sheet.
      expect(tall, lessThanOrEqualTo(800));
    });

    testWidgets('the transport skips CHAPTER, not sentence', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      final chapters = <int>[];
      const canPrev = true;
      const canNext = true;
      await tester.pumpWidget(
        MaterialApp(
          home: TtsAudiobookSheet(
            cubit: cubit,
            bookTitle: 'Book',
            chapterTitle: () => 'Chapter 1',
            canPreviousChapter: () => canPrev,
            canNextChapter: () => canNext,
            onPreviousChapter: () => chapters.add(-1),
            onNextChapter: () => chapters.add(1),
            cover: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-next-chapter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('audiobook-prev-chapter')));
      await tester.pumpAndSettle();

      // The two controls that used to duplicate -1 Sent / +1 Sent now move the
      // chapter, and leave the sentence alone.
      expect(chapters, [1, -1]);
      expect(cubit.seeks, isEmpty);
      await cubit.close();
    });

    testWidgets('chapter buttons disable at the ends of the book', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit(total: 6);
      final chapters = <int>[];
      const canPrev = false;
      const canNext = true;
      await tester.pumpWidget(
        MaterialApp(
          home: TtsAudiobookSheet(
            cubit: cubit,
            bookTitle: 'Book',
            chapterTitle: () => 'Chapter 1',
            canPreviousChapter: () => canPrev,
            canNextChapter: () => canNext,
            onPreviousChapter: () => chapters.add(-1),
            onNextChapter: () => chapters.add(1),
            cover: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final prev = tester.widget<IconButton>(
        find.byKey(const ValueKey('audiobook-prev-chapter')),
      );
      final next = tester.widget<IconButton>(
        find.byKey(const ValueKey('audiobook-next-chapter')),
      );
      expect(prev.onPressed, isNull, reason: 'first chapter has no previous');
      expect(next.onPressed, isNotNull);
      await cubit.close();
    });

    testWidgets('the quick actions drive the cubit for real', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      final chapters = <int>[];
      const canPrev = true;
      const canNext = true;
      await tester.pumpWidget(
        MaterialApp(
          home: TtsAudiobookSheet(
            cubit: cubit,
            bookTitle: 'Book',
            chapterTitle: () => 'Chapter 1',
            canPreviousChapter: () => canPrev,
            canNextChapter: () => canNext,
            onPreviousChapter: () => chapters.add(-1),
            onNextChapter: () => chapters.add(1),
            cover: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // +1 Sent
      await tester.tap(find.byKey(const ValueKey('audiobook-plus-sentence')));
      await tester.pumpAndSettle();
      expect(cubit.seeks.last, 4);

      // -1 Sent
      await tester.tap(find.byKey(const ValueKey('audiobook-minus-sentence')));
      await tester.pumpAndSettle();
      expect(cubit.seeks.last, 3);

      // Speed cycles off the real preset ladder.
      final before = cubit.state.rate;
      await tester.tap(find.byKey(const ValueKey('audiobook-speed')));
      await tester.pumpAndSettle();
      expect(cubit.rate, isNotNull);
      expect(cubit.rate, isNot(before));

      await cubit.close();
    });
  });

  group('the player covers the page', () {
    /// A reader behind it, so there is something for the route to cover and
    /// something to come back to.
    Widget host(_FakeTtsCubit cubit) => MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showTtsAudiobookSheet(
                context,
                cubit: cubit,
                bookTitle: 'A Wizard of Earthsea',
                chapterTitle: () => 'Chapter 8',
                canPreviousChapter: () => true,
                canNextChapter: () => true,
                onPreviousChapter: () {},
                onNextChapter: () {},
              ),
              child: const Text('open the player'),
            ),
          ),
        ),
      ),
    );

    /// The screen size the player actually occupies.
    Size occupiedBy(WidgetTester tester) =>
        tester.getSize(find.byType(TtsAudiobookSheet));

    testWidgets('it fills the screen rather than sitting at 92% of it', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(host(cubit));
      final surface = tester.view.physicalSize / tester.view.devicePixelRatio;

      await tester.tap(find.text('open the player'));
      await tester.pumpAndSettle();

      // The strip of reader showing above it was the complaint: a third of a
      // transcript screen spent on the page behind it.
      expect(occupiedBy(tester).height, surface.height);
      expect(occupiedBy(tester).width, surface.width);
      await cubit.close();
    });

    testWidgets('it covers the page behind it, edge to edge', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(host(cubit));
      await tester.tap(find.text('open the player'));
      await tester.pumpAndSettle();

      // No scrim and no gap: nothing of the reader is reachable while the
      // player is up.
      expect(find.text('open the player'), findsNothing);
      await cubit.close();
    });

    testWidgets('the system back button returns to the reader', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(host(cubit));
      await tester.tap(find.text('open the player'));
      await tester.pumpAndSettle();
      expect(find.byType(TtsAudiobookSheet), findsOneWidget);

      // A route, so back pops it the way back pops anything else. Narration is
      // unaffected either way - it runs in a foreground service.
      final popped = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(popped, isTrue);
      expect(find.byType(TtsAudiobookSheet), findsNothing);
      expect(find.text('open the player'), findsOneWidget);
      await cubit.close();
    });

    testWidgets('the close control still returns to the reader', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(host(cubit));
      await tester.tap(find.text('open the player'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-sheet-close')));
      await tester.pumpAndSettle();

      expect(find.byType(TtsAudiobookSheet), findsNothing);
      expect(find.text('open the player'), findsOneWidget);
      await cubit.close();
    });

    testWidgets('the header clears the status bar', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 48, bottom: 24);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(cubit));
      await tester.tap(find.text('open the player'));
      await tester.pumpAndSettle();

      // Covering the page put the header under the clock, where a sheet never
      // was. It has to come back down.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('audiobook-sheet-close'))).dy,
        greaterThanOrEqualTo(48),
      );
      await cubit.close();
    });

    testWidgets('a short viewport and large text do not overflow', (
      tester,
    ) async {
      // The risk in moving from a sheet to a page is the fixed rows underneath
      // the scrolling body. A small screen and a big system font together is
      // where that gives out, and an overflow is a black-and-yellow stripe
      // across the player's controls.
      final cubit = _FakeTtsCubit(total: 6);
      tester.view.physicalSize = const Size(360, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: host(cubit),
        ),
      );
      await tester.tap(find.text('open the player'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The controls are all still there, on a screen a fifth of the usual area.
      expect(find.byKey(const ValueKey('audiobook-play')), findsOneWidget);
      await cubit.close();
    });

    testWidgets('lyrics stay scrollable on a short viewport', (tester) async {
      final cubit = _FakeTtsCubit(total: 40);
      tester.view.physicalSize = const Size(360, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(host(cubit));
      await tester.tap(find.text('open the player'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('audiobook-sheet-toggle')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The transcript is the thing that has to scroll on a small screen.
      final scrollable = find.descendant(
        of: find.byType(TtsAudiobookSheet),
        matching: find.byType(Scrollable),
      );
      expect(scrollable, findsWidgets);
      await cubit.close();
    });

    testWidgets('the view toggle keeps the controls and the spoken sentence', (
      tester,
    ) async {
      // Switching views must not restart anything: the same cubit, the same
      // transport, and the transcript still opens on what is being read.
      final cubit = _FakeTtsCubit(total: 6, current: 3);
      await tester.pumpWidget(host(cubit));
      await tester.tap(find.text('open the player'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-sheet-toggle')));
      await tester.pumpAndSettle();

      expect(
        find.text('Sentence number 3 of the chapter goes here.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('audiobook-play')), findsOneWidget);
      await cubit.close();
    });
  });
}