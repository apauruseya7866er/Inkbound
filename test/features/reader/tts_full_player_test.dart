import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tts/tts_cubit.dart';
import 'package:watch_app/core/reading/tts/tts_state.dart';
import 'package:watch_app/features/reader/tts_full_player.dart';
import 'package:watch_app/features/reader/tts_player_bar.dart';

class _FakeTtsCubit extends Cubit<TtsState> implements TtsCubit {
  _FakeTtsCubit()
    : super(
        TtsState(
          status: TtsStatus.speaking,
          available: true,
          bookId: 'book',
          chapterId: 'chapter',
          totalSentences: 3,
          sentences: const [
            TtsSentenceView(
              index: 0,
              text: 'The first sentence.',
              blockIndex: 0,
              pauseAfterMs: 0,
            ),
            TtsSentenceView(
              index: 1,
              text: 'The sentence being read now.',
              blockIndex: 0,
              pauseAfterMs: 0,
            ),
            TtsSentenceView(
              index: 2,
              text: 'The final sentence.',
              blockIndex: 1,
              pauseAfterMs: 0,
            ),
          ],
          currentIndex: 1,
        ),
      );

  int? soughtIndex;

  @override
  Future<void> seek(int index) async {
    soughtIndex = index;
    emit(state.copyWith(currentIndex: index));
  }

  @override
  Future<void> skip(int delta) => seek(state.currentIndex + delta);

  @override
  Future<void> toggle() async {}

  @override
  Future<void> setRate(double rate) async {
    emit(state.copyWith(rate: rate));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeTtsCubit cubit;

  setUp(() => cubit = _FakeTtsCubit());
  tearDown(() => cubit.close());

  testWidgets('tapping empty progress track opens the full player', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TtsPlayerBar(
            cubit: cubit,
            onOpenSettings: () {},
            onOpenPlayer: () => opened = true,
            onClose: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('compact-tts-progress')));
    expect(opened, isTrue);
  });

  testWidgets('lyrics page follows playback and tapping a line seeks there', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TtsFullPlayer(
          cubit: cubit,
          bookTitle: 'A Novel',
          chapterTitle: () => 'Chapter 8',
          cover: null,
          onOpenSettings: () {},
        ),
      ),
    );
    await tester.tap(find.byTooltip('Open lyrics').first);
    await tester.pumpAndSettle();

    expect(find.text('READING NOW'), findsOneWidget);
    expect(find.text('The sentence being read now.'), findsOneWidget);
    await tester.tap(find.text('The final sentence.'));
    await tester.pumpAndSettle();
    expect(cubit.soughtIndex, 2);
  });
}
