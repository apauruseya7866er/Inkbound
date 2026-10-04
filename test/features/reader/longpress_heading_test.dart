import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/text_filter.dart';
import 'package:watch_app/features/reader/novel_html.dart';
import 'package:watch_app/features/reader/tts_alignment.dart';

/// A long press offers to hide whatever is under the finger.
///
/// It used to find that by asking the read-aloud sentence list alone, which is a
/// good proxy for "what someone would hear here" but is not the same as "what is
/// on screen". Read-aloud deliberately skips heading blocks, so a source that
/// marks its injected line up as `<h3>` produced a line that was plainly
/// visible and completely untouchable: the lookup returned nothing and the long
/// press ended in silence, with no dialog to explain why.
void main() {
  group('a heading block, which read-aloud never speaks', () {
    // The chapter as it arrived: prose, then the injected line in a heading.
    const html =
        '<p>For a moment, Sasuke froze.</p>'
        '<h3>AN: Check out my P@treon For +40 extra Chapters.</h3>';
    final layout = NovelTextLayout.fromHtml(html);
    final sentences = alignChapter(layout, narrationFilter: false).sentences;
    final adStart = layout.text.indexOf('AN:');

    test('the line is a heading block with no sentence over it', () {
      expect(layout.isHeadingBlock(1), isTrue);
      expect(
        sentences.any((s) => s.startIndex <= adStart && adStart < s.endIndex),
        isFalse,
      );
    });

    test('a long press on it finds the whole block', () {
      final hit = hideableRangeAt(layout, adStart, sentences);
      expect(hit, isNotNull);
      expect(hit!.text, 'AN: Check out my P@treon For +40 extra Chapters.');
      expect(hit.blockIndex, 1);
    });

    test('a press anywhere in that line finds it, not just the first character',
        () {
      for (final needle in ['P@treon', 'extra Chapters']) {
        final at = layout.text.indexOf(needle);
        expect(hideableRangeAt(layout, at, sentences)?.text,
            'AN: Check out my P@treon For +40 extra Chapters.');
      }
    });

    test('hiding it takes the line out and leaves the prose', () {
      final hit = hideableRangeAt(layout, adStart, sentences)!;
      final engine = TextFilterEngine([
        TextFilterRule.hiddenSentence(hit.text, id: 'h1'),
      ]);
      final out = filterNovelHtml(html, engine);
      expect(out, isNot(contains('P@treon')));
      expect(out, contains('For a moment, Sasuke froze.'));
    });
  });

  group('prose still resolves to the sentence, not the block', () {
    const html = '<p>He said it loudly. Then he stopped.</p>';
    final layout = NovelTextLayout.fromHtml(html);
    final sentences = alignChapter(layout, narrationFilter: false).sentences;

    test('the first sentence wins over the whole paragraph', () {
      final hit = hideableRangeAt(layout, 0, sentences)!;
      expect(hit.text, 'He said it loudly.');
    });

    test('the second sentence is found on its own', () {
      final at = layout.text.indexOf('Then');
      expect(hideableRangeAt(layout, at, sentences)!.text,
          'Then he stopped.');
    });
  });

  group('nowhere to hide', () {
    const html = '<p>One.</p>';
    final layout = NovelTextLayout.fromHtml(html);

    test('an offset past the end finds nothing', () {
      expect(
        hideableRangeAt(layout, layout.length, const []),
        isNull,
      );
    });

    test('a negative offset finds nothing', () {
      expect(hideableRangeAt(layout, -1, const []), isNull);
    });
  });
}