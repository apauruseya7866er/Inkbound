import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/text_filter.dart';
import 'package:watch_app/features/reader/novel_html.dart';

/// The text-cleanup path, tested at the seam it actually runs at: HTML in, and
/// a [NovelTextLayout] out whose text, blocks and tokens all still agree.
void main() {
  TextFilterEngine engineFor(List<String> patterns) => TextFilterEngine([
    for (var i = 0; i < patterns.length; i++)
      TextFilterRule(id: 'r$i', pattern: patterns[i], label: 'r$i'),
  ]);

  /// The text a token list renders as — the same rule `NovelTextLayout` uses.
  String textOf(List<NovelToken> tokens) =>
      tokens.map((t) => t.isBreak ? '\n' : t.text).join();

  /// The same, without the final block separator, which belongs to the token
  /// list rather than to the content.
  String bodyOf(List<NovelToken> tokens) {
    final text = textOf(tokens);
    return text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
  }

  final builtins = TextFilterEngine(builtinTextFilterRules);

  group('filterNovelTokens', () {
    test('returns the same list when there are no rules', () {
      final tokens = tokenizeNovelHtml('<p>Hello</p>');
      expect(
        filterNovelTokens(tokens, TextFilterEngine(const [])),
        same(tokens),
      );
    });

    test('returns the same list when nothing matched', () {
      final tokens = tokenizeNovelHtml('<p>Nothing to strip here.</p>');
      expect(
        filterNovelTokens(tokens, engineFor([r'^never matches this$'])),
        same(tokens),
      );
    });

    test('drops a whole paragraph and leaves no blank line behind', () {
      final out = filterNovelTokens(
        tokenizeNovelHtml(
          '<p>The first line.</p><p>Please support me on Patreon!</p>'
          '<p>The third line.</p>',
        ),
        builtins,
      );
      expect(bodyOf(out), 'The first line.\nThe third line.');
    });

    test('keeps the paragraphs that survive as separate blocks', () {
      final layout = NovelTextLayout(
        filterNovelTokens(
          tokenizeNovelHtml(
            '<p>One.</p><p>Please support me.</p><p>Two.</p><p>Three.</p>',
          ),
          builtins,
        ),
      );
      expect(layout.blocks.map((b) => b.textOf(layout)), [
        'One.',
        'Two.',
        'Three.',
      ]);
    });

    test('keeps styling on the parts a rule did not touch', () {
      final out = filterNovelTokens(
        tokenizeNovelHtml(
          '<p><b>Stay bold.</b> Please support me on Patreon.</p>',
        ),
        builtins,
      );
      // The ad is the tail of the paragraph, so the bold run survives whole.
      expect(out.where((t) => !t.isBreak && t.bold).map((t) => t.text), [
        'Stay bold.',
      ]);
      expect(bodyOf(out), 'Stay bold.');
    });

    test('removes an ad appended to the end of a real paragraph', () {
      final out = filterNovelTokens(
        tokenizeNovelHtml('<p>He turned. Please support me on Patreon.</p>'),
        builtins,
      );
      expect(bodyOf(out), 'He turned.');
    });

    test('removes an obfuscated Patreon footer from chapter HTML', () {
      final out = filterNovelHtml(
        '<p>Story text.</p>'
        '<p>AN: Check out my P@treon For +40 extra Chapters.</p>'
        '<p>More story.</p>',
        builtins,
      );
      expect(
        NovelTextLayout(tokenizeNovelHtml(out)).text,
        'Story text.\nMore story.\n',
      );
    });

    test('a cut that would glue two words puts one space back', () {
      final out = filterNovelTokens(
        tokenizeNovelHtml('<p>start [X] end</p>'),
        engineFor([r'\[X\]']),
      );
      expect(bodyOf(out), 'start end');
    });

    test('a soft line break inside a kept paragraph survives', () {
      final out = filterNovelTokens(
        tokenizeNovelHtml('<p>first line<br>second line</p>'),
        builtins,
      );
      expect(textOf(out), 'first line\nsecond line\n');
    });

    test('a removed paragraph takes its soft line breaks with it', () {
      final out = filterNovelTokens(
        tokenizeNovelHtml(
          '<p>keep this</p><p>AD<br>still the ad</p><p>and this</p>',
        ),
        engineFor([r'^\s*AD\b.*', r'^\s*still the ad$']),
      );
      // No stray blank line where the ad's own <br> was.
      expect(bodyOf(out), 'keep this\nand this');
    });

    test('hands the chapter back untouched if the rules would empty it', () {
      final tokens = tokenizeNovelHtml('<p>the whole chapter</p>');
      final out = filterNovelTokens(tokens, engineFor([r'.*']));
      // A filter one typo away from deleting prose must not be able to delete
      // the chapter: an empty reader says nothing about why.
      expect(textOf(out), textOf(tokens));
    });

    test('leaves a clean chapter exactly as it was', () {
      final tokens = tokenizeNovelHtml(
        '<p>He looked at the sea.</p><p>It was calm.</p>',
      );
      expect(textOf(filterNovelTokens(tokens, builtins)), textOf(tokens));
    });
  });

  group('serializeNovelTokens', () {
    test('keeps the text, the bold and the italic', () {
      const html = '<p>plain <b>bold</b> and <i>italic</i> tail</p>';
      final tokens = tokenizeNovelHtml(html);
      final back = NovelTextLayout(
        tokenizeNovelHtml(serializeNovelTokens(tokens)),
      );
      expect(back.text, NovelTextLayout(tokens).text);
      expect(
        back.tokens.where((t) => !t.isBreak && t.bold).map((t) => t.text),
        ['bold'],
      );
      expect(
        back.tokens.where((t) => !t.isBreak && t.italic).map((t) => t.text),
        ['italic'],
      );
    });

    test('keeps paragraph boundaries and soft breaks', () {
      const html = '<p>one</p><p>two<br>three</p>';
      final back = NovelTextLayout(
        tokenizeNovelHtml(serializeNovelTokens(tokenizeNovelHtml(html))),
      );
      expect(back.blocks.map((b) => b.textOf(back)), ['one', 'two\nthree']);
    });

    test('keeps a heading a heading, so narration still skips it', () {
      const html = '<h1>Chapter 4</h1><p>Body text.</p>';
      final out = serializeNovelTokens(tokenizeNovelHtml(html));
      expect(out, contains('<h1>'));
      final back = NovelTextLayout(tokenizeNovelHtml(out));
      expect(back.isHeadingBlock(0), isTrue);
    });

    test('re-escapes text that looks like markup', () {
      const html = '<p>if you &lt;3 this, &amp; read on</p>';
      final out = serializeNovelTokens(tokenizeNovelHtml(html));
      // Written back raw, the `<3` would be read as a tag by the next pass, and
      // the rest of the line with it.
      expect(out, contains('&lt;3'));
      expect(
        NovelTextLayout(tokenizeNovelHtml(out)).text,
        'if you <3 this, & read on\n',
      );
    });

    test('a run that loses bold but keeps italic stays well-formed', () {
      const html = '<p><b><i>both</i></b><i>italic only</i></p>';
      final out = serializeNovelTokens(tokenizeNovelHtml(html));
      final back = NovelTextLayout(tokenizeNovelHtml(out));
      expect(back.text, 'bothitalic only\n');
      final second = back.tokens.where((t) => !t.isBreak).elementAt(1);
      expect(second.text, 'italic only');
      expect(second.italic, isTrue);
      expect(second.bold, isFalse);
    });
  });

  group('filterNovelHtml', () {
    test('returns the input untouched when there are no rules', () {
      const html = '<p>Hello</p>';
      expect(filterNovelHtml(html, TextFilterEngine(const [])), html);
    });

    test('produces HTML that lays out as the filtered text', () {
      const html =
          '<p>Story text.</p>'
          '<p>Please support me on Patreon!</p>'
          '<p>More story.</p>';
      final out = filterNovelHtml(html, builtins);
      expect(
        NovelTextLayout(tokenizeNovelHtml(out)).text,
        'Story text.\nMore story.\n',
      );
    });

    test('is stable: filtering twice changes nothing the second time', () {
      const html = '<p>Story.</p><p>Join our discord for more!</p><p>Text.</p>';
      final once = filterNovelHtml(html, builtins);
      expect(filterNovelHtml(once, builtins), once);
    });

    test('leaves a clean chapter byte-for-byte alone', () {
      const html = '<p>He looked at the sea.</p><p>It was calm.</p>';
      expect(filterNovelHtml(html, builtins), html);
    });

    // The report that started this: a chapter ended with two pieces of injected
    // text on one line. Long-pressing one and hitting Hide saved the rule and
    // re-filtered the chapter, and the sentence stayed put - because the rule
    // was anchored to the whole line and the line held more than the sentence.
    test('a hidden sentence is removed from the middle of a line', () {
      const html =
          '<p>If you like it, read at novelsb.com! New chapters daily.</p>';
      final engine = TextFilterEngine([
        TextFilterRule.hiddenSentence('read at novelsb.com!', id: 'h1'),
      ]);
      final text = NovelTextLayout(
        tokenizeNovelHtml(filterNovelHtml(html, engine)),
      ).text;
      expect(text, contains('If you like it'));
      expect(text, contains('New chapters daily.'));
      expect(text, isNot(contains('novelsb.com')));
      // The comma went with the cut: _isSeparator absorbs a comma so an aside
      // removed mid-sentence does not leave "start , end" behind. Sentence
      // terminators are deliberately not absorbed; a comma is.
    });

    test(
      'two sentences hidden from one line both go, and the line survives',
      () {
        const html =
            '<p>If you like it, read at novelsb.com! New chapters daily.</p>';
        final engine = TextFilterEngine([
          TextFilterRule.hiddenSentence('read at novelsb.com!', id: 'h1'),
          TextFilterRule.hiddenSentence('New chapters daily.', id: 'h2'),
        ]);
        final text = NovelTextLayout(
          tokenizeNovelHtml(filterNovelHtml(html, engine)),
        ).text;
        // What is left is still a line with real prose in it, not a collapsed
        // empty paragraph.
        expect(text.trim(), 'If you like it');
      },
    );

    test(
      'hiding the last sentence of a line does not take the stop with it',
      () {
        const html = '<p>Stay with me.</p><p>Read at novelsb.com!</p>';
        final engine = TextFilterEngine([
          TextFilterRule.hiddenSentence('Read at novelsb.com!', id: 'h1'),
        ]);
        final text = NovelTextLayout(
          tokenizeNovelHtml(filterNovelHtml(html, engine)),
        ).text;
        expect(text.trim(), 'Stay with me.');
      },
    );
  });
}
