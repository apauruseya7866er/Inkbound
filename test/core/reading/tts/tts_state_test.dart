import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tts/tts_state.dart';

/// The player's sentence counter used to be rebuilt from [TtsState.progress]
/// instead of read from [TtsState.currentIndex], and `progress` divided a 0-based
/// index by a count. At the last sentence of a chapter the two errors stacked:
/// the counter read "162 of 163" while the voice and the highlight were both on
/// 163, so the last line of every chapter looked like it was never read.
void main() {
  TtsState at(int index, int total) =>
      TtsState(currentIndex: index, totalSentences: total);

  group('progress', () {
    test('reaches 1.0 on the last sentence', () {
      expect(at(162, 163).progress, 1.0);
      expect(at(3, 4).progress, 1.0);
    });

    test('is 0.0 on the first sentence', () {
      expect(at(0, 163).progress, 0.0);
    });

    test('is the midpoint at the midpoint', () {
      expect(at(81, 163).progress, closeTo(0.5, 0.001));
    });

    test('never leaves 0..1, whatever the index', () {
      for (final total in [2, 7, 100, 163]) {
        for (final index in [0, 1, total ~/ 2, total - 1, total, total + 5]) {
          expect(at(index, total).progress, inInclusiveRange(0.0, 1.0));
        }
      }
    });

    test('a single-sentence chapter is complete, not a divide by zero', () {
      expect(at(0, 1).progress, 0.0);
      expect(at(0, 0).progress, 0.0);
    });
  });

  group('the counter round-trips through the bar without losing a sentence', () {
    // What `_nowPlaying` does: read the index straight off the state.
    int shown(TtsState s) =>
        s.totalSentences > 0 ? s.currentIndex.clamp(0, s.totalSentences - 1) : 0;

    test('every sentence of a chapter is reachable and the last reads N of N', () {
      const total = 163;
      for (var i = 0; i < total; i++) {
        final state = at(i, total);
        expect(shown(state), i);
        expect('Sentence ${shown(state) + 1} of $total',
            'Sentence ${i + 1} of $total');
      }
    });

    test('the fraction round-trip is exact now that progress divides by N-1', () {
      // The bar no longer round-trips through `progress` at all, but the
      // fraction has to be lossless anyway: it is the value a progress bar would
      // show, and a bar that stops one sentence short of the end is the same
      // "the last line is never read" bug wearing a different hat.
      const total = 163;
      for (var i = 0; i < total; i++) {
        final state = at(i, total);
        expect((state.progress * (total - 1)).round(), i);
      }
    });
  });

  group('currentSentence', () {
    test('points at the last sentence of the chapter', () {
      const total = 3;
      final sentences = <TtsSentenceView>[
        for (var i = 0; i < total; i++)
          TtsSentenceView(
            index: i,
            text: 'sentence $i',
            blockIndex: 0,
            pauseAfterMs: 0,
          ),
      ];
      final state = TtsState(
        currentIndex: total - 1,
        totalSentences: total,
        sentences: sentences,
      );
      expect(state.currentSentence?.text, 'sentence 2');
    });
  });
}
