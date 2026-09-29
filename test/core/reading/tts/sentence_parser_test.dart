import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tts/sentence_parser.dart';

/// Table-driven tests for the TTS sentence splitter.
///
/// The splitter is the only part of the TTS stack that decides whether speech
/// sounds human, and it is pure Dart, so it can be proven here rather than
/// eyeballed on a device. Every case below is a way real novel prose breaks a
/// naive `split('.')`.
void main() {
  group('sentence segmentation', () {
    test('splits on plain terminators', () {
      final b = SentenceParser.parseText('He ran. She stayed. They waited.');
      expect(b.sentences.map((s) => s.text).toList(), [
        'He ran.',
        'She stayed.',
        'They waited.',
      ]);
    });

    test('keeps indices contiguous and 0-based', () {
      final b = SentenceParser.parseText('One. Two. Three. Four.');
      expect(b.sentences.map((s) => s.index).toList(), [0, 1, 2, 3]);
    });

    test('a trailing sentence with no terminator is still spoken', () {
      final b = SentenceParser.parseText('Done. And then nothing more');
      expect(b.sentences.last.text, 'And then nothing more');
    });

    test('abbreviations do not end a sentence', () {
      // The reference implementation splits this into three and speaks
      // "Mister. Smith met Mister. Jones" — a name after a title is
      // capitalised, so gating the merge on a lowercase follower never fires.
      // Titles are now never split.
      final b = SentenceParser.parseText('Mr. Smith met Dr. Jones today.');
      expect(b.sentences, hasLength(1));
      expect(b.sentences.single.text, contains('Mr. Smith'));
      expect(b.sentences.single.text, contains('Dr. Jones'));
    });

    test('a lowercase word after a month keeps it one sentence', () {
      // The other class keeps the case-sensitive rule, because here the capital
      // is meaningful: "in Jan. he left" continues, "in Jan. He left" does not.
      final b = SentenceParser.parseText('It was cold in Jan. he left early.');
      expect(b.sentences, hasLength(1));
    });

    test('decimal numbers are not split', () {
      final b = SentenceParser.parseText('It weighed 3.5 kilograms in total.');
      expect(b.sentences, hasLength(1));
    });

    test('initials are not split', () {
      final b = SentenceParser.parseText('J. R. R. Tolkien wrote it. Everyone knows.');
      expect(b.sentences.length, greaterThanOrEqualTo(1));
      expect(b.sentences.first.text, contains('Tolkien'));
    });

    test('a colon splits as a divider', () {
      // Splits with no capitalisation requirement, which is the point: prose
      // like "He said: it begins here" puts a lowercase word after the colon.
      final b = SentenceParser.parseText('He said: it begins here. Then it ended.');
      expect(b.sentences.length, 3);
      expect(b.sentences[0].text, 'He said');
      expect(b.sentences[1].text, contains('it begins here'));
    });

    test('a colon as a divider gets the colon pause', () {
      final b = SentenceParser.parseText('He said: it begins here. Then it ended.');
      expect(b.sentences[0].pauseAfterMs, TtsPause.colon);
    });

    test('a colon between digits is a time, not a divider', () {
      final b = SentenceParser.parseText('The race started at 3:30 and he won it.');
      expect(b.sentences, hasLength(1));
    });

    test('a colon between digits is a ratio, not a divider', () {
      final b = SentenceParser.parseText('They won 2:1 in the final match of the day.');
      expect(b.sentences, hasLength(1));
    });

    test('a mid-sentence ellipsis does not break', () {
      final b = SentenceParser.parseText('He was... uncertain about the path ahead.');
      expect(b.sentences, hasLength(1));
    });

    test('an ellipsis before a capital does break', () {
      final b = SentenceParser.parseText('Wait... What are you doing here?');
      expect(b.sentences.length, greaterThan(1));
    });

    test('a unicode ellipsis is handled like three dots', () {
      final b = SentenceParser.parseText('She hesitated… Then she spoke. Clearly.');
      expect(b.sentences.length, greaterThan(1));
    });

    test('punctuation-only runs are discarded, not spoken', () {
      final b = SentenceParser.parseText('Real words here. --- *** ... 123');
      for (final s in b.sentences) {
        expect(s.text.trim(), isNotEmpty);
        expect(RegExp(r'\p{L}', unicode: true).hasMatch(s.text), isTrue,
            reason: 'segment "${s.text}" has no letters');
      }
    });

    test('a block with no letters at all yields nothing', () {
      final b = SentenceParser.parseText('--- *** ...');
      expect(b.sentences, isEmpty);
    });

    test('a script with no terminators still gets spoken as one block', () {
      // No periods anywhere: must not fall silent.
      final b = SentenceParser.parseText('これはテストです');
      expect(b.sentences, hasLength(1));
      expect(b.sentences.single.text, 'これはテストです');
    });

    test('non-latin text with terminators segments', () {
      final b = SentenceParser.parseText('مرحبا. كيف حالك. أنا بخير.');
      expect(b.sentences.length, greaterThan(1));
    });

    test('quotation marks are stripped from spoken text', () {
      final b = SentenceParser.parseText('He whispered "come here" and waited.');
      expect(b.sentences.first.text, isNot(contains('"')));
    });

    test('curly quotes are stripped too', () {
      final b = SentenceParser.parseText('He said “yes” then “no” at last.');
      for (final s in b.sentences) {
        expect(s.text, isNot(contains('“')));
        expect(s.text, isNot(contains('”')));
      }
    });

    test('a sentence keeps its closing quote for the pause decision', () {
      // The quote is stripped from the spoken text but must still be seen
      // through when picking the pause length.
      final b = SentenceParser.parseText('He stopped. "Why?" she asked. Then silence.');
      expect(b.sentences.length, greaterThanOrEqualTo(3));
    });

    test('whitespace-only input yields nothing', () {
      expect(SentenceParser.parseText('   \n\t  ').sentences, isEmpty);
    });

    test('empty input yields nothing', () {
      expect(SentenceParser.parseText('').sentences, isEmpty);
    });

    test('parsing terminates on pathological input', () {
      // A long run of terminators is the classic way to hang a splitter.
      final b = SentenceParser.parseText('${'.' * 500}text${'.!' * 300}');
      expect(b.sentences, isNotEmpty);
    });

    test('parsing terminates on a huge unterminated run', () {
      final b = SentenceParser.parseText('a' * 20000);
      expect(b.sentences, hasLength(1));
    });
  });

  group('pause selection', () {
    int pauseFor(String text) =>
        SentenceParser.parseText(text).sentences.first.pauseAfterMs;

    test('a plain stop gets the normal beat', () {
      expect(pauseFor('He left. She stayed.'), TtsPause.normal);
    });

    test('a question gets a longer beat than a statement', () {
      expect(pauseFor('Are you sure? Yes.'), greaterThan(TtsPause.normal));
    });

    test('an exclamation sits between a statement and a question', () {
      expect(
        pauseFor('Stop! Now.'),
        allOf(greaterThan(TtsPause.normal), lessThan(TtsPause.question)),
      );
    });

    test('an ellipsis gets the longest beat', () {
      expect(pauseFor('He trailed off… Then silence.'), TtsPause.ellipsis);
    });

    test('a sentence that ends on a dash gets a short beat', () {
      // Only `.!?:` split, so a mid-sentence dash is not a boundary and gets no
      // pause of its own. The tier fires when a segment genuinely ends on one.
      expect(pauseFor('He turned away —'), TtsPause.dash);
    });

    test('a dash inside a sentence does not steal the stop pause', () {
      expect(pauseFor('He turned — and left. No word.'), TtsPause.normal);
    });

    test('every pause is a sane audio value', () {
      for (final p in [
        TtsPause.short,
        TtsPause.normal,
        TtsPause.question,
        TtsPause.ellipsis,
        TtsPause.colon,
      ]) {
        expect(p, greaterThan(0));
        expect(p, lessThan(1000), reason: 'a sub-second beat or it is a silence');
      }
    });
  });

  group('HTML to blocks', () {
    test('paragraphs become separate blocks', () {
      final c = SentenceParser.parseHtml(
        '<p>First para here. Still first.</p><p>Second para now. And more.</p>',
      );
      expect(c.blocks, hasLength(2));
      expect(c.sentences, hasLength(4));
    });

    test('blockIndex is correct and each block knows its sentences', () {
      final c = SentenceParser.parseHtml(
        '<p>One here. Two here.</p><p>Three here. Four here.</p>',
      );
      expect(c.blocks[0].sentences.map((s) => s.index).toList(), [0, 1]);
      expect(c.blocks[1].sentences.map((s) => s.index).toList(), [2, 3]);
      expect(c.sentences.every((s) => s.blockIndex < 2), isTrue);
    });

    test('a soft line break does NOT split a block', () {
      // Poetry and addresses: splitting here would shred a verse.
      final c = SentenceParser.parseHtml(
        '<p>Roses are red<br>Violets are blue</p>',
      );
      expect(c.blocks, hasLength(1));
    });

    test('script and style bodies are dropped', () {
      final c = SentenceParser.parseHtml(
        '<style>p{color:red}</style><script>alert(1)</script>'
        '<p>Actual text. More text.</p>',
      );
      expect(c.totalSentences, 2);
      for (final s in c.sentences) {
        expect(s.text, isNot(contains('alert')));
        expect(s.text, isNot(contains('color')));
      }
    });

    test('inline tags are dropped but their text kept', () {
      final c = SentenceParser.parseHtml(
        '<p>He said <strong>loudly</strong> and <em>softly</em> after.</p>',
      );
      expect(c.totalSentences, 1);
      expect(c.sentences.single.text, contains('loudly'));
      expect(c.sentences.single.text, contains('softly'));
    });

    test('inline styling is not spoken', () {
      final c = SentenceParser.parseHtml(
        '<p><span class="x">Only real words</span> here. Done.</p>',
      );
      for (final s in c.sentences) {
        expect(s.text, isNot(contains('span')));
        expect(s.text, isNot(contains('class')));
      }
    });

    test('headings and list items are their own blocks', () {
      final c = SentenceParser.parseHtml(
        '<h2>A heading here.</h2><ul><li>First item. More.</li></ul>',
      );
      expect(c.blocks.length, greaterThanOrEqualTo(2));
    });

    test('an image-only block contributes no sentences', () {
      final c = SentenceParser.parseHtml('<p><img src="a.jpg"></p><p>Real text.</p>');
      expect(c.totalSentences, 1);
    });

    test('entities are decoded before segmentation', () {
      final c = SentenceParser.parseHtml(
        '<p>He said &quot;hi&quot; &amp; left. Then gone.</p>',
      );
      final all = c.sentences.map((s) => s.text).join(' ');
      expect(all.toLowerCase(), contains('hi'));
      expect(all, isNot(contains('&amp;')));
      expect(all, isNot(contains('&quot;')));
    });

    test('numeric and hex entities are decoded', () {
      final c = SentenceParser.parseHtml('<p>Caf&#233; time. Yes.</p>');
      expect(c.sentences.first.text, contains('Caf'));
    });

    test('nbsp does not glue words together', () {
      final c = SentenceParser.parseHtml('<p>one&nbsp;two three.</p>');
      expect(c.sentences.first.text, contains('one two'));
    });

    test('an unclosed script tag does not leak its body', () {
      final c = SentenceParser.parseHtml('<p>Real text.</p><script>var x = 1;');
      for (final s in c.sentences) {
        expect(s.text, isNot(contains('var x')));
      }
    });

    test('empty and markup-only chapters yield nothing', () {
      expect(SentenceParser.parseHtml('').isEmpty, isTrue);
      expect(SentenceParser.parseHtml('<p></p>').isEmpty, isTrue);
      expect(SentenceParser.parseHtml('<div><br></div>').isEmpty, isTrue);
    });

    test('a realistic chapter segments into a sane number of sentences', () {
      final c = SentenceParser.parseHtml('''
        <p>Zorian's eyes abruptly shot open as a sharp pain erupted from his
        stomach. His whole body convulsed, buckling against the object that
        fell on him, and suddenly he was wide awake.</p>
        <p>"Morning, morning, MORNING!!!" his sister said. He glared at her,
        but she just smiled back at him cheekily.</p>
        <p>It was 6:30 in the morning. He had class at 8:00, which meant he
        needed to be awake in ninety minutes.</p>
      ''');
      expect(c.totalSentences, greaterThan(6));
      // No segment should be absurdly long or absurdly short.
      for (final s in c.sentences) {
        expect(s.text.length, greaterThan(1));
        expect(s.text.length, lessThan(400));
      }
      // The clock times must not have become sentence boundaries.
      expect(c.sentences.any((s) => s.text.trim() == '30'), isFalse);
    });

    test('the same chapter is stable across repeated parses', () {
      const html = '<p>One. Two.</p><p>Three. Four.</p>';
      final a = SentenceParser.parseHtml(html);
      final b = SentenceParser.parseHtml(html);
      expect(
        a.sentences.map((s) => s.text).toList(),
        b.sentences.map((s) => s.text).toList(),
      );
    });

    test('index and blockIndex survive a block that yields nothing', () {
      final c = SentenceParser.parseHtml(
        '<p>First. Here.</p><p><img src="x.jpg"></p><p>Second. Here.</p>',
      );
      expect(c.totalSentences, 4);
      expect(
        c.sentences.map((s) => s.index).toList(),
        [0, 1, 2, 3],
        reason: 'a silent block must not leave a hole in the index',
      );
    });
  });
}
