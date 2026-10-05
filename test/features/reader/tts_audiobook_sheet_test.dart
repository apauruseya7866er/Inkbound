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
            canPreviousChapter: true,
            canNextChapter: true,
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
            canPreviousChapter: canPrev,
            canNextChapter: canNext,
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
            canPreviousChapter: canPrev,
            canNextChapter: canNext,
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
            canPreviousChapter: canPrev,
            canNextChapter: canNext,
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
            canPreviousChapter: true,
            canNextChapter: true,
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
              canPreviousChapter: true,
              canNextChapter: true,
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
            canPreviousChapter: canPrev,
            canNextChapter: canNext,
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
            canPreviousChapter: canPrev,
            canNextChapter: canNext,
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
            canPreviousChapter: canPrev,
            canNextChapter: canNext,
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
}