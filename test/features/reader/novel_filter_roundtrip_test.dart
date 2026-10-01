import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/text_filter.dart';
import 'package:watch_app/features/reader/novel_html.dart';

/// Hiding a sentence re-filters the open chapter, so the round trip has to be
/// honest in two directions: a rule that removes nothing must leave the chapter
/// byte-identical, and one that removes something must not take neighbouring
/// prose with it.
String layoutOf(String html, TextFilterEngine engine) =>
    NovelTextLayout(tokenizeNovelHtml(filterNovelHtml(html, engine))).text;

TextFilterEngine engineFor(List<TextFilterRule> rules) =>
    TextFilterEngine(rules);

void main() {
  // A chapter tail shaped like the real ones: the injected text is two
  // sentences inside ONE paragraph, and LNReader paragraphs often end with a
  // <br> before </p>.
  const html =
      '<p>He put the phone down.</p>'
      '<p>If you like it, read at novelsb.com! New chapters daily.<br></p>'
      '<p>End of chapter.<br></p>';

  group('a rule that matches nothing', () {
    test('leaves the chapter text byte-identical', () {
      // This is what made a hide look broken from the outside: the rule saved,
      // the reader re-filtered, and because the rule never fired the text was
      // exactly as it had been.
      final engine = engineFor([
        TextFilterRule.hiddenSentence('SOMETHING ELSE ENTIRELY', id: 'h1'),
      ]);
      expect(
        layoutOf(html, engine),
        NovelTextLayout(tokenizeNovelHtml(html)).text,
      );
    });
  });

  group('a rule that matches inside a line', () {
    final engine = engineFor([
      TextFilterRule.hiddenSentence('read at novelsb.com!', id: 'h1'),
    ]);
    final text = layoutOf(html, engine);

    test('removes the sentence and keeps its neighbours', () {
      expect(text, isNot(contains('novelsb.com')));
      expect(text, contains('If you like it'));
      expect(text, contains('New chapters daily.'));
    });

    test('leaves the rest of the chapter alone', () {
      expect(text, contains('He put the phone down.'));
      expect(text, contains('End of chapter.'));
    });
  });

  group('re-filtering is idempotent', () {
    test('filtering an already-filtered chapter changes nothing', () {
      final engine = engineFor([
        TextFilterRule.hiddenSentence('read at novelsb.com!', id: 'h1'),
      ]);
      final once = filterNovelHtml(html, engine);
      expect(filterNovelHtml(once, engine), once);
    });

    test('twice through the layout is the same as once', () {
      final engine = engineFor([
        TextFilterRule.hiddenSentence('read at novelsb.com!', id: 'h1'),
      ]);
      final once = filterNovelHtml(html, engine);
      expect(
        NovelTextLayout(tokenizeNovelHtml(filterNovelHtml(once, engine))).text,
        NovelTextLayout(tokenizeNovelHtml(once)).text,
      );
    });
  });

  group('a whole injected paragraph', () {
    test('is removed outright rather than left as a blank line', () {
      final engine = engineFor([
        TextFilterRule.hiddenSentence(
          'If you like it, read at novelsb.com! New chapters daily.',
          id: 'h1',
        ),
      ]);
      final text = layoutOf(html, engine);
      expect(text, isNot(contains('novelsb.com')));
      // What survives is the two real paragraphs; the blank line the trailing
      // <br> leaves is pre-existing and present with no rules at all.
      expect(text.trim(), 'He put the phone down.\nEnd of chapter.');
    });

    test('a paragraph that becomes empty is dropped, not left blank', () {
      const only =
          '<p>He put the phone down.</p><p>READ AT NOVELSB.COM<br></p>';
      final engine = engineFor([
        TextFilterRule.hiddenSentence('READ AT NOVELSB.COM', id: 'h1'),
      ]);
      expect(layoutOf(only, engine).trim(), 'He put the phone down.');
    });
  });

  // The rule-line built-in is the one built-in that has to survive being a
  // whole line of a bigger block, because a source is free to ship the rule
  // and the ad as one <p> separated by a <br> instead of as two paragraphs.
  group('separator lines, through the real chapter pipeline', () {
    final builtins = TextFilterEngine(builtinTextFilterRules);

    test('a rule line in its own paragraph takes the paragraph with it', () {
      const chapter =
          '<p>He sheathed the sword.</p>'
          '<p>-------------------<br></p>'
          '<p>End of chapter.<br></p>';
      expect(
        layoutOf(chapter, builtins).trim(),
        'He sheathed the sword.\nEnd of chapter.',
      );
    });

    test('a rule line sharing a paragraph with the ad still goes', () {
      const chapter =
          '<p>He sheathed the sword.<br>'
          '-------------------<br>'
          'AN: Check out my P@treon For +40 extra Chapters.<br></p>'
          '<p>End of chapter.<br></p>';
      final text = layoutOf(chapter, builtins);
      expect(text, isNot(contains('---')));
      // The heading is its own block, so the rule and the ad both leave and the
      // prose on either side is untouched.
      expect(text, contains('He sheathed the sword.'));
      expect(text, contains('End of chapter.'));
    });

    test('prose that merely contains a dash survives the whole pipeline', () {
      const chapter =
          '<p>"Fine," Tsunade agreed -- her voice softened slightly.</p>'
          '<p>He wrote --- and then stopped.</p>';
      final text = layoutOf(chapter, builtins);
      expect(text, contains('her voice softened slightly.'));
      expect(text, contains('He wrote --- and then stopped.'));
    });
  });
}
